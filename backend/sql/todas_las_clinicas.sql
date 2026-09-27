-- ============================================================================
-- EQUIPO IMAGENDA: acceso a pacientes de TODAS las clínicas
-- ----------------------------------------------------------------------------
-- staff_profiles.all_clinics = true -> un miembro activo del equipo Imagenda
-- puede elegir la clínica con la que trabaja (selector de clínica en la app,
-- header X-Clinic-Id). El backend solo lo respeta si además
-- is_platform_admin = true; para cualquier otra cuenta el header se ignora.
--
-- Alcance: agrega una columna nueva (boolean NOT NULL DEFAULT false: todas
-- las filas existentes quedan en false) y la activa para los Administradores
-- totales actuales. No toca ninguna otra columna.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / update que solo pone true).
-- ============================================================================

alter table public.staff_profiles
  add column if not exists all_clinics boolean not null default false;

update public.staff_profiles
   set all_clinics = true
 where is_platform_admin = true
   and platform_role = 'admin';

-- Verificación
select id, email, platform_role, clinic_id, all_clinics
  from public.staff_profiles
 where is_platform_admin or platform_role is not null;
