const int MOSS_RELAY_PIN = 25;
const int LICHEN_RELAY_PIN = 26;

// --- Real-world timing ---
const unsigned long MOSS_INTERVAL   = 4UL * 60 * 60 * 1000;  // moss jar: every 4 hours
const unsigned long LICHEN_INTERVAL = 24UL * 60 * 60 * 1000; // lichen jar: every 24 hours

const unsigned long MOSS_MIST_DURATION   = 5000; // moss burst: 5 sec
const unsigned long LICHEN_MIST_DURATION = 2000; // lichen burst: 2 sec

const unsigned long MAX_MIST_DURATION = 8000; // hard safety ceiling — should never actually be hit;
                                               // both durations above stay well under it

unsigned long mossLastStart = 0;
unsigned long lichenLastStart = 0;
unsigned long activeMistStart = 0;

enum ActivePump { NONE, MOSS, LICHEN };
ActivePump activePump = NONE;

void setup() {
  Serial.begin(115200);
  pinMode(MOSS_RELAY_PIN, OUTPUT);
  pinMode(LICHEN_RELAY_PIN, OUTPUT);

  // Fail-safe: both relays explicitly OFF before anything else runs
  digitalWrite(MOSS_RELAY_PIN, LOW);
  digitalWrite(LICHEN_RELAY_PIN, LOW);

  delay(1000);
  Serial.println("Interlock firmware starting...");
}

void loop() {
  unsigned long now = millis();

  if (activePump != NONE) {
    unsigned long thisDuration = (activePump == MOSS) ? MOSS_MIST_DURATION : LICHEN_MIST_DURATION;
    unsigned long cutoff = min(thisDuration, MAX_MIST_DURATION);
    if (now - activeMistStart >= cutoff) {
      stopPump();
    }
    return;
  }

  if (now - mossLastStart >= MOSS_INTERVAL) {
    startPump(MOSS);
    mossLastStart = now;
  } else if (now - lichenLastStart >= LICHEN_INTERVAL) {
    startPump(LICHEN);
    lichenLastStart = now;
  }
}

void startPump(ActivePump which) {
  activePump = which;
  activeMistStart = millis();
  if (which == MOSS) {
    digitalWrite(MOSS_RELAY_PIN, HIGH);
    Serial.println("MOSS pump ON");
  } else {
    digitalWrite(LICHEN_RELAY_PIN, HIGH);
    Serial.println("LICHEN pump ON");
  }
}

void stopPump() {
  digitalWrite(MOSS_RELAY_PIN, LOW);
  digitalWrite(LICHEN_RELAY_PIN, LOW);
  Serial.println(activePump == MOSS ? "MOSS pump OFF" : "LICHEN pump OFF");
  activePump = NONE;
}
