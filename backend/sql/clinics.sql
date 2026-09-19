-- ============================================================================
-- MULTI-CLÍNICA — Etapa 1: catálogo de centros + clinic_id opcional
-- ----------------------------------------------------------------------------
-- Primer paso del plan multi-clínica: agrega la tabla clinics (catálogo de
-- centros) y una columna clinic_id NULLABLE en patients, appointments y rooms,
-- apuntando a clinics.id. Es opcional en todo el sistema -- ninguna fila
-- existente ni ningún endpoint actual se rompe por esta migración: el backend
-- de hoy simplemente no lee ni escribe clinic_id todavía.
--
-- Alcance de esta entrega (Etapa 1): SOLO schema + backfill. No cambia nada
-- en server.mjs ni en el frontend -- eso queda para la etapa siguiente, cuando
-- se decida cómo se selecciona/filtra por clínica.
--
-- El backend de Nexa usa la SERVICE ROLE KEY, así que la política RLS de más
-- abajo no lo afecta: solo bloquea el acceso directo con la anon key. Se deja
-- RLS habilitado sin política (deny-all para anon), igual que rooms / lab /
-- dental / ai_analyses.
--
-- ANTES DE CORRER: reemplaza el nombre y la dirección del centro actual en el
-- INSERT de la sección 3 (busca los placeholders <<...>>).
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / backfill solo sobre filas con clinic_id
--   nulo), se puede volver a correr sin duplicar nada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabla clinics
-- ----------------------------------------------------------------------------
create table if not exists public.clinics (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text,
  status     text not null default 'activa'
             check (status in ('activa', 'inactiva')),
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 2. RLS (denegar acceso directo con anon key; el backend usa service role)
-- ----------------------------------------------------------------------------
alter table public.clinics enable row level security;

-- ----------------------------------------------------------------------------
-- 3. clinic_id opcional en patients / appointments / rooms
-- ----------------------------------------------------------------------------
alter table public.patients
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.appointments
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.rooms
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

create index if not exists patients_clinic_id_idx
  on public.patients (clinic_id) where clinic_id is not null;

create index if not exists appointments_clinic_id_idx
  on public.appointments (clinic_id) where clinic_id is not null;

create index if not exists rooms_clinic_id_idx
  on public.rooms (clinic_id) where clinic_id is not null;

-- ----------------------------------------------------------------------------
-- 4. Seed: el centro actual como primera fila de clinics
-- ----------------------------------------------------------------------------
-- Solo inserta si clinics está vacía, así volver a correr el archivo no crea
-- centros duplicados. Reemplaza los placeholders antes de correr.
insert into public.clinics (name, address, status)
select 'Centro Médico MILMED', 'O''Higgins Oriente 251, San Bernardo', 'activa'
where not exists (select 1 from public.clinics);

-- ----------------------------------------------------------------------------
-- 5. Backfill: clinic_id del centro actual en todas las filas existentes
-- ----------------------------------------------------------------------------
-- Toma el centro más antiguo de clinics (el insertado en el paso 4) y lo
-- asigna solo a las filas que todavía no tienen clinic_id, en las tres tablas.
-- Repetible: en una segunda corrida no hay filas con clinic_id nulo, así que
-- los UPDATE no tocan nada.
do $$
declare
  v_clinic_id uuid;
begin
  select id into v_clinic_id
  from public.clinics
  order by created_at asc
  limit 1;

  if v_clinic_id is null then
    raise notice 'Backfill de clinic_id: no hay ninguna fila en clinics todavía, se omite.';
    return;
  end if;

  update public.patients
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.appointments
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.rooms
    set clinic_id = v_clinic_id
    where clinic_id is null;
end $$;
