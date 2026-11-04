# Database SQL

These files record the database for SprayNodal. They are applied by hand in the Supabase SQL
editor; there is no migration runner, so nothing here runs automatically.

| File | What it is |
|---|---|
| `../schema.sql` | The original four tables (nodes, zones, commands, spray_log) and their security. Later changes were made in the SQL editor and are recorded below. |
| `03_camera_agent.sql` | Camera nodes, sensor readings, plant photos, the plant-health agent's observations and setting proposals, push subscriptions, the private photo bucket, and the functions that go with them. Safe to run more than once. |
| `live_schema_snapshot.sql` | The whole current schema printed from the live database: tables, constraints, security policies, functions, triggers, and the reference rows (hardware types, environment contexts, hand-verified plants). Written for reading and for rebuilding a fresh project. |
| `04_tighten_function_grants.sql` | Removes the automatic public access Supabase gives new functions, so `housekeeping()` is server-only and the app-only helpers are not callable without signing in. Safe to run more than once. |
| `export_schema.sql` | Read-only query that produces the snapshot above. Run it in the SQL editor, copy the single result cell, and save it as `live_schema_snapshot.sql`. |

## Keeping the snapshot current

After any change made in the SQL editor, run `export_schema.sql` again and replace
`live_schema_snapshot.sql`, so the repo does not drift from the database.

## Not in these files

- Imported plants (`pn-*`): recreate them with `import_perenual.py`.
- Your own nodes, zones, logs and users.
- API keys and device keys. Never commit these.
