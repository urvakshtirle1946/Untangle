alter table public.notes
  add column if not exists conversation_messages jsonb not null default '[]'::jsonb;
