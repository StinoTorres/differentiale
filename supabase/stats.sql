-- Differentiale: gokverdeling + "x% had hem vandaag", en av_ping om Supabase wakker te houden.
-- Plak in Supabase → SQL Editor → Run. Veilig om opnieuw te draaien.

create or replace function public.av_state(p_player uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d int := av_today(); g av_games; a av_fpl; v_rows jsonb; v_hint jsonb; c int; v_total int;
begin
  select * into g from av_games where player_id = p_player and day = d;
  select * into a from av_fpl where code = av_answer(d);
  select coalesce(jsonb_agg(av_fpl_json(f) || jsonb_build_object('fb', av_cmp(f, a)) order by x.ord), '[]'::jsonb)
    into v_rows
    from unnest(coalesce(g.guesses, '{}'::int[])) with ordinality x(code, ord) join av_fpl f on f.code = x.code;
  select coalesce((value #>> '{}')::int, 0) into v_total from av_meta where key = 'league_total';
  if coalesce(g.hints, 0) >= 1 then
    select coalesce((select p.n from av_picks p where p.code = a.code), 0) into c;
    v_hint := jsonb_build_object('yes', c > 0, 'count', case when g.hints >= 2 then c end);
  end if;
  return jsonb_build_object(
    'day', d, 'rows', v_rows, 'hints', coalesce(g.hints, 0), 'hint', v_hint,
    'done', coalesce(g.done, false), 'won', coalesce(g.won, false), 'gave_up', coalesce(g.gave_up, false),
    'points', coalesce(g.points, 0),
    'answer', case when g.done then av_fpl_json(a) end,
    'fpl_gw', (select (value #>> '{}')::int from av_meta where key = 'fpl_gw'),
    'league', jsonb_build_object('name', (select value #>> '{}' from av_meta where key = 'league_name'),
                                 'total', v_total,
                                 'gw', (select (value #>> '{}')::int from av_meta where key = 'league_gw')),
    'stats', jsonb_build_object(
      'played', (select count(*) from av_games where player_id = p_player and done),
      'won', (select count(*) from av_games where player_id = p_player and won),
      'streak', av_streak(p_player), 'best', av_best(p_player),
      -- gokverdeling: [1/6, 2/6, 3/6, 4/6, 5/6, 6/6, niet geraden]
      'dist', (select jsonb_build_array(
                 count(*) filter (where won and cardinality(guesses) = 1), count(*) filter (where won and cardinality(guesses) = 2),
                 count(*) filter (where won and cardinality(guesses) = 3), count(*) filter (where won and cardinality(guesses) = 4),
                 count(*) filter (where won and cardinality(guesses) = 5), count(*) filter (where won and cardinality(guesses) = 6),
                 count(*) filter (where not won))
               from av_games where player_id = p_player and done)),
    -- hoe deed iedereen het vandaag (pas zichtbaar als je zelf klaar bent)
    'today', case when g.done then (select jsonb_build_object('played', count(*), 'won', count(*) filter (where won)) from av_games where day = d and done) end);
end $$;


-- Lichte aanroep voor de GitHub-update, zodat een gratis Supabase-project niet wordt gepauzeerd
create or replace function public.av_ping() returns int
language sql stable security definer set search_path = public as $$ select count(*)::int from av_meta $$;

revoke all on function public.av_state(uuid) from public, anon, authenticated;
revoke all on function public.av_ping() from public, anon, authenticated;
grant execute on function public.av_ping() to service_role;
