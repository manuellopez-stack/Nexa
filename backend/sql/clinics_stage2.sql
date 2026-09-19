-- ============================================================================
-- MULTI-CLÍNICA — Etapa 2: clinic_id opcional en laboratorio, imagenología,
-- dental, documentos, ai_analyses y cobros
-- ----------------------------------------------------------------------------
-- Mismo patrón que clinics.sql (Etapa 1): columna clinic_id NULLABLE que
-- referencia clinics.id, índice parcial, backfill al único centro existente
-- (Centro Médico MILMED). No cambia nada en server.mjs ni en el frontend --
-- el backend sigue sin leer/escribir clinic_id todavía.
--
-- Alcance: se agrega clinic_id solo a las tablas "raíz" de cada módulo (una
-- fila por orden/paciente/documento), NO a catálogos compartidos entre
-- clínicas ni a tablas hijas/join que ya heredan la clínica a través de su
-- orden:
--
--   laboratorio   -> lab_orders            (NO: lab_panels, lab_parameters,
--                                            lab_order_panels, lab_results)
--   imagenología  -> imaging_orders        (NO: imaging_types,
--                                            imaging_order_types, imaging_files)
--   dental        -> dental_orders         (NO: dental_procedures,
--                                            dental_order_procedures, dental_results)
--   documentos    -> documents
--   ai_analyses   -> ai_analyses
--   cobros        -> billing_items, billing_orders, payments
--
-- Nota sobre billing_items: aunque tiene forma de catálogo (category +
-- item_id + price), cada centro define sus propios precios/prestaciones, así
-- que NO es compartido entre clínicas -- por eso lleva clinic_id igual que
-- las tablas raíz de cada módulo.
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS
-- (las tablas ya tienen su política deny-all para anon).
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / backfill solo sobre clinic_id nulo), se
--   puede volver a correr sin duplicar nada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. clinic_id opcional en las tablas raíz de cada módulo
-- ----------------------------------------------------------------------------
alter table public.lab_orders
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.imaging_orders
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.dental_orders
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.documents
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.ai_analyses
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.billing_items
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.billing_orders
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

alter table public.payments
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

-- ----------------------------------------------------------------------------
-- 2. Índices parciales (mismo criterio que patients/appointments/rooms)
-- ----------------------------------------------------------------------------
create index if not exists lab_orders_clinic_id_idx
  on public.lab_orders (clinic_id) where clinic_id is not null;

create index if not exists imaging_orders_clinic_id_idx
  on public.imaging_orders (clinic_id) where clinic_id is not null;

create index if not exists dental_orders_clinic_id_idx
  on public.dental_orders (clinic_id) where clinic_id is not null;

create index if not exists documents_clinic_id_idx
  on public.documents (clinic_id) where clinic_id is not null;

create index if not exists ai_analyses_clinic_id_idx
  on public.ai_analyses (clinic_id) where clinic_id is not null;

create index if not exists billing_items_clinic_id_idx
  on public.billing_items (clinic_id) where clinic_id is not null;

create index if not exists billing_orders_clinic_id_idx
  on public.billing_orders (clinic_id) where clinic_id is not null;

create index if not exists payments_clinic_id_idx
  on public.payments (clinic_id) where clinic_id is not null;

-- ----------------------------------------------------------------------------
-- 3. Backfill: clinic_id del centro actual en todas las filas existentes
-- ----------------------------------------------------------------------------
-- Mismo criterio que clinics.sql: toma el centro más antiguo de clinics (hoy
-- el único, Centro Médico MILMED) y lo asigna solo a las filas que todavía
-- no tienen clinic_id. Repetible sin efecto en corridas posteriores.
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

  update public.lab_orders
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.imaging_orders
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.dental_orders
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.documents
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.ai_analyses
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.billing_items
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.billing_orders
    set clinic_id = v_clinic_id
    where clinic_id is null;

  update public.payments
    set clinic_id = v_clinic_id
    where clinic_id is null;
end $$;
