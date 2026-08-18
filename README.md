# cmods

An **optional** multi-module workspace layout and build helper for [MicroPython](https://github.com/micropython/micropython) and [CircuitPython](https://github.com/adafruit/circuitpython).

`cmods` makes it easy to build custom firmware containing multiple **user C modules** side-by-side (such as [displayif](https://github.com/PyDevices/displayif), [lvgl-micropython](https://github.com/PyDevices/lvgl-micropython), and [pygraphics](https://github.com/PyDevices/pygraphics)):

- **MicroPython external C modules** (`USER_C_MODULES`, `micropython.mk` / `micropython.cmake`)
- **CircuitPython native extensions** (`shared-bindings` / `shared-module`, via each repo's `apply_cp_patches.sh`)

> **Note for Experienced Developers:** `cmods` is completely optional. If you already have an established build habit (such as standard `make USER_C_MODULES=...` or custom CMake workflows), you can continue building MicroPython and CircuitPython exactly as you always have. This workspace is provided as a friction-free aggregator to make multi-module firmware development faster and more convenient.


## 🚀 Workspace setup

### 1. Get the tooling

**Option A — clone this repo** (recommended when starting fresh):

```bash
git clone https://github.com/PyDevices/cmods.git
cd cmods
```

**Option B — copy into an existing build workspace** (when you already have a
directory with [MicroPython](https://github.com/micropython/micropython) / [CircuitPython](https://github.com/adafruit/circuitpython) / usermods):

Copy the contents of this repo into that workspace root (the directory that
should contain `build_mp.sh`, `manifest-*.py`, and optionally `patches/`). Do
not nest a second `cmods/` folder unless you intend that to be the workspace
root.

### 2. Add the repos you need

Either clone them **into** the workspace, or clone them as **siblings** and
symlink:

```bash
# Into the workspace
git clone https://github.com/micropython/micropython.git micropython
cd micropython && git submodule update --init --recursive && cd ..

# Or as siblings + symlink (example layout: ../micropython next to the workspace)
ln -s ../micropython micropython
```

Repeat for each usermod or runtime you want ([displayif](https://github.com/PyDevices/displayif), [pygraphics](https://github.com/PyDevices/pygraphics),
[lvgl-micropython](https://github.com/PyDevices/lvgl-micropython), [circuitpython](https://github.com/adafruit/circuitpython), …). Each [MicroPython](https://github.com/micropython/micropython) usermod must be an immediate subdirectory of the workspace (clone or symlink) and provide a `micropython.mk` there (optional `manifest.py` for frozen Python).

### Patches (optional; naming convention)

[`patches/`](patches/) is optional. When present, `build_mp.sh` applies every
file whose name contains `micropython-<port>` for the selected `--port` (e.g.
`micropython-unix`, `micropython-windows`). This workspace currently ships two
such patches (windows networking/SSL, unix scheduler depth). Other ports find
no matches and skip. Details: [`patches/README.md`](patches/README.md).

### Quick build (after setup)

```bash
# Optional — only for LVGL
git clone https://github.com/PyDevices/lvgl-micropython.git lvgl-micropython
git clone https://github.com/PyDevices/lvgl-bindings.git lvgl-bindings
cd lvgl-bindings && git submodule update --init lvgl && cd ..
./lvgl-bindings/regenerate_lvmp.sh

./build_mp.sh --port unix --variant standard
```

The [LVGL](https://github.com/lvgl/lvgl) clone and `regenerate_lvmp.sh` steps are **optional** — use them only
when building with [LVGL](https://github.com/lvgl/lvgl). For other user C modules, add those repos (or
symlinks) instead.

## How it works

- `USER_C_MODULES=$(pwd)` — [MicroPython](https://github.com/micropython/micropython) discovers `*/micropython.mk` in immediate subdirectories
- [`manifest-micropython.py`](manifest-micropython.py) — frozen Python from cmod sibling repos, then includes the [MicroPython](https://github.com/micropython/micropython) upstream freeze via `FROZEN_MANIFEST_UPSTREAM`
- [`manifest-circuitpython.py`](manifest-circuitpython.py) — same aggregator shape for [CircuitPython](https://github.com/adafruit/circuitpython) (`build_cp.sh`)
- [`build_mp.sh`](build_mp.sh) — sets `FROZEN_MANIFEST_UPSTREAM` to the freeze file [MicroPython](https://github.com/micropython/micropython) would use for the selected port/board/variant (same as a manual `make` without override)
- [`build_cp.sh`](build_cp.sh) — auto-discovers `*/apply_cp_patches.sh` (optional extensions) and uses `manifest-circuitpython.py` for all ports
- [`micropython.cmake`](micropython.cmake) — aggregates `*/micropython.cmake` for CMake ports (ESP32, RP2)

## Build scripts

| Script | Role |
|--------|------|
| [`build_mp.sh`](build_mp.sh) | Any [MicroPython](https://github.com/micropython/micropython) port (interactive or `--port` / `--board` / `--variant`) |
| [`build_cp.sh`](build_cp.sh) | [CircuitPython](https://github.com/adafruit/circuitpython) ports (interactive or `--port` / `--board` / `--variant`) |
| [`build_runtimes.sh`](build_runtimes.sh) | Desktop/wasm interpreters for local [pydevices-examples](https://github.com/PyDevices/pydevices-examples) work — see below |

Examples:

```bash
./build_mp.sh                                          # interactive
./build_mp.sh --port unix --variant standard
./build_mp.sh --port rp2 --board RPI_PICO2_W
./build_mp.sh --port esp32 --board ESP32_GENERIC_P4 --variant C6_WIFI
./build_cp.sh                                          # interactive
./build_cp.sh --port unix --variant coverage
./build_runtimes.sh --only mp-unix,cp-unix
```

[`build_runtimes.sh`](build_runtimes.sh) builds the host interpreters used by PyDevices and installs them under workspace `bin/` (`micropython`, `micropython.exe`, `circuitpython`, and the wasm `micropython.{mjs,wasm}` pair). Targets are `mp-unix`, `mp-windows`, `mp-wasm`, and `cp-unix`. When the [pydevices](https://github.com/PyDevices/pydevices) core repo sits as a **sibling** of this workspace, the script copies the built binaries directly into `pydevices/bin/` to publish them. When [pydevices-examples](https://github.com/PyDevices/pydevices-examples) is also a sibling, the WebAssembly pair is copied into `.site/pyscript/vendor/micropython/` for the browser gallery. Use `--only` to build a subset, or `--install-only` to refresh installs from an existing build. Re-run after changing usermods (or frozen manifests) that link into these binaries.


**Desktop SDL (`usdl2`):** when [displayif](https://github.com/PyDevices/displayif) is present,
MicroPython `unix` / `windows` and CircuitPython unix link native `import usdl2`
from that repo (not a separate usdl2 usermod). Unix needs `libsdl2-dev`. Windows
needs an unpacked [SDL2 MinGW development ZIP](https://github.com/libsdl-org/SDL/releases)
under the workspace (e.g. `SDL2-2.30.10/`); `build_mp.sh` auto-sets `SDL2_DEV`
or you can export it (see [displayif `tools/sdl2_dev_env.sh`](https://github.com/PyDevices/displayif/blob/main/tools/sdl2_dev_env.sh)).

## 🎨 Hardware example: ESP32-P4 display + touch

End-to-end bring-up for the
[Waveshare ESP32-P4-WIFI6-Touch-LCD-4B](https://www.waveshare.com/esp32-p4-wifi6-touch-lcd-4b.htm)
(4″ 720×720 ST7703 on MIPI DSI, GT911 on I2C) using **[displayif](https://github.com/PyDevices/displayif)** + **[pydevices-examples](https://github.com/PyDevices/pydevices-examples)**.
This is **not** stock [MicroPython](https://github.com/micropython/micropython) — firmware must include the [displayif](https://github.com/PyDevices/displayif) `mipidsi`
cmod.

**Board configs** ([pydevices](https://github.com/PyDevices/pydevices)):

| Runtime | Path |
|---------|------|
| [MicroPython](https://github.com/micropython/micropython) | [`board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b`](https://github.com/PyDevices/pydevices/blob/main/board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b/board_config.py) |
| [CircuitPython](https://github.com/adafruit/circuitpython) | [`board_configs/cp/fbdisplay/esp32-p4-wifi6-touch-lcd-4b`](https://github.com/PyDevices/pydevices/blob/main/board_configs/cp/fbdisplay/esp32-p4-wifi6-touch-lcd-4b/board_config.py) |

```bash
git clone https://github.com/PyDevices/displayif.git displayif

# C6_WIFI — this board’s ESP32-C6 WiFi/BLE coprocessor (use C5_WIFI if yours is C5)
./build_mp.sh --port esp32 --board ESP32_GENERIC_P4 --variant C6_WIFI
```

`build_mp.sh` can flash when the build finishes (offset from `board.json`,
`0x2000` for `ESP32_GENERIC_P4`). Manual flash:

```bash
esptool -b 460800 --before default_reset --after hard_reset \
  write_flash 0x2000 micropython/ports/esp32/build-ESP32_GENERIC_P4/firmware.bin
```

The cmods build discovers `pydevices/manifest.py` and freezes the
core product packages. Install the matching board config (and optional
examples from pydevices-examples) with [mpremote](https://docs.micropython.org/en/latest/reference/mpremote.html):

```bash
mpremote mip install --target "." \
  "github:PyDevices/pydevices/board_configs/fbdisplay/esp32-p4-wifi6-touch-lcd-4b"
# optional: mpremote mip install --target "./examples" "github:PyDevices/pydevices-examples/packages/examples.json"
```

Smoke checks:

```bash
mpremote run displayif/tools/test_mipidsi_smoke.py
```

```python
import board_config
import eventsys

display_drv = board_config.display_drv
runtime = eventsys.Runtime.from_board_config(board_config)
display_drv.fill_rect(0, 0, 200, 200, 0xF800)
display_drv.show()

# Touch: poll until quit
while not runtime.quit_requested:
    for e in runtime.poll():
        print(e)
```

Pinout matches the Waveshare BSP (reset **27**, backlight **26**, I2C **7/8**,
GT911 @ **0x5D**). If the panel stays black, check backlight polarity
(`backlight_on_high=False` in the board config) and the [displayif](https://github.com/PyDevices/displayif) P4 DSI LDO
path (channel 3 @ 2.5 V). Validate display/touch over USB serial before WiFi.

## Related repos

| Repo | Role |
|------|------|
| [lvgl-micropython](https://github.com/PyDevices/lvgl-micropython) | [LVGL](https://github.com/lvgl/lvgl) [MicroPython](https://github.com/micropython/micropython) glue |
| [lvgl-bindings](https://github.com/PyDevices/lvgl-bindings) | [LVGL](https://github.com/lvgl/lvgl) binding generator |
| [lvgl-circuitpython](https://github.com/PyDevices/lvgl-circuitpython) | [LVGL](https://github.com/lvgl/lvgl) [CircuitPython](https://github.com/adafruit/circuitpython) glue (separate workflow) |

[CircuitPython](https://github.com/adafruit/circuitpython) does not use `USER_C_MODULES`. Clone [lvgl-circuitpython](https://github.com/PyDevices/lvgl-circuitpython) into this workspace if you want CP and MP trees side by side.

**[CircuitPython](https://github.com/adafruit/circuitpython)** (optional extensions; see [lvgl-circuitpython README](lvgl-circuitpython/README.md) for CP clone setup):

Native CP modules here follow Adafruit’s
[Extending CircuitPython](https://learn.adafruit.com/extending-circuitpython)
architecture (`shared-bindings` / `shared-module` / `CIRCUITPY_*`), but stay
**out-of-tree**: each extension keeps spikes in its own repo and
`apply_cp_patches.sh` copies them into a local (uncommitted) CircuitPython tree.
Adafruit’s Learn guide assumes in-tree edits; there is no official out-of-tree
C-module path. Per-repo READMEs map Learn steps → spikes/patches.

```bash
./build_cp.sh --port unix --variant standard
```

`build_cp.sh` runs every sibling `*/apply_cp_patches.sh` when present ([pygraphics](https://github.com/PyDevices/pygraphics), [LVGL](https://github.com/lvgl/lvgl), …). Clone only the extensions you need.
Optional: place a `user_post_mpconfigport.mk` at the workspace root ([CircuitPython](https://github.com/adafruit/circuitpython)’s
user-config hook; `build_cp.sh` passes `-I` when it exists) to freeze Adafruit
asyncio/ticks for [`multimer.AsyncTimer`](https://github.com/PyDevices/pydevices/blob/main/docs/multimer.md). See [CircuitPython building.md](https://github.com/adafruit/circuitpython/blob/main/building.md)
and [multimer runtime internals](https://github.com/PyDevices/pydevices/blob/main/docs/multimer-internals.md).

**[MicroPython](https://github.com/micropython/micropython) frozen asyncio** (required for [`multimer.AsyncTimer`](https://github.com/PyDevices/pydevices/blob/main/docs/multimer.md) on unix/windows):

```bash
# pydevices/manifest.py is discovered automatically.
# Add only personal extras to the optional manifest-user.py.
./build_mp.sh --port unix --variant standard
./build_mp.sh --port windows --variant dev
```

## Direct build (without this tooling)

Create any workspace directory, clone [micropython](https://github.com/micropython/micropython) and the usermods you need as
siblings (or symlink them), and build from `micropython/` with `USER_C_MODULES`
pointing at the workspace root. See each usermod’s README (e.g.
[lvgl-micropython](https://github.com/PyDevices/lvgl-micropython)).
