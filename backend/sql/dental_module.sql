-- ============================================================================
-- MÓDULO DE ATENCIONES DENTALES
-- ----------------------------------------------------------------------------
-- Sigue el mismo patrón que el módulo de Laboratorio (lab_panels / lab_orders /
-- lab_order_panels / lab_results):
--
--   dental_procedures        -> catálogo con códigos FONASA (grupo 06)
--   dental_orders            -> una orden por paciente (ordenado/realizado/validado)
--   dental_order_procedures  -> qué prestaciones se pidieron en cada orden
--   dental_results           -> resultado por prestación (pieza, diagnóstico, profesional)
--
-- El backend de Nexa usa la SERVICE ROLE KEY, así que las políticas RLS de más
-- abajo no lo afectan: solo bloquean el acceso directo con la anon key.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / ON CONFLICT), se puede volver a correr.
--
-- Nota sobre el tipo de patient_id: se asume patients.id = bigint (default de
-- Supabase para PKs identity). Si en tu proyecto patients.id es integer, la FK
-- igual funciona (Postgres compara int4/int8), pero si prefieres puedes cambiar
-- "bigint" por "integer" en dental_orders.patient_id.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Catálogo de prestaciones
-- ----------------------------------------------------------------------------
create table if not exists public.dental_procedures (
  id          uuid primary key default gen_random_uuid(),
  fonasa_code text not null unique,
  name        text not null,
  created_at  timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 2. Órdenes por paciente
-- ----------------------------------------------------------------------------
create table if not exists public.dental_orders (
  id           uuid primary key default gen_random_uuid(),
  patient_id   bigint not null references public.patients(id) on delete cascade,
  status       text not null default 'ordenado'
               check (status in ('ordenado', 'realizado', 'validado')),
  requested_at timestamptz not null default now(),
  performed_at timestamptz,
  validated_at timestamptz,
  validated_by text
);

create index if not exists dental_orders_patient_id_idx
  on public.dental_orders (patient_id);

-- ----------------------------------------------------------------------------
-- 3. Prestaciones pedidas en cada orden
-- ----------------------------------------------------------------------------
create table if not exists public.dental_order_procedures (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.dental_orders(id) on delete cascade,
  procedure_id uuid not null references public.dental_procedures(id),
  unique (order_id, procedure_id)
);

create index if not exists dental_order_procedures_order_id_idx
  on public.dental_order_procedures (order_id);

-- ----------------------------------------------------------------------------
-- 4. Resultado por prestación
-- ----------------------------------------------------------------------------
create table if not exists public.dental_results (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.dental_orders(id) on delete cascade,
  procedure_id uuid not null references public.dental_procedures(id),
  tooth        text,          -- pieza dentaria (texto libre: "1.6", "36", "2.1-2.3")
  diagnosis    text,          -- diagnóstico / observación
  professional text,          -- profesional que ejecutó la prestación
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (order_id, procedure_id)
);

create index if not exists dental_results_order_id_idx
  on public.dental_results (order_id);

-- ----------------------------------------------------------------------------
-- 5. RLS (denegar acceso directo con anon key; el backend usa service role)
-- ----------------------------------------------------------------------------
alter table public.dental_procedures       enable row level security;
alter table public.dental_orders           enable row level security;
alter table public.dental_order_procedures enable row level security;
alter table public.dental_results          enable row level security;

-- ----------------------------------------------------------------------------
-- 6. Seed del catálogo (FONASA grupo 06 — Odontología)
-- ----------------------------------------------------------------------------
insert into public.dental_procedures (fonasa_code, name) values
  ('6001001', 'Examen clínico inicial y plan de tratamiento'),
  ('6001019', 'Consulta dental de urgencia'),
  ('6002024', 'Destartraje + profilaxis boca completa'),
  ('6003011', 'Restauración/obturación anterior (resina)'),
  ('6003015', 'Restauración/obturación posterior (resina)'),
  ('6006005', 'Endodoncia (conducto) anterior'),
  ('6006006', 'Endodoncia (conducto) premolar'),
  ('6006007', 'Endodoncia (conducto) molar'),
  ('6010003', 'Exodoncia simple'),
  ('6301002', 'Radiografía retroalveolar')
on conflict (fonasa_code) do update set name = excluded.name;
