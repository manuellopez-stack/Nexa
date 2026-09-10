-- ============================================================================
-- REGISTRO DE ANÁLISIS DE IA
-- ----------------------------------------------------------------------------
-- Fase 2 del dashboard. Hasta ahora las métricas "Documentos analizados por IA"
-- y "Documentos sin analizar" eran falsas: server.mjs devolvía
-- totalAnalyzedDocuments = totalDocuments y documentsAwaitingAnalysis = 0.
--
-- Esta tabla es un log de cada operación de IA sobre un paciente/documento.
-- El dashboard cuenta DOCUMENTOS DISTINTOS (patient_id + doc_key), no cada
-- re-análisis: volver a analizar el mismo PDF, o hacerle 5 preguntas, cuenta 1.
--
-- Operaciones que se registran (server.mjs):
--   'document_analysis' -> POST /patients/:id/documents/analyze   (análisis de PDF)
--   'document_ask'      -> POST /patients/:id/documents/:filename/ask
--   'patient_summary'   -> generatePatientSummary (GET /patients/:id auto,
--                          POST /patients/:id/summary, PATCH .../from-document)
--
-- doc_key: nombre de archivo normalizado (misma normalización que usa el
-- backend para casar documentos). Es NULL para 'patient_summary', que es un
-- análisis a nivel de ficha y no de un documento concreto; en ese caso el
-- par distinto es (patient_id, NULL) -> 1 por paciente con resumen.
--
-- SIN BACKFILL: arranca en cero y crece con lo nuevo. Es total histórico, no
-- "de hoy".
--
-- El backend usa la SERVICE ROLE KEY, así que la política RLS de más abajo no
-- lo afecta: RLS habilitado sin política (deny-all para anon), igual que
-- lab/dental/rooms.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente. IMPORTANTE: correr junto con el deploy del backend; si el
--   backend nuevo corre sin esta tabla, la métrica queda en 0 hasta correrlo.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabla de log
-- ----------------------------------------------------------------------------
create table if not exists public.ai_analyses (
  id          uuid primary key default gen_random_uuid(),
  patient_id  bigint references public.patients(id) on delete set null,
  filename    text,          -- nombre original del archivo (para lectura/debug); NULL en patient_summary
  doc_key     text,          -- filename normalizado; NULL en patient_summary
  kind        text not null
              check (kind in ('document_analysis', 'document_ask', 'patient_summary')),
  staff_email text,          -- quién la gatilló (auditoría)
  created_at  timestamptz not null default now()
);

create index if not exists ai_analyses_patient_dockey_idx
  on public.ai_analyses (patient_id, doc_key);

create index if not exists ai_analyses_kind_idx
  on public.ai_analyses (kind);

-- ----------------------------------------------------------------------------
-- 2. RLS
-- ----------------------------------------------------------------------------
alter table public.ai_analyses enable row level security;

-- ----------------------------------------------------------------------------
-- 3. Normalización de nombre de archivo (misma lógica que normalizeDocumentName
--    en server.mjs: minúsculas, sin extensión .pdf, sin separadores).
-- ----------------------------------------------------------------------------
create or replace function public.nexa_doc_key(name text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(
      regexp_replace(lower(btrim(coalesce(name, ''))), '\.pdf$', ''),
      '[^a-z0-9áéíóúüñ]+', '', 'g'
    ),
    ''
  );
$$;

-- ----------------------------------------------------------------------------
-- 4. Métricas agregadas (una llamada RPC desde /dashboard/summary)
-- ----------------------------------------------------------------------------
--   documentsAnalyzed -> documentos distintos con algún análisis de IA
--                        (patient_id + doc_key, doc_key not null). Puede incluir
--                        PDFs analizados que nunca se incorporaron a la ficha.
--   documentsAwaiting -> documentos YA incorporados (tabla documents) que aún no
--                        tienen ningún análisis de IA.
--   patientSummaries  -> pacientes distintos con resumen de ficha por IA
--   total             -> unidades distintas analizadas por IA (histórico):
--                        documentos + fichas
create or replace function public.ai_analysis_metrics()
returns json
language sql
stable
as $$
  select json_build_object(
    'documentsAnalyzed', (
      select count(*) from (
        select distinct patient_id, doc_key
        from public.ai_analyses
        where doc_key is not null
      ) d
    ),
    'documentsAwaiting', (
      select count(*)
      from public.documents d
      where not exists (
        select 1 from public.ai_analyses a
        where a.patient_id = d.patient_id
          and a.doc_key = public.nexa_doc_key(d.filename)
      )
    ),
    'patientSummaries', (
      select count(distinct patient_id)
      from public.ai_analyses
      where kind = 'patient_summary'
    ),
    'total', (
      select count(*) from (
        select distinct patient_id, doc_key
        from public.ai_analyses
      ) t
    )
  );
$$;
