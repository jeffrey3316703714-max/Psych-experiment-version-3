-- Run once in the Supabase SQL Editor. Do not put the service-role key in browser code.
-- This schema is designed for a small, anonymous student study.

create table if not exists public.study_sessions (
  id uuid primary key default gen_random_uuid(),
  version text not null check (version in ('A','B')),
  step integer not null default 0 check (step between 0 and 7),
  answers jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

-- Lifetime assignments remain balanced even when an individual withdraws
-- and their anonymous response record is deleted.
create table if not exists public.study_assignment_totals (
  singleton boolean primary key default true check (singleton = true),
  count_a bigint not null default 0,
  count_b bigint not null default 0
);
insert into public.study_assignment_totals(singleton,count_a,count_b)
select true, count(*) filter(where version='A'), count(*) filter(where version='B')
from public.study_sessions
on conflict(singleton) do nothing;
alter table public.study_assignment_totals enable row level security;
revoke all on public.study_assignment_totals from anon, authenticated;
grant select on public.study_assignment_totals to service_role;

create index if not exists study_sessions_started_idx on public.study_sessions(started_at);
create index if not exists study_sessions_version_idx on public.study_sessions(version);

alter table public.study_sessions enable row level security;
revoke all on public.study_sessions from anon, authenticated;
-- Only the server-side service role will read the results.
grant select on public.study_sessions to service_role;

create or replace function public.start_study()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n_a bigint;
  n_b bigint;
  chosen text;
  new_id uuid;
begin
  -- Serializes concurrent allocations, keeping ALL assignments balanced.
  perform pg_advisory_xact_lock(202611101);
  select count_a, count_b into n_a, n_b
  from public.study_assignment_totals where singleton = true;

  chosen := case
    when n_a < n_b then 'A'
    when n_b < n_a then 'B'
    when random() < 0.5 then 'A'
    else 'B'
  end;

  insert into public.study_sessions(version)
  values (chosen)
  returning id into new_id;

  update public.study_assignment_totals
  set count_a = count_a + case when chosen = 'A' then 1 else 0 end,
      count_b = count_b + case when chosen = 'B' then 1 else 0 end
  where singleton = true;

  return jsonb_build_object('id', new_id, 'version', chosen, 'step', 0);
end;
$$;

create or replace function public.study_status(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  entry record;
begin
  select version, step, completed_at into entry
  from public.study_sessions where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object('version', entry.version, 'step', entry.step,
                           'completed', entry.completed_at is not null);
end;
$$;

create or replace function public.study_answer(p_id uuid, p_step integer, p_choice text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  entry record;
  question_keys text[] := array['scenario1','distraction1','distraction2',
                                 'distraction3','distraction4','distraction5','scenario2'];
  next_step integer;
begin
  if p_choice not in ('A','B') or p_step not between 0 and 6 then
    raise exception 'INVALID_ANSWER' using errcode = '22023';
  end if;

  select step, completed_at into entry from public.study_sessions
  where id = p_id for update;
  if not found then
    raise exception 'SESSION_NOT_FOUND' using errcode = '22023';
  end if;
  if entry.completed_at is not null or entry.step <> p_step then
    raise exception 'OUT_OF_SEQUENCE' using errcode = '22023';
  end if;
  next_step := p_step + 1;

  update public.study_sessions
  set answers = jsonb_set(answers, array[question_keys[p_step + 1]], to_jsonb(p_choice), true),
      step = next_step,
      completed_at = case when next_step = 7 then now() else null end
  where id = p_id;

  return jsonb_build_object('next_step', next_step, 'completed', next_step = 7);
end;
$$;

create or replace function public.study_withdraw(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.study_sessions where id = p_id;
  return found;
end;
$$;

-- Restrict all functions to the server's service role. End users have no direct credentials.
revoke all on function public.start_study() from public, anon, authenticated;
revoke all on function public.study_status(uuid) from public, anon, authenticated;
revoke all on function public.study_answer(uuid, integer, text) from public, anon, authenticated;
revoke all on function public.study_withdraw(uuid) from public, anon, authenticated;
grant execute on function public.start_study() to service_role;
grant execute on function public.study_status(uuid) to service_role;
grant execute on function public.study_answer(uuid, integer, text) to service_role;
grant execute on function public.study_withdraw(uuid) to service_role;

-- Read-only researcher counts, called using the service-role key from Netlify.
create or replace function public.study_assignment_counts()
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select jsonb_build_object('A',count_a,'B',count_b)
     from public.study_assignment_totals where singleton = true $$;
revoke all on function public.study_assignment_counts() from public, anon, authenticated;
grant execute on function public.study_assignment_counts() to service_role;
