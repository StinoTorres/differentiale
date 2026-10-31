-- Asset van de Dag: tabel voor scores en klassement.
-- Plak dit in Supabase > SQL Editor en klik op Run.

create table if not exists public.players (
  id          uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 24),
  tag         text not null check (char_length(tag) <= 8),
  results     jsonb not null default '{}'::jsonb,
  cur         jsonb,
  updated_at  timestamptz not null default now()
);

alter table public.players enable row level security;

-- Iedereen mag het klassement lezen
drop policy if exists "klassement lezen" on public.players;
create policy "klassement lezen" on public.players
  for select to anon, authenticated using (true);

-- Iedereen (ook anoniem ingelogd) mag alleen zijn eigen rij aanmaken en wijzigen
drop policy if exists "eigen rij aanmaken" on public.players;
create policy "eigen rij aanmaken" on public.players
  for insert to authenticated with check ((select auth.uid()) = id);

drop policy if exists "eigen rij wijzigen" on public.players;
create policy "eigen rij wijzigen" on public.players
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

grant select on public.players to anon, authenticated;
grant insert, update on public.players to authenticated;
