# AGENTS.md — cmods LVGL build & test matrix

Workspace root: `~/github/cmods`. Bindings are generated in **`lv_bindings/`** and consumed by MicroPython, CircuitPython, and CPython mod repos.

## “Build them all”

When the user says **“build them all”**, run targets **1–4 in parallel** (each: build → smoke test), **`wait` for all to finish**, then run target **5 alone** (Windows CPython). Only step 5 must not overlap step 4 — both use editable `pip install -e` on the same `lv_cpython_mod/` tree and clobber `build/`, `*.egg-info`, and in-repo `.so`/`.pyd`.

| # | Phase | Target | Build | Test |
|---|-------|--------|-------|------|
| 1 | **parallel** | MicroPython **unix / standard** | `./build_mp.sh --port unix --variant standard` | [MP smoke test](#micropython-smoke-test) |
| 2 | **parallel** | MicroPython **windows / standard** | `./build_mp.sh --port windows --variant standard --no-os-dupterm` | same script; `micropython.exe` |
| 3 | **parallel** | CircuitPython **unix / coverage** | `./lv_circuitpython_mod/build_cp.sh --port unix --variant coverage` | [CP smoke test](#circuitpython-smoke-test) |
| 4 | **parallel** | CPython **Unix (WSL)** | `lv_cpython_mod/.venv/bin/pip install -e .` | `.venv/bin/python test_lvgl_cpython.py` |
| 5 | **after wait** | CPython **Windows** | `pip.exe install -e "$(wslpath -w ~/github/cmods/lv_cpython_mod)"` | `python.exe test_lvgl_cpython.py` |

**Do not** use a venv for Windows CPython — use **`pip.exe`** / **`python.exe`**.

### One-shot build script (reference)

```bash
CMODS=~/github/cmods

# Phase 1 — parallel (1–4); use $CMODS in every subshell (background jobs do not share cd)
(
  cd "$CMODS" && \
  ./build_mp.sh --port unix --variant standard && \
  "$CMODS/micropython/ports/unix/build-standard/micropython" \
    "$CMODS/lv_micropython_cmod/test_lvgl_unix.py"
) &

(
  cd "$CMODS" && \
  ./build_mp.sh --port windows --variant standard --no-os-dupterm && \
  "$CMODS/micropython/ports/windows/build-standard/micropython.exe" \
    "$CMODS/lv_micropython_cmod/test_lvgl_unix.py"
) &

(
  cd "$CMODS/lv_circuitpython_mod" && \
  ./build_cp.sh --port unix --variant coverage && \
  "$CMODS/circuitpython/ports/unix/build-coverage/micropython" \
    "$CMODS/lv_circuitpython_mod/test_lvgl_cp_unix.py"
) &

(
  cd "$CMODS/lv_cpython_mod" && \
  { test -d .venv || python3 -m venv .venv; } && \
  .venv/bin/pip install -r requirements.txt && \
  .venv/bin/pip install -e . && \
  .venv/bin/python test_lvgl_cpython.py
) &

wait   # all four must finish before step 5

# Phase 2 — Windows CPython alone (clobbers lv_cpython_mod/ if run with step 4)
cd "$CMODS/lv_cpython_mod"
pip.exe install -e "$(wslpath -w "$CMODS/lv_cpython_mod")"
python.exe test_lvgl_cpython.py
```

---

## MicroPython (`build_mp.sh`)

Script: `~/github/cmods/build_mp.sh`

```bash
./build_mp.sh --port PORT [--variant VARIANT] [--no-os-dupterm]
```

| Port | Variant | Notes |
|------|---------|--------|
| `unix` | `standard` | Default desktop smoke-test port |
| `windows` | `standard` | **Always** pass `--no-os-dupterm` (windows does not support `os.dupterm`; omitting it fails at link with `mp_interrupt_char`) |

Outputs:

- Unix: `micropython/ports/unix/build-standard/micropython`
- Windows: `micropython/ports/windows/build-standard/micropython.exe`

WSL can run the Windows `.exe` directly for tests.

### MicroPython smoke test

Script: `lv_micropython_cmod/test_lvgl_unix.py` (port-agnostic, headless display).

```bash
# Unix
~/github/cmods/micropython/ports/unix/build-standard/micropython \
  ~/github/cmods/lv_micropython_cmod/test_lvgl_unix.py

# Windows (from WSL)
~/github/cmods/micropython/ports/windows/build-standard/micropython.exe \
  ~/github/cmods/lv_micropython_cmod/test_lvgl_unix.py
```

---

## CircuitPython (`build_cp.sh`)

Script: `~/github/cmods/lv_circuitpython_mod/build_cp.sh`

```bash
cd ~/github/cmods/lv_circuitpython_mod
./build_cp.sh --port unix --variant coverage
```

Uses `lv_circuitpython_mod/.venv` for CircuitPython build tooling (created automatically).

Output: `circuitpython/ports/unix/build-coverage/micropython`

### CircuitPython smoke test

```bash
~/github/cmods/circuitpython/ports/unix/build-coverage/micropython \
  ~/github/cmods/lv_circuitpython_mod/test_lvgl_cp_unix.py
```

---

## CPython (`lv_cpython_mod`)

See also `lv_cpython_mod/AGENTS.md` and `lv_cpython_mod/README.md`.

Both platforms use the **same repo directory** for editable installs. **Never** run `.venv/bin/pip install -e .` and `pip.exe install -e .` concurrently. For “build them all”, step 4 (Unix) runs in **parallel with 1–3**; step 5 (Windows) runs **only after** `wait`.

### Unix (WSL) — use `.venv`

```bash
cd ~/github/cmods/lv_cpython_mod
python3 -m venv .venv          # once
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install -e .       # rebuild after C or generated/lvpy.c changes

.venv/bin/python test_lvgl_cpython.py
.venv/bin/python -c "import lvgl as lv; lv.init(); lv.deinit(); print('ok')"
```

### Windows — **no venv**; use `pip.exe` / `python.exe` from WSL

Requires MSVC Build Tools on Windows (python.org CPython, not MinGW).

```bash
cd ~/github/cmods/lv_cpython_mod

pip.exe install -e "$(wslpath -w ~/github/cmods/lv_cpython_mod)"
python.exe test_lvgl_cpython.py
python.exe -c "import lvgl as lv; lv.init(); lv.deinit(); print('ok')"
```

First Windows build over `\\wsl.localhost\...` can take several minutes.

---

## lv_bindings (generator)

After changing `binding/`, `lv_conf.h`, or the `lvgl` submodule:

```bash
cd ~/github/cmods/lv_bindings
./regenerate_all.sh              # all three targets + commit + tag (see PUBLISHING.md)
# or individually:
./regenerate_lvmp.sh             # → generated/lvmp.c
./regenerate_lvcp.sh             # → generated/lvcp.c
./regenerate_lvpy.sh             # → generated/lvpy.c
./verify_bindings.sh             # regen + regression checks
```

Sync into consumer repos as needed (`lv_cpython_mod/scripts/sync_from_lv_bindings.sh`, or copy `generated/` + `lvgl` pin for MP/CP).

---

## Gotchas

- **`build_mp.sh` flags** are `--port` / `--variant`, not positional args.
- **Windows MP**: always `--no-os-dupterm` for `windows` port.
- **CP test path** lives in `lv_circuitpython_mod/`, not `lv_micropython_cmod/`.
- **CPython Unix vs Windows**: parallel **1–4**, then **5 alone**; never overlap step 4 and step 5 `pip install -e` on `lv_cpython_mod/`.
- **Editable CPython install** does not recompile on import; rerun `pip install -e .` after C changes.
- **Upstream clones** (`micropython/`, `circuitpython/`): do not commit unless the user explicitly overrides workspace rules.
