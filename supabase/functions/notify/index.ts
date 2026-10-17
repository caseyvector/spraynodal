// Sends a push notification to every device a user has subscribed.
// Called only by our other server-side functions (for example the plant-health agent),
// never by the app or by devices.
//
// Request:  POST JSON { user_id, title, body, url?, tag? }
// Header:   x-internal-secret: <NOTIFY_SECRET>
//
// Deploy with JWT verification off; access is controlled by the shared secret instead.
//   npx supabase functions deploy notify --no-verify-jwt
//
// Secrets (set once):
//   npx supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... \
//        VAPID_SUBJECT=mailto:you@example.com NOTIFY_SECRET=<long random string>

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Compare secrets without leaking length or position of the first mismatch
function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const expected = Deno.env.get("NOTIFY_SECRET") ?? "";
  const given = req.headers.get("x-internal-secret") ?? "";
  if (expected.length < 16 || !safeEqual(given, expected)) {
    return json({ error: "unauthorized" }, 401);
  }

  const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY");
  const vapidSubject = Deno.env.get("VAPID_SUBJECT");
  if (!vapidPublic || !vapidPrivate || !vapidSubject) {
    return json({ error: "push keys not configured" }, 500);
  }
  webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);

  let payload: { user_id?: string; title?: string; body?: string; url?: string; tag?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  if (!payload.user_id || !payload.title || !payload.body) {
    return json({ error: "user_id, title and body are required" }, 400);
  }

  const message = JSON.stringify({
    title: payload.title.slice(0, 80),
    body: payload.body.slice(0, 240),
    url: payload.url ?? "/",
    tag: payload.tag ?? "spraynodal",
  });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data: subs, error } = await supabase
    .from("push_subscriptions")
    .select("id, provider, endpoint, p256dh, auth")
    .eq("user_id", payload.user_id);
  if (error) return json({ error: "lookup failed" }, 500);

  let sent = 0;
  let skipped = 0;
  const gone: string[] = [];

  for (const s of subs ?? []) {
    if (s.provider !== "webpush" || !s.p256dh || !s.auth) {
      skipped++;   // native providers (fcm/apns) are added when there is a native app
      continue;
    }
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        message,
        { TTL: 3600, urgency: "high" },
      );
      sent++;
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode;
      if (status === 404 || status === 410) gone.push(s.id);   // subscription expired
      else skipped++;
    }
  }

  if (gone.length) {
    await supabase.from("push_subscriptions").delete().in("id", gone);
  }

  return json({ sent, skipped, removed: gone.length }, 200);
});
