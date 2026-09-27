void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("ESP32 is alive!");
}

void loop() {
  Serial.println("Still running...");
  delay(1000);
}
