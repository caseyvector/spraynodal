-- Exported from the live database on 2026-11-04 by supabase/sql/export_schema.sql

create table public.commands (
  id bigint generated always as identity not null,
  zone_id uuid not null,
  command text not null,
  created_at timestamp with time zone default now() not null,
  done_at timestamp with time zone
);

create table public.environment_contexts (
  id text not null,
  label text not null,
  interval_multiplier numeric default 1.0 not null,
  humidity_offset_pct integer default 0 not null,
  notes text
);

create table public.hardware_types (
  id text not null,
  label text not null,
  category text not null,
  description text,
  control_params jsonb,
  max_on_sec integer not null,
  control_mode text not null
);

create table public.nodes (
  id uuid default gen_random_uuid() not null,
  owner_id uuid default auth.uid() not null,
  name text not null,
  device_key uuid default gen_random_uuid() not null,
  last_seen timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  kind text default 'relay'::text not null
);

create table public.plant_hardware_requirements (
  id bigint generated always as identity not null,
  plant_id text not null,
  hardware_type_id text not null,
  priority text not null,
  params jsonb default '{}'::jsonb not null,
  notes text
);

create table public.plant_images (
  id uuid default gen_random_uuid() not null,
  node_id uuid not null,
  taken_at timestamp with time zone default now() not null,
  storage_path text not null,
  light_on boolean,
  bytes integer
);

create table public.plant_observations (
  id uuid default gen_random_uuid() not null,
  zone_id uuid not null,
  image_id uuid,
  observed_at timestamp with time zone default now() not null,
  status text not null,
  confidence text not null,
  summary text not null,
  findings jsonb default '{}'::jsonb not null
);

create table public.plant_profiles (
  id text not null,
  common_name text not null,
  scientific_name text,
  category text,
  humidity_min_pct integer,
  humidity_max_pct integer,
  temp_min_f integer,
  temp_max_f integer,
  substrate text,
  dormancy_notes text,
  source_urls text[],
  last_verified date,
  confidence text default 'imported'::text not null,
  needs_review boolean default true not null,
  notes text
);

create table public.push_subscriptions (
  id uuid default gen_random_uuid() not null,
  user_id uuid default auth.uid() not null,
  provider text default 'webpush'::text not null,
  endpoint text not null,
  p256dh text,
  auth text,
  user_agent text,
  created_at timestamp with time zone default now() not null
);

create table public.sensor_readings (
  id bigint generated always as identity not null,
  node_id uuid not null,
  taken_at timestamp with time zone default now() not null,
  temp_c numeric(5,2),
  humidity_pct numeric(5,2)
);

create table public.setting_proposals (
  id uuid default gen_random_uuid() not null,
  zone_id uuid not null,
  observation_id uuid,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone default (now() + '48:00:00'::interval) not null,
  current_settings jsonb not null,
  proposed_settings jsonb not null,
  reason text not null,
  state text default 'pending'::text not null,
  decided_at timestamp with time zone,
  decided_by uuid,
  notified_at timestamp with time zone
);

create table public.spray_log (
  id bigint generated always as identity not null,
  zone_id uuid not null,
  started_at timestamp with time zone default now() not null,
  duration_sec integer not null,
  source text not null
);

create table public.zones (
  id uuid default gen_random_uuid() not null,
  node_id uuid not null,
  name text not null,
  interval_min integer default 240 not null,
  duration_sec integer default 5 not null,
  enabled boolean default true not null,
  plant_id text,
  environment_context_id text,
  hardware_type_id text default 'mist-nozzle'::text not null,
  agent_mode text default 'suggest'::text not null,
  camera_region jsonb
);

alter table only public.commands add constraint commands_command_check CHECK ((command = 'spray'::text));

alter table only public.commands add constraint commands_pkey PRIMARY KEY (id);

alter table only public.environment_contexts add constraint environment_contexts_pkey PRIMARY KEY (id);

alter table only public.hardware_types add constraint hardware_types_control_mode_check CHECK ((control_mode = ANY (ARRAY['timed'::text, 'setpoint'::text])));

alter table only public.hardware_types add constraint hardware_types_pkey PRIMARY KEY (id);

alter table only public.nodes add constraint nodes_kind_check CHECK ((kind = ANY (ARRAY['relay'::text, 'camera'::text])));

alter table only public.nodes add constraint nodes_pkey PRIMARY KEY (id);

alter table only public.plant_hardware_requirements add constraint plant_hardware_requirements_pkey PRIMARY KEY (id);

alter table only public.plant_hardware_requirements add constraint plant_hardware_requirements_plant_hw_uniq UNIQUE (plant_id, hardware_type_id);

alter table only public.plant_hardware_requirements add constraint plant_hardware_requirements_priority_check CHECK ((priority = ANY (ARRAY['required'::text, 'recommended'::text, 'avoid'::text])));

alter table only public.plant_images add constraint plant_images_pkey PRIMARY KEY (id);

alter table only public.plant_images add constraint plant_images_storage_path_key UNIQUE (storage_path);

alter table only public.plant_observations add constraint plant_observations_confidence_check CHECK ((confidence = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text])));

alter table only public.plant_observations add constraint plant_observations_pkey PRIMARY KEY (id);

alter table only public.plant_observations add constraint plant_observations_status_check CHECK ((status = ANY (ARRAY['healthy'::text, 'watch'::text, 'stressed'::text, 'critical'::text, 'unknown'::text])));

alter table only public.plant_profiles add constraint plant_profiles_pkey PRIMARY KEY (id);

alter table only public.push_subscriptions add constraint push_subscriptions_endpoint_key UNIQUE (endpoint);

alter table only public.push_subscriptions add constraint push_subscriptions_pkey PRIMARY KEY (id);

alter table only public.push_subscriptions add constraint push_subscriptions_provider_check CHECK ((provider = ANY (ARRAY['webpush'::text, 'fcm'::text, 'apns'::text])));

alter table only public.sensor_readings add constraint sensor_readings_humidity_pct_check CHECK (((humidity_pct >= (0)::numeric) AND (humidity_pct <= (100)::numeric)));

alter table only public.sensor_readings add constraint sensor_readings_pkey PRIMARY KEY (id);

alter table only public.sensor_readings add constraint sensor_readings_temp_c_check CHECK (((temp_c >= ('-40'::integer)::numeric) AND (temp_c <= (85)::numeric)));

alter table only public.setting_proposals add constraint setting_proposals_pkey PRIMARY KEY (id);

alter table only public.setting_proposals add constraint setting_proposals_proposed_settings_check CHECK (((proposed_settings - ARRAY['interval_min'::text, 'duration_sec'::text, 'enabled'::text]) = '{}'::jsonb));

alter table only public.setting_proposals add constraint setting_proposals_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'applied'::text, 'rejected'::text, 'expired'::text])));

alter table only public.spray_log add constraint spray_log_pkey PRIMARY KEY (id);

alter table only public.spray_log add constraint spray_log_source_check CHECK ((source = ANY (ARRAY['schedule'::text, 'manual'::text])));

alter table only public.zones add constraint zones_agent_mode_check CHECK ((agent_mode = ANY (ARRAY['off'::text, 'suggest'::text, 'auto'::text])));

alter table only public.zones add constraint zones_duration_sec_check CHECK (((duration_sec >= 1) AND (duration_sec <= 86400)));

alter table only public.zones add constraint zones_interval_min_check CHECK (((interval_min >= 1) AND (interval_min <= 525600)));

alter table only public.zones add constraint zones_node_id_name_key UNIQUE (node_id, name);

alter table only public.zones add constraint zones_pkey PRIMARY KEY (id);

CREATE OR REPLACE FUNCTION public.device_sync(p_node_id uuid, p_device_key uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           'hardware_type_id', z.hardware_type_id,
           'interval_min', z.interval_min,
           'duration_sec', z.duration_sec,
           'max_on_sec', h.max_on_sec,
           'enabled', z.enabled) order by z.name), '[]'::json)
    into v_zones
    from zones z
    join hardware_types h on h.id = z.hardware_type_id
   where z.node_id = p_node_id;

  -- Mark all pending commands as done, but only hand back recent ones.
  -- An "activate now" from 3 days ago (node was offline) should NOT fire.
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
$function$
;

CREATE OR REPLACE FUNCTION public.device_log_spray(p_node_id uuid, p_device_key uuid, p_zone text, p_duration_sec integer, p_source text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.zones_enforce_max_on_sec()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_max int;
  v_mode text;
begin
  select max_on_sec, control_mode into v_max, v_mode
    from hardware_types where id = new.hardware_type_id;

  if v_mode = 'timed' and new.duration_sec > v_max then
    raise exception 'duration_sec (%) exceeds the % max_on_sec (%) for hardware type %',
      new.duration_sec, new.hardware_type_id, v_max, new.hardware_type_id;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.device_checkin(p_node_id uuid, p_device_key uuid)
 RETURNS TABLE(zone_name text, hardware_type_id text, interval_min integer, duration_sec integer, max_on_sec integer, enabled boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update nodes set last_seen = now()
   where id = p_node_id and device_key = p_device_key;

  if not found then
    raise exception 'invalid node credentials';
  end if;

  return query
    select z.name, z.hardware_type_id, z.interval_min, z.duration_sec, h.max_on_sec, z.enabled
      from zones z
      join hardware_types h on h.id = z.hardware_type_id
     where z.node_id = p_node_id
     order by z.name;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.owns_node(p_node_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from nodes n where n.id = p_node_id and n.owner_id = auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public.owns_zone(p_zone_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from zones z join nodes n on n.id = z.node_id
     where z.id = p_zone_id and n.owner_id = auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public.device_post_reading(p_node_id uuid, p_device_key uuid, p_temp_c numeric, p_humidity_pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.apply_setting_proposal(p_proposal_id uuid, p_approve boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.housekeeping()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update setting_proposals set state = 'expired'
   where state = 'pending' and expires_at < now();
  delete from sensor_readings where taken_at < now() - interval '90 days';
$function$
;

revoke all on function public.device_sync(p_node_id uuid, p_device_key uuid) from public;

revoke all on function public.device_log_spray(p_node_id uuid, p_device_key uuid, p_zone text, p_duration_sec integer, p_source text) from public;

revoke all on function public.device_checkin(p_node_id uuid, p_device_key uuid) from public;

revoke all on function public.owns_node(p_node_id uuid) from public;

revoke all on function public.owns_zone(p_zone_id uuid) from public;

revoke all on function public.device_post_reading(p_node_id uuid, p_device_key uuid, p_temp_c numeric, p_humidity_pct numeric) from public;

revoke all on function public.apply_setting_proposal(p_proposal_id uuid, p_approve boolean) from public;

revoke all on function public.housekeeping() from public;

grant execute on function public.device_sync(p_node_id uuid, p_device_key uuid) to anon;

grant execute on function public.device_sync(p_node_id uuid, p_device_key uuid) to authenticated;

grant execute on function public.device_sync(p_node_id uuid, p_device_key uuid) to service_role;

grant execute on function public.device_log_spray(p_node_id uuid, p_device_key uuid, p_zone text, p_duration_sec integer, p_source text) to anon;

grant execute on function public.device_log_spray(p_node_id uuid, p_device_key uuid, p_zone text, p_duration_sec integer, p_source text) to authenticated;

grant execute on function public.device_log_spray(p_node_id uuid, p_device_key uuid, p_zone text, p_duration_sec integer, p_source text) to service_role;

grant execute on function public.zones_enforce_max_on_sec() to public;

grant execute on function public.zones_enforce_max_on_sec() to anon;

grant execute on function public.zones_enforce_max_on_sec() to authenticated;

grant execute on function public.zones_enforce_max_on_sec() to service_role;

grant execute on function public.device_checkin(p_node_id uuid, p_device_key uuid) to anon;

grant execute on function public.device_checkin(p_node_id uuid, p_device_key uuid) to authenticated;

grant execute on function public.device_checkin(p_node_id uuid, p_device_key uuid) to service_role;

grant execute on function public.owns_node(p_node_id uuid) to anon;

grant execute on function public.owns_node(p_node_id uuid) to authenticated;

grant execute on function public.owns_node(p_node_id uuid) to service_role;

grant execute on function public.owns_zone(p_zone_id uuid) to anon;

grant execute on function public.owns_zone(p_zone_id uuid) to authenticated;

grant execute on function public.owns_zone(p_zone_id uuid) to service_role;

grant execute on function public.device_post_reading(p_node_id uuid, p_device_key uuid, p_temp_c numeric, p_humidity_pct numeric) to anon;

grant execute on function public.device_post_reading(p_node_id uuid, p_device_key uuid, p_temp_c numeric, p_humidity_pct numeric) to authenticated;

grant execute on function public.device_post_reading(p_node_id uuid, p_device_key uuid, p_temp_c numeric, p_humidity_pct numeric) to service_role;

grant execute on function public.apply_setting_proposal(p_proposal_id uuid, p_approve boolean) to anon;

grant execute on function public.apply_setting_proposal(p_proposal_id uuid, p_approve boolean) to authenticated;

grant execute on function public.apply_setting_proposal(p_proposal_id uuid, p_approve boolean) to service_role;

grant execute on function public.housekeeping() to anon;

grant execute on function public.housekeeping() to authenticated;

grant execute on function public.housekeeping() to service_role;

alter table only public.commands add constraint commands_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES zones(id) ON DELETE CASCADE;

alter table only public.nodes add constraint nodes_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table only public.plant_hardware_requirements add constraint plant_hardware_requirements_hardware_type_id_fkey FOREIGN KEY (hardware_type_id) REFERENCES hardware_types(id);

alter table only public.plant_hardware_requirements add constraint plant_hardware_requirements_plant_id_fkey FOREIGN KEY (plant_id) REFERENCES plant_profiles(id);

alter table only public.plant_images add constraint plant_images_node_id_fkey FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;

alter table only public.plant_observations add constraint plant_observations_image_id_fkey FOREIGN KEY (image_id) REFERENCES plant_images(id) ON DELETE SET NULL;

alter table only public.plant_observations add constraint plant_observations_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES zones(id) ON DELETE CASCADE;

alter table only public.push_subscriptions add constraint push_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table only public.sensor_readings add constraint sensor_readings_node_id_fkey FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;

alter table only public.setting_proposals add constraint setting_proposals_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES auth.users(id);

alter table only public.setting_proposals add constraint setting_proposals_observation_id_fkey FOREIGN KEY (observation_id) REFERENCES plant_observations(id) ON DELETE SET NULL;

alter table only public.setting_proposals add constraint setting_proposals_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES zones(id) ON DELETE CASCADE;

alter table only public.spray_log add constraint spray_log_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES zones(id) ON DELETE CASCADE;

alter table only public.zones add constraint zones_environment_context_id_fkey FOREIGN KEY (environment_context_id) REFERENCES environment_contexts(id);

alter table only public.zones add constraint zones_hardware_type_id_fkey FOREIGN KEY (hardware_type_id) REFERENCES hardware_types(id);

alter table only public.zones add constraint zones_node_id_fkey FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;

alter table only public.zones add constraint zones_plant_id_fkey FOREIGN KEY (plant_id) REFERENCES plant_profiles(id);

CREATE INDEX plant_images_node_time ON public.plant_images USING btree (node_id, taken_at DESC);

CREATE INDEX plant_observations_zone_time ON public.plant_observations USING btree (zone_id, observed_at DESC);

CREATE INDEX sensor_readings_node_time ON public.sensor_readings USING btree (node_id, taken_at DESC);

CREATE INDEX setting_proposals_zone_state ON public.setting_proposals USING btree (zone_id, state);

alter table public.commands enable row level security;

alter table public.environment_contexts enable row level security;

alter table public.hardware_types enable row level security;

alter table public.nodes enable row level security;

alter table public.plant_hardware_requirements enable row level security;

alter table public.plant_images enable row level security;

alter table public.plant_observations enable row level security;

alter table public.plant_profiles enable row level security;

alter table public.push_subscriptions enable row level security;

alter table public.sensor_readings enable row level security;

alter table public.setting_proposals enable row level security;

alter table public.spray_log enable row level security;

alter table public.zones enable row level security;

create policy "own commands" on public.commands as permissive for all
  using ((EXISTS ( SELECT 1
   FROM (zones z
     JOIN nodes n ON ((n.id = z.node_id)))
  WHERE ((z.id = commands.zone_id) AND (n.owner_id = auth.uid())))))
  with check ((EXISTS ( SELECT 1
   FROM (zones z
     JOIN nodes n ON ((n.id = z.node_id)))
  WHERE ((z.id = commands.zone_id) AND (n.owner_id = auth.uid())))));

create policy "authenticated can read environment_contexts" on public.environment_contexts as permissive for select to authenticated
  using (true);

create policy "authenticated can read hardware_types" on public.hardware_types as permissive for select to authenticated
  using (true);

create policy "own nodes" on public.nodes as permissive for all
  using ((owner_id = auth.uid()))
  with check ((owner_id = auth.uid()));

create policy "authenticated can read plant_hardware_requirements" on public.plant_hardware_requirements as permissive for select to authenticated
  using (true);

create policy "read own plant images" on public.plant_images as permissive for select to authenticated
  using (owns_node(node_id));

create policy "read own observations" on public.plant_observations as permissive for select to authenticated
  using (owns_zone(zone_id));

create policy "authenticated can read plant_profiles" on public.plant_profiles as permissive for select to authenticated
  using (true);

create policy "manage own push subscriptions" on public.push_subscriptions as permissive for all to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));

create policy "read own sensor readings" on public.sensor_readings as permissive for select to authenticated
  using (owns_node(node_id));

create policy "read own proposals" on public.setting_proposals as permissive for select to authenticated
  using (owns_zone(zone_id));

create policy "read own spray log" on public.spray_log as permissive for select
  using ((EXISTS ( SELECT 1
   FROM (zones z
     JOIN nodes n ON ((n.id = z.node_id)))
  WHERE ((z.id = spray_log.zone_id) AND (n.owner_id = auth.uid())))));

create policy "own zones" on public.zones as permissive for all
  using ((EXISTS ( SELECT 1
   FROM nodes n
  WHERE ((n.id = zones.node_id) AND (n.owner_id = auth.uid())))))
  with check ((EXISTS ( SELECT 1
   FROM nodes n
  WHERE ((n.id = zones.node_id) AND (n.owner_id = auth.uid())))));

insert into storage.buckets (id, name, public) values ('plant-images', 'plant-images', false) on conflict (id) do nothing;

create policy "owner reads own plant images" on storage.objects as permissive for select to authenticated
  using (((bucket_id = 'plant-images'::text) AND (EXISTS ( SELECT 1
   FROM nodes n
  WHERE (((n.id)::text = (storage.foldername(objects.name))[1]) AND (n.owner_id = auth.uid()))))));

CREATE TRIGGER zones_check_max_on_sec BEFORE INSERT OR UPDATE ON public.zones FOR EACH ROW EXECUTE FUNCTION zones_enforce_max_on_sec();

insert into public.hardware_types select * from json_populate_recordset(null::public.hardware_types, '[{"id":"drip-emitter","label":"Drip Emitter","category":"irrigation","description":"Slow trickle onto substrate, not foliage","control_params":{"duration_sec": "int", "interval_min": "int"},"max_on_sec":300,"control_mode":"timed"}, 
 {"id":"fan","label":"Air Circulator","category":"airflow","description":"Gentle airflow — prevents mold/stagnant air, can work against humidity goals so combine thoughtfully","control_params":{"hours_per_day": "int"},"max_on_sec":21600,"control_mode":"timed"}, 
 {"id":"grow-light","label":"Grow Light","category":"lighting","description":"Supplemental light on a timer","control_params":{"intensity": "enum(low,medium,high)", "hours_per_day": "int"},"max_on_sec":43200,"control_mode":"timed"}, 
 {"id":"heat-mat","label":"Heat Mat","category":"climate","description":"Substrate/ambient heating","control_params":{"target_temp_f": "int"},"max_on_sec":1800,"control_mode":"setpoint"}, 
 {"id":"humidifier","label":"Ambient Humidifier","category":"climate","description":"Raises room/case humidity without wetting the plant directly","control_params":{"target_humidity_pct": "int"},"max_on_sec":1800,"control_mode":"setpoint"}, 
 {"id":"mist-nozzle","label":"Mist Nozzle","category":"irrigation","description":"Short pressurized bursts onto foliage — what your current nodes have","control_params":{"burst_sec": "int", "interval_min": "int"},"max_on_sec":8,"control_mode":"timed"}, 
 {"id":"soak-reservoir","label":"Soak/Bottom-Water","category":"irrigation","description":"Deep periodic soak with drainage, then dry-out between waterings","control_params":{"interval_min": "int", "soak_duration_sec": "int"},"max_on_sec":120,"control_mode":"timed"}]') on conflict do nothing;

insert into public.environment_contexts select * from json_populate_recordset(null::public.environment_contexts, '[{"id":"greenhouse","label":"Greenhouse","interval_multiplier":1.2,"humidity_offset_pct":10,"notes":"humid by design, varies a lot by greenhouse type"}, 
 {"id":"indoor-case","label":"Indoor, enclosed/case","interval_multiplier":1.5,"humidity_offset_pct":15,"notes":"terrarium/jar retains humidity longer, water less often"}, 
 {"id":"indoor-open","label":"Indoor, open room","interval_multiplier":1.0,"humidity_offset_pct":0,"notes":"baseline — typical room, no enclosure"}, 
 {"id":"outdoor-covered","label":"Outdoor, sheltered","interval_multiplier":0.85,"humidity_offset_pct":-5,"notes":"more airflow/evaporation than indoors, some shelter"}, 
 {"id":"outdoor-exposed","label":"Outdoor, fully exposed","interval_multiplier":0.6,"humidity_offset_pct":-15,"notes":"dries fastest; rain exposure not modeled numerically, see notes"}]') on conflict do nothing;

insert into public.plant_profiles select * from json_populate_recordset(null::public.plant_profiles, '[{"id":"cushion-moss","common_name":"Cushion moss","scientific_name":"Leucobryum glaucum","category":"moss","humidity_min_pct":70,"humidity_max_pct":95,"temp_min_f":45,"temp_max_f":75,"substrate":"damp soil, rock, or bark","dormancy_notes":null,"source_urls":["https://en.wikipedia.org/wiki/Leucobryum_glaucum"],"last_verified":"2026-10-01","confidence":"verified","needs_review":false,"notes":"Forms dense cushions; prefers consistent moisture but good drainage, avoid waterlogging."}, 
 {"id":"indoor-cactus-generic","common_name":"Generic indoor cactus","scientific_name":null,"category":"cactus/succulent","humidity_min_pct":10,"humidity_max_pct":40,"temp_min_f":60,"temp_max_f":85,"substrate":"well-draining cactus/succulent mix","dormancy_notes":"Reduce watering significantly in winter dormancy.","source_urls":["https://en.wikipedia.org/wiki/Cactus"],"last_verified":"2026-10-01","confidence":"verified","needs_review":false,"notes":"Generic profile for common indoor cacti -- prone to rot if misted or overwatered; prefers infrequent deep soak."}, 
 {"id":"sphagnum","common_name":"Sphagnum moss","scientific_name":"Sphagnum spp.","category":"moss","humidity_min_pct":80,"humidity_max_pct":100,"temp_min_f":50,"temp_max_f":75,"substrate":"live on damp substrate or bare","dormancy_notes":null,"source_urls":["https://en.wikipedia.org/wiki/Sphagnum"],"last_verified":"2026-10-01","confidence":"verified","needs_review":false,"notes":"Needs consistently high humidity; never let fully dry out; avoid standing water/rot."}, 
 {"id":"usnea","common_name":"Usnea (beard lichen)","scientific_name":"Usnea spp.","category":"lichen","humidity_min_pct":60,"humidity_max_pct":85,"temp_min_f":40,"temp_max_f":80,"substrate":"bark, wood, or hung/mounted","dormancy_notes":"Tolerates brief dry spells better than moss; avoid prolonged soaking.","source_urls":["https://en.wikipedia.org/wiki/Usnea"],"last_verified":"2026-10-01","confidence":"verified","needs_review":false,"notes":"Lichen, not a plant -- no roots, absorbs moisture/nutrients from air and rain. Avoid overwatering."}]') on conflict do nothing;

insert into public.plant_hardware_requirements overriding system value select * from json_populate_recordset(null::public.plant_hardware_requirements, '[{"id":6,"plant_id":"cushion-moss","hardware_type_id":"humidifier","priority":"recommended","params":{"target_humidity_pct": 80},"notes":"Supplemental humidity between mistings."}, 
 {"id":5,"plant_id":"cushion-moss","hardware_type_id":"mist-nozzle","priority":"required","params":{"burst_sec": 3, "interval_min": 480},"notes":"Consistent light moisture; avoid heavy soaking."}, 
 {"id":9,"plant_id":"indoor-cactus-generic","hardware_type_id":"grow-light","priority":"recommended","params":{"intensity": "high", "hours_per_day": 6},"notes":"Cacti need strong light; supplement if not in direct sun."}, 
 {"id":8,"plant_id":"indoor-cactus-generic","hardware_type_id":"mist-nozzle","priority":"avoid","params":{},"notes":"Misting promotes rot in cacti/succulents -- do not use."}, 
 {"id":7,"plant_id":"indoor-cactus-generic","hardware_type_id":"soak-reservoir","priority":"required","params":{"interval_min": 20160, "soak_duration_sec": 30},"notes":"Deep soak every ~2 weeks (longer in winter); let dry fully between soaks."}, 
 {"id":2,"plant_id":"sphagnum","hardware_type_id":"humidifier","priority":"recommended","params":{"target_humidity_pct": 90},"notes":"Helps maintain humidity between misting cycles."}, 
 {"id":1,"plant_id":"sphagnum","hardware_type_id":"mist-nozzle","priority":"required","params":{"burst_sec": 4, "interval_min": 360},"notes":"Keep consistently moist; mist frequently rather than soaking."}, 
 {"id":4,"plant_id":"usnea","hardware_type_id":"fan","priority":"recommended","params":{"minutes_per_hour": 10},"notes":"Airflow helps it dry between mistings, mimicking natural conditions."}, 
 {"id":3,"plant_id":"usnea","hardware_type_id":"mist-nozzle","priority":"required","params":{"burst_sec": 2, "interval_min": 720},"notes":"Light, infrequent misting -- avoid prolonged wetness."}]') on conflict do nothing;

select setval(pg_get_serial_sequence('public.plant_hardware_requirements', 'id'), greatest((select coalesce(max(id), 0) from public.plant_hardware_requirements), 1));
