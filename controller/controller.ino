#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_task_wdt.h>
#include "secrets.h"

// ================= Hardware =================
const int RELAY_ON  = HIGH;   // swap HIGH/LOW if your relay module is active-LOW
const int RELAY_OFF = LOW;

// Absolute, hardcoded last-resort ceiling. No matter what the cloud says (bad
// data, a bug, a stale response), nothing this firmware controls is ever left
// on longer than this. Per-hardware-type ceilings below are the *real* limits
// in normal operation; this is just the backstop if those ever fail to apply.
const unsigned long ABSOLUTE_MAX_ON_MS = 6UL * 60 * 60 * 1000;   // 6 hours

// Watchdog: if the ESP32 freezes for this long, it restarts itself,
// and setup() switches every relay OFF. Safety net for a stuck pump.
const uint32_t WATCHDOG_MS = 30000;

// ================= Zones =================
// Pin numbers AND hardware type live here on purpose: the cloud never chooses
// pins, and it never silently changes what's physically wired to one either.
// If the cloud ever reports a different hardware_type_id for a zone than what's
// compiled in here, that update is logged and ignored rather than trusted --
// see the check in syncWithCloud().
//
// defaultMaxOnSec is only a fallback used before the first successful cloud
// sync (or if sync keeps failing). Once synced, maxOnSec comes from the
// cloud's hardware_types.max_on_sec, which is the authoritative source.
struct Zone {
  const char* name;
  const char* hardwareType;
  int pin;
  unsigned long intervalMin;
  unsigned long durationSec;
  unsigned long maxOnSec;          // current effective safety ceiling for this zone
  unsigned long defaultMaxOnSec;   // fallback until the cloud confirms one
  bool enabled;
  unsigned long lastStart;
  bool manualPending;
};

Zone zones[] = {
  // name,     hardwareType,  pin, intervalMin, durationSec, maxOnSec(placeholder), defaultMaxOnSec, enabled, lastStart, manualPending
  { "moss",   "mist-nozzle", 25, 240,  5, 8, 8,  true, 0, false },
  { "lichen", "mist-nozzle", 26, 1440, 2, 8, 8,  true, 0, false },
};
const int NUM_ZONES = sizeof(zones) / sizeof(zones[0]);

int activeZone = -1;            // -1 means nothing is active
unsigned long activeStart = 0;
bool activeManual = false;

// ================= Cloud =================
const unsigned long SYNC_EVERY_MS = 60UL * 1000;   // check in every 60 s
unsigned long lastSync = 0;
bool firstSync = true;

// Activations waiting to be logged (sent only while nothing is currently on)
struct LogEntry { int zone; int durationSec; bool manual; };
const int LOG_QUEUE_SIZE = 10;
LogEntry logQueue[LOG_QUEUE_SIZE];
int logCount = 0;

Preferences prefs;

// ================= Helpers =================
unsigned long minToMs(unsigned long m) { return m * 60UL * 1000UL; }

int findZone(const char* name) {
  for (int i = 0; i < NUM_ZONES; i++) {
    if (strcmp(zones[i].name, name) == 0) return i;
  }
  return -1;
}

bool anyActivationWaiting() {
  for (int i = 0; i < NUM_ZONES; i++) {
    if (zones[i].manualPending) return true;
  }
  return false;
}

// This zone's actual ceiling right now: whatever the cloud most recently
// confirmed, capped by the absolute hardcoded backstop either way.
unsigned long effectiveMaxOnMs(int i) {
  unsigned long ms = zones[i].maxOnSec * 1000UL;
  return min(ms, ABSOLUTE_MAX_ON_MS);
}

// ================= Watchdog =================
void startWatchdog() {
  esp_task_wdt_config_t cfg = {
    .timeout_ms = WATCHDOG_MS,
    .idle_core_mask = 0,
    .trigger_panic = true,     // restart the chip if it trips
  };
  // The watchdog usually exists already; if not, create it
  if (esp_task_wdt_reconfigure(&cfg) != ESP_OK) {
    esp_task_wdt_init(&cfg);
  }
  esp_task_wdt_add(NULL);      // watch this loop
}

void feedWatchdog() {
  esp_task_wdt_reset();        // "I'm still alive"
}

// ================= Saved settings (flash) =================
void loadSettings() {
  prefs.begin("spraynodal", false);
  for (int i = 0; i < NUM_ZONES; i++) {
    String n = zones[i].name;
    // Fallback ceiling until the cloud confirms a real one, so a cold boot
    // with no network yet still has a sane limit rather than an unset one.
    zones[i].maxOnSec   = prefs.getULong((n + "_maxon").c_str(), zones[i].defaultMaxOnSec);
    zones[i].intervalMin = constrain(prefs.getULong((n + "_int").c_str(), zones[i].intervalMin), 1UL, 525600UL);
    zones[i].durationSec = constrain(prefs.getULong((n + "_dur").c_str(), zones[i].durationSec), 1UL, zones[i].maxOnSec);
    zones[i].enabled     = prefs.getBool((n + "_en").c_str(), zones[i].enabled);
  }
  prefs.end();
}

void saveZone(int i) {
  String n = zones[i].name;
  prefs.begin("spraynodal", false);
  prefs.putULong((n + "_int").c_str(), zones[i].intervalMin);
  prefs.putULong((n + "_dur").c_str(), zones[i].durationSec);
  prefs.putULong((n + "_maxon").c_str(), zones[i].maxOnSec);
  prefs.putBool((n + "_en").c_str(), zones[i].enabled);
  prefs.end();
}

// ================= Relays =================
void allRelaysOff() {
  for (int i = 0; i < NUM_ZONES; i++) digitalWrite(zones[i].pin, RELAY_OFF);
}

void startZone(int i, bool manual) {
  activeZone = i;
  activeStart = millis();
  activeManual = manual;
  zones[i].lastStart = activeStart;   // a manual activation also restarts the schedule
  digitalWrite(zones[i].pin, RELAY_ON);
  Serial.printf("%s (%s) ON (%s)\n", zones[i].name, zones[i].hardwareType, manual ? "manual" : "schedule");
}

void stopActive() {
  allRelaysOff();
  Serial.printf("%s OFF\n", zones[activeZone].name);
  if (logCount < LOG_QUEUE_SIZE) {
    logQueue[logCount++] = { activeZone, (int)zones[activeZone].durationSec, activeManual };
  }
  activeZone = -1;
}

// ================= Supabase =================
// Calls a database function; returns the HTTP status and fills in the response
int callRpc(const char* fn, const String& body, String& response) {
  feedWatchdog();   // a network call may take a while; reset the timer before it

  WiFiClientSecure client;
  client.setInsecure();            // TEMPORARY: replaced in the hardening phase
  client.setHandshakeTimeout(10);  // give up on the secure connection after 10 s

  HTTPClient http;
  http.setConnectTimeout(5000);    // give up on the basic connection after 5 s
  http.setTimeout(5000);           // give up waiting for a reply after 5 s
  http.begin(client, String(SUPABASE_URL) + "/rest/v1/rpc/" + fn);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  if (String(SUPABASE_KEY).startsWith("eyJ")) {
    http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  }

  unsigned long t0 = millis();
  int code = http.POST(body);
  response = http.getString();
  http.end();
  Serial.printf("  %s: HTTP %d in %lu ms\n", fn, code, millis() - t0);

  feedWatchdog();
  return code;
}

String authFields() {
  return String("\"p_node_id\":\"") + NODE_ID + "\",\"p_device_key\":\"" + DEVICE_KEY + "\"";
}

void syncWithCloud() {
  String response;
  int code = callRpc("device_sync", String("{") + authFields() + "}", response);
  if (code != 200) {
    Serial.printf("Sync failed: HTTP %d %s\n", code, response.c_str());
    return;   // keep running on the settings we already have
  }

  JsonDocument doc;
  if (deserializeJson(doc, response)) {
    Serial.println("Sync: couldn't read response");
    return;
  }

  Serial.printf("Sync OK, %d command(s) waiting, free memory %u bytes\n",
                doc["commands"].as<JsonArray>().size(), ESP.getFreeHeap());

  // Settings
  for (JsonObject z : doc["zones"].as<JsonArray>()) {
    int i = findZone(z["name"] | "");
    if (i < 0) continue;   // a zone this node doesn't have

    const char* cloudHwType = z["hardware_type_id"] | "";
    if (strcmp(cloudHwType, zones[i].hardwareType) != 0) {
      // The cloud thinks this zone is wired as something it isn't. Ignore the
      // update entirely rather than apply a safety ceiling or timing meant for
      // different hardware to what's actually on this pin.
      Serial.printf("REFUSING update for %s: cloud says hardware_type '%s', firmware says '%s'\n",
                    zones[i].name, cloudHwType, zones[i].hardwareType);
      continue;
    }

    if (!z["interval_min"].is<int>() || !z["duration_sec"].is<int>() || !z["max_on_sec"].is<int>()) {
      continue;   // skip bad/incomplete data
    }

    unsigned long cloudMaxOn = constrain(z["max_on_sec"].as<long>(), 1L, 86400L);
    unsigned long iv = constrain(z["interval_min"].as<long>(), 1L, 525600L);
    unsigned long ds = constrain(z["duration_sec"].as<long>(), 1L, (long)cloudMaxOn);
    bool en = z["enabled"] | true;

    if (iv != zones[i].intervalMin || ds != zones[i].durationSec ||
        cloudMaxOn != zones[i].maxOnSec || en != zones[i].enabled) {
      zones[i].intervalMin = iv;
      zones[i].durationSec = ds;
      zones[i].maxOnSec = cloudMaxOn;
      zones[i].enabled = en;
      saveZone(i);   // only write flash when something actually changed
      Serial.printf("Updated %s (%s): every %lu min, %lu s (ceiling %lu s), %s\n",
                    zones[i].name, zones[i].hardwareType, iv, ds, cloudMaxOn, en ? "enabled" : "disabled");
    }
  }

  // "Activate now" commands
  for (JsonObject c : doc["commands"].as<JsonArray>()) {
    int i = findZone(c["zone"] | "");
    if (i >= 0) {
      zones[i].manualPending = true;
      Serial.printf("Command received: activate %s\n", zones[i].name);
    }
  }
}

void flushLogs() {
  while (logCount > 0) {
    LogEntry e = logQueue[0];
    String body = String("{") + authFields() +
                  ",\"p_zone\":\"" + zones[e.zone].name + "\"" +
                  ",\"p_duration_sec\":" + e.durationSec +
                  ",\"p_source\":\"" + (e.manual ? "manual" : "schedule") + "\"}";
    String response;
    int code = callRpc("device_log_spray", body, response);
    if (code < 200 || code >= 300) {
      Serial.printf("Log failed: HTTP %d, will retry next check-in\n", code);
      return;
    }
    for (int k = 1; k < logCount; k++) logQueue[k - 1] = logQueue[k];
    logCount--;
  }
}

// ================= Setup & loop =================
void setup() {
  // Fail-safe: relays OFF before anything else
  for (int i = 0; i < NUM_ZONES; i++) {
    pinMode(zones[i].pin, OUTPUT);
    digitalWrite(zones[i].pin, RELAY_OFF);
  }

  Serial.begin(115200);
  delay(1000);
  Serial.println("Spraynodal node starting...");

  startWatchdog();
  loadSettings();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    delay(500);
    Serial.print(".");
    feedWatchdog();
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("Wi-Fi connected, IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("Wi-Fi failed, running on saved settings");
  }
}

void loop() {
  feedWatchdog();
  unsigned long now = millis();

  // 1. Something is active: only decide when to stop it. No network calls while active.
  if (activeZone >= 0) {
    unsigned long onMs = min(zones[activeZone].durationSec * 1000UL, effectiveMaxOnMs(activeZone));
    if (now - activeStart >= onMs) stopActive();
    return;
  }

  // 2. Manual "activate now" commands go first
  for (int i = 0; i < NUM_ZONES; i++) {
    if (zones[i].manualPending) {
      zones[i].manualPending = false;
      startZone(i, true);
      return;
    }
  }

  // 3. Scheduled activations
  for (int i = 0; i < NUM_ZONES; i++) {
    if (zones[i].enabled && now - zones[i].lastStart >= minToMs(zones[i].intervalMin)) {
      startZone(i, false);
      return;
    }
  }

  // 4. Idle: talk to the cloud
  if (WiFi.status() == WL_CONNECTED && (firstSync || now - lastSync >= SYNC_EVERY_MS)) {
    firstSync = false;
    lastSync = now;
    syncWithCloud();

    // If an activation just arrived, do it first. Logs go out at the next check-in.
    if (!anyActivationWaiting()) flushLogs();
  }
}
