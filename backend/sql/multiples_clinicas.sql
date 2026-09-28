-- Múltiples clínicas por usuario: una misma cuenta puede trabajar en varias
-- clínicas, con un rol distinto en cada una.
--
-- staff_profiles.clinic_id y staff_profiles.role se mantienen como "clínica y
-- rol principal" (compatibilidad con todo lo que ya los lee). Las membresías
-- de esta tabla son las que deciden a qué clínicas entra cada persona y con
-- qué rol (ver requireAuth en backend/server.mjs).
--
-- Solo el backend (service role) lee y escribe esta tabla: RLS activado y sin
-- políticas = deny-all para anon/authenticated.

create table if not exists public.staff_clinic_memberships (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff_profiles(id) on delete cascade,
  clinic_id uuid not null references public.clinics(id) on delete cascade,
  role text not null check (role in ('administrador', 'medico', 'tecnico', 'recepcion')),
  created_at timestamptz not null default now(),
  unique (staff_id, clinic_id)
);

create index if not exists staff_clinic_memberships_clinic_id_idx
  on public.staff_clinic_memberships (clinic_id);

alter table public.staff_clinic_memberships enable row level security;
revoke all on public.staff_clinic_memberships from anon, authenticated;

-- Backfill: cada persona con clínica principal queda como miembro de esa
-- clínica con su rol actual. Idempotente.
insert into public.staff_clinic_memberships (staff_id, clinic_id, role)
select sp.id, sp.clinic_id, sp.role
from public.staff_profiles sp
where sp.clinic_id is not null
  and sp.role in ('administrador', 'medico', 'tecnico', 'recepcion')
on conflict (staff_id, clinic_id) do nothing;
