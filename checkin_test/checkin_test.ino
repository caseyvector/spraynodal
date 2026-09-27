#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include "secrets.h"

const unsigned long CHECKIN_EVERY = 60UL * 1000;  // check in every 60 seconds
unsigned long lastCheckin = 0;
bool firstCheckin = true;

void connectWiFi() {
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
    Serial.println("Wi-Fi failed");
  }
}

void checkIn() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("No Wi-Fi, skipping check-in");
    return;
  }

  WiFiClientSecure client;
  client.setInsecure();  // TEMPORARY: encrypts but skips verifying Supabase's certificate.
                         // We'll replace this in the hardening phase.

  HTTPClient http;
  http.begin(client, String(SUPABASE_URL) + "/rest/v1/rpc/device_checkin");
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);

  // Older "anon" keys (they start with "eyJ") also need this header; new publishable keys don't
  if (String(SUPABASE_KEY).startsWith("eyJ")) {
    http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  }

  // The function's inputs, as JSON
  String body = String("{\"p_node_id\":\"") + NODE_ID +
                "\",\"p_device_key\":\"" + DEVICE_KEY + "\"}";

  int code = http.POST(body);
  String response = http.getString();
  http.end();

  Serial.printf("Check-in: HTTP %d\n", code);
  if (code != 200) {
    Serial.println(response);   // Supabase explains what went wrong here
    return;
  }

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, response);
  if (err) {
    Serial.print("Couldn't read response: ");
    Serial.println(err.c_str());
    return;
  }

  for (JsonObject zone : doc.as<JsonArray>()) {
    const char* name = zone["zone_name"];
    int interval    = zone["interval_min"];
    int burst       = zone["burst_sec"];
    bool enabled    = zone["enabled"];
    Serial.printf("  %s: every %d min, %d s burst, %s\n",
                  name, interval, burst, enabled ? "enabled" : "disabled");
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("Check-in test starting...");
  connectWiFi();
}

void loop() {
  if (firstCheckin || millis() - lastCheckin >= CHECKIN_EVERY) {
    firstCheckin = false;
    lastCheckin = millis();
    checkIn();
  }
}