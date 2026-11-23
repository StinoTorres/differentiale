-- Differentiale: maandtrofee in de poule (naast de weekbeker).
-- Per afgelopen kalendermaand krijgt de hoogste maandscore in de poule een trofee 👑; gelijk = allebei.
-- Alleen hele maanden tellen: oktober 2026 (het spel begon op 31 oktober) doet niet mee.
-- Plak in Supabase → SQL Editor → Run. Veilig om opnieuw te draaien.

-- Maandnummer van een speldag (jaar * 12 + maand), dag 0 = 31-10-2026
create or replace function public.av_month(p_day int) returns int
language sql immutable as $$
  select (extract(year from date '2026-10-31' + p_day) * 12 + extract(month from date '2026-10-31' + p_day))::int
$$;

-- Telt een maand mee voor de trofee? Alleen als de hele maand binnen het spel valt.
create or replace function public.av_month_full(p_month int) returns boolean
language sql immutable as $$
  select make_date(((p_month - 1) / 12)::int, ((p_month - 1) % 12 + 1)::int, 1) >= date '2026-10-31'
$$;

drop function if exists public.av_board(uuid, uuid, text);
create function public.av_board(p_player uuid, p_secret uuid, p_scope text)
returns table (name text, tag text, is_me boolean, today_played boolean, today_n int, today_won boolean,
               today_gave_up boolean, today_points int, week_points int, last_week_points int, season_points int,
               streak int, cups int, month_points int, last_month_points int, month_cups int)
language plpgsql stable security definer set search_path = public as $$
declare d int := av_today(); v_wk int := av_week(av_today()); v_mo int := av_month(av_today()); v_done boolean;
        v_scope text := upper(coalesce(p_scope, ''));
begin
  perform av_check(p_player, p_secret);
  -- alleen poule-klassementen: geen openbare ranglijst
  if not exists (select 1 from av_members where player_id = p_player and league_code = v_scope) then
    raise exception 'Je zit niet in deze poule';
  end if;
  select coalesce((select done from av_games where player_id = p_player and day = d), false) into v_done;
  return query
    with grp as (
      select p.id, p.name, p.tag from av_players p
      where exists (select 1 from av_members m where m.player_id = p.id and m.league_code = v_scope)
    ),
    g as (
      select x.player_id, x.day, x.points, x.won, x.done, x.gave_up, cardinality(x.guesses) n
      from av_games x join grp on grp.id = x.player_id where x.done and x.day <= d
    ),
    wk as (select player_id, av_week(day) w, sum(points) pts from g group by 1, 2),
    best as (select w, max(pts) mx from wk where w < v_wk group by w),
    cup as (select wk.player_id, count(*)::int c from wk join best on best.w = wk.w and wk.pts = best.mx and best.mx > 0 group by 1),
    mo as (select player_id, av_month(day) m, sum(points) pts from g group by 1, 2),
    mbest as (select m, max(pts) mx from mo where m < v_mo and av_month_full(m) group by m),
    mcup as (select mo.player_id, count(*)::int c from mo join mbest on mbest.m = mo.m and mo.pts = mbest.mx and mbest.mx > 0 group by 1)
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
           coalesce(cup.c, 0),
           coalesce((select sum(pts) from mo where mo.player_id = grp.id and mo.m = v_mo), 0)::int,
           -- vorige maand telt alleen als het een hele maand was (anders geen trofee en geen banner)
           coalesce((select sum(pts) from mo where mo.player_id = grp.id and mo.m = v_mo - 1 and av_month_full(v_mo - 1)), 0)::int,
           coalesce(mcup.c, 0)
    from grp
    left join g t on t.player_id = grp.id and t.day = d
    left join cup on cup.player_id = grp.id
    left join mcup on mcup.player_id = grp.id;
end $$;

revoke all on function public.av_month(int), public.av_month_full(int) from public, anon, authenticated;
revoke all on function public.av_board(uuid, uuid, text) from public;
grant execute on function public.av_board(uuid, uuid, text) to anon, authenticated;
