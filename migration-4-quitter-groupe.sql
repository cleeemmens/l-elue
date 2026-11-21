-- =====================================================================
--  L'ÉLUE — mise à jour n°4 : réparer « Quitter ce groupe »
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
-- =====================================================================
create or replace function public.leave_league(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid;
begin
  select id into me from public.profiles where owner = auth.uid();
  if me is null then raise exception 'NO_PROFILE'; end if;
  delete from public.league_members where league_id = p_league and profile_id = me;
  -- un groupe qui n'a plus personne disparaît
  delete from public.leagues l where l.id = p_league
    and not exists (select 1 from public.league_members m where m.league_id = l.id);
end $$;
grant execute on function public.leave_league(uuid) to anon, authenticated;

select 'Mise à jour L''Élue n°4 installée ✅' as statut;
