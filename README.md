# cmods

Optional workspace wrapper for building MicroPython with multiple user C modules.

This repo does **not** include MicroPython or any user modules — clone them into this directory, then run the build scripts. It is not required for LVGL or any other module; each module repo documents direct builds without cmods.

## Quick start

```bash
git clone git@github.com:PyDevices/cmods.git
cd cmods

git clone git@github.com:micropython/micropython.git micropython
cd micropython && git submodule update --init --recursive && cd ..

# Optional — only for LVGL; skip and clone other user C modules instead
git clone git@github.com:PyDevices/lv_micropython_cmod.git lv_micropython_cmod
git clone git@github.com:PyDevices/lv_bindings.git lv_bindings
cd lv_bindings && git submodule update --init lvgl && cd ..
./lv_bindings/regenerate_lvmp.sh

./build_unix.sh
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
| [`build_unix.sh`](build_unix.sh) | MicroPython unix |
| [`build_esp32.sh`](build_esp32.sh) | ESP32 (CMake) |
| [`build_rp2.sh`](build_rp2.sh) | RP2 Pico (CMake) |

## Related repos

| Repo | Role |
|------|------|
| [lv_micropython_cmod](https://github.com/PyDevices/lv_micropython_cmod) | LVGL MicroPython glue |
| [lv_bindings](https://github.com/PyDevices/lv_bindings) | LVGL binding generator |
| [lv_circuitpython_mod](https://github.com/PyDevices/lv_circuitpython_mod) | LVGL CircuitPython glue (separate workflow) |

CircuitPython does not use `USER_C_MODULES`. Clone `lv_circuitpython_mod` into this workspace if you want CP and MP trees side by side.

## Direct build (without cmods)

Create any workspace directory, clone `micropython`, `lv_micropython_cmod`, and `lv_bindings` as siblings, and build from `micropython/` with `USER_C_MODULES` pointing at the workspace root. See [lv_micropython_cmod](https://github.com/PyDevices/lv_micropython_cmod) README.
