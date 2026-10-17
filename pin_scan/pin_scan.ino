// Steps through candidate GPIOs one at a time so you can see which relay clicks.
const int PINS[] = {32, 33, 25, 26, 21, 19, 18, 5, 23, 22, 27, 14, 13, 4, 16, 17};
const int N = sizeof(PINS) / sizeof(PINS[0]);

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("pin_scan starting. Watch the relays and note which GPIO clicks.");
}

void loop() {
  for (int i = 0; i < N; i++) {
    int p = PINS[i];
    pinMode(p, OUTPUT);
    Serial.printf("GPIO%d -> HIGH\n", p);
    digitalWrite(p, HIGH);
    delay(2000);
    Serial.printf("GPIO%d -> LOW\n", p);
    digitalWrite(p, LOW);
    delay(2000);
    pinMode(p, INPUT);
  }
  Serial.println("--- scan finished, repeating ---");
  delay(3000);
}
