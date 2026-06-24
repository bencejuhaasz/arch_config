#!/usr/bin/env python3

from evdev import InputDevice, categorize, ecodes
import time
import subprocess
import sys

# ========= CONFIG =========

DEVICE_PATH = "/dev/input/by-path/platform-gpio-keys.1.auto-event"

DOT_THRESHOLD = 0.3      # rövid nyomás → pont
LETTER_PAUSE = 0.7       # ennyi szünet → új betű
WORD_PAUSE = 1.7         # ennyi → új szó

DEBOUNCE = 0.05          # túl rövid zajok kiszűrése

ENABLE_CLIPBOARD = False

# ==========================

MORSE_DICT = {
    ".-": "A", "-...": "B", "-.-.": "C", "-..": "D", ".": "E",
    "..-.": "F", "--.": "G", "....": "H", "..": "I", ".---": "J",
    "-.-": "K", ".-..": "L", "--": "M", "-.": "N", "---": "O",
    ".--.": "P", "--.-": "Q", ".-.": "R", "...": "S", "-": "T",
    "..-": "U", "...-": "V", ".--": "W", "-..-": "X", "-.--": "Y",
    "--..": "Z",
    "-----": "0", ".----": "1", "..---": "2", "...--": "3",
    "....-": "4", ".....": "5", "-....": "6", "--...": "7",
    "---..": "8", "----.": "9"
}

# ========= STATE =========

press_time = None
last_event_time = time.time()

current_symbol = ""
current_word = ""

# =========================


def flush_letter():
    global current_symbol, current_word

    if current_symbol:
        letter = MORSE_DICT.get(current_symbol, "?")
        current_word += letter

        print(f"\n[LETTER] {current_symbol} → {letter}")

        current_symbol = ""


def flush_word():
    global current_word

    if current_word:
        if current_word == "SOS":
            subprocess.run(["pkill", "-SIGUSR1", "swaylock"])
        print(f"[WORD] {current_word}\n")

        if ENABLE_CLIPBOARD:
            subprocess.run(
                ["wl-copy"],
                input=current_word.encode(),
            )

        current_word = ""


def main():
    global press_time, last_event_time, current_symbol

    try:
        device = InputDevice(DEVICE_PATH)
    except Exception as e:
        print(f"❌ Nem tudtam megnyitni: {DEVICE_PATH}")
        print(e)
        sys.exit(1)

    print("🎧 Morse input fut (hangerő le gomb)")
    print("CTRL+C kilépés\n")

    for event in device.read_loop():
        now = time.time()

        # ===== PAUSE DETECTION =====
        gap = now - last_event_time

        if gap > WORD_PAUSE:
            flush_letter()
            flush_word()

        elif gap > LETTER_PAUSE:
            flush_letter()

        last_event_time = now

        # ===== KEY HANDLING =====
        if event.type != ecodes.EV_KEY:
            continue

        key = categorize(event)

        if key.scancode != ecodes.KEY_VOLUMEDOWN:
            continue

        # --- KEY DOWN ---
        if key.keystate == 1:
            press_time = now

        # --- KEY UP ---
        elif key.keystate == 0:
            if press_time is None:
                continue

            duration = now - press_time

            # debounce
            if duration < DEBOUNCE:
                continue

            if duration < DOT_THRESHOLD:
                current_symbol += "."
                print(".", end="", flush=True)
            else:
                current_symbol += "-"
                print("-", end="", flush=True)

        # --- KEY REPEAT (IGNORE) ---
        elif key.keystate == 2:
            continue


if __name__ == "__main__":
    main()
