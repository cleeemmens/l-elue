-- =====================================================================
--  L'ÉLUE — SIMULATION : 100 joueuses fictives + fin de la manche 1
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Tout ce qui est créé ici s'appelle « Simu-... » et s'efface avec simulation-effacer.sql
-- =====================================================================
do $$
declare i int; ord jsonb;
begin
  -- popularité de base de chaque candidate (certaines plaisent plus que d'autres)
  create temp table if not exists _pop(cand text, base float) on commit drop;
  delete from _pop;
  insert into _pop select 'c'||g, random()*10 from generate_series(0,30) g;
  for i in 1..100 loop
    select jsonb_agg(cand order by base + random()*7 desc) into ord from _pop;
    insert into public.profiles(owner, name, emoji, notes, rounds, quiz_score, quiz_total)
    values (gen_random_uuid(), 'Simu-' || lpad(i::text, 3, '0'),
            (array['👑','💄','✨','🌸','💅','🦋','💎','🎀'])[1 + floor(random()*8)::int],
            '{}'::jsonb, jsonb_build_object('1', ord),
            20 + floor(random()*35)::int, 60);
  end loop;
end $$;

-- fin de la manche 1 : les votes sont fermés et le classement de la France est révélé
update public.results set manche = 1, votes_locked = true, close_at = null, updated_at = now() where id = 1;

select count(*) as joueuses_simulees from public.profiles where name like 'Simu-%';
