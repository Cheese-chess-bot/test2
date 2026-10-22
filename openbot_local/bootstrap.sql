-- Private schemas for the Jevie OpenBot fork. No browser/Data API grants.
create schema if not exists openbot;
create schema if not exists jevie_runtime;
revoke all on schema openbot, jevie_runtime from public;
create table if not exists jevie_runtime.threads (
 id text primary key check (length(id) between 1 and 200),
 owner_id text not null,
 agent_id text not null,
 name text,
 messages jsonb not null default '[]'::jsonb check(jsonb_typeof(messages)='array'),
 events jsonb not null default '[]'::jsonb check(jsonb_typeof(events)='array'),
 active_run text,
 lock_until timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table jevie_runtime.threads enable row level security;
create index if not exists jevie_threads_owner_updated_idx on jevie_runtime.threads(owner_id,updated_at desc);
