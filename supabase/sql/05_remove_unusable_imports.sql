-- t084: remove the first 60 imported plants (pn-1 to pn-60). Run once in the Supabase SQL editor.
--
-- Why: all 60 are trees (9 firs, 51 maples). Perenual returned no watering or sunlight data for any
-- of them, so the importer filled every plant with its fallback defaults ("mist nozzle required,
-- every 24 hours, 3 seconds" plus an 8 hour grow light). That is not care data, and trees are not
-- plants for a misting node. They can be re-imported later with a better importer.
--
-- Safe: if any zone is using one of these plants, nothing is deleted and you get an error saying so.
-- Hand-verified plants (confidence = 'verified') are never touched.

do $$
begin
  if exists (select 1 from zones where plant_id like 'pn-%') then
    raise exception 'A zone still uses an imported plant. Nothing was deleted.';
  end if;

  delete from plant_hardware_requirements
   where plant_id in (select id from plant_profiles where id like 'pn-%' and confidence = 'imported');

  delete from plant_profiles
   where id like 'pn-%' and confidence = 'imported';
end $$;

-- Check: expect 4 verified plants and no imported ones.
select confidence, count(*) as plants from plant_profiles group by confidence order by confidence;
