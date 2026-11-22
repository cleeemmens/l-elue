-- =====================================================================
--  L'ÉLUE — mise à jour n°5 : tenir un maximum de joueuses gratuitement
--  À coller en entier dans Supabase > SQL Editor > New query, puis "Run".
--  (Ton mot de passe admin ne change pas, rien à modifier dans ce script.)
--
--  Ce qui change :
--   - plus de connexions Supabase (elles sont plafonnées à 50 000 par mois) :
--     chaque téléphone garde une clé secrète, la base n'en garde qu'une empreinte ;
--   - plus de « temps réel » (plafonné à 200 personnes en même temps) ;
--   - le classement de la France est calculé une fois, à la clôture de la manche,
--     puis gardé tout prêt ; les statistiques sont recalculées au plus toutes les 2 min ;
--   - les tables ne sont plus lisibles directement : tout passe par des fonctions.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Clés des téléphones ----------
create table if not exists public.profile_tokens (
  tok_hash   text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists profile_tokens_profile on public.profile_tokens(profile_id);
alter table public.profile_tokens enable row level security;

alter table public.profiles alter column owner drop not null;
alter table public.profiles alter column owner drop default;

-- ---------- Classement France et statistiques gardés tout prêts ----------
alter table public.results add column if not exists fr       jsonb not null default '{}'::jsonb;
alter table public.results add column if not exists stats    jsonb;
alter table public.results add column if not exists stats_at timestamptz;

create table if not exists public.fr_acc (
  manche int  not null,
  cand   text not null,
  pts    bigint not null default 0,
  primary key (manche, cand)
);
create table if not exists public.fr_job (
  manche int primary key,
  voters bigint not null default 0,
  last_id uuid
);
alter table public.fr_acc enable row level security;
alter table public.fr_job enable row level security;

-- ---------- Fermer l'accès direct aux tables ----------
drop policy if exists "profils lisibles"     on public.profiles;
drop policy if exists "créer son profil"     on public.profiles;
drop policy if exists "modifier son profil"  on public.profiles;
drop policy if exists "supprimer son profil" on public.profiles;
drop policy if exists "groupes lisibles"     on public.leagues;
drop policy if exists "membres lisibles"     on public.league_members;
drop policy if exists "quitter un groupe"    on public.league_members;
drop policy if exists "résultats lisibles"   on public.results;
revoke all on public.profiles, public.leagues, public.league_members, public.results,
  public.app_secrets, public.recovery, public.profile_tokens, public.fr_acc, public.fr_job
  from anon, authenticated;

do $$ begin
  alter publication supabase_realtime drop table public.results;
exception when others then null; end $$;

-- ---------- Outils internes ----------
create or replace function public._hash(p_tok text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(p_tok, 'sha256'), 'hex')
$$;

create or replace function public._me(p_tok text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare pid uuid;
begin
  if p_tok is null or char_length(p_tok) < 32 then raise exception 'NO_PROFILE'; end if;
  select profile_id into pid from public.profile_tokens where tok_hash = public._hash(p_tok);
  if pid is null then raise exception 'NO_PROFILE'; end if;
  return pid;
end $$;

create or replace function public._profile_json(p public.profiles) returns json
language sql stable as $$
  select json_build_object('id', p.id, 'name', p.name, 'emoji', p.emoji, 'mode', p.mode, 'crits', p.crits,
    'notes', p.notes, 'coeur', p.coeur, 'top5', p.top5, 'prono', p.prono, 'quiz_score', p.quiz_score,
    'quiz_total', p.quiz_total, 'soulmate', p.soulmate, 'rounds', p.rounds, 'created_at', p.created_at)
$$;

-- Garde-fou des profils : on ne change le classement que de la manche ouverte
create or replace function public._profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; k text;
begin
  if new.rounds is distinct from old.rounds then
    select manche, votes_locked into s from public.results where id = 1;
    foreach k in array array['1','2','3'] loop
      if (new.rounds -> k) is distinct from (old.rounds -> k) then
        if k::int <> s.manche or s.votes_locked then raise exception 'VOTES_LOCKED'; end if;
      end if;
    end loop;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- ---------- Profil ----------
drop function if exists public.my_profile();
create or replace function public.my_profile(p_tok text) returns json
language sql stable security definer set search_path = public as $$
  select public._profile_json(p) from public.profiles p where p.id = public._me(p_tok)
$$;

create or replace function public.create_profile(p_tok text, p_name text, p_emoji text) returns json
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if p_tok is null or char_length(p_tok) < 32 then raise exception 'BAD_TOKEN'; end if;
  select profile_id into pid from public.profile_tokens where tok_hash = public._hash(p_tok);
  if pid is null then
    insert into public.profiles (name, emoji) values (trim(p_name), coalesce(nullif(p_emoji,''), '👑'))
      returning id into pid;
    insert into public.profile_tokens (tok_hash, profile_id) values (public._hash(p_tok), pid);
  end if;
  return public.my_profile(p_tok);
end $$;

create or replace function public.save_profile(p_tok text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(p_tok);
begin
  update public.profiles set
    name       = case when p ? 'name'       then trim(p->>'name')                    else name end,
    emoji      = case when p ? 'emoji'      then p->>'emoji'                         else emoji end,
    mode       = case when p ? 'mode'       then p->>'mode'                          else mode end,
    crits      = case when p ? 'crits'      then p->'crits'                          else crits end,
    notes      = case when p ? 'notes'      then coalesce(p->'notes','{}')           else notes end,
    coeur      = case when p ? 'coeur'      then p->>'coeur'                         else coeur end,
    top5       = case when p ? 'top5'       then coalesce(p->'top5','[]')            else top5 end,
    prono      = case when p ? 'prono'      then p->'prono'                          else prono end,
    quiz_score = case when p ? 'quiz_score' then (p->>'quiz_score')::int             else quiz_score end,
    quiz_total = case when p ? 'quiz_total' then (p->>'quiz_total')::int             else quiz_total end,
    soulmate   = case when p ? 'soulmate'   then p->>'soulmate'                      else soulmate end,
    rounds     = case when p ? 'rounds'     then coalesce(p->'rounds','{}')          else rounds end
  where id = me;
end $$;

drop function if exists public.my_recovery_code();
create or replace function public.my_recovery_code(p_tok text) returns text
language sql stable security definer set search_path = public as $$
  select code from public.recovery where profile_id = public._me(p_tok)
$$;

-- Retrouver son profil sur un nouveau téléphone
drop function if exists public.recover_profile(text);
create or replace function public.recover_profile(p_tok text, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare pid uuid; v_old uuid; h text := public._hash(p_tok);
begin
  if p_tok is null or char_length(p_tok) < 32 then raise exception 'BAD_TOKEN'; end if;
  select profile_id into pid from public.recovery where code = upper(trim(p_code));
  if pid is null then raise exception 'BAD_CODE'; end if;
  select profile_id into v_old from public.profile_tokens where tok_hash = h;
  insert into public.profile_tokens (tok_hash, profile_id) values (h, pid)
    on conflict (tok_hash) do update set profile_id = excluded.profile_id;
  -- le profil vide créé par erreur sur ce téléphone disparaît s'il n'est relié à rien d'autre
  if v_old is not null and v_old <> pid and not exists (select 1 from public.profile_tokens where profile_id = v_old) then
    delete from public.profiles where id = v_old;
  end if;
  return public.my_profile(p_tok);
end $$;

-- ---------- Groupes ----------
drop function if exists public.create_league(text, jsonb);
create or replace function public.create_league(p_tok text, p_name text, p_crits jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(p_tok); c text; lid uuid; nm text := coalesce(nullif(trim(p_name),''),'Mon groupe');
  cr jsonb := coalesce(p_crits, '["beaute","defiles","discours","video","costume","culture","vibe"]'::jsonb);
  words text[] := array['ROSE','PERLE','STRASS','TIARE','SATIN','PLUME','GLAM','DIVA',
                        'LUXE','NACRE','ECRIN','VELOURS','ETOILE','SOIE','BIJOU','RUBIS'];
begin
  if jsonb_typeof(cr) <> 'array' or jsonb_array_length(cr) = 0 then raise exception 'NO_CRITS'; end if;
  loop
    c := words[1 + floor(random()*array_length(words,1))::int] || '-' || lpad(floor(random()*10000)::int::text, 4, '0');
    begin
      insert into public.leagues (code, name, created_by, crits) values (c, nm, me, cr) returning id into lid;
      exit;
    exception when unique_violation then end;
  end loop;
  insert into public.league_members (league_id, profile_id) values (lid, me);
  return json_build_object('id', lid, 'code', c, 'name', nm, 'crits', cr);
end $$;

drop function if exists public.set_league_crits(uuid, jsonb);
create or replace function public.set_league_crits(p_tok text, p_league uuid, p_crits jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(p_tok);
begin
  if not exists (select 1 from public.league_members where league_id = p_league and profile_id = me) then
    raise exception 'NOT_MEMBER';
  end if;
  if jsonb_typeof(p_crits) <> 'array' or jsonb_array_length(p_crits) = 0 then raise exception 'NO_CRITS'; end if;
  update public.leagues set crits = p_crits where id = p_league;
end $$;

drop function if exists public.join_league(text);
create or replace function public.join_league(p_tok text, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(p_tok); myname text; l record;
begin
  select name into myname from public.profiles where id = me;
  select * into l from public.leagues where code = upper(trim(p_code));
  if l.id is null then raise exception 'BAD_CODE'; end if;
  if exists (select 1 from public.league_members m join public.profiles p on p.id = m.profile_id
             where m.league_id = l.id and p.id <> me and lower(p.name) = lower(myname)) then
    raise exception 'NAME_TAKEN';
  end if;
  insert into public.league_members (league_id, profile_id) values (l.id, me) on conflict do nothing;
  return json_build_object('id', l.id, 'code', l.code, 'name', l.name, 'crits', l.crits);
end $$;

drop function if exists public.leave_league(uuid);
create or replace function public.leave_league(p_tok text, p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public._me(p_tok);
begin
  delete from public.league_members where league_id = p_league and profile_id = me;
  delete from public.leagues l where l.id = p_league
    and not exists (select 1 from public.league_members m where m.league_id = l.id);
end $$;

drop function if exists public.my_leagues();
create or replace function public.my_leagues(p_tok text) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', l.id, 'code', l.code, 'name', l.name, 'crits', l.crits,
           'members', (select count(*) from public.league_members x where x.league_id = l.id))
           order by m.joined_at), '[]'::json)
  from public.league_members m join public.leagues l on l.id = m.league_id
  where m.profile_id = public._me(p_tok)
$$;

-- Les joueuses d'un groupe (réservé aux membres ; la manche en cours reste secrète)
drop function if exists public.league_profiles(uuid);
create or replace function public.league_profiles(p_tok text, p_league uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public._me(p_tok);
begin
  if not exists (select 1 from public.league_members where league_id = p_league and profile_id = me) then
    raise exception 'NOT_MEMBER';
  end if;
  return (select coalesce(json_agg(json_build_object(
      'id', p.id, 'name', p.name, 'emoji', p.emoji, 'mode', p.mode, 'crits', p.crits,
      'notes', p.notes, 'coeur', p.coeur, 'quiz_score', p.quiz_score, 'quiz_total', p.quiz_total,
      'soulmate', p.soulmate,
      'rounds', case when p.id = me then p.rounds else public._public_rounds(p.rounds) end
    ) order by m.joined_at), '[]'::json)
  from public.profiles p join public.league_members m on m.profile_id = p.id
  where m.league_id = p_league);
end $$;

-- ---------- Ce que tout le monde voit ----------
-- État de la soirée + classements France déjà révélés (tout prêts, rien à recalculer)
create or replace function public.public_state() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('manche', manche, 'votes_locked', votes_locked, 'show_at', show_at,
    'close_at', close_at, 'top15', top15, 'top5', top5, 'ord', ord, 'fr', fr,
    'v', floor(extract(epoch from updated_at) * 1000)::bigint)
  from public.results where id = 1
$$;

-- Statistiques générales, recalculées au plus toutes les 2 minutes
drop function if exists public.france_stats();
create or replace function public.france_stats() returns json
language plpgsql volatile security definer set search_path = public as $$
declare s jsonb; t timestamptz;
begin
  select stats, stats_at into s, t from public.results where id = 1;
  if s is null or t is null or t < now() - interval '2 minutes' then
    s := jsonb_build_object(
      'players', (select count(*) from public.profiles),
      'voters',  (select count(*) from public.profiles where jsonb_typeof(rounds -> '1') = 'array'),
      'quiz_avg', (select round(avg(quiz_score::numeric / nullif(quiz_total,0)) * 20, 1) from public.profiles where quiz_total > 0),
      'quiz_n',   (select count(*) from public.profiles where quiz_total > 0));
    update public.results set stats = s, stats_at = now() where id = 1;
  end if;
  return s::json;
end $$;

drop function if exists public.france_round(int);

-- ---------- Classement France : calcul par paquets (tient des millions de joueuses) ----------
create or replace function public.admin_fr_step(p_pwd text, n int, p_restart boolean) returns json
language plpgsql security definer set search_path = public as $$
declare j record; v_last uuid; cnt bigint;
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  if n not between 1 and 3 then raise exception 'BAD_MANCHE'; end if;
  if p_restart then
    delete from public.fr_acc where manche = n;
    insert into public.fr_job (manche, voters, last_id) values (n, 0, null)
      on conflict (manche) do update set voters = 0, last_id = null;
  end if;
  select * into j from public.fr_job where manche = n;
  with batch as (
    select id, rounds from public.profiles
    where (j.last_id is null or id > j.last_id) order by id limit 15000
  ), e as (
    select x.value #>> '{}' as cand, x.ord from batch b,
      jsonb_array_elements(case when jsonb_typeof(b.rounds -> n::text) = 'array' then b.rounds -> n::text else '[]'::jsonb end)
      with ordinality as x(value, ord)
  ), ins as (
    insert into public.fr_acc (manche, cand, pts)
    select n, cand, sum(32 - ord) from e group by cand
    on conflict (manche, cand) do update set pts = public.fr_acc.pts + excluded.pts
    returning 1
  )
  select (select max(id::text)::uuid from batch),
         (select count(*) from batch where jsonb_typeof(rounds -> n::text) = 'array')
    into v_last, cnt;
  if v_last is null then
    return json_build_object('done', true, 'voters', j.voters);
  end if;
  update public.fr_job set voters = voters + cnt, last_id = v_last where manche = n;
  return json_build_object('done', false, 'voters', j.voters + cnt);
end $$;

-- Regarder le classement calculé (aperçu admin) ou le révéler à tout le monde
create or replace function public.admin_fr_finish(p_pwd text, n int, p_publish boolean) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  select json_build_object('manche', n, 'hidden', false,
           'voters', coalesce((select voters from public.fr_job where manche = n), 0),
           'order', coalesce((select json_agg(cand order by pts desc, cand) from public.fr_acc where manche = n), '[]'::json))
    into r;
  if p_publish then
    update public.results set fr = fr || jsonb_build_object(n::text, r::jsonb), updated_at = now() where id = 1;
  end if;
  return r;
end $$;

-- ---------- Pilotage de la soirée (admin) ----------
create or replace function public.admin_set_state(p_pwd text, p_manche int, p_locked boolean,
                                                  p_show_at timestamptz, p_close_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  if p_manche not between 1 and 4 then raise exception 'BAD_MANCHE'; end if;
  update public.results set manche = p_manche, votes_locked = p_locked,
    show_at = coalesce(p_show_at, show_at), close_at = p_close_at,
    -- une manche rouverte par erreur redevient secrète
    fr = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(fr) as x(k, v)
          where k::int < p_manche or (k::int = p_manche and p_locked)),
    updated_at = now()
  where id = 1;
end $$;

create or replace function public.admin_set_results(p_pwd text, p_top15 jsonb, p_top5 jsonb, p_ord jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  update public.results set top15 = p_top15, top5 = p_top5, ord = p_ord, updated_at = now() where id = 1;
end $$;

create or replace function public.admin_reset_night(p_pwd text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  alter table public.profiles disable trigger profiles_guard;
  update public.profiles set rounds = (rounds - '2') - '3' where rounds ? '2' or rounds ? '3';
  alter table public.profiles enable trigger profiles_guard;
  delete from public.fr_acc; delete from public.fr_job;
  update public.results set manche = 1, votes_locked = false, close_at = null, fr = '{}',
    top15 = '[]', top5 = '[]', ord = '[null,null,null,null,null]', updated_at = now() where id = 1;
end $$;

drop function if exists public.admin_france_round(text, int);
drop function if exists public.admin_set_lock(text, boolean);

-- ---------- Droits : seules ces fonctions sont accessibles depuis l'appli ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.my_profile(text), public.create_profile(text, text, text), public.save_profile(text, jsonb),
  public.my_recovery_code(text), public.recover_profile(text, text),
  public.create_league(text, text, jsonb), public.set_league_crits(text, uuid, jsonb),
  public.join_league(text, text), public.leave_league(text, uuid), public.my_leagues(text),
  public.league_profiles(text, uuid), public.public_state(), public.france_stats(),
  public.admin_check(text), public.admin_set_results(text, jsonb, jsonb, jsonb),
  public.admin_set_state(text, int, boolean, timestamptz, timestamptz), public.admin_reset_night(text),
  public.admin_fr_step(text, int, boolean), public.admin_fr_finish(text, int, boolean)
  to anon;

-- Remettre les classements déjà révélés dans la nouvelle mémoire (si une manche était fermée)
do $$ declare s record; n int; r json; begin
  select * into s from public.results where id = 1;
  for n in 1..3 loop
    if s.manche > n or (s.manche = n and s.votes_locked) then
      with e as (
        select x.value #>> '{}' as cand, x.ord from public.profiles p,
          jsonb_array_elements(p.rounds -> n::text) with ordinality as x(value, ord)
        where jsonb_typeof(p.rounds -> n::text) = 'array'
      ), rk as (select cand, sum(32 - ord) as pts from e group by cand)
      select json_build_object('manche', n, 'hidden', false,
        'voters', (select count(*) from public.profiles where jsonb_typeof(rounds -> n::text) = 'array'),
        'order', coalesce((select json_agg(cand order by pts desc, cand) from rk), '[]'::json)) into r;
      update public.results set fr = fr || jsonb_build_object(n::text, r::jsonb) where id = 1;
    end if;
  end loop;
end $$;

select 'Mise à jour L''Élue n°5 installée ✅' as statut;
