create table if not exists public.ai_request_limits (
  user_id uuid primary key references auth.users (id) on delete cascade,
  window_started_at timestamptz not null,
  request_count integer not null check (request_count >= 0)
);

alter table public.ai_request_limits enable row level security;
revoke all on public.ai_request_limits from anon, authenticated;

create or replace function public.consume_ai_request_limit(
  p_max_requests integer default 10,
  p_window_seconds integer default 60
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_started timestamptz;
  v_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_max_requests < 1 or p_max_requests > 60 or p_window_seconds < 1 or p_window_seconds > 3600 then
    raise exception 'Invalid request limit parameters' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_user_id::text));
  select window_started_at, request_count
    into v_started, v_count
    from public.ai_request_limits
    where user_id = v_user_id
    for update;

  if not found or v_started <= pg_catalog.now() - pg_catalog.make_interval(secs => p_window_seconds) then
    insert into public.ai_request_limits(user_id, window_started_at, request_count)
      values (v_user_id, pg_catalog.now(), 1)
      on conflict (user_id) do update
        set window_started_at = excluded.window_started_at, request_count = 1;
    return true;
  end if;
  if v_count >= p_max_requests then return false; end if;
  update public.ai_request_limits set request_count = request_count + 1 where user_id = v_user_id;
  return true;
end;
$$;

revoke all on function public.consume_ai_request_limit(integer, integer) from public, anon;
grant execute on function public.consume_ai_request_limit(integer, integer) to authenticated;
