-- Tighten who may call the helper functions. Run once in the Supabase SQL editor. Safe to re-run.
--
-- Why: Supabase automatically grants EXECUTE on every new function in the public schema to
-- anon, authenticated and service_role. The "revoke all ... from public" lines in
-- 03_camera_agent.sql do not remove those grants, so the live database (see
-- live_schema_snapshot.sql) let anyone holding the public anon key call functions that were
-- meant for the server or for signed-in users only.
--
-- What changes:
--   housekeeping()            server only (it expires proposals and deletes old readings)
--   apply_setting_proposal()  signed-in users only (anon always got "proposal not found")
--   owns_node(), owns_zone()  signed-in users only (used by policies that apply to them)
--
-- Not changed: device_sync, device_log_spray, device_checkin and device_post_reading stay
-- callable by anon on purpose, because the ESP32 nodes call them with the public key plus
-- their own device key.

revoke execute on function public.housekeeping() from anon, authenticated;
revoke execute on function public.apply_setting_proposal(uuid, boolean) from anon;
revoke execute on function public.owns_node(uuid) from anon;
revoke execute on function public.owns_zone(uuid) from anon;

-- Check: who can run what now. Expected: housekeeping only service_role; apply_setting_proposal,
-- owns_node, owns_zone authenticated and service_role; the device_* functions anon too.
select p.proname as function,
       bool_or(a.grantee = (select oid from pg_roles where rolname = 'anon'))          as anon,
       bool_or(a.grantee = (select oid from pg_roles where rolname = 'authenticated')) as authenticated,
       bool_or(a.grantee = (select oid from pg_roles where rolname = 'service_role'))  as service_role
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
where p.prokind = 'f' and p.proname in
      ('housekeeping', 'apply_setting_proposal', 'owns_node', 'owns_zone',
       'device_sync', 'device_log_spray', 'device_checkin', 'device_post_reading')
  and a.privilege_type = 'EXECUTE'
group by p.proname
order by p.proname;
