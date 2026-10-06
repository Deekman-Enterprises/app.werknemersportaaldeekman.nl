-- ============================================================================
-- Werknemers portaal Deekman Enterprises — Supabase setup script
-- ============================================================================
-- Plak dit hele bestand in Supabase → SQL Editor → New query → Run.
-- Het is veilig om dit script opnieuw te draaien als er iets misgaat,
-- BEHALVE de "ALTER PUBLICATION" regel helemaal onderaan (zie opmerking daar).
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Tabellen
-- ----------------------------------------------------------------------------

create table if not exists websites (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  url        text,
  created_by text,
  created_at timestamptz not null default now()
);

create table if not exists tasks (
  id             uuid primary key default gen_random_uuid(),
  website_id     uuid references websites(id) on delete set null,
  website_name   text,
  title          text not null,
  category       text not null check (category in ('SEO', 'SEA', 'Content & Social', 'Techniek & onderhoud')),
  assignee_name  text,
  assignee_email text,
  due_date       date,
  notes          text,
  created_by     text,
  created_at     timestamptz not null default now(),
  completed_at   timestamptz
);

create table if not exists employees (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  email      text not null unique,
  added_by   text,
  added_at   timestamptz not null default now()
);

create table if not exists admins (
  id         uuid primary key default gen_random_uuid(),
  email      text not null unique,
  added_by   text,
  added_at   timestamptz not null default now()
);

create table if not exists allowed_domains (
  id         uuid primary key default gen_random_uuid(),
  domain     text not null unique,   -- zonder "@", bv. "deekmanenterprises.com"
  added_by   text,
  added_at   timestamptz not null default now()
);

create index if not exists tasks_website_id_idx     on tasks (website_id);
create index if not exists tasks_assignee_email_idx on tasks (lower(assignee_email));
create index if not exists tasks_due_date_idx       on tasks (due_date);

-- ----------------------------------------------------------------------------
-- Helper-functies (draaien met verhoogde rechten, maar geven alleen ja/nee terug)
-- ----------------------------------------------------------------------------

create or replace function current_email()
returns text
language sql
stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

create or replace function is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    current_email() = 'thomasdeekman@gmail.com'
    or exists (select 1 from admins a where lower(a.email) = current_email());
$$;

create or replace function is_allowed()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    current_email() = 'thomasdeekman@gmail.com'
    or exists (select 1 from admins a where lower(a.email) = current_email())
    or exists (select 1 from employees e where lower(e.email) = current_email())
    or exists (
      select 1 from allowed_domains d
      where current_email() like '%@' || lower(d.domain)
    );
$$;

grant execute on function current_email() to anon, authenticated;
grant execute on function is_admin()      to anon, authenticated;
grant execute on function is_allowed()    to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Row Level Security
-- ----------------------------------------------------------------------------

alter table websites        enable row level security;
alter table tasks           enable row level security;
alter table employees       enable row level security;
alter table admins          enable row level security;
alter table allowed_domains enable row level security;

-- websites: iedereen die toegang heeft mag lezen/schrijven
drop policy if exists "read_websites"   on websites;
drop policy if exists "insert_websites" on websites;
drop policy if exists "update_websites" on websites;
drop policy if exists "delete_websites" on websites;

create policy "read_websites"   on websites for select using (is_allowed());
create policy "insert_websites" on websites for insert with check (is_allowed());
create policy "update_websites" on websites for update using (is_allowed()) with check (is_allowed());
create policy "delete_websites" on websites for delete using (is_allowed());

-- tasks: iedereen die toegang heeft mag lezen/schrijven
drop policy if exists "read_tasks"   on tasks;
drop policy if exists "insert_tasks" on tasks;
drop policy if exists "update_tasks" on tasks;
drop policy if exists "delete_tasks" on tasks;

create policy "read_tasks"   on tasks for select using (is_allowed());
create policy "insert_tasks" on tasks for insert with check (is_allowed());
create policy "update_tasks" on tasks for update using (is_allowed()) with check (is_allowed());
create policy "delete_tasks" on tasks for delete using (is_allowed());

-- employees / admins / allowed_domains: alleen beheerders mogen dit zien en wijzigen
drop policy if exists "admin_read_employees"   on employees;
drop policy if exists "admin_write_employees"  on employees;
drop policy if exists "admin_update_employees" on employees;
drop policy if exists "admin_delete_employees" on employees;

create policy "admin_read_employees"   on employees for select using (is_admin());
create policy "admin_write_employees"  on employees for insert with check (is_admin());
create policy "admin_update_employees" on employees for update using (is_admin()) with check (is_admin());
create policy "admin_delete_employees" on employees for delete using (is_admin());

drop policy if exists "admin_read_admins"   on admins;
drop policy if exists "admin_write_admins"  on admins;
drop policy if exists "admin_update_admins" on admins;
drop policy if exists "admin_delete_admins" on admins;

create policy "admin_read_admins"   on admins for select using (is_admin());
create policy "admin_write_admins"  on admins for insert with check (is_admin());
create policy "admin_update_admins" on admins for update using (is_admin()) with check (is_admin());
create policy "admin_delete_admins" on admins for delete using (is_admin());

drop policy if exists "admin_read_domains"   on allowed_domains;
drop policy if exists "admin_write_domains"  on allowed_domains;
drop policy if exists "admin_update_domains" on allowed_domains;
drop policy if exists "admin_delete_domains" on allowed_domains;

create policy "admin_read_domains"   on allowed_domains for select using (is_admin());
create policy "admin_write_domains"  on allowed_domains for insert with check (is_admin());
create policy "admin_update_domains" on allowed_domains for update using (is_admin()) with check (is_admin());
create policy "admin_delete_domains" on allowed_domains for delete using (is_admin());

-- ----------------------------------------------------------------------------
-- Startgegevens: het eigen bedrijfsdomein mag altijd inloggen
-- ----------------------------------------------------------------------------

insert into allowed_domains (domain, added_by)
values ('deekmanenterprises.com', 'system')
on conflict (domain) do nothing;

-- ----------------------------------------------------------------------------
-- Realtime: zorg dat wijzigingen live doorkomen bij alle ingelogde gebruikers
-- ----------------------------------------------------------------------------
-- LET OP: als je dit script een 2e keer draait en de tabellen staan al in de
-- publicatie, geeft onderstaande regel een foutmelding ("already member of
-- publication"). Dat is onschuldig — dan staat alles al goed en kun je die
-- foutmelding negeren (of de regel eenmalig weglaten).

alter publication supabase_realtime add table websites, tasks, employees, admins, allowed_domains;
