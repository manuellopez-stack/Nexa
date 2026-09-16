-- ============================================================================
-- CORREO DEL PACIENTE — Etapa 4 del plan de autoagendamiento web
-- ----------------------------------------------------------------------------
-- Agrega un correo opcional a la ficha del paciente, para poder mandarle la
-- confirmación de su reserva hecha desde /reservar. Es opcional en todo el
-- sistema -- un paciente sin correo simplemente no recibe confirmación.
--
-- El backend usa la SERVICE ROLE KEY, así que la política RLS de patients no
-- se ve afectada por esto.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS), se puede volver a correr.
-- ============================================================================

alter table public.patients
  add column if not exists email text;
