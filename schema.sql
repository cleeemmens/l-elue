-- =====================================================================
--  COURONNE PRONO — script de création de la base
--  À coller en entier dans Supabase > SQL Editor > New query, puis "Run".
--
--  ⚠️ AVANT DE LANCER : remplace CHANGE-MOI (ligne ~40) par TON mot de
--  passe admin (celui que tu taperas sur la page admin le soir J).
--  Ne le partage avec personne.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Profils (une joueuse = un profil, lié à son téléphone) ----------
create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null unique default auth.uid(),
  name        text not null check (char_length(name) between 1 and 20),
  emoji       text not null default '👑' check (char_length(emoji) <= 8),
  mode        text not null default 'detail' check (mode in ('detail','global')),
  crits       jsonb not null default '["beaute","defiles","discours","video"]',
  notes       jsonb not null default '{}'  check (pg_column_size(notes) < 30000),
  coeur       text,
  top5        jsonb not null default '[]',
  prono       jsonb not null default '{"top15":[],"top5":[],"order":[null,null,null,null,null]}',
  quiz_score  int,
  quiz_total  int,
  soulmate    text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- Secrets (illisibles depuis l'appli) ----------
create table if not exists public.app_secrets (k text primary key, v text not null);
alter table public.app_secrets enable row level security;
insert into public.app_secrets (k, v)
values ('admin_password', extensions.crypt('CHANGE-MOI', extensions.gen_salt('bf')))
on conflict (k) do update set v = excluded.v;

-- ---------- Codes perso (pour changer de téléphone) ----------
create table if not exists public.recovery (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  code       text not null unique
);
alter table public.recovery enable row level security;

-- ---------- Groupes ----------
create table if not exists public.leagues (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null check (char_length(name) between 1 and 30),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.league_members (
  league_id  uuid not null references public.leagues(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (league_id, profile_id)
);

-- ---------- Résultats officiels (une seule ligne) ----------
create table if not exists public.results (
  id           int primary key default 1 check (id = 1),
  top15        jsonb not null default '[]',
  top5         jsonb not null default '[]',
  ord          jsonb not null default '[null,null,null,null,null]',
  votes_locked boolean not null default false,
  updated_at   timestamptz not null default now()
);
insert into public.results (id) values (1) on conflict do nothing;

-- ---------- Sécurité (RLS) ----------
alter table public.profiles        enable row level security;
alter table public.leagues         enable row level security;
alter table public.league_members  enable row level security;
alter table public.results         enable row level security;

drop policy if exists "profils lisibles"        on public.profiles;
drop policy if exists "créer son profil"        on public.profiles;
drop policy if exists "modifier son profil"     on public.profiles;
drop policy if exists "supprimer son profil"    on public.profiles;
create policy "profils lisibles"     on public.profiles for select using (true);
create policy "créer son profil"     on public.profiles for insert with check (owner = auth.uid());
create policy "modifier son profil"  on public.profiles for update using (owner = auth.uid()) with check (owner = auth.uid());
create policy "supprimer son profil" on public.profiles for delete using (owner = auth.uid());

drop policy if exists "groupes lisibles" on public.leagues;
create policy "groupes lisibles" on public.leagues for select using (true);

drop policy if exists "membres lisibles" on public.league_members;
drop policy if exists "quitter un groupe" on public.league_members;
create policy "membres lisibles"  on public.league_members for select using (true);
create policy "quitter un groupe" on public.league_members for delete
  using (profile_id in (select id from public.profiles where owner = auth.uid()));

drop policy if exists "résultats lisibles" on public.results;
create policy "résultats lisibles" on public.results for select using (true);
-- (aucune règle d'écriture : seuls les outils admin protégés par mot de passe peuvent modifier)

grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.leagues, public.league_members, public.results to anon, authenticated;
grant insert, update, delete on public.profiles to authenticated;
grant delete on public.league_members to authenticated;
revoke all on public.app_secrets, public.recovery from anon, authenticated;

-- ---------- Outils internes ----------
create or replace function public._rand_code(n int) returns text
language sql volatile as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random()*32)::int, 1), '')
  from generate_series(1, n)
$$;

create or replace function public._is_admin(p_pwd text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.app_secrets where k = 'admin_password' and v = extensions.crypt(p_pwd, v))
$$;
revoke all on function public._is_admin(text) from public, anon, authenticated;

-- Profil : date de mise à jour + blocage des votes après le verrouillage
create or replace function public._profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select votes_locked from public.results where id = 1) and (
       new.prono is distinct from old.prono or new.top5 is distinct from old.top5 or
       new.notes is distinct from old.notes or new.coeur is distinct from old.coeur or
       new.mode  is distinct from old.mode  or new.crits is distinct from old.crits) then
    raise exception 'VOTES_LOCKED';
  end if;
  new.updated_at := now();
  if coalesce(current_setting('app.recovering', true), '') <> 'on' then
    new.owner := old.owner;  -- on ne peut pas "voler" un profil par une simple mise à jour
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public._profiles_guard();

-- Code perso créé automatiquement pour chaque nouveau profil
create or replace function public._profiles_recovery() returns trigger
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  loop
    c := public._rand_code(4) || '-' || public._rand_code(4);
    begin
      insert into public.recovery (profile_id, code) values (new.id, c);
      exit;
    exception when unique_violation then end;
  end loop;
  return new;
end $$;
drop trigger if exists profiles_recovery on public.profiles;
create trigger profiles_recovery after insert on public.profiles
  for each row execute function public._profiles_recovery();

-- ---------- Fonctions appelées par l'appli ----------

-- Mon code perso
create or replace function public.my_recovery_code() returns text
language sql stable security definer set search_path = public as $$
  select r.code from public.recovery r join public.profiles p on p.id = r.profile_id
  where p.owner = auth.uid()
$$;

-- Retrouver mon profil sur un nouveau téléphone
create or replace function public.recover_profile(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select profile_id into pid from public.recovery where code = upper(trim(p_code));
  if pid is null then raise exception 'BAD_CODE'; end if;
  delete from public.profiles where owner = auth.uid() and id <> pid;
  perform set_config('app.recovering', 'on', true);
  update public.profiles set owner = auth.uid() where id = pid;
  perform set_config('app.recovering', 'off', true);
  return pid;
end $$;

-- Créer un groupe : le code est généré automatiquement et garanti unique
create or replace function public.create_league(p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid; c text; lid uuid;
  words text[] := array['ROSE','PERLE','STRASS','TIARE','SATIN','PLUME','GLAM','DIVA',
                        'LUXE','NACRE','ECRIN','VELOURS','ETOILE','SOIE','BIJOU','RUBIS'];
begin
  select id into me from public.profiles where owner = auth.uid();
  if me is null then raise exception 'NO_PROFILE'; end if;
  loop
    c := words[1 + floor(random()*array_length(words,1))::int] || '-' || lpad(floor(random()*10000)::int::text, 4, '0');
    begin
      insert into public.leagues (code, name, created_by) values (c, coalesce(nullif(trim(p_name),''),'Mon groupe'), me)
      returning id into lid;
      exit;
    exception when unique_violation then end;
  end loop;
  insert into public.league_members (league_id, profile_id) values (lid, me);
  return json_build_object('id', lid, 'code', c, 'name', coalesce(nullif(trim(p_name),''),'Mon groupe'));
end $$;

-- Rejoindre un groupe avec son code (refuse un prénom déjà pris dans le groupe)
create or replace function public.join_league(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid; myname text; l record;
begin
  select id, name into me, myname from public.profiles where owner = auth.uid();
  if me is null then raise exception 'NO_PROFILE'; end if;
  select * into l from public.leagues where code = upper(trim(p_code));
  if l.id is null then raise exception 'BAD_CODE'; end if;
  if exists (select 1 from public.league_members m join public.profiles p on p.id = m.profile_id
             where m.league_id = l.id and p.id <> me and lower(p.name) = lower(myname)) then
    raise exception 'NAME_TAKEN';
  end if;
  insert into public.league_members (league_id, profile_id) values (l.id, me) on conflict do nothing;
  return json_build_object('id', l.id, 'code', l.code, 'name', l.name);
end $$;

-- Mes groupes
create or replace function public.my_leagues() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', l.id, 'code', l.code, 'name', l.name,
           'members', (select count(*) from public.league_members x where x.league_id = l.id))
           order by m.joined_at), '[]'::json)
  from public.league_members m
  join public.leagues l on l.id = m.league_id
  join public.profiles p on p.id = m.profile_id
  where p.owner = auth.uid()
$$;

-- Les joueuses d'un groupe
create or replace function public.league_profiles(p_league uuid) returns setof public.profiles
language sql stable security definer set search_path = public as $$
  select p.* from public.profiles p join public.league_members m on m.profile_id = p.id
  where m.league_id = p_league order by m.joined_at
$$;

-- Le classement de la France : chaque top 5 donne 5-4-3-2-1 points
create or replace function public.france_stats() returns json
language sql stable security definer set search_path = public as $$
  with tops as (
    select e.value #>> '{}' as cand, e.ord
    from public.profiles p, jsonb_array_elements(p.top5) with ordinality as e(value, ord)
    where jsonb_typeof(p.top5) = 'array' and e.ord <= 5
  ), rk as (
    select cand, sum(6 - ord)::int as pts, count(*)::int as voters from tops group by cand
  ), win as (
    select prono->'order'->>0 as cand, count(*)::int as n from public.profiles
    where prono->'order'->>0 is not null group by 1
  )
  select json_build_object(
    'players', (select count(*) from public.profiles),
    'voters',  (select count(*) from public.profiles where jsonb_array_length(top5) > 0),
    'ranking', coalesce((select json_agg(json_build_object('cand', cand, 'pts', pts, 'voters', voters) order by pts desc, voters desc, cand) from rk), '[]'::json),
    'winner_prono', coalesce((select json_agg(json_build_object('cand', cand, 'n', n) order by n desc) from win), '[]'::json),
    'quiz_avg', (select round(avg(quiz_score::numeric / nullif(quiz_total,0)) * 20, 1) from public.profiles where quiz_total > 0)
  )
$$;

-- ---------- Outils admin (protégés par ton mot de passe) ----------
create or replace function public.admin_check(p_pwd text) returns boolean
language sql stable security definer set search_path = public as $$
  select public._is_admin(p_pwd)
$$;

create or replace function public.admin_set_results(p_pwd text, p_top15 jsonb, p_top5 jsonb, p_ord jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  update public.results set top15 = p_top15, top5 = p_top5, ord = p_ord, updated_at = now() where id = 1;
end $$;

create or replace function public.admin_set_lock(p_pwd text, p_locked boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  update public.results set votes_locked = p_locked, updated_at = now() where id = 1;
end $$;

grant execute on function public.my_recovery_code(), public.recover_profile(text), public.create_league(text),
  public.join_league(text), public.my_leagues(), public.league_profiles(uuid), public.france_stats(),
  public.admin_check(text), public.admin_set_results(text, jsonb, jsonb, jsonb), public.admin_set_lock(text, boolean)
  to anon, authenticated;

-- ---------- Mises à jour en direct des résultats ----------
do $$ begin
  alter publication supabase_realtime add table public.results;
exception when duplicate_object then null; when undefined_object then null; end $$;

select 'Base Couronne Prono prête ✅' as statut;
