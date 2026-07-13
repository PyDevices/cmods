# AGENTS.md — cmods LVGL build & test matrix

Workspace root: **this repository** (directory containing `build_all.sh` / `AGENTS.md`). Bindings are generated in **`lv_bindings/`** and consumed by MicroPython, CircuitPython, and CPython mod repos.

All paths below are relative to the workspace root unless noted. Scripts resolve the root from their own location (`CMODS="$(cd … && pwd)"`); do not hard-code a home directory.

## Sub-repo `AGENTS.md`

This workspace is a collection of sibling git clones. **Before editing files under a sub-repo**, read that repo's root **`AGENTS.md`** when it exists — it may override or extend these workspace instructions for that tree.

1. Run discovery from the cmods root:

```bash
./scripts/list_subrepo_agents.sh          # markdown index
./scripts/list_subrepo_agents.sh --paths  # paths to read (existing only)
```

2. Read every path from `--paths` (or open `<sub-repo>/AGENTS.md` for the repo you are touching).

**Upstream clones** (`micropython/`, `circuitpython/`): an `AGENTS.md` may be present; still read it for port-specific notes, but **do not commit** in those trees unless the user explicitly overrides `.cursor/rules/cmods-upstream-no-commit.mdc`.

Owned PyDevices siblings (`lv_*`, `usdl2`, `graphics`, `displayif`, …) may add or grow their own `AGENTS.md`; use the script above rather than hard-coding the list.

## “Build them all”

**Primary API:** per-target and full-matrix scripts at the cmods root:

```bash
# from workspace root
./build_target.sh mp-unix       # one target: build + smoke test
./build_target.sh --smoke-only mp-unix   # smoke test only (binary must exist)
./build_target.sh cpy-windows
./build_all.sh                  # all five (safe parallelism)
./build_all.sh --sequential     # all five, one at a time
./build_all.sh --smoke-only     # smoke tests only, all five
```

| Target ID | Port | Build | Smoke test |
|-----------|------|-------|------------|
| `mp-unix` | MicroPython unix / standard | `./build_mp.sh --port unix --variant standard` | [`lv_bindings/test_lvgl_smoke.py`](lv_bindings/test_lvgl_smoke.py) |
| `mp-windows` | MicroPython windows / dev | `./build_mp.sh --port windows --variant dev` | same script via `micropython.exe` |
| `cp-unix` | CircuitPython unix / coverage | `./lv_circuitpython_mod/build_cp.sh --port unix --variant coverage` | same [`test_lvgl_smoke.py`](lv_bindings/test_lvgl_smoke.py) |
| `cpy-unix` | CPython Unix (WSL) | `lv_cpython_mod/.venv/bin/pip install -e .` | same smoke test (`.venv/bin/python …/lv_bindings/test_lvgl_smoke.py`) |
| `cpy-windows` | CPython Windows | `pip.exe install -e …` | `python.exe …/lv_bindings/test_lvgl_smoke.py` |

When the user says **“build them all”**, run `./build_all.sh` (or `./build_target.sh` for a single failing target). Default orchestration: targets **1–4 in parallel** (`mp-unix`, `mp-windows`, `cp-unix`, `cpy-unix`), **`wait`**, then **`cpy-windows` alone**.

**Imperative:** **`cpy-unix` and `cpy-windows` must never run concurrently** — both use editable `pip install -e` on the same `lv_cpython_mod/` tree and clobber `build/`, `*.egg-info`, and in-repo `.so`/`.pyd`. `build_target.sh` uses a flock on `lv_cpython_mod/.build.lock`; `build_all.sh` enforces the phase split above.

CPython targets auto-sync `generated/lvgl_python.c` (and `lv_conf.h`) from sibling `lv_bindings/` before build (`SYNC_LVPY=0` to skip). MP/CP read bindings directly from `lv_bindings/generated/`.

**Do not** use a venv for Windows CPython — use **`pip.exe`** / **`python.exe`**.

### One-shot build script (reference — equivalent to `./build_all.sh`)

```bash
# run from workspace root
CMODS="$(pwd)"

# Phase 1 — parallel (1–4); use $CMODS in every subshell (background jobs do not share cd)
(
  cd "$CMODS" && \
  ./build_mp.sh --port unix --variant standard && \
  "$CMODS/micropython/ports/unix/build-standard/micropython" \
    "$CMODS/lv_bindings/test_lvgl_smoke.py"
) &

(
  cd "$CMODS" && \
  ./build_mp.sh --port windows --variant dev && \
  "$CMODS/micropython/ports/windows/build-dev/micropython.exe" \
    "$CMODS/lv_bindings/test_lvgl_smoke.py"
) &

(
  cd "$CMODS/lv_circuitpython_mod" && \
  ./build_cp.sh --port unix --variant coverage && \
  "$CMODS/circuitpython/ports/unix/build-coverage/micropython" \
    "$CMODS/lv_bindings/test_lvgl_smoke.py"
) &

(
  cd "$CMODS/lv_cpython_mod" && \
  { test -d .venv || python3 -m venv .venv; } && \
  .venv/bin/pip install -r requirements.txt && \
  .venv/bin/pip install -e . && \
  .venv/bin/python "$CMODS/lv_bindings/test_lvgl_smoke.py"
) &

wait   # all four must finish before step 5

# Phase 2 — Windows CPython alone (clobbers lv_cpython_mod/ if run with step 4)
cd "$CMODS/lv_cpython_mod"
pip.exe install -e "$(wslpath -w "$CMODS/lv_cpython_mod")"
python.exe "$(wslpath -w "$CMODS/lv_bindings/test_lvgl_smoke.py")"
```

---

## MicroPython (`build_mp.sh`)

Script: `./build_mp.sh`

```bash
./build_mp.sh --port PORT [--variant VARIANT] [--no-os-dupterm] [--os-dupterm]
```

| Port | Variant | Notes |
|------|---------|--------|
| `unix` | `standard` | Default desktop smoke-test port |
| `windows` | `dev` (matrix) / `standard` | `build_target`/`build_all` use **`dev`**. `os.dupterm` is **off by default** (enabling it fails at link with `mp_interrupt_char`); pass `--os-dupterm` or `OS_DUPTERM=1` to force |

Outputs:

- Unix: `micropython/ports/unix/build-standard/micropython`
- Windows (matrix): `micropython/ports/windows/build-dev/micropython.exe`

WSL can run the Windows `.exe` directly for tests.

### MicroPython smoke test

Script: `lv_micropython_cmod/test_lvgl_unix.py` (port-agnostic, headless display).

```bash
# Unix
./micropython/ports/unix/build-standard/micropython \
  ./lv_bindings/test_lvgl_smoke.py

# Windows (from WSL)
./micropython/ports/windows/build-dev/micropython.exe \
  ./lv_bindings/test_lvgl_smoke.py
```

---

## CircuitPython (`build_cp.sh`)

Script: `./lv_circuitpython_mod/build_cp.sh`

```bash
cd lv_circuitpython_mod
./build_cp.sh --port unix --variant coverage
```

Uses `lv_circuitpython_mod/.venv` for CircuitPython build tooling (created automatically).

Output: `circuitpython/ports/unix/build-coverage/micropython`

### CircuitPython smoke test

```bash
./circuitpython/ports/unix/build-coverage/micropython \
  ./lv_bindings/test_lvgl_smoke.py
```

---

## CPython (`lv_cpython_mod`)

See also `lv_cpython_mod/BUILDING.md` and `lv_cpython_mod/README.md`.

Both platforms use the **same repo directory** for editable installs. **Never** run `.venv/bin/pip install -e .` and `pip.exe install -e .` concurrently. For “build them all”, step 4 (Unix) runs in **parallel with 1–3**; step 5 (Windows) runs **only after** `wait`.

### Unix (WSL) — use `.venv`

```bash
cd lv_cpython_mod
python3 -m venv .venv          # once
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install -e .       # rebuild after C or generated/lvgl_python.c changes

.venv/bin/python ../lv_bindings/test_lvgl_smoke.py
.venv/bin/python -c "import lvgl as lv; lv.init(); lv.deinit(); print('ok')"
```

### Windows — **no venv**; use `pip.exe` / `python.exe` from WSL

Requires MSVC Build Tools on Windows (python.org CPython, not MinGW).

```bash
# from workspace root
CMODS="$(pwd)"
cd lv_cpython_mod

pip.exe install -e "$(wslpath -w "$CMODS/lv_cpython_mod")"
python.exe "$(wslpath -w "$CMODS/lv_bindings/test_lvgl_smoke.py")"
python.exe -c "import lvgl as lv; lv.init(); lv.deinit(); print('ok')"
```

First Windows build over `\\wsl.localhost\...` can take several minutes.

---

## lv_bindings (generator)

After changing `binding/`, `lv_conf.h`, or the `lvgl` submodule:

```bash
cd lv_bindings
./regenerate_all.sh              # all three targets + commit + tag (see PUBLISHING.md)
# or individually:
./regenerate_lvmp.sh             # → generated/lvgl_micropython.c
./regenerate_lvcp.sh             # → generated/lvgl_circuitpython.c
./regenerate_lvpy.sh             # → generated/lvgl_python.c
./scripts/verify_bindings.sh     # regen + regression checks
```

Sync into consumer repos as needed (`lv_cpython_mod/scripts/sync_from_lv_bindings.sh`, or copy `generated/` + `lvgl` pin for MP/CP).

---

## Gotchas

- **`build_mp.sh` flags** are `--port` / `--variant`, not positional args.
- **Windows MP**: `os.dupterm` disabled by default; use `--os-dupterm` only if you intend to fix/port dupterm support.
- **CP test path** lives in `lv_circuitpython_mod/`, not `lv_micropython_cmod/`.
- **CPython Unix vs Windows**: never concurrent; use `./build_all.sh` or `./build_target.sh` (flock + phase split).
- **Editable CPython install** does not recompile on import; rerun `pip install -e .` after C changes.
- **Upstream clones** (`micropython/`, `circuitpython/`): do not commit unless the user explicitly overrides workspace rules.
