# cmods

Optional workspace wrapper for building MicroPython with multiple user C modules.

This repo does **not** include MicroPython or any user modules — clone them into this directory, then run the build scripts. It is not required for LVGL or any other module; each module repo documents direct builds without cmods.

## Quick start

```bash
git clone https://github.com/PyDevices/cmods.git
cd cmods

git clone https://github.com/micropython/micropython.git micropython
cd micropython && git submodule update --init --recursive && cd ..

# Optional — only for LVGL; skip and clone other user C modules instead
git clone https://github.com/PyDevices/lv_micropython_cmod.git lv_micropython_cmod
git clone https://github.com/PyDevices/lv_bindings.git lv_bindings
cd lv_bindings && git submodule update --init lvgl && cd ..
./lv_bindings/regenerate_lvmp.sh

./build_mp.sh --port unix --variant standard
```

The LVGL clone and `regenerate_lvmp.sh` steps are **optional** — use them only when building with LVGL. For other user C modules, clone those repos as siblings instead (see below).

Add more user C modules by cloning them as siblings (each needs `micropython.mk` and optional `manifest.py`).

## How it works

- `USER_C_MODULES=$(pwd)` — MicroPython discovers `*/micropython.mk` in immediate subdirectories
- [`manifest.py`](manifest.py) — aggregates `*/manifest.py` from subdirectories
- [`micropython.cmake`](micropython.cmake) — aggregates `*/micropython.cmake` for CMake ports (ESP32, RP2)

## Build scripts

| Script | Port |
|--------|------|
| [`build_mp.sh`](build_mp.sh) | Any MicroPython port (interactive or `--port` / `--board` / `--variant`) |

Examples:

```bash
./build_mp.sh                                          # interactive
./build_mp.sh --port unix --variant standard
./build_mp.sh --port rp2 --board RPI_PICO2_W
./build_mp.sh --port esp32 --board ESP32_GENERIC_P4 --variant C6_WIFI
```

## Related repos

| Repo | Role |
|------|------|
| [lv_micropython_cmod](https://github.com/PyDevices/lv_micropython_cmod) | LVGL MicroPython glue |
| [lv_bindings](https://github.com/PyDevices/lv_bindings) | LVGL binding generator |
| [lv_circuitpython_mod](https://github.com/PyDevices/lv_circuitpython_mod) | LVGL CircuitPython glue (separate workflow) |

CircuitPython does not use `USER_C_MODULES`. Clone `lv_circuitpython_mod` into this workspace if you want CP and MP trees side by side.

## usdl2 (desktop SDL2 subset)

[`usdl2`](https://github.com/PyDevices/usdl2) is a native module exposing a pydisplay-sized subset of libSDL2 as `import usdl2`. Builds on MicroPython **unix** and **windows** ports. Clone into this workspace as `usdl2/`.

```bash
git clone https://github.com/PyDevices/usdl2.git
sudo apt install libsdl2-dev   # Debian/Ubuntu — unix port only
```

**MicroPython unix** (no patching):

```bash
./build_mp.sh --port unix --variant standard
./micropython/ports/unix/build-standard/micropython ./usdl2/test_usdl2.py
```

**MicroPython windows** (static SDL2; SDL2 not vendored — use the official MinGW dev ZIP):

```bash
# Download SDL2-devel-*-mingw.zip from https://github.com/libsdl-org/SDL/releases
# Unpack outside the repo, e.g. ~/SDL2-2.30.10
export SDL2_DEV=~/SDL2-2.30.10
sudo apt install gcc-mingw-w64   # cross-build from Linux/WSL
./build_mp.sh --port windows --variant standard
```

See [usdl2/README.md](usdl2/README.md) for `PKG_CONFIG_PATH`, MSYS2, and runtime notes.

## pydisplay_android (Android APK)

[`pydisplay_android`](https://github.com/PyDevices/pydisplay_android) holds python-for-android recipes, a buildozer demo APK, and desktop smoke tests for running pydisplay under CPython on Android. Clone into this workspace as `pydisplay_android/` (sibling of `usdl2/` and `pydisplay/`):

```bash
git clone https://github.com/PyDevices/pydisplay_android.git
```

usdl2 keeps the ctypes FFI package and `p4a_recipes/usdl2/`; pydisplay_android provides `p4a_recipes/pydisplay/` and `p4a_recipes/lvglcpython/`. See [pydisplay Android platform notes](https://github.com/PyDevices/pydisplay/blob/main/docs/platforms/android.md).

**CircuitPython** (requires patch script; see [lv_circuitpython_mod README](lv_circuitpython_mod/README.md) for CP clone setup):

```bash
# Frozen asyncio for multimer.AsyncTimer (copy example first):
cp cp-user-config/user_post_mpconfigport.mk.example cp-user-config/user_post_mpconfigport.mk
git clone https://github.com/adafruit/Adafruit_CircuitPython_asyncio.git
git clone https://github.com/adafruit/Adafruit_CircuitPython_Ticks.git

./usdl2/apply_cp_unix_usdl_patches.sh --apply
./lv_circuitpython_mod/build_cp.sh --port unix --variant standard
./circuitpython/ports/unix/build-standard/micropython ./usdl2/test_usdl2.py
```

`build_cp.sh` passes `-I cp-user-config/` when that directory exists so CircuitPython
picks up `user_post_mpconfigport.mk`. See [multimer building docs](https://github.com/PyDevices/multimer/blob/main/docs/building.md).

**MicroPython frozen asyncio** (required for `multimer.AsyncTimer` on unix/windows):

```bash
cp my-manifest.py.example my-manifest.py   # if present; or use pydisplay/manifest.py
./build_mp.sh --port unix --variant standard
./build_mp.sh --port windows --variant dev
```

## Direct build (without cmods)

Create any workspace directory, clone `micropython`, `lv_micropython_cmod`, and `lv_bindings` as siblings, and build from `micropython/` with `USER_C_MODULES` pointing at the workspace root. See [lv_micropython_cmod](https://github.com/PyDevices/lv_micropython_cmod) README.
