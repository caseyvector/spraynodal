#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include "secrets.h"

WebServer server(80);   // web server on the standard port

// Settings we want to change remotely
unsigned long mossIntervalMin = 240;  // minutes between sprays
unsigned long mossBurstSec = 5;       // seconds per spray

// Shows the settings page
void handleRoot() {
  String page = "<html><body style='font-family:sans-serif'>";
  page += "<h1>Spraynodal</h1>";
  page += "<form action='/set'>";
  page += "Moss interval (minutes): <input name='interval' value='" + String(mossIntervalMin) + "'><br><br>";
  page += "Moss burst (seconds): <input name='burst' value='" + String(mossBurstSec) + "'><br><br>";
  page += "<input type='submit' value='Save'>";
  page += "</form></body></html>";
  server.send(200, "text/html", page);
}

// Receives new settings from the form
void handleSet() {
  if (server.hasArg("interval")) {
    long v = server.arg("interval").toInt();
    if (v > 0) mossIntervalMin = v;   // ignore 0 or junk input
  }
  if (server.hasArg("burst")) {
    long v = server.arg("burst").toInt();
    if (v > 0) mossBurstSec = v;
  }
  Serial.printf("New settings: interval=%lu min, burst=%lu s\n", mossIntervalMin, mossBurstSec);
  server.sendHeader("Location", "/");   // send the browser back to the main page
  server.send(303);
}

void setup() {
  Serial.begin(115200);
  delay(1000);

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

    MDNS.begin("spraynodal");   // lets you use http://spraynodal.local
    server.on("/", handleRoot);
    server.on("/set", handleSet);
    server.begin();
    Serial.println("Web server running");
  } else {
    Serial.println("Wi-Fi failed, continuing without it");
  }
}

void loop() {
  server.handleClient();   // check for web requests
}
