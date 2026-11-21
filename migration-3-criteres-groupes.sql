-- =====================================================================
--  L'ÉLUE — mise à jour n°3 : chaque groupe choisit ses critères
--  À coller en entier dans Supabase > SQL Editor > New query, puis "Run".
-- =====================================================================

alter table public.leagues add column if not exists crits jsonb not null
  default '["beaute","defiles","discours","video","costume","culture","vibe"]';

-- Créer un groupe (avec ses critères)
drop function if exists public.create_league(text);
create or replace function public.create_league(p_name text, p_crits jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid; c text; lid uuid; nm text := coalesce(nullif(trim(p_name),''),'Mon groupe');
  cr jsonb := coalesce(p_crits, '["beaute","defiles","discours","video","costume","culture","vibe"]'::jsonb);
  words text[] := array['ROSE','PERLE','STRASS','TIARE','SATIN','PLUME','GLAM','DIVA',
                        'LUXE','NACRE','ECRIN','VELOURS','ETOILE','SOIE','BIJOU','RUBIS'];
begin
  select id into me from public.profiles where owner = auth.uid();
  if me is null then raise exception 'NO_PROFILE'; end if;
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

-- Modifier les critères d'un groupe (réservé à ses membres)
create or replace function public.set_league_crits(p_league uuid, p_crits jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.league_members m join public.profiles p on p.id = m.profile_id
                 where m.league_id = p_league and p.owner = auth.uid()) then
    raise exception 'NOT_MEMBER';
  end if;
  if jsonb_typeof(p_crits) <> 'array' or jsonb_array_length(p_crits) = 0 then raise exception 'NO_CRITS'; end if;
  update public.leagues set crits = p_crits where id = p_league;
end $$;

-- Mes groupes (avec leurs critères)
create or replace function public.my_leagues() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', l.id, 'code', l.code, 'name', l.name, 'crits', l.crits,
           'members', (select count(*) from public.league_members x where x.league_id = l.id))
           order by m.joined_at), '[]'::json)
  from public.league_members m
  join public.leagues l on l.id = m.league_id
  join public.profiles p on p.id = m.profile_id
  where p.owner = auth.uid()
$$;

grant execute on function public.create_league(text, jsonb), public.set_league_crits(uuid, jsonb), public.my_leagues()
  to anon, authenticated;

select 'Mise à jour L''Élue n°3 installée ✅' as statut;
