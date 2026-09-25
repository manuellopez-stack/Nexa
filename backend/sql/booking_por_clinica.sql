-- ============================================================================
-- AUTOAGENDAMIENTO WEB POR CLÍNICA
-- ----------------------------------------------------------------------------
-- Cada clínica que ofrece reserva web pública tiene un booking_slug: el
-- identificador corto que va en la URL de la página de reserva
-- (/reservar/<slug>, o reservar.imagenda.cl/<slug>). El backend lo usa para
-- resolver el clinic_id y limitar cupo, pacientes y citas a esa clínica.
-- Una clínica sin booking_slug no aparece en la lista pública ni acepta
-- reservas web.
--
-- Alcance: SOLO agrega la columna y fija el slug de las dos clínicas
-- actuales. No toca ninguna otra columna ni fila.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / update por id), se puede volver a correr.
--   Requiere que clinics.sql ya se haya corrido antes.
-- ============================================================================

alter table public.clinics
  add column if not exists booking_slug text unique;

update public.clinics
  set booking_slug = 'milmed'
  where id = '17f51a50-e6da-47a7-b8c0-0cb766abf0e9';

update public.clinics
  set booking_slug = 'apsa'
  where id = 'b69403c3-4e71-40f3-9c38-0d47a4b1d067';
