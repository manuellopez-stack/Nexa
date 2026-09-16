-- ============================================================================
-- AUTOAGENDAMIENTO WEB — Etapa 1 (backend)
-- ----------------------------------------------------------------------------
-- Agrega una forma de distinguir las citas creadas por el propio paciente
-- desde la página pública de reserva ('web'), de las creadas por el personal
-- ('staff', el valor por defecto para todo lo que ya existe).
--
-- Una cita con origin = 'web' nace sin room_id (sala pendiente de asignar);
-- el personal la completa desde la pantalla de Agendamiento.
--
-- El backend usa la SERVICE ROLE KEY, así que la política RLS de appointments
-- (deny-all para anon) no se ve afectada por esto.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS), se puede volver a correr.
--   Requiere que appointments.sql ya se haya corrido antes.
-- ============================================================================

alter table public.appointments
  add column if not exists origin text not null default 'staff'
  check (origin in ('staff', 'web'));

create index if not exists appointments_origin_idx
  on public.appointments (origin);
