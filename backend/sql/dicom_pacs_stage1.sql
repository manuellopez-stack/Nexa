-- ============================================================================
-- DICOM/PACS (Orthanc) — Etapa 2.5: base de datos
-- ----------------------------------------------------------------------------
-- Primer paso de la integración con Orthanc (ver plan-dicom-pacs.md, sección
-- "Diseño de integración con Imagenda"). Solo schema: no toca Orthanc, el
-- cron de sincronización, la pantalla de reconciliación ni el frontend.
--
-- Qué agrega:
--   1. accession_number en imaging_orders: identificador corto que se le
--      manda a Orthanc/el equipo de imagenología para poder casar después el
--      estudio DICOM recibido con la orden de Imagenda que lo originó.
--      Formato: 'IMD' || el número de una secuencia dedicada, con padding a
--      6 dígitos -- ej. IMD000001, IMD000002... 9 caracteres, muy por debajo
--      del máximo de 16 del campo AccessionNumber del estándar DICOM.
--      No incluye clinic_id todavía (el resto del sistema tampoco lo usa de
--      forma consistente aún); se puede sumar más adelante si hace falta.
--   2. orthanc_studies: un registro por estudio DICOM recibido en Orthanc,
--      pendiente de casar (o ya casado / no casado) con una imaging_order.
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS
-- (orthanc_studies queda con RLS habilitado sin política, deny-all para
-- anon, igual que el resto de las tablas internas).
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / guards sobre pg_constraint), se puede
--   volver a correr sin duplicar nada. No hay backfill: las órdenes viejas
--   quedan con accession_number null a propósito.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Secuencia dedicada para accession_number
-- ----------------------------------------------------------------------------
create sequence if not exists public.imaging_accession_seq;

-- ----------------------------------------------------------------------------
-- 2. accession_number: identificador corto, único, nullable para órdenes
--    viejas (las creadas antes de este cambio, o si el backend insertara sin
--    pasar por el default de esta columna)
-- ----------------------------------------------------------------------------
alter table public.imaging_orders
  add column if not exists accession_number text;

alter table public.imaging_orders
  alter column accession_number
  set default ('IMD' || lpad(nextval('public.imaging_accession_seq')::text, 6, '0'));

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'imaging_orders_accession_number_key'
  ) then
    alter table public.imaging_orders
      add constraint imaging_orders_accession_number_key unique (accession_number);
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 3. orthanc_studies: un registro por estudio DICOM recibido en Orthanc
-- ----------------------------------------------------------------------------
create table if not exists public.orthanc_studies (
  id                         uuid primary key default gen_random_uuid(),
  orthanc_study_id           text not null unique,
  accession_number_received  text,
  patient_name_received      text,
  patient_id_received        text,
  study_date                 text,
  status                     text not null default 'pending'
                             check (status in ('pending', 'linked', 'unlinked')),
  linked_order_id            uuid references public.imaging_orders(id) on delete set null,
  linked_at                  timestamptz,
  created_at                 timestamptz not null default now()
);

-- Soporta la futura pantalla de reconciliación (estudios pendientes de casar)
-- sin tocarla todavía.
create index if not exists orthanc_studies_pending_idx
  on public.orthanc_studies (created_at) where status = 'pending';

create index if not exists orthanc_studies_linked_order_id_idx
  on public.orthanc_studies (linked_order_id) where linked_order_id is not null;

-- ----------------------------------------------------------------------------
-- 4. RLS
-- ----------------------------------------------------------------------------
alter table public.orthanc_studies enable row level security;
