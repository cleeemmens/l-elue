-- =====================================================================
--  L'ÉLUE — EFFACER LA SIMULATION
--  Supprime toutes les joueuses « Simu-... » (et leurs groupes vides) et remet la soirée à zéro.
--  Tes vrais profils et ton mot de passe admin ne sont pas touchés.
-- =====================================================================
delete from public.profiles where name like 'Simu-%';
delete from public.leagues l where not exists (select 1 from public.league_members m where m.league_id = l.id);
alter table public.profiles disable trigger profiles_guard;
update public.profiles set rounds = (rounds - '2') - '3' where rounds ? '2' or rounds ? '3';
alter table public.profiles enable trigger profiles_guard;
update public.results set manche = 1, votes_locked = false, close_at = null,
  top15 = '[]', top5 = '[]', ord = '[null,null,null,null,null]', updated_at = now() where id = 1;
select 'Simulation effacée, soirée remise à zéro ✅' as statut;
