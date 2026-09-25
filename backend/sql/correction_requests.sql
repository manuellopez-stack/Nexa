-- ============================================================================
-- VALIDACIÓN — "Pedir corrección" (etapa 2 del rediseño, paso 2)
-- ----------------------------------------------------------------------------
-- Un validador (médico o administrador) puede devolver un informe para que se
-- corrija, con un motivo obligatorio. Mientras correction_reason no sea nulo,
-- el ítem está "devuelto para corrección":
--
--   documents      validation_status 'rechazado' + correction_reason
--                  (incluye los informes de imagenología; la orden vuelve a
--                  'realizado' para que se vincule un informe corregido)
--   lab_orders     vuelve de 'completado' a 'en_proceso'
--   dental_orders  vuelve de 'realizado' a 'ordenado'
--
-- Los tres campos se limpian cuando el ítem vuelve a quedar listo para
-- validar (documento guardado de nuevo como 'pendiente', laboratorio de
-- vuelta en 'completado', dental de vuelta en 'realizado').
--
--   correction_reason        motivo escrito por quien pidió la corrección
--   correction_requested_at  cuándo se pidió
--   correction_requested_by  correo de quien la pidió
--
-- Cowork ya aplicó estas columnas en Supabase; este archivo las deja
-- documentadas. El backend usa la SERVICE ROLE KEY, así que no requiere RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS), se puede volver a correr.
-- ============================================================================

alter table public.documents
  add column if not exists correction_reason text;
alter table public.documents
  add column if not exists correction_requested_at timestamptz;
alter table public.documents
  add column if not exists correction_requested_by text;

alter table public.lab_orders
  add column if not exists correction_reason text;
alter table public.lab_orders
  add column if not exists correction_requested_at timestamptz;
alter table public.lab_orders
  add column if not exists correction_requested_by text;

alter table public.dental_orders
  add column if not exists correction_reason text;
alter table public.dental_orders
  add column if not exists correction_requested_at timestamptz;
alter table public.dental_orders
  add column if not exists correction_requested_by text;
