-- Cryostock database schema for Supabase (Postgres)
-- Run this in your Supabase project: Dashboard -> SQL Editor -> New query -> paste -> Run.
-- Safe to re-run any time (every statement is idempotent) if you need to reapply after a change.

create extension if not exists pgcrypto;

-- ---------- profiles (display name per account, approval gate) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  approved boolean not null default false,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- in case profiles already existed from an earlier run of this script
alter table public.profiles add column if not exists approved boolean not null default false;
alter table public.profiles add column if not exists is_admin boolean not null default false;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

-- true if the CURRENT session's user has been approved by an admin
create or replace function public.is_approved()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select approved from public.profiles where id = auth.uid()), false);
$$;

-- true if the CURRENT session's user is an admin (can approve others)
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- inventory hierarchy ----------
create table if not exists public.tanks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sort_order integer not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.racks (
  id uuid primary key default gen_random_uuid(),
  tank_id uuid not null references public.tanks(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.boxes (
  id uuid primary key default gen_random_uuid(),
  rack_id uuid not null references public.racks(id) on delete cascade,
  name text not null,
  rows int not null default 9,
  cols int not null default 9,
  sort_order integer not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- in case these tables already existed from an earlier run of this script
alter table public.tanks add column if not exists sort_order integer not null default 0;
alter table public.racks add column if not exists sort_order integer not null default 0;
alter table public.boxes add column if not exists sort_order integer not null default 0;

-- one-time backfill: gives existing rows a stable order (oldest first) based on
-- when they were created. Only touches a group (all racks under one tank, all
-- boxes under one rack, or the whole tanks table) if EVERY row in it still has
-- the untouched default of 0 — so it never overwrites an order you've already
-- set by hand with the up/down arrows, on this or any later re-run.
do $$
begin
  if coalesce((select bool_and(sort_order = 0) from public.tanks), true) then
    with ranked as (
      select id, row_number() over (order by created_at) - 1 as rn from public.tanks
    )
    update public.tanks t set sort_order = ranked.rn from ranked where ranked.id = t.id;
  end if;
end $$;

with untouched_racks as (
  select tank_id from public.racks group by tank_id having bool_and(sort_order = 0)
),
ranked_racks as (
  select id, row_number() over (partition by tank_id order by created_at) - 1 as rn
  from public.racks where tank_id in (select tank_id from untouched_racks)
)
update public.racks r set sort_order = ranked_racks.rn
from ranked_racks where ranked_racks.id = r.id;

with untouched_boxes as (
  select rack_id from public.boxes group by rack_id having bool_and(sort_order = 0)
),
ranked_boxes as (
  select id, row_number() over (partition by rack_id order by created_at) - 1 as rn
  from public.boxes where rack_id in (select rack_id from untouched_boxes)
)
update public.boxes b set sort_order = ranked_boxes.rn
from ranked_boxes where ranked_boxes.id = b.id;

create table if not exists public.samples (
  id uuid primary key default gen_random_uuid(),
  box_id uuid not null references public.boxes(id) on delete cascade,
  position text not null,
  cell_line text not null,
  type text not null default 'other',
  passage text,
  freeze_date date,
  count text,
  medium text,
  myco text,          -- '' (not sure) or 'negative'
  clone text,
  viability text,
  owner text,          -- self-declared responsible researcher (free text)
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  unique (box_id, position)
);

-- in case the samples table already existed from an earlier run of this script
alter table public.samples add column if not exists clone text;
alter table public.samples add column if not exists viability text;

create or replace function public.set_sample_meta()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  if (tg_op = 'INSERT') then
    new.created_by = coalesce(new.created_by, auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_samples_meta on public.samples;
create trigger trg_samples_meta
  before insert or update on public.samples
  for each row execute function public.set_sample_meta();

-- ---------- audit log: who changed what, automatically ----------
create table if not exists public.audit_log (
  id bigserial primary key,
  table_name text not null,
  record_id uuid not null,
  action text not null, -- insert / update / delete
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  old_data jsonb,
  new_data jsonb
);

create or replace function public.log_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.audit_log(table_name, record_id, action, changed_by, new_data)
    values (tg_table_name, new.id, 'insert', auth.uid(), to_jsonb(new));
    return new;
  elsif (tg_op = 'UPDATE') then
    insert into public.audit_log(table_name, record_id, action, changed_by, old_data, new_data)
    values (tg_table_name, new.id, 'update', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  elsif (tg_op = 'DELETE') then
    insert into public.audit_log(table_name, record_id, action, changed_by, old_data)
    values (tg_table_name, old.id, 'delete', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_tanks_audit on public.tanks;
create trigger trg_tanks_audit after insert or update or delete on public.tanks
  for each row execute function public.log_change();
drop trigger if exists trg_racks_audit on public.racks;
create trigger trg_racks_audit after insert or update or delete on public.racks
  for each row execute function public.log_change();
drop trigger if exists trg_boxes_audit on public.boxes;
create trigger trg_boxes_audit after insert or update or delete on public.boxes
  for each row execute function public.log_change();
drop trigger if exists trg_samples_audit on public.samples;
create trigger trg_samples_audit after insert or update or delete on public.samples
  for each row execute function public.log_change();

-- ---------- row level security: only APPROVED lab members can read/write ----------
alter table public.profiles enable row level security;
alter table public.tanks enable row level security;
alter table public.racks enable row level security;
alter table public.boxes enable row level security;
alter table public.samples enable row level security;
alter table public.audit_log enable row level security;

-- profiles: everyone can always read their OWN row (so a pending account can see
-- its own approval status); approved members can also read everyone else's, so the
-- app can show names in "added by" / activity log / the admin approval list.
drop policy if exists "read profiles" on public.profiles;
create policy "read profiles" on public.profiles for select
  using (auth.uid() = id or public.is_approved());

-- only an admin can flip approved/is_admin on someone else's profile
drop policy if exists "admin updates profiles" on public.profiles;
create policy "admin updates profiles" on public.profiles for update
  using (public.is_admin());

drop policy if exists "read tanks" on public.tanks;
create policy "read tanks"   on public.tanks   for select using (public.is_approved());
drop policy if exists "write tanks" on public.tanks;
create policy "write tanks"  on public.tanks   for insert with check (public.is_approved());
drop policy if exists "update tanks" on public.tanks;
create policy "update tanks" on public.tanks   for update using (public.is_approved());
drop policy if exists "delete tanks" on public.tanks;
create policy "delete tanks" on public.tanks   for delete using (public.is_approved());

drop policy if exists "read racks" on public.racks;
create policy "read racks"   on public.racks   for select using (public.is_approved());
drop policy if exists "write racks" on public.racks;
create policy "write racks"  on public.racks   for insert with check (public.is_approved());
drop policy if exists "update racks" on public.racks;
create policy "update racks" on public.racks   for update using (public.is_approved());
drop policy if exists "delete racks" on public.racks;
create policy "delete racks" on public.racks   for delete using (public.is_approved());

drop policy if exists "read boxes" on public.boxes;
create policy "read boxes"   on public.boxes   for select using (public.is_approved());
drop policy if exists "write boxes" on public.boxes;
create policy "write boxes"  on public.boxes   for insert with check (public.is_approved());
drop policy if exists "update boxes" on public.boxes;
create policy "update boxes" on public.boxes   for update using (public.is_approved());
drop policy if exists "delete boxes" on public.boxes;
create policy "delete boxes" on public.boxes   for delete using (public.is_approved());

drop policy if exists "read samples" on public.samples;
create policy "read samples"   on public.samples for select using (public.is_approved());
drop policy if exists "write samples" on public.samples;
create policy "write samples"  on public.samples for insert with check (public.is_approved());
drop policy if exists "update samples" on public.samples;
create policy "update samples" on public.samples for update using (public.is_approved());
drop policy if exists "delete samples" on public.samples;
create policy "delete samples" on public.samples for delete using (public.is_approved());

-- audit_log: readable by approved lab members, never directly writable by them
-- (rows are inserted only by the SECURITY DEFINER trigger function above)
drop policy if exists "read audit" on public.audit_log;
create policy "read audit" on public.audit_log for select using (public.is_approved());

-- ---------- realtime: let the app subscribe to live changes ----------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tanks') then
    alter publication supabase_realtime add table public.tanks;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='racks') then
    alter publication supabase_realtime add table public.racks;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='boxes') then
    alter publication supabase_realtime add table public.boxes;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='samples') then
    alter publication supabase_realtime add table public.samples;
  end if;
end $$;

-- ---------- one-time: approve yourself as the first admin ----------
-- New accounts (including yours, if it predates this migration) start with
-- approved = false and is_admin = false. Run this once, with YOUR OWN email,
-- so you can get into the app and approve everyone else from there:
--
-- update public.profiles set approved = true, is_admin = true
-- where id = (select id from auth.users where email = 'YOUR_EMAIL_HERE');
