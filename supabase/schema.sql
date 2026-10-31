-- Asset van de Dag: tabellen voor scores, klassement en poules.
-- Plak dit in Supabase > SQL Editor en klik op Run. Je kunt het veilig opnieuw draaien.

-- Spelers en hun scores
create table if not exists public.players (
  id          uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 24),
  tag         text not null check (char_length(tag) <= 8),
  results     jsonb not null default '{}'::jsonb,
  leagues     text[] not null default '{}' check (cardinality(leagues) <= 20),
  cur         jsonb,
  updated_at  timestamptz not null default now()
);
alter table public.players add column if not exists leagues text[] not null default '{}';

-- Poules (mini-leagues) voor vrienden
create table if not exists public.leagues (
  code        text primary key check (code ~ '^[A-Z0-9]{6}$'),
  name        text not null check (char_length(name) between 1 and 30),
  created_by  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

alter table public.players enable row level security;
alter table public.leagues enable row level security;

-- Iedereen mag het klassement en de poulenamen lezen
drop policy if exists "klassement lezen" on public.players;
create policy "klassement lezen" on public.players for select to anon, authenticated using (true);
drop policy if exists "poules lezen" on public.leagues;
create policy "poules lezen" on public.leagues for select to anon, authenticated using (true);

-- Iedereen (ook anoniem ingelogd) mag alleen zijn eigen rij aanmaken en wijzigen
drop policy if exists "eigen rij aanmaken" on public.players;
create policy "eigen rij aanmaken" on public.players
  for insert to authenticated with check ((select auth.uid()) = id);
drop policy if exists "eigen rij wijzigen" on public.players;
create policy "eigen rij wijzigen" on public.players
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Iedereen mag een poule aanmaken (op eigen naam)
drop policy if exists "poule aanmaken" on public.leagues;
create policy "poule aanmaken" on public.leagues
  for insert to authenticated with check ((select auth.uid()) = created_by);

grant select on public.players, public.leagues to anon, authenticated;
grant insert, update on public.players to authenticated;
grant insert on public.leagues to authenticated;
