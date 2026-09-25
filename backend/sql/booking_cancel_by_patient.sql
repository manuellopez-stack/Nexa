-- ============================================================================
-- AUTOAGENDAMIENTO WEB — cancelación por el paciente
-- ----------------------------------------------------------------------------
-- Cada reserva web lleva un cancel_token secreto: el paciente recibe el
-- enlace https://reservar.imagenda.cl/cancelar/<token> al reservar y con él
-- puede cancelar su hora sin iniciar sesión (hasta BOOKING_MIN_LEAD_MINUTES
-- antes de la hora, ver server.mjs).
--
--   cancel_token  secreto del enlace de cancelación (solo reservas web)
--   cancelled_by  quién canceló: 'paciente' cuando fue por ese enlace
--   cancelled_at  cuándo se canceló
--
-- Cowork ya aplicó estas columnas en Supabase; este archivo las deja
-- documentadas. El backend usa la SERVICE ROLE KEY, así que no requiere RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS), se puede volver a correr.
--   Requiere que appointments.sql ya se haya corrido antes.
-- ============================================================================

alter table public.appointments
  add column if not exists cancel_token text unique;

alter table public.appointments
  add column if not exists cancelled_by text;

alter table public.appointments
  add column if not exists cancelled_at timestamptz;
