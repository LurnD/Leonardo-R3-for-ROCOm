// Leonardo R3 - Roco hardware HID bridge
// Acts as a real USB keyboard + absolute-position mouse.
// Receives line-based serial commands from the PC host (115200 baud).
//
// Required libraries (Arduino IDE -> Sketch -> Include Library -> Manage):
//   - Keyboard       (built-in)
//   - AbsMouse       (by Jonathan Edgecombe)  https://github.com/jonathanedgecombe/absmouse
//
// Protocol (LF-terminated lines, replies prefixed with OK/ERR):
//   PING                                   -> PONG
//   STOP                                   -> abort any running script
//   K  <keycode> <holdMs>                  -> tap one key (keycode = Arduino Keyboard byte)
//   MC <x> <y> <holdMs>                    -> move (abs) then left click
//   INIT                                   -> press Down arrow 10 times
//   CATCH  <x> <y> <holdMin> <holdMax> <intvMin> <intvMax>
//   FLOWER <cx> <cy> <loopMin> <loopMax> <afkPct> <restPct> <keyDelay>
//
// Coordinates x/y are in absolute HID range 0..32767 (the host scales pixels).
// The firmware never moves the mouse on its own except inside CATCH/FLOWER/MC.

#include <Keyboard.h>
#include <AbsMouse.h>

enum Mode { IDLE, CATCH_MODE, FLOWER_MODE };
static volatile Mode mode = IDLE;

// CATCH params
static int catchX, catchY;
static int catchHoldMin, catchHoldMax;
static int catchIntvMin, catchIntvMax;

// FLOWER params
static int flowerCx, flowerCy;
static int flowerLoopMin, flowerLoopMax;
static int flowerAfkPct, flowerRestPct;
static int flowerKeyDelay;

static char inputBuf[128];
static size_t inputLen = 0;

void setup() {
  Serial.begin(115200);
  Keyboard.begin();
  AbsMouse.init(32767, 32767);
  randomSeed((uint32_t)analogRead(A0) ^ (uint32_t)micros());

  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);

  delay(400);
  Serial.println(F("READY"));
}

void loop() {
  pollSerial();

  switch (mode) {
    case CATCH_MODE:  runCatchOnce();  break;
    case FLOWER_MODE: runFlowerOnce(); break;
    case IDLE:        delay(2);        break;
  }
}

// ----- Serial -----

void pollSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (inputLen > 0) {
        inputBuf[inputLen] = '\0';
        handleCommand(inputBuf);
        inputLen = 0;
      }
    } else if (inputLen < sizeof(inputBuf) - 1) {
      inputBuf[inputLen++] = c;
    } else {
      inputLen = 0;
      Serial.println(F("ERR OVERFLOW"));
    }
  }
}

void handleCommand(char* cmd) {
  if (!strcmp(cmd, "PING")) {
    Serial.println(F("PONG"));
    return;
  }
  if (!strcmp(cmd, "STOP")) {
    stopAll();
    Serial.println(F("OK STOPPED"));
    return;
  }
  if (!strncmp(cmd, "CATCH ", 6)) {
    int n = sscanf(cmd + 6, "%d %d %d %d %d %d",
                   &catchX, &catchY,
                   &catchHoldMin, &catchHoldMax,
                   &catchIntvMin, &catchIntvMax);
    if (n == 6) {
      stopAll();
      mode = CATCH_MODE;
      digitalWrite(LED_BUILTIN, HIGH);
      Serial.println(F("OK CATCH"));
    } else {
      Serial.println(F("ERR CATCH ARGS"));
    }
    return;
  }
  if (!strncmp(cmd, "FLOWER ", 7)) {
    int n = sscanf(cmd + 7, "%d %d %d %d %d %d %d",
                   &flowerCx, &flowerCy,
                   &flowerLoopMin, &flowerLoopMax,
                   &flowerAfkPct, &flowerRestPct,
                   &flowerKeyDelay);
    if (n == 7) {
      stopAll();
      mode = FLOWER_MODE;
      digitalWrite(LED_BUILTIN, HIGH);
      Serial.println(F("OK FLOWER"));
    } else {
      Serial.println(F("ERR FLOWER ARGS"));
    }
    return;
  }
  if (!strncmp(cmd, "K ", 2)) {
    int kc, hold;
    if (sscanf(cmd + 2, "%d %d", &kc, &hold) == 2) {
      Keyboard.press((uint8_t)kc);
      delay(hold);
      Keyboard.release((uint8_t)kc);
      Serial.println(F("OK K"));
    } else {
      Serial.println(F("ERR K ARGS"));
    }
    return;
  }
  if (!strncmp(cmd, "MC ", 3)) {
    int x, y, hold;
    if (sscanf(cmd + 3, "%d %d %d", &x, &y, &hold) == 3) {
      AbsMouse.move(x, y);
      delay(15);
      AbsMouse.press(MOUSE_LEFT);
      delay(hold);
      AbsMouse.release(MOUSE_LEFT);
      Serial.println(F("OK MC"));
    } else {
      Serial.println(F("ERR MC ARGS"));
    }
    return;
  }
  if (!strcmp(cmd, "INIT")) {
    for (int i = 0; i < 10; i++) {
      Keyboard.press(KEY_DOWN_ARROW);
      delay(100);
      Keyboard.release(KEY_DOWN_ARROW);
      delay(200);
    }
    Serial.println(F("OK INIT"));
    return;
  }
  Serial.print(F("ERR UNKNOWN "));
  Serial.println(cmd);
}

// ----- Helpers -----

void stopAll() {
  mode = IDLE;
  Keyboard.releaseAll();
  AbsMouse.release(MOUSE_LEFT);
  AbsMouse.release(MOUSE_RIGHT);
  digitalWrite(LED_BUILTIN, LOW);
}

bool sleepWithStop(unsigned long ms) {
  unsigned long start = millis();
  while ((millis() - start) < ms) {
    pollSerial();
    if (mode == IDLE) return false;
    delay(2);
  }
  return true;
}

bool sleepRange(int minMs, int maxMs) {
  if (maxMs < minMs) maxMs = minMs;
  unsigned long target = random(minMs, maxMs + 1);
  return sleepWithStop(target);
}

bool clickAt(int x, int y, int holdMin, int holdMax) {
  if (mode == IDLE) return false;
  AbsMouse.move(x, y);
  delay(15);
  if (mode == IDLE) return false;
  AbsMouse.press(MOUSE_LEFT);
  bool ok = sleepRange(holdMin, holdMax);
  AbsMouse.release(MOUSE_LEFT);
  return ok;
}

bool tapKey(uint8_t code, int holdMin, int holdMax) {
  if (mode == IDLE) return false;
  Keyboard.press(code);
  bool ok = sleepRange(holdMin, holdMax);
  Keyboard.release(code);
  return ok;
}

// ----- CATCH script -----

void runCatchOnce() {
  if (!clickAt(catchX, catchY, catchHoldMin, catchHoldMax)) return;
  sleepRange(catchIntvMin, catchIntvMax);
}

// ----- FLOWER script -----
// Mirrors roco_single_flower.ahk:
//   1. prefix "13456": for each digit -> tap (80..120), wait 450..550,
//      left click at (cx,cy) (80..120), wait 450..550
//   2. tap '2' (180..240), wait 3800..4200
//   3. inner loop of [Tab, '2', Esc, R, X] with per-key sleeps;
//      R/X have 15% chance of 2 presses, additional 5% chance of 3 presses
//      with 150..300 ms between presses
//   4. AFK roll at start of every inner cycle: 10..20 s pause
//   5. rest pause between outer iterations: 5..10 s or 800..1200 ms

struct KeySpec {
  uint8_t code;
  int sleepMin;
  int sleepMax;
  int holdMin;
  int holdMax;
  bool multi;
};

void runFlowerOnce() {
  const char* prefix = "13456";
  for (int i = 0; prefix[i] != 0; i++) {
    if (mode != FLOWER_MODE) return;
    if (!tapKey((uint8_t)prefix[i], 80, 120)) return;
    if (!sleepRange(450, 550)) return;
    if (!clickAt(flowerCx, flowerCy, 80, 120)) return;
    if (!sleepRange(450, 550)) return;
  }

  if (!tapKey('2', 180, 240)) return;
  if (!sleepRange(3800, 4200)) return;

  bool infinite = (flowerLoopMin == 0 || flowerLoopMax == 0);
  int loopCount = 0;
  if (!infinite) {
    int lo = flowerLoopMin, hi = flowerLoopMax;
    if (hi < lo) hi = lo;
    loopCount = random(lo, hi + 1);
  }

  int done = 0;
  while (mode == FLOWER_MODE && (infinite || done < loopCount)) {
    if (!innerCycle()) return;
    done++;
  }

  if (mode != FLOWER_MODE) return;
  if ((int)random(1, 101) <= flowerRestPct) {
    sleepRange(5000, 10000);
  } else {
    sleepRange(800, 1200);
  }
}

bool innerCycle() {
  if ((int)random(1, 101) <= flowerAfkPct) {
    if (!sleepRange(10000, 20000)) return false;
  }

  KeySpec keys[5] = {
    { KEY_TAB,        900,  1100,  80, 120, false },
    { (uint8_t)'2',  3800,  4200, 180, 240, false },
    { KEY_ESC,        450,   550,  80, 120, false },
    { (uint8_t)'r',  9500, 10500,  80, 120, true  },
    { (uint8_t)'x',    40,    60,  80, 120, true  },
  };

  for (int i = 0; i < 5; i++) {
    if (mode != FLOWER_MODE) return false;
    KeySpec& k = keys[i];
    int presses = 1;
    if (k.multi) {
      int roll = random(1, 101);
      if (roll <= 15) presses = 2;
      else if (roll <= 20) presses = 3;
    }
    for (int p = 0; p < presses; p++) {
      if (!tapKey(k.code, k.holdMin, k.holdMax)) return false;
      if (p < presses - 1) {
        if (!sleepRange(150, 300)) return false;
      }
    }
    if (!sleepRange(k.sleepMin, k.sleepMax)) return false;
    if (flowerKeyDelay > 0) {
      if (!sleepWithStop(flowerKeyDelay)) return false;
    }
  }
  return true;
}
