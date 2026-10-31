-- Differentiale: "Kleine speler" (opgeven), net als bij Transferroute.
-- Plak in Supabase → SQL Editor → Run. Veilig om opnieuw te draaien.

alter table public.av_games add column if not exists gave_up boolean not null default false;

-- Opgeven: het spel van vandaag is klaar, 0 punten, en je reeks stopt (net als niet geraden)
create or replace function public.av_giveup(p_player uuid, p_secret uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d int := av_today();
begin
  perform av_check(p_player, p_secret);
  insert into av_games(player_id, day) values (p_player, d) on conflict do nothing;
  update av_games set done = true, won = false, gave_up = true, points = 0, updated_at = now()
   where player_id = p_player and day = d and not done;
  return av_state(p_player);
end $$;

-- av_state: ook doorgeven of je hebt opgegeven
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
    'league', jsonb_build_object('name', (select value #>> '{}' from av_meta where key = 'league_name'),
                                 'total', v_total,
                                 'gw', (select (value #>> '{}')::int from av_meta where key = 'league_gw')),
    'stats', jsonb_build_object(
      'played', (select count(*) from av_games where player_id = p_player and done),
      'won', (select count(*) from av_games where player_id = p_player and won),
      'streak', av_streak(p_player), 'best', av_best(p_player)));
end $$;

-- Klassement: extra kolom today_gave_up (daarom eerst weggooien en opnieuw maken)
drop function if exists public.av_board(uuid, uuid, text);
create function public.av_board(p_player uuid, p_secret uuid, p_scope text)
returns table (name text, tag text, is_me boolean, today_played boolean, today_n int, today_won boolean,
               today_gave_up boolean, today_points int, week_points int, last_week_points int, season_points int,
               streak int, cups int)
language plpgsql stable security definer set search_path = public as $$
declare d int := av_today(); v_wk int := av_week(av_today()); v_done boolean; v_scope text := upper(coalesce(p_scope, 'ALL'));
begin
  perform av_check(p_player, p_secret);
  if v_scope <> 'ALL' and not exists (select 1 from av_members where player_id = p_player and league_code = v_scope) then
    raise exception 'Je zit niet in deze poule';
  end if;
  select coalesce((select done from av_games where player_id = p_player and day = d), false) into v_done;
  return query
    with grp as (
      select p.id, p.name, p.tag from av_players p
      where v_scope = 'ALL' or exists (select 1 from av_members m where m.player_id = p.id and m.league_code = v_scope)
    ),
    g as (
      select x.player_id, x.day, x.points, x.won, x.done, x.gave_up, cardinality(x.guesses) n
      from av_games x join grp on grp.id = x.player_id where x.done and x.day <= d
    ),
    wk as (
      select player_id, av_week(day) w, sum(points) pts from g group by 1, 2
    ),
    best as (
      select w, max(pts) mx from wk where w < v_wk group by w
    ),
    cup as (
      select wk.player_id, count(*)::int c from wk join best on best.w = wk.w and wk.pts = best.mx and best.mx > 0 group by 1
    )
    select grp.name, grp.tag, grp.id = p_player,
           t.player_id is not null,
           case when v_done or grp.id = p_player then t.n end::int,
           case when v_done or grp.id = p_player then t.won end,
           case when v_done or grp.id = p_player then t.gave_up end,
           case when v_done or grp.id = p_player then t.points end::int,
           coalesce((select sum(pts) from wk where wk.player_id = grp.id and wk.w = v_wk), 0)::int,
           coalesce((select sum(pts) from wk where wk.player_id = grp.id and wk.w = v_wk - 1), 0)::int,
           coalesce((select sum(points) from g where g.player_id = grp.id), 0)::int,
           av_streak(grp.id),
           coalesce(cup.c, 0)
    from grp
    left join g t on t.player_id = grp.id and t.day = d
    left join cup on cup.player_id = grp.id
    where exists (select 1 from g where g.player_id = grp.id) or v_scope <> 'ALL' or grp.id = p_player;
end $$;

-- Rechten
revoke all on function public.av_state(uuid) from public, anon, authenticated;
revoke all on function public.av_giveup(uuid, uuid), public.av_board(uuid, uuid, text) from public;
grant execute on function public.av_giveup(uuid, uuid), public.av_board(uuid, uuid, text) to anon, authenticated;
