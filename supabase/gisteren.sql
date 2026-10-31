-- Differentiale: "Wie was het gisteren?" en de gameweek van de cijfers doorgeven.
-- Plak in Supabase → SQL Editor → Run. Veilig om opnieuw te draaien.

-- av_state: geeft nu ook fpl_gw door (van welke afgeronde gameweek de cijfers zijn)
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
      'streak', av_streak(p_player), 'best', av_best(p_player)));
end $$;

-- Wie was het gisteren? Het antwoord van gisteren plus jouw uitslag van gisteren.
create or replace function public.av_yesterday(p_player uuid, p_secret uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d int := av_today() - 1; a av_fpl; g av_games;
begin
  perform av_check(p_player, p_secret);
  if d < 0 then return null; end if;
  select * into a from av_fpl where code = av_answer(d);
  if a is null then return null; end if;
  select * into g from av_games where player_id = p_player and day = d;
  return jsonb_build_object('day', d, 'answer', av_fpl_json(a),
    'played', coalesce(g.done, false), 'won', coalesce(g.won, false), 'gave_up', coalesce(g.gave_up, false),
    'n', cardinality(coalesce(g.guesses, '{}'::int[])), 'points', coalesce(g.points, 0));
end $$;

revoke all on function public.av_state(uuid) from public, anon, authenticated;
revoke all on function public.av_yesterday(uuid, uuid) from public;
grant execute on function public.av_yesterday(uuid, uuid) to anon, authenticated;
