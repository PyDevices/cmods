# Waveshare ESP32-P4-WIFI6-Touch-LCD-4B — MicroPython bring-up

End-to-end example: build MicroPython with **displayif** in the [cmods](https://github.com/PyDevices/cmods) workspace, install **pydisplay**, and smoke-test display + touch on the [Waveshare ESP32-P4-WIFI6-Touch-LCD-4B](https://www.waveshare.com/esp32-p4-wifi6-touch-lcd-4b.htm).

**Hardware:** 4″ 720×720 IPS panel (ST7703) on MIPI DSI, GT911 capacitive touch on I2C.

---

## Board config (pydisplay)

| Runtime | Path |
|---------|------|
| **MicroPython** | [`board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b/board_config.py`](https://github.com/PyDevices/pydisplay/blob/main/board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b/board_config.py) |
| **CircuitPython** | [`board_configs/fbdisplay/cp_esp32-p4-wifi6-touch-lcd-4b/board_config.py`](https://github.com/PyDevices/pydisplay/blob/main/board_configs/fbdisplay/cp_esp32-p4-wifi6-touch-lcd-4b/board_config.py) |

The MicroPython config wires:

- **720×720** ST7703 via `mipidsi.Bus` / `mipidsi.Display` ([displayif](https://github.com/PyDevices/displayif) on ESP32-P4)
- Full **ST7703 init sequence** from the Waveshare BSP
- **GT911** touch on I2C (SCL=8, SDA=7) with an `eventsys.Runtime`

This is **not** stock MicroPython — you need firmware built with the displayif `mipidsi` cmod.

---

## 1. Workspace setup

Clone cmods, MicroPython, displayif, and pydisplay as siblings:

```bash
git clone https://github.com/PyDevices/cmods.git
cd cmods

git clone https://github.com/micropython/micropython.git micropython
cd micropython && git submodule update --init --recursive && cd ..

git clone https://github.com/PyDevices/displayif.git displayif
# pydisplay is installed on-device via mip (step 3); clone locally only if you want examples on disk
```

displayif is discovered automatically via `USER_C_MODULES` (see [README](README.md)).

---

## 2. Build and flash firmware (once)

```bash
cd cmods
./build_mp.sh --port esp32 --board ESP32_GENERIC_P4 --variant C6_WIFI
```

Use **`C6_WIFI`** — this board pairs ESP32-P4 with an external **ESP32-C6** WiFi/BLE coprocessor (WiFi 6). If your variant uses a C5 instead, pass `--variant C5_WIFI`.

When the build finishes, `build_mp.sh` offers to flash. Accept the prompt — it reads the correct offset from the board’s `board.json` (`0x2000` for `ESP32_GENERIC_P4`).

Manual flash (same offset):

```bash
esptool -b 460800 --before default_reset --after hard_reset \
  write_flash 0x2000 micropython/ports/esp32/build-ESP32_GENERIC_P4/firmware.bin
```

Firmware output: `micropython/ports/esp32/build-ESP32_GENERIC_P4/firmware.bin`

---

## 3. Install pydisplay on the device

From your PC (with [mpremote](https://docs.micropython.org/en/latest/reference/mpremote.html)):

```bash
# Core libraries
mpremote mip install --target "." "github:PyDevices/pydisplay/packages/pydisplay-bundle.json"

# Board config + GT911 driver (install last → root board_config.py)
mpremote mip install --target "." \
  "github:PyDevices/pydisplay/board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b"

# Optional: examples
mpremote mip install --target "./examples" "github:PyDevices/pydisplay/packages/examples.json"
```

On-device REPL:

```python
import mip
mip.install("github:PyDevices/pydisplay/packages/pydisplay-bundle.json", target=".")
mip.install(
    "github:PyDevices/pydisplay/board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b",
    target=".",
)
```

---

## 4. Smoke tests (display + touch)

### displayif import (no panel draw)

```bash
mpremote run displayif/tests/test_mipidsi_smoke.py
```

### Quick draw test

```python
from board_config import display_drv, runtime

display_drv.fill_rect(0, 0, 200, 200, 0xF800)  # red block
display_drv.show()
```

### Fill-rect animation

```bash
mpremote mount /path/to/pydisplay/src
mpremote run examples/displaysys_fill_rect_test.py
```

### Full demo (touch + scroll)

```python
import pydisplay_demo
```

If you mounted pydisplay’s `src/` tree: `import lib.path` first when needed, then `import pydisplay_demo`.

### Touch check

```python
from board_config import runtime

while not runtime.quit_requested:
    for e in runtime.poll():
        print(e)
```

Tap the screen — you should see touch events.

---

## 5. Caveats

- Pinout matches Waveshare BSP: reset **27**, backlight **26**, I2C **7/8**, GT911 @ **0x5D**.
- On-device validation on this exact board may still be pending — if the panel stays black, check:
  - Backlight polarity (`backlight_on_high=False` in the board config)
  - displayif P4 DSI LDO path (channel 3 @ 2.5 V)
- **WiFi** is separate from display bring-up; test display and touch over USB serial first.

---

## Related

- [pydisplay board configs](https://github.com/PyDevices/pydisplay/tree/main/board_configs/fbdisplay)
- [displayif esp32 mipidsi](https://github.com/PyDevices/displayif/tree/main/ports/esp32)
- [cmods build_mp.sh](build_mp.sh)
