create table if not exists public.notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  preview text not null,
  transcript text,
  created_at timestamptz not null default now(),
  category text,
  category_source text,
  audio_url text,
  duration_seconds integer
);

alter table public.notes add column if not exists preview text;
alter table public.notes add column if not exists transcript text;
alter table public.notes add column if not exists category text;
alter table public.notes add column if not exists category_source text;
alter table public.notes add column if not exists audio_url text;
alter table public.notes add column if not exists duration_seconds integer;

alter table public.notes enable row level security;

drop policy if exists "Users can read their own notes" on public.notes;
create policy "Users can read their own notes"
  on public.notes for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert their own notes" on public.notes;
create policy "Users can insert their own notes"
  on public.notes for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own notes" on public.notes;
create policy "Users can update their own notes"
  on public.notes for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete their own notes" on public.notes;
create policy "Users can delete their own notes"
  on public.notes for delete to authenticated
  using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.notes to authenticated;
