// Receives a JPEG from a camera node and stores it.
//
// Request:  POST with the raw JPEG as the body (Content-Type: image/jpeg)
// Headers:  x-node-id: <node uuid>
//           x-device-key: <device key uuid>
//           x-light-on: 1 | 0        (optional: was the grow light on?)
//
// Deploy with JWT verification off: this function does its own device authentication.
//   npx supabase functions deploy ingest-image --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_BYTES = 500_000;          // ESP32-CAM JPEGs at SVGA/XGA are well below this
const MIN_SECONDS_BETWEEN = 60;     // per node
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const nodeId = req.headers.get("x-node-id") ?? "";
  const deviceKey = req.headers.get("x-device-key") ?? "";
  if (!UUID.test(nodeId) || !UUID.test(deviceKey)) {
    return json({ error: "invalid credentials" }, 401);
  }

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BYTES) return json({ error: "image too large" }, 413);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // Authenticate the device: node id + device key, and it must be a camera node
  const { data: node, error: nodeErr } = await supabase
    .from("nodes")
    .select("id")
    .eq("id", nodeId)
    .eq("device_key", deviceKey)
    .eq("kind", "camera")
    .maybeSingle();
  if (nodeErr) return json({ error: "lookup failed" }, 500);
  if (!node) return json({ error: "invalid credentials" }, 401);

  // Throttle
  const { data: last } = await supabase
    .from("plant_images")
    .select("taken_at")
    .eq("node_id", nodeId)
    .order("taken_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (last && Date.now() - new Date(last.taken_at).getTime() < MIN_SECONDS_BETWEEN * 1000) {
    return json({ error: "too many images, slow down" }, 429);
  }

  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length === 0) return json({ error: "empty body" }, 400);
  if (bytes.length > MAX_BYTES) return json({ error: "image too large" }, 413);
  // JPEG files start with FF D8 FF
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
    return json({ error: "not a JPEG" }, 415);
  }

  const lightHeader = req.headers.get("x-light-on");
  const lightOn = lightHeader === "1" ? true : lightHeader === "0" ? false : null;

  const takenAt = new Date();
  const path = `${nodeId}/${takenAt.toISOString().replace(/[:.]/g, "-")}.jpg`;

  const { error: upErr } = await supabase.storage
    .from("plant-images")
    .upload(path, bytes, { contentType: "image/jpeg", upsert: false });
  if (upErr) return json({ error: "storage failed" }, 500);

  const { data: row, error: insErr } = await supabase
    .from("plant_images")
    .insert({
      node_id: nodeId,
      taken_at: takenAt.toISOString(),
      storage_path: path,
      light_on: lightOn,
      bytes: bytes.length,
    })
    .select("id")
    .single();
  if (insErr) {
    // Don't leave an orphan file behind
    await supabase.storage.from("plant-images").remove([path]);
    return json({ error: "database failed" }, 500);
  }

  await supabase.from("nodes").update({ last_seen: takenAt.toISOString() }).eq("id", nodeId);

  return json({ id: row.id }, 201);
});
