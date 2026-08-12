# AGENTS.md — cmods workspace builds

Workspace root: the directory containing `build_mp.sh` / `AGENTS.md` (this
repo’s contents, whether you cloned cmods or copied them into an existing
tree). Bindings are generated in **`lvgl-bindings/`** and consumed by
MicroPython, CircuitPython, and CPython mod repos.

All paths below are relative to the workspace root unless noted. Scripts resolve
the root from their own location (`WORKSPACE_DIR="$(cd … && pwd)"`); do not
hard-code a home directory.

## Workspace setup

1. **Get the tooling** — either:
   - **Clone** https://github.com/PyDevices/cmods (preferred for a new workspace), or
   - **Copy** this repo’s files into an existing build workspace root (so
     `build_mp.sh`, manifests, and optional `patches/` sit beside your clones).
2. **Add runtimes / usermods** — clone them **into** the workspace, **or** clone
   them as siblings of the workspace and **symlink** (e.g.
   `ln -s ../micropython micropython`).
3. **`patches/`** — optional. `build_mp.sh` applies files named with
   `micropython-<port>` for the selected port; no matches → skip. See
   [`patches/README.md`](patches/README.md).

## Sub-repo `AGENTS.md`

This workspace is a collection of sibling git clones (or symlinks to them).
**Before editing files under a sub-repo**, read that repo's root **`AGENTS.md`**
when it exists — it may override or extend these workspace instructions for
that tree.

**Upstream clones** (`micropython/`, `circuitpython/`): an `AGENTS.md` may be
present; still read it for port-specific notes, but **do not commit** in those
trees unless the user explicitly overrides the user Cursor rule
`cmods-upstream-no-commit` (`~/.cursor/rules/cmods-upstream-no-commit.mdc`).

Owned PyDevices siblings (`lv_*`, `pygraphics`, `displayif`, …) may add
or grow their own `AGENTS.md`.

## Runtimes (`build_runtimes.sh`)

Builds desktop / wasm interpreters used day-to-day, installs into **`bin/`**, and
when **pydisplay** is a sibling of this workspace (`../pydisplay`), also copies
into that tree.

```bash
./build_runtimes.sh
./build_runtimes.sh --only mp-unix,mp-wasm
./build_runtimes.sh --install-only   # copy existing build outputs
```

| Target | Build | Always install | Sibling pydisplay also |
|--------|-------|----------------|------------------------|
| `mp-unix` | `./build_mp.sh --port unix --variant standard` | `bin/micropython` | `../pydisplay/bin/micropython` |
| `mp-windows` | `./build_mp.sh --port windows --variant dev` | `bin/micropython.exe` | `../pydisplay/bin/micropython.exe` |
| `mp-wasm` | `./build_mp.sh --port webassembly --variant pyscript` | `bin/micropython.{mjs,wasm}` | `../pydisplay/web/pyscript/vendor/micropython/` |
| `cp-unix` | `./build_cp.sh --port unix --variant coverage` | `bin/circuitpython` | `../pydisplay/bin/circuitpython` |

**When to run:** after changing any usermod or freeze/config compiled into these
binaries (`pygraphics`, `lvgl-micropython`, `lvgl-circuitpython` /
regenerated `lvgl-bindings`, `displayif` when present — including desktop
`usdl2` — freeze aggregators, or related port patches). Without a sibling
pydisplay, only workspace `bin/` is updated. Windows `mp-windows` needs
`SDL2_DEV` (auto-detected under the workspace; see displayif
`tools/sdl2_dev_env.sh`).

When the user says **“build the runtimes”** / **“refresh pydisplay binaries”**,
run `./build_runtimes.sh` (optionally `--only …`).

---

## MicroPython (`build_mp.sh`)

Script: `./build_mp.sh`

```bash
./build_mp.sh --port PORT [--variant VARIANT] [--no-os-dupterm] [--os-dupterm]
```

| Port | Variant | Notes |
|------|---------|--------|
| `unix` | `standard` | Default desktop port |
| `windows` | `dev` (runtimes) / `standard` | Runtimes use **`dev`**. `os.dupterm` is **off by default** (enabling it fails at link with `mp_interrupt_char`); pass `--os-dupterm` or `OS_DUPTERM=1` to force |

Outputs:

- Unix: `micropython/ports/unix/build-standard/micropython`
- Windows (runtimes): `micropython/ports/windows/build-dev/micropython.exe`

WSL can run the Windows `.exe` directly for tests.

### MicroPython smoke test

Prefer [`lvgl-bindings/tools/test_lvgl_smoke.py`](lvgl-bindings/tools/test_lvgl_smoke.py)
when `lvgl-bindings` is present:

```bash
# Unix
./micropython/ports/unix/build-standard/micropython \
  ./lvgl-bindings/tools/test_lvgl_smoke.py

# Windows (from WSL)
./micropython/ports/windows/build-dev/micropython.exe \
  ./lvgl-bindings/tools/test_lvgl_smoke.py
```

---

## CircuitPython (`build_cp.sh`)

Script: `./build_cp.sh` (cmods orchestrator — auto-discovers optional
`*/apply_cp_patches.sh`, then make)

```bash
./build_cp.sh --port unix --variant coverage
```

Before `make`, runs every executable `$WORKSPACE_DIR/*/apply_cp_patches.sh`
(sorted). Missing extensions are skipped. Unix-only scripts exit 0 on non-unix
ports.

Each apply script also works **standalone** (clone `circuitpython` + that one
repo as siblings; set `CP_DIR` if needed) with plain `make` afterward — no cmods
required.

Uses `$WORKSPACE_DIR/.venv` for CircuitPython build tooling (created
automatically). Freeze aggregator: `manifest-circuitpython.py` (all ports).

Espressif / Qualia + LVGL build-and-flash lessons (partitions, TinyUF2, WSL COM
ports):
[`lvgl-circuitpython/docs/BUILD_AND_FLASH.md`](lvgl-circuitpython/docs/BUILD_AND_FLASH.md).

Output: `circuitpython/ports/unix/build-coverage/micropython`

### CircuitPython smoke test

```bash
./circuitpython/ports/unix/build-coverage/micropython \
  ./lvgl-bindings/tools/test_lvgl_smoke.py
```

---

## CPython (`lvgl-python`)

Prefer **TestPyPI** wheels (`pydevices-lvgl`) for day-to-day use. Local editable
builds are optional — see `lvgl-python/docs/BUILDING.md` (vendored
`generated/`; no workspace matrix scripts).

---

## lvgl-bindings (generator)

After changing `binding/`, `lv_conf.h`, or the `lvgl` submodule:

```bash
cd lvgl-bindings
./regenerate_all.sh              # all three targets + commit + tag (see lvgl-bindings/docs/PUBLISHING.md)
# or individually:
./regenerate_lvmp.sh             # → generated/lvgl_micropython.c
./regenerate_lvcp.sh             # → generated/lvgl_circuitpython.c
./regenerate_lvpy.sh             # → generated/lvgl_python.c
./scripts/verify_bindings.sh     # regen + regression checks
```

Sync into consumer repos as needed
(`lvgl-python/scripts/sync_from_lvgl_bindings.sh`, or copy `generated/` +
`lvgl` pin for MP/CP). Then rebuild with `./build_runtimes.sh` / `./build_mp.sh`
/ `./build_cp.sh` as appropriate.

---

## Gotchas

- **`build_mp.sh` flags** are `--port` / `--variant`, not positional args.
- **Windows MP**: `os.dupterm` disabled by default; use `--os-dupterm` only if
  you intend to fix/port dupterm support.
- **CP test path** lives in `lvgl-circuitpython/`, not `lvgl-micropython/`.
- **CPython**: use TestPyPI or `lvgl-python` docs — not a cmods matrix target.
- **Editable CPython install** does not recompile on import; rerun
  `pip install -e .` after C changes.
- **Upstream clones** (`micropython/`, `circuitpython/`): do not commit unless
  the user explicitly overrides workspace rules.
