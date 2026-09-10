-- ============================================================================
-- CATÁLOGO DE SALAS
-- ----------------------------------------------------------------------------
-- Fase 2 del dashboard. Hasta ahora el total de salas estaba hardcodeado en
-- server.mjs (KNOWN_ROOMS = ["Sala 1", "Sala 2", "Sala 3"]) y "salas en uso"
-- se calculaba comparando strings sueltos de patients.room. Esta tabla es el
-- catálogo real; el backend pasa a leer el total desde aquí.
--
-- Alcance de esta entrega (Salas): SOLO el catálogo + el seed + que
-- /dashboard/summary lea el total desde la tabla. La relación sala <-> cita
-- se resuelve en la entrega de Citas (appointments.room_id), no aquí.
--
-- El backend de Nexa usa la SERVICE ROLE KEY, así que la política RLS de más
-- abajo no lo afecta: solo bloquea el acceso directo con la anon key. Se deja
-- RLS habilitado sin política (deny-all para anon), igual que lab/dental.
--
-- Cómo correrlo:
--   Supabase -> SQL Editor -> pega este archivo completo -> Run.
--   Es idempotente (IF NOT EXISTS / ON CONFLICT), se puede volver a correr.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabla
-- ----------------------------------------------------------------------------
create table if not exists public.rooms (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  kind       text not null default 'consulta'
             check (kind in (
               'consulta', 'procedimiento', 'imagenologia',
               'laboratorio', 'dental', 'otro'
             )),
  capacity   integer not null default 1 check (capacity >= 0),
  active     boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- Orden de listado habitual: primero las activas, luego por sort_order y nombre.
create index if not exists rooms_active_sort_idx
  on public.rooms (active, sort_order, name);

-- ----------------------------------------------------------------------------
-- 2. RLS (denegar acceso directo con anon key; el backend usa service role)
-- ----------------------------------------------------------------------------
alter table public.rooms enable row level security;

-- ----------------------------------------------------------------------------
-- 3. Seed
-- ----------------------------------------------------------------------------
-- Sala 1-3 replican el KNOWN_ROOMS actual para no romper la métrica existente.
-- `do nothing` en vez de `do update`: si alguien edita una sala a mano en
-- Supabase, volver a correr este archivo no la pisa.
--
-- kind = 'consulta' es un valor neutro de partida. Ajusta kind/capacity de
-- cada sala una vez confirmadas las salas reales de la clínica, y agrega las
-- que falten con un INSERT del mismo formato.
insert into public.rooms (name, kind, capacity, active, sort_order) values
  ('Sala 1', 'consulta', 1, true, 1),
  ('Sala 2', 'consulta', 1, true, 2),
  ('Sala 3', 'consulta', 1, true, 3)
on conflict (name) do nothing;

-- Ejemplo para las salas reales (descomentar y ajustar cuando se confirmen):
-- insert into public.rooms (name, kind, capacity, active, sort_order) values
--   ('Ecografía',   'imagenologia',  1, true, 10),
--   ('Mamografía',  'imagenologia',  1, true, 11),
--   ('Rayos X',     'imagenologia',  1, true, 12),
--   ('Box dental',  'dental',        1, true, 20)
-- on conflict (name) do nothing;
