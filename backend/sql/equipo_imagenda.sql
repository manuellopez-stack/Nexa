-- ============================================================================
-- EQUIPO IMAGENDA: tipo de acceso y desactivación en staff_profiles
-- ----------------------------------------------------------------------------
-- El equipo interno de la plataforma son las cuentas con
-- is_platform_admin = true. Desde esta migración cada una tiene además un
-- tipo de acceso:
--
--   - platform_role = 'admin'   -> Administrador total (crea/edita clínicas y
--                                  gestiona al equipo Imagenda).
--   - platform_role = 'soporte' -> Soporte: ve todo, pero no crea/edita
--                                  clínicas ni gestiona al equipo.
--
-- is_platform_admin sigue en true para ambos tipos. Al quitarle el acceso a
-- alguien (POST /platform-team/:id/revoke) queda is_platform_admin = false,
-- disabled_at con la fecha y platform_role se conserva para saber que fue
-- del equipo (y poder reactivarlo).
--
-- Alcance: SOLO agrega dos columnas nuevas (nulas) y llena platform_role en
-- los admins de plataforma que ya existen. No toca ninguna otra columna.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / update solo donde platform_role es nulo).
-- ============================================================================

alter table public.staff_profiles
  add column if not exists platform_role text
    check (platform_role in ('admin', 'soporte'));

alter table public.staff_profiles
  add column if not exists disabled_at timestamptz;

update public.staff_profiles
   set platform_role = 'admin'
 where is_platform_admin = true
   and platform_role is null;

-- Verificación: los admins de plataforma actuales, ahora con platform_role.
select id, email, clinic_id, is_platform_admin, platform_role, disabled_at
  from public.staff_profiles
 where is_platform_admin or platform_role is not null;
