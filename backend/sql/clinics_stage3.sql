-- ============================================================================
-- MULTI-CLÍNICA — Etapa 3 (paso 1): clinic_id opcional en staff_profiles
-- ----------------------------------------------------------------------------
-- Mismo patrón que clinics.sql / clinics_stage2.sql: columna clinic_id
-- NULLABLE que referencia clinics.id, índice parcial, backfill al único
-- centro existente (Centro Médico MILMED). No cambia nada en server.mjs ni
-- en el frontend -- el backend sigue sin leer/escribir clinic_id todavía.
--
-- staff_profiles NO es tabla puente: cada persona del staff pertenece a un
-- solo centro, así que clinic_id va directo en la fila (mismo criterio que
-- patients/appointments/rooms en Etapa 1), no en una tabla de unión.
--
-- Alcance: SOLO agrega la columna nueva y hace backfill sobre ella. No toca,
-- edita ni borra ninguna otra columna ni fila existente de staff_profiles.
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / backfill solo sobre clinic_id nulo), se
--   puede volver a correr sin duplicar nada ni tocar datos existentes.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. clinic_id opcional en staff_profiles
-- ----------------------------------------------------------------------------
alter table public.staff_profiles
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

-- ----------------------------------------------------------------------------
-- 2. Índice parcial (mismo criterio que las tablas anteriores)
-- ----------------------------------------------------------------------------
create index if not exists staff_profiles_clinic_id_idx
  on public.staff_profiles (clinic_id) where clinic_id is not null;

-- ----------------------------------------------------------------------------
-- 3. Backfill: clinic_id del centro actual en todo el staff existente
-- ----------------------------------------------------------------------------
-- Mismo criterio que las etapas anteriores: toma el centro más antiguo de
-- clinics (hoy el único, Centro Médico MILMED) y lo asigna solo a las filas
-- que todavía no tienen clinic_id. No modifica ninguna otra columna.
-- Repetible sin efecto en corridas posteriores.
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

  update public.staff_profiles
    set clinic_id = v_clinic_id
    where clinic_id is null;
end $$;
