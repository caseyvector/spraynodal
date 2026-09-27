-- ===== TABLES =====

-- One row per ESP32
create table nodes (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null,
  device_key  uuid not null default gen_random_uuid(),  -- the node's secret "password"
  last_seen   timestamptz,
  created_at  timestamptz not null default now()
);

-- One row per pump/jar on a node
create table zones (
  id            uuid primary key default gen_random_uuid(),
  node_id       uuid not null references nodes(id) on delete cascade,
  name          text not null,
  interval_min  int not null default 240 check (interval_min between 1 and 10080),
  burst_sec     int not null default 5   check (burst_sec between 1 and 8),
  enabled       boolean not null default true,
  unique (node_id, name)
);

-- "Spray now" requests from the app
create table commands (
  id          bigint generated always as identity primary key,
  zone_id     uuid not null references zones(id) on delete cascade,
  command     text not null check (command in ('spray')),
  created_at  timestamptz not null default now(),
  done_at     timestamptz   -- empty until the node carries it out
);

-- History of every spray
create table spray_log (
  id            bigint generated always as identity primary key,
  zone_id       uuid not null references zones(id) on delete cascade,
  started_at    timestamptz not null default now(),
  duration_sec  int not null,
  source        text not null check (source in ('schedule', 'manual'))
);

-- ===== SECURITY: row-level security =====
-- Without this, anyone with the app's public key could read or change every row.

alter table nodes     enable row level security;
alter table zones     enable row level security;
alter table commands  enable row level security;
alter table spray_log enable row level security;

-- Users can only see and change their own nodes
create policy "own nodes" on nodes for all
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- ...and zones on their own nodes
create policy "own zones" on zones for all
  using (exists (select 1 from nodes n
                 where n.id = zones.node_id and n.owner_id = auth.uid()))
  with check (exists (select 1 from nodes n
                 where n.id = zones.node_id and n.owner_id = auth.uid()));

-- ...and commands for their own zones
create policy "own commands" on commands for all
  using (exists (select 1 from zones z join nodes n on n.id = z.node_id
                 where z.id = commands.zone_id and n.owner_id = auth.uid()))
  with check (exists (select 1 from zones z join nodes n on n.id = z.node_id
                 where z.id = commands.zone_id and n.owner_id = auth.uid()));

-- Users can read their own spray history (only nodes will write it)
create policy "read own spray log" on spray_log for select
  using (exists (select 1 from zones z join nodes n on n.id = z.node_id
                 where z.id = spray_log.zone_id and n.owner_id = auth.uid()));

                 -- Nodes call this to check in and get their zone settings
create or replace function device_checkin(p_node_id uuid, p_device_key uuid)
returns table (zone_name text, interval_min int, burst_sec int, enabled boolean)
language plpgsql
security definer          -- runs with owner rights, so RLS doesn't block the node
set search_path = public
as $$
begin
  -- Verify the key and record the check-in in one step
  update nodes set last_seen = now()
   where id = p_node_id and device_key = p_device_key;

  if not found then
    raise exception 'invalid node credentials';
  end if;

  return query
    select z.name, z.interval_min, z.burst_sec, z.enabled
      from zones z
     where z.node_id = p_node_id
     order by z.name;
end;
$$;

-- Only allow calling it, nothing else
revoke all on function device_checkin(uuid, uuid) from public;
grant execute on function device_checkin(uuid, uuid) to anon;

-- Node check-in v2: returns settings AND claims any pending "spray now" commands
create or replace function device_sync(p_node_id uuid, p_device_key uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_zones json;
  v_commands json;
begin
  update nodes set last_seen = now()
   where id = p_node_id and device_key = p_device_key;
  if not found then
    raise exception 'invalid node credentials';
  end if;

  select coalesce(json_agg(json_build_object(
           'name', z.name,
           'interval_min', z.interval_min,
           'burst_sec', z.burst_sec,
           'enabled', z.enabled) order by z.name), '[]'::json)
    into v_zones
    from zones z
   where z.node_id = p_node_id;

  -- Mark all pending commands as done, but only hand back recent ones.
  -- A "spray now" from 3 days ago (node was offline) should NOT fire.
  with claimed as (
    update commands c set done_at = now()
      from zones z
     where c.zone_id = z.id
       and z.node_id = p_node_id
       and c.done_at is null
    returning c.id, c.created_at, z.name as zone_name
  )
  select coalesce(json_agg(json_build_object('id', id, 'zone', zone_name) order by id), '[]'::json)
    into v_commands
    from claimed
   where created_at > now() - interval '10 minutes';

  return json_build_object('zones', v_zones, 'commands', v_commands);
end;
$$;

revoke all on function device_sync(uuid, uuid) from public;
grant execute on function device_sync(uuid, uuid) to anon;

-- Nodes call this after each spray to record it
create or replace function device_log_spray(
  p_node_id uuid, p_device_key uuid, p_zone text, p_duration_sec int, p_source text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_zone_id uuid;
begin
  select z.id into v_zone_id
    from zones z join nodes n on n.id = z.node_id
   where n.id = p_node_id and n.device_key = p_device_key and z.name = p_zone;

  if v_zone_id is null then
    raise exception 'invalid node credentials or zone';
  end if;

  insert into spray_log (zone_id, duration_sec, source)
  values (v_zone_id, p_duration_sec, p_source);
end;
$$;

revoke all on function device_log_spray(uuid, uuid, text, int, text) from public;
grant execute on function device_log_spray(uuid, uuid, text, int, text) to anon;