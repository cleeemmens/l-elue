-- =====================================================================
--  L'ÉLUE — mise à jour n°2 : le jeu en 3 manches
--  À coller en entier dans Supabase > SQL Editor > New query, puis "Run".
--  (Ton mot de passe admin ne change pas, rien à modifier dans ce script.)
-- =====================================================================

-- ---------- Nouvelles colonnes ----------
alter table public.profiles add column if not exists rounds jsonb not null default '{}'::jsonb;
alter table public.profiles drop constraint if exists rounds_size;
alter table public.profiles add constraint rounds_size check (pg_column_size(rounds) < 20000);

alter table public.results add column if not exists manche   int not null default 1;
alter table public.results add column if not exists show_at  timestamptz not null default '2026-12-12 21:10:00+01';
alter table public.results add column if not exists close_at timestamptz;
update public.results set votes_locked = false where id = 1 and manche = 1 and top15 = '[]'::jsonb;

-- ---------- Les classements des autres restent secrets pendant une manche ----------
-- On ne laisse lire que les colonnes "publiques" des profils ; le reste passe par des fonctions.
revoke select on public.profiles from anon, authenticated;
grant select (id, name, emoji, created_at) on public.profiles to anon, authenticated;

-- Mon profil complet
create or replace function public.my_profile() returns public.profiles
language sql stable security definer set search_path = public as $$
  select * from public.profiles where owner = auth.uid()
$$;

-- Masque la manche en cours tant qu'elle n'est pas fermée
create or replace function public._public_rounds(r jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when s.votes_locked then r else coalesce(r, '{}'::jsonb) - s.manche::text end
  from public.results s where s.id = 1
$$;

-- Les joueuses d'un groupe (avec la manche en cours masquée pour les autres)
drop function if exists public.league_profiles(uuid);
create or replace function public.league_profiles(p_league uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
      'id', p.id, 'name', p.name, 'emoji', p.emoji, 'mode', p.mode, 'crits', p.crits,
      'notes', p.notes, 'coeur', p.coeur, 'quiz_score', p.quiz_score, 'quiz_total', p.quiz_total,
      'soulmate', p.soulmate,
      'rounds', case when p.owner = auth.uid() then p.rounds else public._public_rounds(p.rounds) end
    ) order by m.joined_at), '[]'::json)
  from public.profiles p join public.league_members m on m.profile_id = p.id
  where m.league_id = p_league
$$;

-- ---------- Règles d'écriture ----------
create or replace function public._profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; k text;
begin
  select * into s from public.results where id = 1;
  if new.rounds is distinct from old.rounds then
    foreach k in array array['1','2','3'] loop
      if (new.rounds -> k) is distinct from (old.rounds -> k) then
        if k::int <> s.manche or s.votes_locked then
          raise exception 'VOTES_LOCKED';
        end if;
      end if;
    end loop;
  end if;
  new.updated_at := now();
  if coalesce(current_setting('app.recovering', true), '') <> 'on' then
    new.owner := old.owner;
  end if;
  return new;
end $$;

-- ---------- Le classement de la France, manche par manche ----------
-- Chaque classement donne des points : 1re place = beaucoup, dernière = peu (méthode Borda).
create or replace function public._france_round(n int) returns json
language sql stable security definer set search_path = public as $$
  with e as (
    select x.value #>> '{}' as cand, x.ord
    from public.profiles p, jsonb_array_elements(p.rounds -> n::text) with ordinality as x(value, ord)
    where jsonb_typeof(p.rounds -> n::text) = 'array'
  ), rk as (
    select cand, sum(32 - ord)::int as pts from e group by cand
  )
  select json_build_object(
    'manche', n,
    'hidden', false,
    'voters', (select count(*) from public.profiles where jsonb_typeof(rounds -> n::text) = 'array'),
    'order', coalesce((select json_agg(cand order by pts desc, cand) from rk), '[]'::json)
  )
$$;
revoke all on function public._france_round(int) from public, anon, authenticated;

create or replace function public.france_round(n int) returns json
language plpgsql stable security definer set search_path = public as $$
declare s record;
begin
  select * into s from public.results where id = 1;
  if s.manche > n or (s.manche = n and s.votes_locked) then
    return public._france_round(n);
  end if;
  return json_build_object('manche', n, 'hidden', true,
    'voters', (select count(*) from public.profiles where jsonb_typeof(rounds -> n::text) = 'array'));
end $$;

create or replace function public.admin_france_round(p_pwd text, n int) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  return public._france_round(n);
end $$;

-- ---------- Pilotage de la soirée (admin) ----------
create or replace function public.admin_set_state(p_pwd text, p_manche int, p_locked boolean,
                                                  p_show_at timestamptz, p_close_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  if p_manche not between 1 and 4 then raise exception 'BAD_MANCHE'; end if;
  update public.results set manche = p_manche, votes_locked = p_locked,
    show_at = coalesce(p_show_at, show_at), close_at = p_close_at, updated_at = now()
  where id = 1;
end $$;

-- Remise à zéro de la soirée (pour faire des essais avant le jour J)
create or replace function public.admin_reset_night(p_pwd text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  alter table public.profiles disable trigger profiles_guard;
  update public.profiles set rounds = (rounds - '2') - '3' where rounds ? '2' or rounds ? '3';
  alter table public.profiles enable trigger profiles_guard;
  update public.results set manche = 1, votes_locked = false, close_at = null,
    top15 = '[]', top5 = '[]', ord = '[null,null,null,null,null]', updated_at = now() where id = 1;
end $$;

-- Statistiques générales (nombre de joueuses, moyenne du quiz)
create or replace function public.france_stats() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'players', (select count(*) from public.profiles),
    'voters',  (select count(*) from public.profiles where jsonb_typeof(rounds -> '1') = 'array'),
    'quiz_avg', (select round(avg(quiz_score::numeric / nullif(quiz_total,0)) * 20, 1) from public.profiles where quiz_total > 0),
    'quiz_n',   (select count(*) from public.profiles where quiz_total > 0)
  )
$$;

grant execute on function public.my_profile(), public.league_profiles(uuid), public.france_round(int),
  public.admin_france_round(text, int), public.admin_reset_night(text), public.admin_set_state(text, int, boolean, timestamptz, timestamptz),
  public.france_stats()
  to anon, authenticated;

select 'Mise à jour L''Élue n°2 installée ✅' as statut;
