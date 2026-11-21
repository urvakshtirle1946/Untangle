-- Review and apply this migration before deploying the summary-enabled app.
-- Existing notes RLS policies remain in force because these are columns on
-- the existing owner-scoped notes table.
alter table public.notes
  add column if not exists summary_title text,
  add column if not exists summary_sections jsonb,
  add column if not exists summary_status text not null default 'not_started',
  add column if not exists is_favorite boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'notes_summary_status_check'
      and conrelid = 'public.notes'::regclass
  ) then
    alter table public.notes
      add constraint notes_summary_status_check
      check (summary_status in ('not_started', 'generating', 'ready', 'failed'));
  end if;
end $$;
