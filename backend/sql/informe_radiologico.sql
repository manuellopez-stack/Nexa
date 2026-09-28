-- ============================================================================
-- INFORME RADIOLÓGICO: el médico escribe y firma el informe dentro de Imagenda
-- ----------------------------------------------------------------------------
-- 1. staff_profiles.rut / specialty: datos de firma del médico (nulos). Se
--    copian al informe al firmar, así un cambio posterior no altera informes
--    ya firmados.
-- 2. documents.validated_by / validation_note:
--      - validated_by: email de quien aprobó (o rechazó) el documento. Lo
--        llenan tanto la firma del informe como la validación normal.
--      - validation_note: nota del sistema al rechazar sin pedir corrección
--        (p. ej. "Reemplazado por versión corregida"). NO es correction_reason:
--        esa columna significa "corrección pendiente" y cuenta en Devueltos.
-- 3. imaging_reports: borradores y versiones firmadas del informe de cada
--    orden de imagenología. document_id apunta al PDF generado en documents;
--    su tipo se toma de documents.id (no está fijado en los SQL del repo).
--
-- Alcance: solo agrega columnas nulas y una tabla nueva. No modifica datos.
-- El backend usa la SERVICE ROLE KEY: RLS activado sin políticas = nadie más
-- (anon/authenticated) puede leer ni escribir, igual que las demás tablas.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS en todo).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Datos de firma en staff_profiles
-- ----------------------------------------------------------------------------
alter table public.staff_profiles
  add column if not exists rut text;

alter table public.staff_profiles
  add column if not exists specialty text;

-- ----------------------------------------------------------------------------
-- 2. Quién validó y nota de validación en documents
-- ----------------------------------------------------------------------------
alter table public.documents
  add column if not exists validated_by text;

alter table public.documents
  add column if not exists validation_note text;

-- ----------------------------------------------------------------------------
-- 3. imaging_reports
-- ----------------------------------------------------------------------------
create table if not exists public.imaging_reports (
  id                uuid primary key default gen_random_uuid(),
  clinic_id         uuid references public.clinics(id) on delete set null,
  imaging_order_id  uuid not null references public.imaging_orders(id) on delete cascade,
  patient_id        bigint references public.patients(id) on delete set null,
  clinical_history  text,
  technique         text,
  findings          text,
  impression        text,
  status            text not null default 'borrador'
                    check (status in ('borrador', 'firmado', 'reemplazado')),
  version           int not null default 1,
  created_by        uuid references public.staff_profiles(id) on delete set null,
  signed_by         uuid references public.staff_profiles(id) on delete set null,
  signed_at         timestamptz,
  -- Copia de los datos de firma al momento de firmar.
  signer_name       text,
  signer_rut        text,
  signer_specialty  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- document_id con el mismo tipo que documents.id (uuid o bigint).
do $$
declare
  v_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_type
  from pg_attribute a
  where a.attrelid = 'public.documents'::regclass
    and a.attname = 'id'
    and not a.attisdropped;

  execute format(
    'alter table public.imaging_reports add column if not exists document_id %s references public.documents(id) on delete set null',
    v_type
  );
end $$;

create index if not exists imaging_reports_imaging_order_id_idx
  on public.imaging_reports (imaging_order_id);

-- Una sola versión con cada número por orden, y un solo borrador a la vez.
create unique index if not exists imaging_reports_order_version_key
  on public.imaging_reports (imaging_order_id, version);

create unique index if not exists imaging_reports_one_draft_idx
  on public.imaging_reports (imaging_order_id) where status = 'borrador';

alter table public.imaging_reports enable row level security;

-- Verificación
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'imaging_reports'
 order by ordinal_position;
