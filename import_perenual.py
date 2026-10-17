#!/usr/bin/env python3
"""
Bulk-import plant care data from Perenual into spraynodal's plant_profiles +
plant_hardware_requirements tables.

Run this on your own machine (not the sandbox) -- it needs real internet access.

Setup:
    pip install requests
    export PERENUAL_API_KEY="your-key-from-perenual.com"
    export SUPABASE_URL="https://your-project.supabase.co"
    export SUPABASE_SERVICE_KEY="your-service-role-key"   # NOT the anon/public key --
        # this needs write access and bypasses RLS, so keep it out of git, out of the
        # app bundle, and only ever on your own machine for scripts like this one.

Usage:
    python3 import_perenual.py --max-pages 50   # ~30 species/page on Perenual's free tier
    python3 import_perenual.py --max-pages 3 --start-page 4   # resume from page 4

Schema this targets (create these in Supabase before running):
    hardware_types              -- static catalog, see the conversation for starter rows
    plant_profiles              -- plant identity + environmental preferences
    plant_hardware_requirements -- which hardware_types a plant needs/avoids, and at what settings

Notes on the mapping, read before trusting the output:
  - Perenual's "watering" field (frequent/average/minimum/none) describes general SOIL
    watering, not misting or soaking specifically. This script uses it only as a rough
    signal, then maps it onto one of your actual hardware types. It is NOT a substitute
    for knowing a plant's real care needs.
  - Every row this script writes gets confidence='imported', needs_review=true on the
    plant_profiles row. Nothing from here should drive a real node unscrutinized --
    that's what the review flag is for. Hand-verified entries (sphagnum, usnea, cushion
    moss, indoor-cactus-generic, etc.) stay confidence='verified' and this script must
    never touch those -- it only ever writes ids prefixed 'pn-', so it can't collide with
    your hand-verified slugs.
  - Succulents/cacti (detected via family/common-name keyword matching -- imperfect, will
    miss edge cases) get mist-nozzle priority='avoid' and soak-reservoir priority='required'
    instead of a mist-nozzle requirement, mirroring the hand-verified cactus entry. Review
    this logic against actual results.
  - Perenual's free tier has a 100-request/day quota. Each species-list page costs 1
    request plus 1 per species detail lookup (~30/page), so budget roughly 3 pages/day
    safely. The script stops itself at --daily-request-budget (default 90) rather than
    running until Perenual 429s you, and detects a hard quota block (still 429 right
    after the 60s retry) to stop immediately instead of failing through every remaining
    species one by one.
"""

import os
import sys
import time
import argparse
import requests

PERENUAL_API_KEY = os.environ.get("PERENUAL_API_KEY")
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY")

PERENUAL_BASE = "https://perenual.com/api"
REQUEST_DELAY_SEC = 1.0   # be polite; raise this if you see 429s

WATERING_TO_INTERVAL_MIN = {
    "frequent": 360,
    "average":  720,
    "minimum":  2880,
    "none":     10080,
}

SUCCULENT_KEYWORDS = [
    "cactus", "cacti", "succulent", "echeveria", "aloe", "sedum", "crassula",
    "haworthia", "agave", "euphorbia", "sempervivum",
]

SUNLIGHT_TO_LIGHT_HOURS_INTENSITY = {
    "full_shade":      (6, "low"),
    "part_shade":      (8, "medium"),
    "sun-part_shade":  (8, "medium"),
    "full_sun":        (6, "high"),
}


class DailyQuotaExhausted(Exception):
    """Raised when Perenual keeps returning 429 even after the retry -- almost
    always means the daily request quota (100/day on the free tier) is spent,
    not a short burst limit, so there's no point burning further requests on
    retries for the rest of the run."""
    pass


request_count = 0


def perenual_get(path, params=None):
    global request_count
    params = dict(params or {})
    params["key"] = PERENUAL_API_KEY
    request_count += 1
    resp = requests.get(f"{PERENUAL_BASE}/{path}", params=params, timeout=15)
    if resp.status_code == 429:
        print("  Rate limited -- sleeping 60s and retrying once...", file=sys.stderr)
        time.sleep(60)
        request_count += 1
        resp = requests.get(f"{PERENUAL_BASE}/{path}", params=params, timeout=15)
        if resp.status_code == 429:
            raise DailyQuotaExhausted(
                "Still rate-limited immediately after a 60s wait -- this is the daily "
                "quota, not a short burst limit. Stopping now instead of burning more "
                "requests on retries that will all fail the same way."
            )
    resp.raise_for_status()
    return resp.json()


def is_succulent(common_name, family):
    text = f"{common_name or ''} {family or ''}".lower()
    return any(kw in text for kw in SUCCULENT_KEYWORDS)


def map_species(species, details):
    """Returns (plant_profile_row, [hardware_requirement_rows])."""
    plant_id = f"pn-{species['id']}"
    common_name = species.get("common_name") or "Unknown"
    scientific = ", ".join(species.get("scientific_name") or []) or None
    family = (details or {}).get("family")

    watering = ((details or {}).get("watering") or species.get("watering") or "").lower()
    sunlight_raw = (details or {}).get("sunlight") or species.get("sunlight") or []
    sunlight = sunlight_raw[0].lower() if sunlight_raw else None
    light_hours, light_intensity = SUNLIGHT_TO_LIGHT_HOURS_INTENSITY.get(sunlight, (8, "medium"))

    succulent = is_succulent(common_name, family)
    interval_min = WATERING_TO_INTERVAL_MIN.get(watering, 1440)

    profile = {
        "id": plant_id,
        "common_name": common_name,
        "scientific_name": scientific,
        "category": family or "unclassified",
        "humidity_min_pct": None,
        "humidity_max_pct": None,
        "temp_min_f": None,
        "temp_max_f": None,
        "substrate": ((details or {}).get("soil") or [None])[0] if details else None,
        "dormancy_notes": None,
        "source_urls": ["https://perenual.com/api"],
        "last_verified": time.strftime("%Y-%m-%d"),
        "confidence": "imported",
        "needs_review": True,
        "notes": f"Imported from Perenual (species id {species['id']}); "
                 f"raw watering='{watering}', sunlight='{sunlight}', family='{family}'. Not hand-verified.",
    }

    requirements = []
    if succulent or watering == "none":
        requirements.append({
            "plant_id": plant_id, "hardware_type_id": "soak-reservoir",
            "priority": "required",
            "params": {"interval_min": interval_min, "soak_duration_sec": 20},
            "notes": "Imported heuristic: treated as succulent/low-water -- verify before trusting.",
        })
        requirements.append({
            "plant_id": plant_id, "hardware_type_id": "mist-nozzle",
            "priority": "avoid",
            "params": {},
            "notes": "Imported heuristic flagged this as succulent-like; misting may cause rot. Verify.",
        })
    else:
        requirements.append({
            "plant_id": plant_id, "hardware_type_id": "mist-nozzle",
            "priority": "required",
            "params": {"interval_min": interval_min, "burst_sec": 3},
            "notes": "Imported from Perenual's general watering field -- not misting-specific. Verify.",
        })

    requirements.append({
        "plant_id": plant_id, "hardware_type_id": "grow-light",
        "priority": "recommended",
        "params": {"hours_per_day": light_hours, "intensity": light_intensity},
        "notes": "Derived from Perenual's sunlight field.",
    })

    return profile, requirements


def upsert_profiles(rows):
    if not rows:
        return
    resp = requests.post(
        f"{SUPABASE_URL}/rest/v1/plant_profiles",
        headers={
            "apikey": SUPABASE_SERVICE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates",
        },
        params={"on_conflict": "id"},
        json=rows,
        timeout=30,
    )
    if resp.status_code >= 300:
        print(f"  plant_profiles upsert failed: HTTP {resp.status_code} {resp.text}", file=sys.stderr)
    resp.raise_for_status()


def insert_requirements(rows):
    if not rows:
        return
    # Relies on a unique constraint on (plant_id, hardware_type_id) in Supabase --
    # see the setup instructions. Without it this falls back to plain inserts and
    # will duplicate rows on a re-run.
    resp = requests.post(
        f"{SUPABASE_URL}/rest/v1/plant_hardware_requirements",
        headers={
            "apikey": SUPABASE_SERVICE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates",
        },
        params={"on_conflict": "plant_id,hardware_type_id"},
        json=rows,
        timeout=30,
    )
    if resp.status_code >= 300:
        print(f"  plant_hardware_requirements insert failed: HTTP {resp.status_code} {resp.text}", file=sys.stderr)
    resp.raise_for_status()


def main():
    global request_count
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-pages", type=int, default=10,
                         help="Perenual paginates ~30 species/page on the free tier")
    parser.add_argument("--start-page", type=int, default=1,
                         help="Resume from this page instead of page 1 -- use the "
                              "'next start page' the previous run prints when it stops")
    parser.add_argument("--batch-size", type=int, default=20,
                         help="plants to upsert to Supabase per call")
    parser.add_argument("--daily-request-budget", type=int, default=90,
                         help="Stop cleanly once this many Perenual requests have been "
                              "made in this run, leaving headroom under a 100/day free-"
                              "tier quota rather than running until a 429 forces a stop")
    args = parser.parse_args()

    missing = [n for n in ("PERENUAL_API_KEY", "SUPABASE_URL", "SUPABASE_SERVICE_KEY")
               if not os.environ.get(n)]
    if missing:
        print(f"Missing required env vars: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    profile_batch = []
    requirement_batch = []
    total = 0
    page = args.start_page
    last_page_fetched = args.start_page - 1
    stop_reason = None

    try:
        while page < args.start_page + args.max_pages:
            if request_count >= args.daily_request_budget:
                stop_reason = "budget"
                break

            print(f"Fetching species list page {page}...")
            data = perenual_get("species-list", {"page": page})
            species_list = data.get("data", [])
            if not species_list:
                print("No more results, stopping.")
                last_page_fetched = page
                break

            for species in species_list:
                if request_count >= args.daily_request_budget:
                    stop_reason = "budget"
                    break
                time.sleep(REQUEST_DELAY_SEC)
                try:
                    details = perenual_get(f"species/details/{species['id']}")
                except requests.HTTPError as e:
                    print(f"  Skipping species {species['id']}: {e}", file=sys.stderr)
                    details = None

                profile, requirements = map_species(species, details)
                profile_batch.append(profile)
                requirement_batch.extend(requirements)
                total += 1

                if len(profile_batch) >= args.batch_size:
                    upsert_profiles(profile_batch)
                    insert_requirements(requirement_batch)
                    print(f"  Upserted batch, {total} total so far ({request_count} requests used)")
                    profile_batch, requirement_batch = [], []

            last_page_fetched = page

            if stop_reason == "budget":
                break

            if data.get("current_page") and data.get("last_page"):
                if data["current_page"] >= data["last_page"]:
                    print("Reached Perenual's last page.")
                    break

            page += 1
    except DailyQuotaExhausted as e:
        stop_reason = "quota"
        print(f"  {e}", file=sys.stderr)

    if profile_batch:
        upsert_profiles(profile_batch)
        insert_requirements(requirement_batch)
        print(f"  Upserted final batch, {total} total")

    print(f"Done this run. Imported/updated {total} species using {request_count} requests.")

    if stop_reason in ("budget", "quota"):
        resume_page = last_page_fetched + 1
        print(
            f"\nStopped early ({'hit the request budget' if stop_reason == 'budget' else 'Perenual rate-limited us'}) "
            f"before finishing all pages.\nResume tomorrow (or once your quota resets) with:\n"
            f"  python3 import_perenual.py --max-pages {args.max_pages} --start-page {resume_page}"
        )


if __name__ == "__main__":
    main()
