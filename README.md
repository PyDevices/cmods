# cmods

Tools for building MicroPython and CircuitPython with LVGL user C modules.

## Layout

```
cmods/
  micropython/              MicroPython clone (local, gitignored)
  circuitpython/            CircuitPython clone (local, gitignored; pin 10.2.1)
  lv_micropython_cmod/      LVGL + bindings generator
  pydisplay_cmods/          Display helpers
  manifest.py               Frozen Python modules
  build_unix.sh             Build Unix port
  build_esp32.sh            Build ESP32 port
  build_cp_unix.sh          CircuitPython unix port (coverage variant)
```

## First-time setup

1. Clone MicroPython and CircuitPython next to this tree (both gitignored; not submodules):

```bash
git clone https://github.com/micropython/micropython.git micropython
git clone https://github.com/adafruit/circuitpython.git circuitpython
cd micropython && git submodule update --init --recursive && cd ..
```

Pin CircuitPython to the **latest stable release** (not `main`):

```bash
cd circuitpython
git fetch --tags
git checkout -B circuitpython-10.2.1 10.2.1
make fetch-all-submodules
cd ..
```

Use `git describe --tags --exact-match` inside `circuitpython/` to confirm `10.2.1`. Do not `git pull` on `main` — that returns to the development branch.

2. Initialize submodules inside `lv_micropython_cmod/` (lvgl, pycparser, etc.).
3. Generate LVGL bindings (required before any build):

```bash
./lv_micropython_cmod/regenerate_lvmp.sh
```

4. Build a port, e.g.:

```bash
./build_unix.sh
```

## LVGL bindings

Bindings are **not** committed to the repo. Regenerate after changing:

- `lv_micropython_cmod/lvgl/` (LVGL submodule)
- `lv_micropython_cmod/lv_conf.h`
- `lv_micropython_cmod/binding/` (modular generator)

### Generate

```bash
./lv_micropython_cmod/regenerate_lvmp.sh
```

By default only `lvmp.c` (and `lvcp_module_globals.h` for CP) are kept under `generated/`.
Set `LV_BINDINGS_DEBUG=1` to also keep preprocessed `.pp` and `.json` metadata files.

```bash
LV_BINDINGS_DEBUG=1 ./lv_micropython_cmod/regenerate_lvmp.sh
```

Output (gitignored):

```
lv_micropython_cmod/generated/
  lvmp.c          # MicroPython bindings (compiled into firmware)
  lvcp.c          # CircuitPython bindings (phase 7; merge via LVCP_MODULE_GLOBALS)
  lvcp_module_globals.h
  # with LV_BINDINGS_DEBUG=1 only:
  lvmp.c.pp, lvmp.c.json, lvcp.c.pp, lvcp.c.json
```

Clean generated artifacts and pycparser caches:

```bash
./lv_micropython_cmod/clean_generated.sh
```

### Modular generator

`gen_lv_bindings.py` is the supported entry point. It uses the `binding/` package:

```
lv_micropython_cmod/binding/
  cli.py              argparse, --target micropython|circuitpython
  preprocess.py       gcc -E preprocessing
  context.py          BindingContext, regex patterns
  parse.py            AST helpers (pycparser)
  helpers.py          name sanitization, LVGL pattern matching
  analyze.py          AST analysis and metadata extraction
  runtime.py          shared generation state (sync hub)
  emit_c.py           MicroPython C source emission
  emit_circuitpython.py CircuitPython emission (phases 1–7 → lvcp.c)
  emit_micropython.py orchestrates analyze + emit_c
  generator.py        wires context, generation, metadata
  metadata.py         JSON export
  util.py             memoize, eprint
```

Design notes and CP integration docs live under `docs/lvgl/` (see table below).

### Full regression (CircuitPython bindings)

```bash
./lv_micropython_cmod/verify_bindings.sh
```

Regenerates `lvmp.c` and `lvcp.c` (with metadata) and checks `lvcp.c` size, metadata counts, `LVCP_MODULE_GLOBALS`, and absence of `MP_REGISTER_MODULE`.

MicroPython unix smoke test (after `./build_unix.sh`):

```bash
./micropython/ports/unix/build-standard/micropython ./lv_micropython_cmod/test_lvgl_unix.py
```

CircuitPython unix smoke test (after `./build_cp_unix.sh` with LVGL patched):

```bash
./circuitpython/ports/unix/build-coverage/micropython ./lv_micropython_cmod/test_lvgl_cp_unix.py
```

Covers init, headless display, widgets, event callbacks, and GC visibility (see `docs/lvgl/gc_callback_audit.md`).

Before the first CircuitPython build, read `docs/lvgl/cp_flash_budget.md` (flash partition headroom + allocator notes).

## Builds

| Script | Port | Notes |
|--------|------|-------|
| `build_unix.sh` | `micropython/ports/unix` | Desktop dev / testing |
| `build_esp32.sh` | `micropython/ports/esp32` | Requires ESP-IDF |
| `build_cp_unix.sh` | `circuitpython/ports/unix` | Default `VARIANT=coverage`; stock or LVGL-patched tree |

All MicroPython builds pass `USER_C_MODULES` pointing at this repo root and use `manifest.py` for frozen modules.

## CircuitPython

Use a **release** tree, not Adafruit's `main` branch. After cloning, pin tag **`10.2.1`** on local branch `circuitpython-10.2.1` (see first-time setup above). **Leave the CP tree unpatched** until you are ready to integrate LVGL; check status with:

```bash
./lv_micropython_cmod/apply_cp_lvgl_patches.sh --status
```

When ready to wire LVGL (default **unix** / **standard** port):

```bash
./lv_micropython_cmod/apply_cp_lvgl_patches.sh --apply
```

**Primary target:** CircuitPython **unix** port, **`coverage`** variant (desktop dev; avoids unix `standard` + `ringio` ringbuf mismatch on 10.2.1). Patches wire `ports/unix/Makefile` and `variants/coverage/mpconfigvariant.mk`.

**Embedded target (later):** **[ESP32-P4-Function-EV-Board](https://circuitpython.org/board/espressif_esp32p4_function_ev/)** (`espressif_esp32p4_function_ev`) — `build_cp_esp32.sh` (not yet implemented); patch with `PORT=espressif BOARD=espressif_esp32p4_function_ev ./lv_micropython_cmod/apply_cp_lvgl_patches.sh --apply`

Build glue and full emission live in `lv_micropython_cmod/`:

| File | Purpose |
|------|---------|
| `circuitpython.mk` | Port Makefile fragment (LVGL + allocator + `lvcp.c`) |
| `apply_cp_lvgl_patches.sh` | Copy spike + patch CP tree (`--dry-run` / `--apply`) |
| `clean_generated.sh` | Remove `generated/` artifacts and pycparser caches |
| `regenerate_lvcp.sh` | Preprocess + `--target circuitpython` → `generated/lvcp.c` |
| `circuitpython_spike/` | Hand-written module templates (copy into CP tree) |
| `docs/lvgl/gc_callback_audit.md` | GC roots and callback lifetime notes |
| `docs/lvgl/cp_flash_budget.md` | Flash/allocator review before first CP build |
| `docs/lvgl/circuitpython_emit_plan.md` | Phased API mapping from metadata |
| `docs/lvgl/circuitpython_spike.md` | Spike merge workflow and `lvcp.c` integration |

Current status:

1. Phase 0 spike templates (`shared-bindings/lvgl/`, `shared-module/lvgl/`)
2. Phase 1–7 emitter complete (`max_phase: 7`); `lvcp.c` ~39.5k lines (parity with `lvmp.c`)
3. GC-aware allocator draft (`lv_mem_core_circuitpython.c`, via `circuitpython.mk`)
4. Port wiring + on-tree build (`apply_cp_lvgl_patches.sh` → `./build_cp_unix.sh`)
5. **Display bridge — ON HOLD** (Python `displayio`/`mipidsi` flush/tick; resume when requested)

Regenerate and verify bindings:

```bash
./lv_micropython_cmod/regenerate_lvcp.sh
./lv_micropython_cmod/verify_bindings.sh
```

Build CircuitPython unix (works **before or after** patching; does not modify the CP tree):

```bash
./build_cp_unix.sh
```

On a **clean** release tree this builds stock CircuitPython. After patching, run `regenerate_lvcp.sh` first; the patched Makefile supplies `CMODS_DIR` and pulls in full LVGL + `lvcp.c` (make fails if bindings are missing). Each run starts with `make clean`.

After patching:

```bash
./lv_micropython_cmod/regenerate_lvcp.sh
./lv_micropython_cmod/apply_cp_lvgl_patches.sh --apply
./build_cp_unix.sh
```

Patch status: `./lv_micropython_cmod/apply_cp_lvgl_patches.sh --status` (`pending` / `patched` / `ok` / `missing`). Defaults to `PORT=unix` `VARIANT=coverage`.

**Display bridge is ON HOLD.** C bindings do not include flush/tick; a future Python `displayio` bridge (similar to `pydisplay_cmods` on MicroPython) will be designed when you ask to resume that work.

The `binding/` package supports `--target circuitpython` with `max_phase: 7` for full API emission.
