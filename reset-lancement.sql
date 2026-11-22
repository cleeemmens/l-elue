-- =====================================================================
--  L'ÉLUE — TOUT EFFACER avant le lancement
--  Supprime TOUS les profils, groupes, classements, notes et résultats.
--  Garde uniquement ton mot de passe admin. IRRÉVERSIBLE.
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
-- =====================================================================
delete from public.league_members where true;
delete from public.leagues where true;
delete from public.profile_tokens where true;
delete from public.recovery where true;
delete from public.profiles where true;
delete from public.fr_acc where true;
delete from public.fr_job where true;
update public.results set manche = 1, votes_locked = false, close_at = null, fr = '{}',
  top15 = '[]', top5 = '[]', ord = '[null,null,null,null,null]', stats = null, stats_at = null,
  updated_at = now() where id = 1;
select 'Tout est effacé, prête pour le lancement ✅' as statut;
