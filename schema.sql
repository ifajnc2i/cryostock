-- Cryostock database schema for Supabase (Postgres)
-- Run this in your Supabase project: Dashboard -> SQL Editor -> New query -> paste -> Run.
-- Safe to re-run any time (every statement is idempotent) if you need to reapply after a change.

create extension if not exists pgcrypto;

-- ---------- profiles (display name per account) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  created_at timestamptz not null default now()
);

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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- inventory hierarchy ----------
create table if not exists public.tanks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.racks (
  id uuid primary key default gen_random_uuid(),
  tank_id uuid not null references public.tanks(id) on delete cascade,
  name text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.boxes (
  id uuid primary key default gen_random_uuid(),
  rack_id uuid not null references public.racks(id) on delete cascade,
  name text not null,
  rows int not null default 9,
  cols int not null default 9,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

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

-- ---------- row level security: any logged-in lab member can read/write ----------
alter table public.profiles enable row level security;
alter table public.tanks enable row level security;
alter table public.racks enable row level security;
alter table public.boxes enable row level security;
alter table public.samples enable row level security;
alter table public.audit_log enable row level security;

drop policy if exists "read profiles" on public.profiles;
create policy "read profiles" on public.profiles for select using (auth.role() = 'authenticated');

drop policy if exists "read tanks" on public.tanks;
create policy "read tanks"   on public.tanks   for select using (auth.role() = 'authenticated');
drop policy if exists "write tanks" on public.tanks;
create policy "write tanks"  on public.tanks   for insert with check (auth.role() = 'authenticated');
drop policy if exists "update tanks" on public.tanks;
create policy "update tanks" on public.tanks   for update using (auth.role() = 'authenticated');
drop policy if exists "delete tanks" on public.tanks;
create policy "delete tanks" on public.tanks   for delete using (auth.role() = 'authenticated');

drop policy if exists "read racks" on public.racks;
create policy "read racks"   on public.racks   for select using (auth.role() = 'authenticated');
drop policy if exists "write racks" on public.racks;
create policy "write racks"  on public.racks   for insert with check (auth.role() = 'authenticated');
drop policy if exists "update racks" on public.racks;
create policy "update racks" on public.racks   for update using (auth.role() = 'authenticated');
drop policy if exists "delete racks" on public.racks;
create policy "delete racks" on public.racks   for delete using (auth.role() = 'authenticated');

drop policy if exists "read boxes" on public.boxes;
create policy "read boxes"   on public.boxes   for select using (auth.role() = 'authenticated');
drop policy if exists "write boxes" on public.boxes;
create policy "write boxes"  on public.boxes   for insert with check (auth.role() = 'authenticated');
drop policy if exists "update boxes" on public.boxes;
create policy "update boxes" on public.boxes   for update using (auth.role() = 'authenticated');
drop policy if exists "delete boxes" on public.boxes;
create policy "delete boxes" on public.boxes   for delete using (auth.role() = 'authenticated');

drop policy if exists "read samples" on public.samples;
create policy "read samples"   on public.samples for select using (auth.role() = 'authenticated');
drop policy if exists "write samples" on public.samples;
create policy "write samples"  on public.samples for insert with check (auth.role() = 'authenticated');
drop policy if exists "update samples" on public.samples;
create policy "update samples" on public.samples for update using (auth.role() = 'authenticated');
drop policy if exists "delete samples" on public.samples;
create policy "delete samples" on public.samples for delete using (auth.role() = 'authenticated');

-- audit_log: readable by lab members, never directly writable by them
-- (rows are inserted only by the SECURITY DEFINER trigger function above)
drop policy if exists "read audit" on public.audit_log;
create policy "read audit" on public.audit_log for select using (auth.role() = 'authenticated');

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
