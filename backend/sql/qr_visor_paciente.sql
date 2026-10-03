-- ============================================================================
-- QR DEL VISOR PARA EL PACIENTE: enlace en el informe radiológico firmado
-- ----------------------------------------------------------------------------
-- Al firmar un informe en Imagenda (POST .../report/sign) el backend crea un
-- enlace <base>/ver/<token> que se imprime como QR en el PDF. El paciente lo
-- abre en el celular, ingresa los 4 primeros dígitos de su RUT y ve las
-- imágenes de ESA orden y el informe firmado. Ver backend/shareLinks.mjs.
--
-- 1. study_share_links: un enlace por firma. Solo se guarda el SHA-256 del
--    token (token_hash), nunca el token en claro. Vence a los 365 días; al
--    firmar una versión nueva los enlaces activos anteriores quedan revocados.
--    failed_attempts / locked_until: 5 claves erradas seguidas bloquean el
--    enlace 15 minutos.
-- 2. study_share_access_log: cada intento de clave y cada vista
--    (action: 'unlock_ok', 'unlock_fail', 'view').
--
-- Alcance: solo crea dos tablas nuevas. No modifica datos existentes.
-- El backend usa la SERVICE ROLE KEY (se salta RLS). RLS activado + la
-- política restrictiva no_direct_client_access = anon/authenticated no leen
-- ni escriben nada, igual que las demás tablas.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / DROP POLICY IF EXISTS).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. study_share_links
-- ----------------------------------------------------------------------------
create table if not exists public.study_share_links (
  id                 uuid primary key default gen_random_uuid(),
  clinic_id          uuid not null references public.clinics(id) on delete cascade,
  imaging_order_id   uuid not null references public.imaging_orders(id) on delete cascade,
  imaging_report_id  uuid references public.imaging_reports(id) on delete set null,
  token_hash         text not null unique,
  expires_at         timestamptz not null,
  revoked_at         timestamptz,
  revoked_by         uuid,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  failed_attempts    int not null default 0,
  locked_until       timestamptz,
  last_access_at     timestamptz,
  access_count       int not null default 0
);

create index if not exists study_share_links_imaging_order_id_idx
  on public.study_share_links (imaging_order_id);

-- token_hash ya tiene índice por el UNIQUE; este lo deja explícito por nombre.
create index if not exists study_share_links_token_hash_idx
  on public.study_share_links (token_hash);

alter table public.study_share_links enable row level security;

drop policy if exists no_direct_client_access on public.study_share_links;
create policy no_direct_client_access on public.study_share_links
  as restrictive
  for all
  to anon, authenticated
  using (false)
  with check (false);

-- ----------------------------------------------------------------------------
-- 2. study_share_access_log
-- ----------------------------------------------------------------------------
create table if not exists public.study_share_access_log (
  id       uuid primary key default gen_random_uuid(),
  link_id  uuid not null references public.study_share_links(id) on delete cascade,
  at       timestamptz not null default now(),
  ip       text,
  ok       boolean not null,
  action   text not null check (action in ('unlock_ok', 'unlock_fail', 'view'))
);

create index if not exists study_share_access_log_link_id_idx
  on public.study_share_access_log (link_id, at desc);

alter table public.study_share_access_log enable row level security;

drop policy if exists no_direct_client_access on public.study_share_access_log;
create policy no_direct_client_access on public.study_share_access_log
  as restrictive
  for all
  to anon, authenticated
  using (false)
  with check (false);

-- Verificación
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and table_name in ('study_share_links', 'study_share_access_log')
 order by table_name, ordinal_position;

select tablename, policyname, permissive, roles, cmd
  from pg_policies
 where schemaname = 'public'
   and tablename in ('study_share_links', 'study_share_access_log');
