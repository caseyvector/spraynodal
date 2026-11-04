-- SprayNodal stage 1: camera node, sensor readings, plant images, agent observations,
-- setting proposals, push subscriptions. Applied by hand in the Supabase SQL editor.
-- Safe to re-run: tables use IF NOT EXISTS, policies are dropped and recreated.
--
-- Requires the core schema (../schema.sql) and the plant database to exist first: it alters
-- the nodes and zones tables. live_schema_snapshot.sql in this folder is the full current state;
-- this file is the incremental step that added the camera and agent tables.
--
-- History: the storage read policy originally compared against `name` inside a subquery over
-- nodes, where `name` meant nodes.name, so every photo read was denied ("Object not found").
-- It is now qualified as objects.name below.

-- ===== Changes to existing tables =====

-- A node is either a relay controller or a camera/sensor node
alter table nodes add column if not exists kind text not null default 'relay';
alter table nodes drop constraint if exists nodes_kind_check;
alter table nodes add constraint nodes_kind_check check (kind in ('relay', 'camera'));

-- Per-zone control over what the plant-health agent may do
alter table zones add column if not exists agent_mode text not null default 'suggest';
alter table zones drop constraint if exists zones_agent_mode_check;
alter table zones add constraint zones_agent_mode_check check (agent_mode in ('off', 'suggest', 'auto'));

-- ===== Ownership helpers (used by policies and RPCs) =====

create or replace function owns_node(p_node_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from nodes n where n.id = p_node_id and n.owner_id = auth.uid());
$$;

create or replace function owns_zone(p_zone_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from zones z join nodes n on n.id = z.node_id
     where z.id = p_zone_id and n.owner_id = auth.uid());
$$;

revoke all on function owns_node(uuid) from public;
revoke all on function owns_zone(uuid) from public;
grant execute on function owns_node(uuid) to authenticated;
grant execute on function owns_zone(uuid) to authenticated;

-- ===== Tables =====

create table if not exists sensor_readings (
  id            bigint generated always as identity primary key,
  node_id       uuid not null references nodes(id) on delete cascade,
  taken_at      timestamptz not null default now(),
  temp_c        numeric(5,2) check (temp_c between -40 and 85),
  humidity_pct  numeric(5,2) check (humidity_pct between 0 and 100)
);
create index if not exists sensor_readings_node_time on sensor_readings (node_id, taken_at desc);

create table if not exists plant_images (
  id            uuid primary key default gen_random_uuid(),
  node_id       uuid not null references nodes(id) on delete cascade,
  taken_at      timestamptz not null default now(),
  storage_path  text not null unique,
  light_on      boolean,
  bytes         int
);
create index if not exists plant_images_node_time on plant_images (node_id, taken_at desc);

-- Which part of the camera frame shows which zone: {"x":0.1,"y":0.2,"w":0.4,"h":0.5} as fractions of
-- the image. Kept as a column on zones, NOT as a separate table with foreign keys to both nodes and zones:
-- that creates a second route between nodes and zones and makes "nodes -> zones" embeds ambiguous,
-- which breaks the Controls page.
alter table zones add column if not exists camera_region jsonb;
drop table if exists zone_camera_regions;

create table if not exists plant_observations (
  id           uuid primary key default gen_random_uuid(),
  zone_id      uuid not null references zones(id) on delete cascade,
  image_id     uuid references plant_images(id) on delete set null,
  observed_at  timestamptz not null default now(),
  status       text not null check (status in ('healthy', 'watch', 'stressed', 'critical', 'unknown')),
  confidence   text not null check (confidence in ('low', 'medium', 'high')),
  summary      text not null,
  findings     jsonb not null default '{}'::jsonb
);
create index if not exists plant_observations_zone_time on plant_observations (zone_id, observed_at desc);

-- A suggested settings change. It only ever touches these three zone fields.
create table if not exists setting_proposals (
  id                 uuid primary key default gen_random_uuid(),
  zone_id            uuid not null references zones(id) on delete cascade,
  observation_id     uuid references plant_observations(id) on delete set null,
  created_at         timestamptz not null default now(),
  expires_at         timestamptz not null default (now() + interval '48 hours'),
  current_settings   jsonb not null,
  proposed_settings  jsonb not null,
  reason             text not null,
  state              text not null default 'pending'
                     check (state in ('pending', 'applied', 'rejected', 'expired')),
  decided_at         timestamptz,
  decided_by         uuid references auth.users(id),
  notified_at        timestamptz,   -- set once a push has been sent, so we never notify twice
  check ((proposed_settings - array['interval_min', 'duration_sec', 'enabled']) = '{}'::jsonb)
);
create index if not exists setting_proposals_zone_state on setting_proposals (zone_id, state);

-- Push notification targets. 'webpush' for the web app now; fcm/apns reserved for a native app later.
create table if not exists push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  provider    text not null default 'webpush' check (provider in ('webpush', 'fcm', 'apns')),
  endpoint    text not null unique,   -- web push endpoint URL, or the native device token
  p256dh      text,                   -- web push only
  auth        text,                   -- web push only
  user_agent  text,
  created_at  timestamptz not null default now()
);

-- ===== Row-level security =====

alter table sensor_readings      enable row level security;
alter table plant_images         enable row level security;
alter table plant_observations   enable row level security;
alter table setting_proposals    enable row level security;
alter table push_subscriptions   enable row level security;

drop policy if exists "read own sensor readings" on sensor_readings;
create policy "read own sensor readings" on sensor_readings for select to authenticated
  using (owns_node(node_id));

drop policy if exists "read own plant images" on plant_images;
create policy "read own plant images" on plant_images for select to authenticated
  using (owns_node(node_id));

drop policy if exists "read own observations" on plant_observations;
create policy "read own observations" on plant_observations for select to authenticated
  using (owns_zone(zone_id));

drop policy if exists "read own proposals" on setting_proposals;
create policy "read own proposals" on setting_proposals for select to authenticated
  using (owns_zone(zone_id));

drop policy if exists "manage own push subscriptions" on push_subscriptions;
create policy "manage own push subscriptions" on push_subscriptions for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Observations and proposals are written only by the server-side agent (service role),
-- and proposals are decided only through apply_setting_proposal() below.

-- ===== Private storage bucket for photos =====

insert into storage.buckets (id, name, public)
values ('plant-images', 'plant-images', false)
on conflict (id) do nothing;

-- Files are stored as <node_id>/<timestamp>.jpg. Owners may read their own; only the
-- server (service role) writes.
drop policy if exists "owner reads own plant images" on storage.objects;
create policy "owner reads own plant images" on storage.objects for select to authenticated
  using (bucket_id = 'plant-images'
         and exists (select 1 from public.nodes n
                      where n.id::text = (storage.foldername(objects.name))[1]
                        and n.owner_id = auth.uid()));

-- ===== Device RPC: camera node posts a sensor reading =====

create or replace function device_post_reading(
  p_node_id uuid, p_device_key uuid, p_temp_c numeric, p_humidity_pct numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update nodes set last_seen = now()
   where id = p_node_id and device_key = p_device_key and kind = 'camera';
  if not found then
    raise exception 'invalid node credentials';
  end if;

  -- Ignore bursts: at most one reading per 20 seconds per node
  if exists (select 1 from sensor_readings
              where node_id = p_node_id and taken_at > now() - interval '20 seconds') then
    return;
  end if;

  insert into sensor_readings (node_id, temp_c, humidity_pct)
  values (p_node_id, p_temp_c, p_humidity_pct);
end;
$$;

revoke all on function device_post_reading(uuid, uuid, numeric, numeric) from public;
grant execute on function device_post_reading(uuid, uuid, numeric, numeric) to anon;

-- ===== App RPC: approve or reject a proposal =====
-- Approving writes the new values to the zone. The existing zones trigger still enforces
-- the per-hardware max_on_sec ceiling, so a bad proposal fails here instead of reaching a pump.

create or replace function apply_setting_proposal(p_proposal_id uuid, p_approve boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p setting_proposals%rowtype;
begin
  select p.* into v_p
    from setting_proposals p
    join zones z on z.id = p.zone_id
    join nodes n on n.id = z.node_id
   where p.id = p_proposal_id and n.owner_id = auth.uid()
   for update of p;

  if not found then
    raise exception 'proposal not found';
  end if;
  if v_p.state <> 'pending' then
    raise exception 'proposal is already %', v_p.state;
  end if;
  if v_p.expires_at < now() then
    update setting_proposals set state = 'expired' where id = v_p.id;
    return json_build_object('state', 'expired');
  end if;

  if not p_approve then
    update setting_proposals
       set state = 'rejected', decided_at = now(), decided_by = auth.uid()
     where id = v_p.id;
    return json_build_object('state', 'rejected');
  end if;

  update zones
     set interval_min = coalesce((v_p.proposed_settings ->> 'interval_min')::int, interval_min),
         duration_sec = coalesce((v_p.proposed_settings ->> 'duration_sec')::int, duration_sec),
         enabled      = coalesce((v_p.proposed_settings ->> 'enabled')::boolean, enabled)
   where id = v_p.zone_id;

  update setting_proposals
     set state = 'applied', decided_at = now(), decided_by = auth.uid()
   where id = v_p.id;

  return json_build_object('state', 'applied');
end;
$$;

revoke all on function apply_setting_proposal(uuid, boolean) from public;
grant execute on function apply_setting_proposal(uuid, boolean) to authenticated;

-- ===== Housekeeping: expire old proposals, prune old rows =====
-- Called from the analyze function, or schedule it with pg_cron.

create or replace function housekeeping()
returns void
language sql
security definer
set search_path = public
as $$
  update setting_proposals set state = 'expired'
   where state = 'pending' and expires_at < now();
  delete from sensor_readings where taken_at < now() - interval '90 days';
$$;

revoke all on function housekeeping() from public;
-- No grant here, but Supabase grants new functions to anon and authenticated automatically;
-- 04_tighten_function_grants.sql removes that so only the service role can run it.
