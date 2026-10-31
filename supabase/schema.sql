-- Asset van de Dag: alles voor Supabase in één script.
-- Plak dit in Supabase → SQL Editor → New query → Run. Daarna seed.sql op dezelfde manier.
-- Het is veilig om het opnieuw te draaien. Alle namen beginnen met av_, zodat het naast
-- andere spellen (zoals Transferroute) in hetzelfde Supabase-project kan staan.
--
-- Beveiliging: de tabellen zijn NIET leesbaar of schrijfbaar met de publieke (anon) sleutel.
-- Alles loopt via de functies hieronder. Die controleren wie je bent met de geheime code op je
-- telefoon. Het antwoord van de dag staat alleen hier op de server en gaat pas naar je telefoon
-- als je klaar bent; ook je score rekent de server zelf uit.

-- ---------- Tabellen ----------
create table if not exists public.av_players (
  id          uuid primary key default gen_random_uuid(),
  secret      uuid not null default gen_random_uuid(),
  recovery    text not null unique,                 -- herstelcode, 12 tekens
  name        text not null check (char_length(name) between 1 and 24),
  tag         text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.av_leagues (
  code        text primary key check (code ~ '^[A-Z0-9]{6}$'),
  name        text not null check (char_length(name) between 1 and 30),
  created_by  uuid references public.av_players(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.av_members (
  player_id   uuid not null references public.av_players(id) on delete cascade,
  league_code text not null references public.av_leagues(code) on delete cascade,
  joined_at   timestamptz not null default now(),
  primary key (player_id, league_code)
);

-- FPL-gegevens van alle spelers (bijgewerkt door de GitHub Action)
create table if not exists public.av_fpl (
  code        int primary key,                      -- vaste FPL-spelerscode
  web         text not null,
  team        int not null,
  pos         int not null,
  price       int not null,                         -- in tienden: 62 = £6.2m
  own         numeric not null,
  pts         int not null,
  gw          int not null,
  updated_at  timestamptz not null default now()
);

-- Antwoord per speldag (dag 0 = 31 oktober 2026). Reserves vangen spelers op die uit FPL verdwijnen.
create table if not exists public.av_answers (
  day         int primary key,
  code        int not null,
  spare       boolean not null default false
);

-- Snoep PL: in hoeveel teams zit een speler (alleen aantallen, geen namen)
create table if not exists public.av_picks (
  code        int primary key,
  n           int not null
);

create table if not exists public.av_meta (
  key         text primary key,
  value       jsonb not null
);

-- Eén spel per speler per dag
create table if not exists public.av_games (
  player_id   uuid not null references public.av_players(id) on delete cascade,
  day         int  not null,
  guesses     int[] not null default '{}',
  hints       int  not null default 0,
  done        boolean not null default false,
  won         boolean not null default false,
  points      int  not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (player_id, day)
);

create index if not exists av_games_day_idx on public.av_games(day);
create index if not exists av_members_league_idx on public.av_members(league_code);

alter table public.av_players enable row level security;
alter table public.av_leagues enable row level security;
alter table public.av_members enable row level security;
alter table public.av_fpl     enable row level security;
alter table public.av_answers enable row level security;
alter table public.av_picks   enable row level security;
alter table public.av_meta    enable row level security;
alter table public.av_games   enable row level security;
revoke all on public.av_players, public.av_leagues, public.av_members, public.av_fpl,
              public.av_answers, public.av_picks, public.av_meta, public.av_games from anon, authenticated;

-- ---------- Interne hulpfuncties (niet aan te roepen vanaf de telefoon) ----------
-- Speldag volgens de Nederlandse kalender (dag 0 = 31 oktober 2026)
create or replace function public.av_today() returns int
language sql stable as $$
  select ((now() at time zone 'Europe/Amsterdam')::date - date '2026-10-31')::int
$$;

-- Week (maandag t/m zondag); dag 0 is een zaterdag
create or replace function public.av_week(p_day int) returns int
language sql immutable as $$ select floor((p_day + 5) / 7.0)::int $$;

-- Willekeurige code zonder verwarrende tekens (geen O/0, I/1), sterk willekeurig via gen_random_uuid
create or replace function public.av_code(p_len int) returns text
language sql volatile as $$
  with u as (select decode(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 'hex') b)
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (get_byte(u.b, i) % 32), 1), '' order by i)
  from u, unnest(array[0,1,2,3,4,5,10,11,12,13,14,15,16,17,18,19,20,21,26,27,28,29,30,31]) with ordinality t(i, ord)
  where ord <= p_len
$$;

create or replace function public.av_check(p_player uuid, p_secret uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from av_players where id = p_player and secret = p_secret) then
    raise exception 'Onbekende speler';
  end if;
end $$;

create or replace function public.av_answer(p_day int) returns int
language sql stable security definer set search_path = public as $$
  select code from av_answers where not spare
  order by day offset (greatest(p_day, 0) % greatest((select count(*) from av_answers where not spare), 1)) limit 1
$$;

create or replace function public.av_num(g numeric, a numeric, tol numeric) returns jsonb
language sql immutable as $$
  select case when a = g then jsonb_build_object('c', 'exact')
              else jsonb_build_object('c', case when abs(a - g) <= tol then 'close' else 'miss' end,
                                      'd', case when a > g then 1 else -1 end) end
$$;

create or replace function public.av_cmp(g public.av_fpl, a public.av_fpl) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'team',  jsonb_build_object('c', case when g.team = a.team then 'exact' else 'miss' end),
    'pos',   jsonb_build_object('c', case when g.pos  = a.pos  then 'exact' else 'miss' end),
    'price', public.av_num(g.price, a.price, 10),
    'own',   public.av_num(g.own,   a.own,   8),
    'pts',   public.av_num(g.pts,   a.pts,   10),
    'gw',    public.av_num(g.gw,    a.gw,    3))
$$;

create or replace function public.av_fpl_json(f public.av_fpl) returns jsonb
language sql immutable as $$
  select jsonb_build_object('code', f.code, 'web', f.web, 'team', f.team, 'pos', f.pos,
                            'price', f.price, 'own', f.own, 'pts', f.pts, 'gw', f.gw)
$$;

-- Huidige reeks en beste reeks (aaneengesloten geraden dagen)
create or replace function public.av_streak(p_player uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare d int := av_today(); n int := 0;
begin
  if exists (select 1 from av_games where player_id = p_player and day = d and done and not won) then return 0; end if;
  if not exists (select 1 from av_games where player_id = p_player and day = d and won) then d := d - 1; end if;
  while exists (select 1 from av_games where player_id = p_player and day = d and won) loop
    n := n + 1; d := d - 1;
  end loop;
  return n;
end $$;

create or replace function public.av_best(p_player uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(max(cnt), 0)::int from (
    select count(*) cnt from (
      select day - row_number() over (order by day) grp from av_games where player_id = p_player and won
    ) x group by grp) y
$$;

-- Alles wat de telefoon over het spel van vandaag mag weten
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
    'done', coalesce(g.done, false), 'won', coalesce(g.won, false), 'points', coalesce(g.points, 0),
    'answer', case when g.done then av_fpl_json(a) end,
    'league', jsonb_build_object('name', (select value #>> '{}' from av_meta where key = 'league_name'),
                                 'total', v_total,
                                 'gw', (select (value #>> '{}')::int from av_meta where key = 'league_gw')),
    'stats', jsonb_build_object(
      'played', (select count(*) from av_games where player_id = p_player and done),
      'won', (select count(*) from av_games where player_id = p_player and won),
      'streak', av_streak(p_player), 'best', av_best(p_player)));
end $$;

-- ---------- Functies voor de telefoon ----------
-- Nieuwe speler. Geeft id, geheime code, herstelcode en nummer terug; de telefoon bewaart id en geheime code.
create or replace function public.av_create_player(p_name text)
returns table (player_id uuid, secret uuid, recovery text, tag text)
language plpgsql security definer set search_path = public as $$
declare v_rec text;
begin
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 24 then raise exception 'Kies een naam van 1 tot 24 tekens'; end if;
  loop
    v_rec := av_code(12);
    exit when not exists (select 1 from av_players p where p.recovery = v_rec);
  end loop;
  return query
    insert into av_players(name, tag, recovery)
    values (trim(p_name), lpad((floor(random() * 9000) + 1000)::int::text, 4, '0'), v_rec)
    returning av_players.id, av_players.secret, av_players.recovery, av_players.tag;
end $$;

-- Profiel terughalen met de herstelcode (bijvoorbeeld op een nieuwe telefoon)
create or replace function public.av_restore(p_recovery text)
returns table (player_id uuid, secret uuid, name text, tag text)
language plpgsql security definer set search_path = public as $$
declare v_code text := upper(regexp_replace(coalesce(p_recovery, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  perform pg_sleep(0.3);  -- remt raden af
  return query select p.id, p.secret, p.name, p.tag from av_players p where p.recovery = v_code;
  if not found then raise exception 'Onbekende herstelcode'; end if;
end $$;

create or replace function public.av_rename(p_player uuid, p_secret uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform av_check(p_player, p_secret);
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 24 then raise exception 'Kies een naam van 1 tot 24 tekens'; end if;
  update av_players set name = trim(p_name) where id = p_player;
end $$;

-- Alles bij het openen: profiel, herstelcode, poules en het spel van vandaag
create or replace function public.av_get(p_player uuid, p_secret uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p av_players;
begin
  perform av_check(p_player, p_secret);
  select * into p from av_players where id = p_player;
  return av_state(p_player) || jsonb_build_object(
    'me', jsonb_build_object('name', p.name, 'tag', p.tag, 'recovery', p.recovery),
    'leagues', coalesce((select jsonb_agg(jsonb_build_object('code', l.code, 'name', l.name) order by m.joined_at)
                         from av_members m join av_leagues l on l.code = m.league_code where m.player_id = p_player), '[]'::jsonb));
end $$;

-- Een gok doen. De server controleert alles en rekent de score zelf uit.
create or replace function public.av_guess(p_player uuid, p_secret uuid, p_code int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d int := av_today(); g av_games; v_ans int := av_answer(d); v_n int; v_won boolean; v_done boolean;
begin
  perform av_check(p_player, p_secret);
  if not exists (select 1 from av_fpl where code = p_code) then raise exception 'Onbekende FPL-speler'; end if;
  insert into av_games(player_id, day) values (p_player, d) on conflict do nothing;
  select * into g from av_games where player_id = p_player and day = d for update;
  if g.done or p_code = any(g.guesses) then return av_state(p_player); end if;
  v_n := cardinality(g.guesses) + 1;
  v_won := (p_code = v_ans);
  v_done := v_won or v_n >= 6;
  update av_games
     set guesses = g.guesses || p_code, done = v_done, won = v_won,
         points = case when v_won then greatest(0, 70 - 10 * v_n - 5 * g.hints) else 0 end,
         updated_at = now()
   where player_id = p_player and day = d;
  return av_state(p_player);
end $$;

-- Snoep PL-hint: stap 1 = ja/nee, stap 2 = in hoeveel teams. Elke stap kost 5 punten.
create or replace function public.av_hint(p_player uuid, p_secret uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d int := av_today(); g av_games; c int;
begin
  perform av_check(p_player, p_secret);
  select * into g from av_games where player_id = p_player and day = d for update;
  if g is null or g.done or cardinality(g.guesses) < 1 or g.hints >= 2 then return av_state(p_player); end if;
  if g.hints = 1 then
    select coalesce((select n from av_picks where code = av_answer(d)), 0) into c;
    if c = 0 then return av_state(p_player); end if;   -- 'nee': stap 2 heeft geen zin
  end if;
  update av_games set hints = g.hints + 1, updated_at = now() where player_id = p_player and day = d;
  return av_state(p_player);
end $$;

-- Poules
create or replace function public.av_create_league(p_player uuid, p_secret uuid, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  perform av_check(p_player, p_secret);
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 30 then raise exception 'Kies een poulenaam van 1 tot 30 tekens'; end if;
  if (select count(*) from av_members where player_id = p_player) >= 20 then raise exception 'Je zit al in 20 poules'; end if;
  loop
    v_code := av_code(6);
    exit when not exists (select 1 from av_leagues l where l.code = v_code);
  end loop;
  insert into av_leagues(code, name, created_by) values (v_code, trim(p_name), p_player);
  insert into av_members(player_id, league_code) values (p_player, v_code);
  return v_code;
end $$;

create or replace function public.av_join_league(p_player uuid, p_secret uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); v_name text;
begin
  perform av_check(p_player, p_secret);
  select name into v_name from av_leagues where code = v_code;
  if v_name is null then raise exception 'Deze poule bestaat niet'; end if;
  if (select count(*) from av_members where player_id = p_player) >= 20 then raise exception 'Je zit al in 20 poules'; end if;
  insert into av_members(player_id, league_code) values (p_player, v_code) on conflict do nothing;
  return v_name;
end $$;

create or replace function public.av_league_name(p_code text) returns text
language sql stable security definer set search_path = public as $$
  select name from av_leagues where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

create or replace function public.av_leave_league(p_player uuid, p_secret uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform av_check(p_player, p_secret);
  delete from av_members where player_id = p_player and league_code = upper(p_code);
end $$;

-- Klassement voor iedereen (p_scope = 'ALL') of voor een poule (p_scope = poulecode).
-- Uitslagen van anderen voor vandaag zie je pas als je zelf klaar bent.
-- Weekbekers: per afgelopen week (ma t/m zo) krijgt de hoogste weekscore in de groep een beker; gelijk = allebei.
create or replace function public.av_board(p_player uuid, p_secret uuid, p_scope text)
returns table (name text, tag text, is_me boolean, today_played boolean, today_n int, today_won boolean,
               today_points int, week_points int, last_week_points int, season_points int, streak int, cups int)
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
      select x.player_id, x.day, x.points, x.won, x.done, cardinality(x.guesses) n
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

-- ---------- Beheer (alleen voor de GitHub Action met de service-sleutel) ----------
-- Laadt nieuwe FPL-gegevens en Snoep PL-aantallen en repareert toekomstige antwoorden
-- waarvan de speler niet meer in FPL staat (die krijgen een ongebruikte reservespeler).
create or replace function public.av_admin_load(p_fpl jsonb, p_picks jsonb, p_meta jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare r record; v_spare int; v_fixed int := 0;
begin
  if p_fpl is not null and jsonb_array_length(p_fpl) > 0 then
    insert into av_fpl(code, web, team, pos, price, own, pts, gw, updated_at)
    select (e->>0)::int, e->>1, (e->>2)::int, (e->>3)::int, (e->>4)::int, (e->>5)::numeric, (e->>6)::int, (e->>7)::int, now()
    from jsonb_array_elements(p_fpl) e
    on conflict (code) do update set web = excluded.web, team = excluded.team, pos = excluded.pos, price = excluded.price,
      own = excluded.own, pts = excluded.pts, gw = excluded.gw, updated_at = now();
    delete from av_fpl where code not in (select (e->>0)::int from jsonb_array_elements(p_fpl) e)
      and code not in (select unnest(guesses) from av_games)
      and code not in (select code from av_answers where day <= av_today());
  end if;
  if p_picks is not null then
    delete from av_picks where true;
    insert into av_picks(code, n) select key::int, value::int from jsonb_each_text(p_picks);
  end if;
  if p_meta is not null then
    insert into av_meta(key, value) select key, value from jsonb_each(p_meta)
    on conflict (key) do update set value = excluded.value;
  end if;
  for r in select a.day from av_answers a where not a.spare and a.day > av_today()
             and not exists (select 1 from av_fpl f where f.code = a.code) order by a.day loop
    select a.code into v_spare from av_answers a where a.spare and exists (select 1 from av_fpl f where f.code = a.code) order by a.day limit 1;
    exit when v_spare is null;
    update av_answers set code = v_spare where day = r.day;
    delete from av_answers where spare and code = v_spare;
    v_fixed := v_fixed + 1;
  end loop;
  return 'fpl=' || (select count(*) from av_fpl) || ' picks=' || (select count(*) from av_picks) || ' answers_fixed=' || v_fixed;
end $$;

-- ---------- Rechten ----------
-- Supabase geeft nieuwe functies standaard aan iedereen; hier zetten we dat precies goed.
revoke all on function public.av_today(), public.av_week(int), public.av_code(int), public.av_check(uuid, uuid),
  public.av_answer(int), public.av_num(numeric, numeric, numeric), public.av_cmp(public.av_fpl, public.av_fpl),
  public.av_fpl_json(public.av_fpl), public.av_streak(uuid), public.av_best(uuid), public.av_state(uuid),
  public.av_admin_load(jsonb, jsonb, jsonb)
  from public, anon, authenticated;

revoke all on function public.av_create_player(text), public.av_restore(text), public.av_rename(uuid, uuid, text),
  public.av_get(uuid, uuid), public.av_guess(uuid, uuid, int), public.av_hint(uuid, uuid),
  public.av_create_league(uuid, uuid, text), public.av_join_league(uuid, uuid, text), public.av_league_name(text),
  public.av_leave_league(uuid, uuid, text), public.av_board(uuid, uuid, text)
  from public;
grant execute on function public.av_create_player(text), public.av_restore(text), public.av_rename(uuid, uuid, text),
  public.av_get(uuid, uuid), public.av_guess(uuid, uuid, int), public.av_hint(uuid, uuid),
  public.av_create_league(uuid, uuid, text), public.av_join_league(uuid, uuid, text), public.av_league_name(text),
  public.av_leave_league(uuid, uuid, text), public.av_board(uuid, uuid, text)
  to anon, authenticated;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.av_admin_load(jsonb, jsonb, jsonb) to service_role';
  end if;
end $$;
