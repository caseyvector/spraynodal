-- t084: list the imported (pn-*) plants for review. READ-ONLY: only a SELECT, changes nothing.
-- Run in the Supabase SQL editor. One row per imported plant, in Perenual id order.
select p.id,
       p.common_name,
       p.scientific_name,
       p.category,
       substring(p.notes from 'family=''([^'']*)''')          as family,
       substring(p.notes from 'raw watering=''([^'']*)''')    as perenual_watering,
       substring(p.notes from 'sunlight=''([^'']*)''')        as perenual_sunlight,
       p.needs_review,
       (select string_agg(r.hardware_type_id || ':' || r.priority, ', ' order by r.hardware_type_id)
          from plant_hardware_requirements r
         where r.plant_id = p.id)                             as hardware
from plant_profiles p
where p.id like 'pn-%'
order by substring(p.id from 4)::int;
