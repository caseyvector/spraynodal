#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include "secrets.h"

// ================= Hardware =================
const int RELAY_ON  = HIGH;   // swap HIGH/LOW if your relay module is active-LOW
const int RELAY_OFF = LOW;
const unsigned long MAX_MIST_MS = 8000;   // hard safety ceiling

// ================= Zones =================
// Pin numbers live here on purpose: the cloud never chooses pins.
struct Zone {
  const char* name;
  int pin;
  unsigned long intervalMin;
  unsigned long burstSec;
  bool enabled;
  unsigned long lastStart;
  bool manualPending;
};

Zone zones[] = {
  { "moss",   25, 240,  5, true, 0, false },
  { "lichen", 26, 1440, 2, true, 0, false },
};
const int NUM_ZONES = sizeof(zones) / sizeof(zones[0]);

int activeZone = -1;            // -1 means nothing is spraying
unsigned long activeStart = 0;
bool activeManual = false;

// ================= Cloud =================
const unsigned long SYNC_EVERY_MS = 60UL * 1000;   // check in every 60 s
unsigned long lastSync = 0;
bool firstSync = true;

// Sprays waiting to be logged (sent only while no pump is running)
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

// ================= Saved settings (flash) =================
void loadSettings() {
  prefs.begin("spraynodal", false);
  for (int i = 0; i < NUM_ZONES; i++) {
    String n = zones[i].name;
    zones[i].intervalMin = constrain(prefs.getULong((n + "_int").c_str(), zones[i].intervalMin), 1UL, 10080UL);
    zones[i].burstSec    = constrain(prefs.getULong((n + "_burst").c_str(), zones[i].burstSec), 1UL, 8UL);
    zones[i].enabled     = prefs.getBool((n + "_en").c_str(), zones[i].enabled);
  }
  prefs.end();
}

void saveZone(int i) {
  String n = zones[i].name;
  prefs.begin("spraynodal", false);
  prefs.putULong((n + "_int").c_str(), zones[i].intervalMin);
  prefs.putULong((n + "_burst").c_str(), zones[i].burstSec);
  prefs.putBool((n + "_en").c_str(), zones[i].enabled);
  prefs.end();
}

// ================= Pumps =================
void allRelaysOff() {
  for (int i = 0; i < NUM_ZONES; i++) digitalWrite(zones[i].pin, RELAY_OFF);
}

void startZone(int i, bool manual) {
  activeZone = i;
  activeStart = millis();
  activeManual = manual;
  zones[i].lastStart = activeStart;   // a manual spray also restarts the schedule
  digitalWrite(zones[i].pin, RELAY_ON);
  Serial.printf("%s pump ON (%s)\n", zones[i].name, manual ? "manual" : "schedule");
}

void stopActive() {
  allRelaysOff();
  Serial.printf("%s pump OFF\n", zones[activeZone].name);
  if (logCount < LOG_QUEUE_SIZE) {
    logQueue[logCount++] = { activeZone, (int)zones[activeZone].burstSec, activeManual };
  }
  activeZone = -1;
}

// ================= Supabase =================
// Calls a database function; returns the HTTP status and fills in the response
int callRpc(const char* fn, const String& body, String& response) {
  WiFiClientSecure client;
  client.setInsecure();   // TEMPORARY: replaced in the hardening phase

  HTTPClient http;
  http.setTimeout(5000);
  http.begin(client, String(SUPABASE_URL) + "/rest/v1/rpc/" + fn);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  if (String(SUPABASE_KEY).startsWith("eyJ")) {
    http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  }

  int code = http.POST(body);
  response = http.getString();
  http.end();
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

  // Settings
  for (JsonObject z : doc["zones"].as<JsonArray>()) {
    int i = findZone(z["name"] | "");
    if (i < 0) continue;   // a zone this node doesn't have
    if (!z["interval_min"].is<int>() || !z["burst_sec"].is<int>()) continue;   // skip bad data

    unsigned long iv = constrain(z["interval_min"].as<long>(), 1L, 10080L);
    unsigned long bs = constrain(z["burst_sec"].as<long>(), 1L, 8L);
    bool en = z["enabled"] | true;

    if (iv != zones[i].intervalMin || bs != zones[i].burstSec || en != zones[i].enabled) {
      zones[i].intervalMin = iv;
      zones[i].burstSec = bs;
      zones[i].enabled = en;
      saveZone(i);   // only write flash when something actually changed
      Serial.printf("Updated %s: every %lu min, %lu s, %s\n",
                    zones[i].name, iv, bs, en ? "enabled" : "disabled");
    }
  }

  // "Spray now" commands
  for (JsonObject c : doc["commands"].as<JsonArray>()) {
    int i = findZone(c["zone"] | "");
    if (i >= 0) {
      zones[i].manualPending = true;
      Serial.printf("Command received: spray %s\n", zones[i].name);
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
      Serial.printf("Log failed: HTTP %d, will retry\n", code);
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

  loadSettings();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    delay(500);
    Serial.print(".");
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
  unsigned long now = millis();

  // 1. A pump is running: only decide when to stop it. No network calls while spraying.
  if (activeZone >= 0) {
    unsigned long burstMs = min(zones[activeZone].burstSec * 1000UL, MAX_MIST_MS);
    if (now - activeStart >= burstMs) stopActive();
    return;
  }

  // 2. Manual "spray now" commands go first
  for (int i = 0; i < NUM_ZONES; i++) {
    if (zones[i].manualPending) {
      zones[i].manualPending = false;
      startZone(i, true);
      return;
    }
  }

  // 3. Scheduled sprays
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
    flushLogs();
  }
}