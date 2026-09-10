-- ============================================================================
-- AGENDA DE CITAS
-- ----------------------------------------------------------------------------
-- Fase Citas del dashboard. Hasta ahora una "cita" no era una entidad: eran
-- campos sueltos en la tabla patients (time, room, exam, status, doctor) y la
-- vista "Pacientes del día" (/patients/today) leía patients ordenada por time.
-- No había fecha real (solo un string de hora) ni historial de citas.
--
-- Esta tabla convierte la cita en su propia entidad, con:
--   - scheduled_at real (timestamptz), no un string de hora
--   - room_id -> catálogo rooms (la relación sala <-> cita que el SQL de Salas
--     dejó pendiente para esta entrega)
--   - status con ciclo de vida completo
--   - varias citas por paciente (historial)
--
-- Qué cambia en el backend (server.mjs) al correr esto:
--   - GET  /appointments            -> lista la agenda (por fecha / sala / estado)
--   - POST /appointments            -> crear cita
--   - PATCH /appointments/:id       -> reprogramar, cambiar sala/estado, cancelar
--   - GET  /patients/today          -> pasa a leer de appointments (con fallback:
--     si esta tabla no existe todavía, o no hay citas para hoy, sigue leyendo
--     patients.time como antes, así la vista no se rompe entre el deploy y el Run).
--   - GET  /patients                -> lista liviana (id/nombre/rut) para el
--     selector de "nueva cita" de la agenda.
--
-- Dos reglas de negocio de la agenda se aplican SOLO en el backend (no como
-- constraints en esta tabla, para no bloquear cargas manuales ni el backfill):
--   1. Puente cita -> ficha: al pasar una cita a 'en_atencion' o 'atendida', el
--      backend actualiza también patients.status ("En atención" / "Atendido"),
--      para que el dashboard y "Pacientes del día" no queden desincronizados.
--   2. Choque de agenda: POST/PATCH rechazan (409) una cita que se solape en el
--      tiempo con otra cita activa en la misma sala o del mismo profesional.
--
-- El backend usa la SERVICE ROLE KEY, así que la política RLS de más abajo no lo
-- afecta: RLS habilitado sin política (deny-all para anon), igual que
-- rooms / lab / dental / ai_analyses.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / backfill sólo si la tabla está vacía).
--   Requiere que rooms.sql ya se haya corrido (FK a public.rooms).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabla
-- ----------------------------------------------------------------------------
create table if not exists public.appointments (
  id           uuid primary key default gen_random_uuid(),
  patient_id   bigint not null references public.patients(id) on delete cascade,
  room_id      uuid references public.rooms(id) on delete set null,
  scheduled_at timestamptz not null,
  duration_min integer not null default 30 check (duration_min > 0),
  status       text not null default 'programada'
               check (status in (
                 'programada', 'en_espera', 'en_atencion',
                 'atendida', 'cancelada', 'no_asistio'
               )),
  professional text,          -- profesional a cargo (patients.doctor en el backfill)
  reason       text,          -- motivo / examen (patients.exam en el backfill)
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Agenda del día: el filtro habitual es por rango de scheduled_at.
create index if not exists appointments_scheduled_at_idx
  on public.appointments (scheduled_at);

create index if not exists appointments_patient_id_idx
  on public.appointments (patient_id);

create index if not exists appointments_room_id_idx
  on public.appointments (room_id) where room_id is not null;

create index if not exists appointments_status_idx
  on public.appointments (status);

-- ----------------------------------------------------------------------------
-- 2. RLS (denegar acceso directo con anon key; el backend usa service role)
-- ----------------------------------------------------------------------------
alter table public.appointments enable row level security;

-- ----------------------------------------------------------------------------
-- 3. Backfill desde patients
-- ----------------------------------------------------------------------------
-- Genera una cita por cada paciente de la tabla patients, sobre la fecha de HOY
-- (patients se venía usando como "la agenda del día"). Sólo corre si la tabla
-- appointments está vacía, así volver a correr el archivo no duplica.
--
-- Mapeos:
--   scheduled_at -> HOY (día local de Chile) + patients.time, interpretado como
--                   hora de Chile y guardado como timestamptz. Se usa
--                   timezone('America/Santiago', now()), NO current_date, porque
--                   el servidor de Postgres corre en UTC y una cita de la noche
--                   quedaría con la fecha del día siguiente.
--   room_id      -> rooms.id de la sala cuyo nombre calza con patients.room
--   professional -> patients.doctor
--   reason       -> patients.exam
--   status       -> equivalente snake_case del string actual (ver CASE abajo)
--
-- NOTA sobre el cast de patients.time: se asume text ("09:30") o time. Si en tu
-- proyecto es timestamptz, cambia `p.time::text::time` por `p.time::time`.

-- Aviso previo: estados de patients.status que el CASE de más abajo NO reconoce
-- y que, por lo tanto, se guardarán como 'programada'. Aparece en la salida del
-- SQL Editor al correr; si sale algún estado inesperado, agrégalo al CASE.
do $$
declare
  unmapped text;
begin
  select string_agg(distinct s, ', ' order by s) into unmapped
  from (select btrim(coalesce(status, '')) as s from public.patients) x
  where s <> ''
    and s not in (
      'Programado', 'En atención', 'Esperando', 'Atendido',
      'Cancelada', 'No asistió', 'Pendiente de validación'
    );
  if unmapped is not null then
    raise notice 'Backfill de citas: estados de patients.status sin mapeo explícito (se guardan como "programada"): %', unmapped;
  end if;
end $$;

insert into public.appointments
  (patient_id, room_id, scheduled_at, professional, reason, status)
select
  p.id,
  r.id,
  (
    (
      timezone('America/Santiago', now())::date
      + coalesce(nullif(btrim(p.time::text), '')::time, time '09:00')
    ) at time zone 'America/Santiago'
  ),
  nullif(btrim(p.doctor), ''),
  nullif(btrim(p.exam), ''),
  case btrim(coalesce(p.status, ''))
    when 'En atención'           then 'en_atencion'
    when 'Esperando'             then 'en_espera'
    when 'Atendido'              then 'atendida'
    when 'Cancelada'             then 'cancelada'
    when 'No asistió'            then 'no_asistio'
    -- "Pendiente de validación": el paciente YA fue atendido y lo que falta es
    -- que un profesional valide su examen/resultado (mismo concepto de
    -- validación que documentos y órdenes en el resto del sistema). La cita en
    -- sí está cumplida -> 'atendida'. La validación pendiente se sigue viendo
    -- en su módulo correspondiente, no en el estado de la cita.
    when 'Pendiente de validación' then 'atendida'
    else 'programada'
  end
from public.patients p
left join public.rooms r
  on btrim(lower(r.name)) = btrim(lower(p.room))
where not exists (select 1 from public.appointments);
