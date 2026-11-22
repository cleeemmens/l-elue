-- =====================================================================
--  L'ÉLUE — mise à jour n°6 : réparer « Réinitialiser la soirée »
--  (Supabase refuse les suppressions sans condition : on en ajoute une)
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
-- =====================================================================
create or replace function public.admin_reset_night(p_pwd text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_pwd) then raise exception 'NOT_ADMIN'; end if;
  alter table public.profiles disable trigger profiles_guard;
  update public.profiles set rounds = (rounds - '2') - '3' where rounds ? '2' or rounds ? '3';
  alter table public.profiles enable trigger profiles_guard;
  delete from public.fr_acc where manche > 0;
  delete from public.fr_job where manche > 0;
  update public.results set manche = 1, votes_locked = false, close_at = null, fr = '{}',
    top15 = '[]', top5 = '[]', ord = '[null,null,null,null,null]', updated_at = now() where id = 1;
end $$;
grant execute on function public.admin_reset_night(text) to anon;

-- Et on remet la soirée à zéro tout de suite
alter table public.profiles disable trigger profiles_guard;
update public.profiles set rounds = (rounds - '2') - '3' where rounds ? '2' or rounds ? '3';
alter table public.profiles enable trigger profiles_guard;
delete from public.fr_acc where manche > 0;
delete from public.fr_job where manche > 0;
update public.results set manche = 1, votes_locked = false, close_at = null, fr = '{}',
  top15 = '[]', top5 = '[]', ord = '[null,null,null,null,null]', updated_at = now() where id = 1;

select 'Soirée remise à zéro ✅' as statut;
