-- ============================================================================
-- DICOM/PACS (Orthanc) — Etapa 2.5b: soporte para el script de sincronización
-- ----------------------------------------------------------------------------
-- Complemento a dicom_pacs_stage1.sql (ya aplicado). Necesario para que
-- syncOrthanc.mjs sea seguro de reintentar sin perder ni duplicar nada:
--
--   1. orthanc_sync_state: fila única con el último Seq de /changes de
--      Orthanc que se procesó con éxito. Reemplaza el enfoque original de
--      "limpiar /changes al final de cada corrida": con un cursor persistente
--      no se puede perder un estudio que llegue justo durante la corrida (con
--      DELETE /changes sí era posible: un cambio nuevo entre el último GET y
--      el DELETE se borraba sin haberse visto nunca).
--
--   2. imaging_files.orthanc_instance_id: para poder saber, instancia por
--      instancia, cuáles ya se copiaron a Storage antes de un fallo a mitad
--      de estudio. Sin esto, reintentar un estudio que falló en la instancia
--      3 de 5 volvería a subir las 2 primeras, duplicándolas. Queda NULL para
--      los archivos subidos a mano desde la app (no vienen de Orthanc).
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente, se puede volver a correr sin duplicar nada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Cursor persistente de /changes de Orthanc (una sola fila, id = 1)
-- ----------------------------------------------------------------------------
create table if not exists public.orthanc_sync_state (
  id         smallint primary key default 1,
  last_seq   bigint not null default 0,
  updated_at timestamptz not null default now(),
  constraint orthanc_sync_state_singleton check (id = 1)
);

insert into public.orthanc_sync_state (id, last_seq)
values (1, 0)
on conflict (id) do nothing;

alter table public.orthanc_sync_state enable row level security;

-- ----------------------------------------------------------------------------
-- 2. imaging_files.orthanc_instance_id: idempotencia por instancia al copiar
--    un estudio de Orthanc
-- ----------------------------------------------------------------------------
alter table public.imaging_files
  add column if not exists orthanc_instance_id text;

create index if not exists imaging_files_orthanc_instance_idx
  on public.imaging_files (order_id, orthanc_instance_id)
  where orthanc_instance_id is not null;
