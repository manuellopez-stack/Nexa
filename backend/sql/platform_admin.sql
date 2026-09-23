-- ============================================================================
-- ACCESO DE PLATAFORMA: staff_profiles.is_platform_admin
-- ----------------------------------------------------------------------------
-- Hasta ahora un staff_profile con clinic_id nulo era, de hecho, "global":
-- todos los filtros de server.mjs se saltaban cuando quien pedía no tenía
-- clínica. Desde esta migración eso deja de ser así:
--
--   - clinic_id nulo  -> la cuenta NO tiene acceso a datos de ninguna clínica.
--   - is_platform_admin = true -> puede ver/crear clínicas, invitar personal
--     a cualquier clínica, gestionar el personal de todas y ver el resumen del
--     dashboard sumado entre clínicas. Para datos clínicos (pacientes, agenda,
--     órdenes, cobros) sigue viendo solo los de SU propia clinic_id.
--
-- Alcance:
--   1. Agrega la columna nueva (boolean NOT NULL DEFAULT false): todas las
--      filas existentes quedan en false, no se toca ninguna otra columna.
--   2. Marca UNA sola cuenta como admin de plataforma, pedida explícitamente
--      por Manuel: su cuenta principal (id 645b81e1-…, perfil
--      manuel.lopez@mail.udp.cl, que inicia sesión como contacto@imagenda.cl).
--      Se filtra por id Y email para que no calce con ninguna otra fila.
--
-- El backend usa la SERVICE ROLE KEY, así que esto no requiere tocar RLS.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / update que solo afecta a esa fila).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Columna nueva
-- ----------------------------------------------------------------------------
alter table public.staff_profiles
  add column if not exists is_platform_admin boolean not null default false;

-- ----------------------------------------------------------------------------
-- 2. Cuenta principal de Manuel como admin de plataforma
-- ----------------------------------------------------------------------------
update public.staff_profiles
   set is_platform_admin = true
 where id = '645b81e1-152a-4f4f-83d7-3bff06899175'
   and email = 'manuel.lopez@mail.udp.cl';

-- Verificación: debe devolver exactamente una fila.
select id, email, role, clinic_id, is_platform_admin
  from public.staff_profiles
 where is_platform_admin;

-- ----------------------------------------------------------------------------
-- 3. Métricas de IA del dashboard acotadas a una clínica
-- ----------------------------------------------------------------------------
-- Misma lógica que ai_analysis_metrics() (ai_analyses.sql), pero solo cuenta
-- los pacientes de p_clinic_id (vía patients.clinic_id). La usa
-- /dashboard/summary para quien no es admin de plataforma; la función
-- original, sin filtro, queda solo para el admin de plataforma. Mientras esta
-- función no exista, el backend cae al comportamiento de respaldo que ya
-- tenía (métricas de IA sin desglose).
create or replace function public.ai_analysis_metrics_for_clinic(p_clinic_id uuid)
returns json
language sql
stable
as $$
  select json_build_object(
    'documentsAnalyzed', (
      select count(*) from (
        select distinct a.patient_id, a.doc_key
        from public.ai_analyses a
        join public.patients p on p.id = a.patient_id
        where a.doc_key is not null
          and p.clinic_id = p_clinic_id
      ) d
    ),
    'documentsAwaiting', (
      select count(*)
      from public.documents d
      join public.patients p on p.id = d.patient_id
      where p.clinic_id = p_clinic_id
        and not exists (
          select 1 from public.ai_analyses a
          where a.patient_id = d.patient_id
            and a.doc_key = public.nexa_doc_key(d.filename)
        )
    ),
    'patientSummaries', (
      select count(distinct a.patient_id)
      from public.ai_analyses a
      join public.patients p on p.id = a.patient_id
      where a.kind = 'patient_summary'
        and p.clinic_id = p_clinic_id
    ),
    'total', (
      select count(*) from (
        select distinct a.patient_id, a.doc_key
        from public.ai_analyses a
        join public.patients p on p.id = a.patient_id
        where p.clinic_id = p_clinic_id
      ) t
    )
  );
$$;
