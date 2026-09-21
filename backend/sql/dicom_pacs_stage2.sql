-- ============================================================================
-- DICOM/PACS — Etapa 4 (paso 2): clinic_id en orthanc_studies
-- ----------------------------------------------------------------------------
-- Mismo patrón que las migraciones anteriores de multi-clínica (clinics.sql /
-- clinics_stage2.sql / clinics_stage3.sql): columna clinic_id NULLABLE que
-- referencia clinics.id, con índice parcial.
--
-- A diferencia de esas migraciones, NO hay backfill acá: orthanc_studies solo
-- tiene sentido asignarle clinic_id a partir de ahora, cuando syncOrthanc.mjs
-- empiece a leer la label del estudio en Orthanc (ver Etapa 4, plugin
-- MultitenantDicom) y resolverla contra clinics.id. Los estudios ya
-- registrados antes de este cambio no tienen ninguna label que mapear, así
-- que quedan con clinic_id null a propósito (mismo criterio que
-- accession_number en dicom_pacs_stage1.sql).
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS), se puede volver a correr sin duplicar
--   nada ni tocar filas existentes.
-- ============================================================================

alter table public.orthanc_studies
  add column if not exists clinic_id uuid references public.clinics(id) on delete set null;

create index if not exists orthanc_studies_clinic_id_idx
  on public.orthanc_studies (clinic_id) where clinic_id is not null;
