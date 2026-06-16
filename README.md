# cmods

Tools for building MicroPython and CircuitPython with LVGL user C modules.

## Layout

```
cmods/
  micropython/              MicroPython submodule
  circuitpython/            CircuitPython clone (local, gitignored)
  lv_micropython_cmod/      LVGL + bindings generator
  pydisplay_cmods/          Display helpers
  manifest.py               Frozen Python modules
  build_unix.sh             Build Unix port
  build_esp32.sh            Build ESP32 port
  build_circuitpython.sh    CircuitPython build (ESP32-P4 default board)
```

## First-time setup

1. Initialize submodules (micropython, lvgl, etc.).
2. Generate LVGL bindings (required before any build):

```bash
./lv_micropython_cmod/regenerate_lvmp.sh
```

3. Build a port, e.g.:

```bash
./build_unix.sh
```

## LVGL bindings

Bindings are **not** committed to the repo. Regenerate after changing:

- `lv_micropython_cmod/lvgl/` (LVGL submodule)
- `lv_micropython_cmod/lv_conf.h`
- `lv_micropython_cmod/binding/` (modular generator; primary)
- `lv_micropython_cmod/gen_mpy.py` (regression reference only)

### Generate

```bash
./lv_micropython_cmod/regenerate_lvmp.sh
```

Output (gitignored):

```
lv_micropython_cmod/generated/
  lvmp.c          # MicroPython bindings (compiled into firmware)
  lvmp.c.pp       # preprocessed lvgl.h
  lvmp.c.json     # API metadata
  lvcp.c          # CircuitPython bindings (phase 7; merge via LVCP_MODULE_GLOBALS)
  lvcp.c.pp
  lvcp.c.json
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
  circuitpython_spike/    Phase 0 templates (copy into CP tree)
  circuitpython_emit_plan.md  CP emission phases and API mapping
  emit_micropython.py orchestrates analyze + emit_c
  generator.py        wires context, generation, metadata
  metadata.py         JSON export
  util.py             memoize, eprint
```

`gen_mpy.py` is kept only for regression testing (`compare_bindings.sh`). Production builds use `gen_lv_bindings.py`.

### Verify generator parity

```bash
./lv_micropython_cmod/compare_bindings.sh
```

Compares `gen_mpy.py` vs `gen_lv_bindings.py` output (ignoring the command-line comment).

### Full regression (MicroPython + CircuitPython)

```bash
./lv_micropython_cmod/verify_bindings.sh
```

Runs `compare_bindings.sh`, `regenerate_lvcp.sh`, and checks `generated/lvcp.c` size, metadata counts, `LVCP_MODULE_GLOBALS`, and absence of `MP_REGISTER_MODULE`.

MicroPython unix smoke test (after `./build_unix.sh`):

```bash
./micropython/ports/unix/build-standard/micropython ./lv_micropython_cmod/test_lvgl_unix.py
```

Covers init, headless display, widgets, event callbacks, and GC visibility (see `binding/gc_callback_audit.md`).

Before the first CircuitPython build, read `binding/cp_flash_budget.md` (flash partition headroom + allocator notes).

## Builds

| Script | Port | Notes |
|--------|------|-------|
| `build_unix.sh` | `micropython/ports/unix` | Desktop dev / testing |
| `build_esp32.sh` | `micropython/ports/esp32` | Requires ESP-IDF |
| `build_circuitpython.sh` | `circuitpython/` | Default `BOARD=espressif_esp32p4_function_ev` |

All MicroPython builds pass `USER_C_MODULES` pointing at this repo root and use `manifest.py` for frozen modules.

## CircuitPython

Target board: **[ESP32-P4-Function-EV-Board](https://circuitpython.org/board/espressif_esp32p4_function_ev/)**
(`espressif_esp32p4_function_ev`). Build glue and full emission live in `lv_micropython_cmod/`:

| File | Purpose |
|------|---------|
| `circuitpython.mk` | Port Makefile fragment (LVGL + allocator + `lvcp.c`) |
| `apply_cp_lvgl_patches.sh` | Copy spike + patch CP tree (`--dry-run` / `--apply`) |
| `circuitpython_board.snippet.mk` | Manual patch checklist (reference) |
| `binding/gc_callback_audit.md` | GC roots and callback lifetime notes |
| `binding/cp_flash_budget.md` | Flash/allocator review before first CP build |
| `regenerate_lvcp.sh` | Preprocess + `--target circuitpython` → `generated/lvcp.c` |
| `binding/circuitpython_emit_plan.md` | Phased API mapping from metadata |
| `circuitpython_spike/` | Hand-written module + merge docs for phase-1 entries |

Current status:

1. Phase 0 spike templates (`shared-bindings/lvgl/`, `shared-module/lvgl/`)
2. Phase 1–7 emitter complete (`max_phase: 7`); `lvcp.c` ~39.5k lines (parity with `lvmp.c`)
3. GC-aware allocator draft (`lv_mem_core_circuitpython.c`, via `circuitpython.mk`)
4. Board wiring + first on-tree build (`apply_cp_lvgl_patches.sh` → `build_circuitpython.sh`)
5. **Display bridge — ON HOLD** (Python `displayio`/`mipidsi` flush/tick; resume when requested)

Regenerate and verify bindings:

```bash
./lv_micropython_cmod/regenerate_lvcp.sh
./lv_micropython_cmod/verify_bindings.sh
```

Build (once the CP tree is wired; `build_circuitpython.sh` applies patches automatically):

```bash
CMODS_LVGL_ALLOW_MISSING_BINDINGS=1 ./build_circuitpython.sh
```

Or manually:

```bash
./lv_micropython_cmod/apply_cp_lvgl_patches.sh --apply
CMODS_LVGL_ALLOW_MISSING_BINDINGS=1 ./build_circuitpython.sh
```

Patch status: `./lv_micropython_cmod/apply_cp_lvgl_patches.sh --status` (`pending` / `patched` / `ok` / `missing`).

For CP unix only (not P4 LVGL): `build_cp_unix.sh` — see script header.

**Display bridge is ON HOLD.** C bindings do not include flush/tick; a future Python `displayio` bridge (similar to `pydisplay_cmods` on MicroPython) will be designed when you ask to resume that work.

The `binding/` package supports `--target circuitpython` with `max_phase: 7` for full API emission.
