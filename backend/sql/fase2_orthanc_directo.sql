-- ============================================================================
-- Servidor de imágenes — Fase 2A: imágenes servidas directo desde Orthanc
-- ----------------------------------------------------------------------------
-- Hasta ahora, vincular un estudio de Orthanc a una orden copiaba cada
-- instancia a Storage (imaging_files.dicom_path / png_path) y borraba el
-- estudio de Orthanc. Desde la Fase 2A el estudio se queda en Orthanc y
-- imaging_files solo guarda la referencia (orthanc_instance_id); el backend
-- sirve el DICOM y la vista previa con URLs firmadas (/imaging-files/:id/...).
--
-- Qué cambia:
--   1. dicom_path deja de ser obligatorio: las filas de Orthanc lo tienen en
--      NULL. (La definición original de imaging_files no está en backend/sql;
--      si la columna ya era nullable, este paso no hace nada.)
--   2. Serie y orden de cada instancia, leídos de Orthanc al vincular, para
--      que GET .../images devuelva las imágenes ordenadas por serie y número
--      de instancia y marque la primera de cada serie (miniatura):
--        orthanc_series_id        ID interno de Orthanc de la serie
--        orthanc_series_number    SeriesNumber (0020,0011), puede venir vacío
--        orthanc_instance_number  InstanceNumber (0020,0013), puede venir vacío
--      Quedan NULL en las filas antiguas (copiadas a Storage o subidas a mano).
--
-- Las filas antiguas no se tocan: siguen sirviéndose desde Storage.
--
-- Orden de despliegue: correr ESTE archivo en Supabase ANTES de desplegar el
-- backend de la rama fase2-orthanc-directo (el vínculo inserta estas columnas).
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (DROP NOT NULL / IF NOT EXISTS), se puede volver a correr.
-- ============================================================================

-- 1. dicom_path opcional (NULL = la imagen vive en Orthanc)
alter table public.imaging_files
  alter column dicom_path drop not null;

-- 2. Serie y orden de la instancia en Orthanc
alter table public.imaging_files
  add column if not exists orthanc_series_id text;

alter table public.imaging_files
  add column if not exists orthanc_series_number integer;

alter table public.imaging_files
  add column if not exists orthanc_instance_number integer;
