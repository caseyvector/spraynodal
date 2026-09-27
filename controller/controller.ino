#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include "secrets.h"

const int MOSS_RELAY_PIN = 25;
const int LICHEN_RELAY_PIN = 26;

// If pumps run when they should be off (and stop when they should spray),
// your relay module is active-LOW: swap HIGH and LOW on these two lines.
const int RELAY_ON  = HIGH;
const int RELAY_OFF = LOW;

const unsigned long MAX_MIST_DURATION = 8000; // hard safety ceiling (ms)

// --- Settings: these are defaults; saved values load from flash at boot ---
unsigned long mossIntervalMin   = 240;   // every 4 hours
unsigned long lichenIntervalMin = 1440;  // every 24 hours
unsigned long mossBurstSec      = 5;
unsigned long lichenBurstSec    = 2;

unsigned long mossLastStart = 0;
unsigned long lichenLastStart = 0;
unsigned long activeMistStart = 0;

enum ActivePump { NONE, MOSS, LICHEN };
ActivePump activePump = NONE;

WebServer server(80);
Preferences prefs;

// ---------- Helpers ----------

unsigned long minutesToMs(unsigned long m) {
  return m * 60UL * 1000UL;
}

unsigned long minutesUntil(unsigned long lastStart, unsigned long intervalMin, unsigned long now) {
  unsigned long elapsed = now - lastStart;
  unsigned long interval = minutesToMs(intervalMin);
  if (elapsed >= interval) return 0;
  return (interval - elapsed) / 60000UL;
}

// ---------- Saving settings to flash ----------

void loadSettings() {
  prefs.begin("spraynodal", false);
  mossIntervalMin   = prefs.getULong("mossInt", mossIntervalMin);
  lichenIntervalMin = prefs.getULong("lichenInt", lichenIntervalMin);
  mossBurstSec      = prefs.getULong("mossBurst", mossBurstSec);
  lichenBurstSec    = prefs.getULong("lichenBurst", lichenBurstSec);
  prefs.end();
}

void saveSettings() {
  prefs.begin("spraynodal", false);
  prefs.putULong("mossInt", mossIntervalMin);
  prefs.putULong("lichenInt", lichenIntervalMin);
  prefs.putULong("mossBurst", mossBurstSec);
  prefs.putULong("lichenBurst", lichenBurstSec);
  prefs.end();
}

// ---------- Pumps ----------

void startPump(ActivePump which) {
  activePump = which;
  activeMistStart = millis();
  if (which == MOSS) {
    digitalWrite(MOSS_RELAY_PIN, RELAY_ON);
    Serial.println("MOSS pump ON");
  } else {
    digitalWrite(LICHEN_RELAY_PIN, RELAY_ON);
    Serial.println("LICHEN pump ON");
  }
}

void stopPump() {
  digitalWrite(MOSS_RELAY_PIN, RELAY_OFF);
  digitalWrite(LICHEN_RELAY_PIN, RELAY_OFF);
  Serial.println(activePump == MOSS ? "MOSS pump OFF" : "LICHEN pump OFF");
  activePump = NONE;
}

// ---------- Web pages ----------

void redirectHome() {
  server.sendHeader("Location", "/");
  server.send(303);
}

void handleRoot() {
  unsigned long now = millis();
  String status = (activePump == NONE) ? "Idle"
                : (activePump == MOSS) ? "MOSS spraying" : "LICHEN spraying";

  String page = "<html><head><meta name='viewport' content='width=device-width'></head>";
  page += "<body style='font-family:sans-serif'>";
  page += "<h1>Spraynodal</h1>";
  page += "<p>Status: <b>" + status + "</b><br>";
  page += "Next moss spray in: " + String(minutesUntil(mossLastStart, mossIntervalMin, now)) + " min<br>";
  page += "Next lichen spray in: " + String(minutesUntil(lichenLastStart, lichenIntervalMin, now)) + " min</p>";

  page += "<h2>Settings</h2><form action='/set'>";
  page += "Moss interval (minutes): <input name='mossInt' value='" + String(mossIntervalMin) + "'><br><br>";
  page += "Moss burst (seconds, 1-8): <input name='mossBurst' value='" + String(mossBurstSec) + "'><br><br>";
  page += "Lichen interval (minutes): <input name='lichenInt' value='" + String(lichenIntervalMin) + "'><br><br>";
  page += "Lichen burst (seconds, 1-8): <input name='lichenBurst' value='" + String(lichenBurstSec) + "'><br><br>";
  page += "<input type='submit' value='Save'></form>";

  page += "<h2>Test</h2><form action='/test'>";
  page += "<button name='pump' value='moss'>Spray moss now</button> ";
  page += "<button name='pump' value='lichen'>Spray lichen now</button></form>";

  page += "</body></html>";
  server.send(200, "text/html", page);
}

// Reads one form field; only accepts it if it's within [minVal, maxVal]
void readSetting(const char* name, unsigned long &target, long minVal, long maxVal) {
  if (server.hasArg(name)) {
    long v = server.arg(name).toInt();
    if (v >= minVal && v <= maxVal) target = v;
  }
}

void handleSet() {
  readSetting("mossInt",     mossIntervalMin,   1, 10080); // 1 min to 1 week
  readSetting("lichenInt",   lichenIntervalMin, 1, 10080);
  readSetting("mossBurst",   mossBurstSec,      1, 8);     // never above safety ceiling
  readSetting("lichenBurst", lichenBurstSec,    1, 8);
  saveSettings();
  Serial.printf("Saved: moss %lu min / %lu s, lichen %lu min / %lu s\n",
                mossIntervalMin, mossBurstSec, lichenIntervalMin, lichenBurstSec);
  redirectHome();
}

void handleTest() {
  if (activePump == NONE && server.hasArg("pump")) {   // interlock: one pump at a time
    if (server.arg("pump") == "moss") {
      startPump(MOSS);
      mossLastStart = millis();     // counts as a real spray, schedule restarts
    } else if (server.arg("pump") == "lichen") {
      startPump(LICHEN);
      lichenLastStart = millis();
    }
  }
  redirectHome();
}

// ---------- Setup & loop ----------

void setup() {
  // Fail-safe: relays OFF before anything else
  pinMode(MOSS_RELAY_PIN, OUTPUT);
  pinMode(LICHEN_RELAY_PIN, OUTPUT);
  digitalWrite(MOSS_RELAY_PIN, RELAY_OFF);
  digitalWrite(LICHEN_RELAY_PIN, RELAY_OFF);

  Serial.begin(115200);
  delay(1000);
  Serial.println("Spraynodal controller starting...");

  loadSettings();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long startTime = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startTime < 15000) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("Connected! IP address: ");
    Serial.println(WiFi.localIP());
    MDNS.begin("spraynodal");
  } else {
    Serial.println("Wi-Fi failed, running schedule without it");
  }

  server.on("/", handleRoot);
  server.on("/set", handleSet);
  server.on("/test", handleTest);
  server.begin();
}

void loop() {
  server.handleClient();   // must run every loop, even while spraying

  unsigned long now = millis();

  if (activePump != NONE) {
    unsigned long burstMs = (activePump == MOSS ? mossBurstSec : lichenBurstSec) * 1000UL;
    unsigned long cutoff = min(burstMs, MAX_MIST_DURATION);
    if (now - activeMistStart >= cutoff) {
      stopPump();
    }
    return;
  }

  if (now - mossLastStart >= minutesToMs(mossIntervalMin)) {
    startPump(MOSS);
    mossLastStart = now;
  } else if (now - lichenLastStart >= minutesToMs(lichenIntervalMin)) {
    startPump(LICHEN);
    lichenLastStart = now;
  }
}
