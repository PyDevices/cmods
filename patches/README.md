# MicroPython patches

Mailbox patches for a stock
[micropython/micropython](https://github.com/micropython/micropython) tree.
`build_mp.sh` applies them as temporary overlays and reverses them on every
exit. It never commits inside the upstream checkout.

## Naming convention

`build_mp.sh` applies every file under this directory whose name contains
`micropython-<port>` for the selected `--port` (sorted). Examples:

- `0001-micropython-windows-….patch` → applied when `--port windows`
- `0002-micropython-unix-….patch` → applied when `--port unix`

No matching files → nothing to apply (this directory is optional for other
ports). Add future patches by following the same `micropython-<port>` token in
the filename.

**Base (current patches):** tag `v1.28.0` (`e0e9fbb17`).

| Patch | Port | Purpose |
|-------|------|---------|
| `0001-micropython-windows-…` | `windows` | Windows-local `modsocket.c` (Winsock), `select`/asyncio wakeups, mingw/msvc mbedtls SSL, MSVC project glue, and related `tests/**` updates |
| `0002-micropython-unix-…MICROPY_SCHEDULER_DEPTH…` | `unix` | Raise unix `MICROPY_SCHEDULER_DEPTH` for desktop SDL / host display timers |
| `0003-micropython-windows-enable-ffi-modffi-libffi.patch` | `windows` | Enable FFI (modffi, libffi) on Windows (MinGW) for uwin32 / Win32 bindings |
| `0004-micropython-webassembly-…Asyncify…` | `webassembly` | Await Asyncify-backed execution in the module API |
| `0005-micropython-webassembly-…ccall…` | `webassembly` | Correct Node hook ccall signatures |
| `0006-micropython-webassembly-…soft…` | `webassembly` | Expose repeatable VM soft reinitialization |

## Apply

From a clean `v1.28.0` checkout (or let `build_mp.sh` apply them):

```bash
git checkout v1.28.0
git apply /path/to/cmods/patches/0001-micropython-windows-*.patch
# Build, then return the checkout to clean state:
git apply --reverse /path/to/cmods/patches/0001-micropython-windows-*.patch
```

## Regenerate

On a tree with these commits atop the base tag:

```bash
git format-patch -N -o .
# rename so each filename contains micropython-<port>
```


## Ownership moved (2026-08-29, modernization Phase 2)

The authoritative copies of everything here now live in public repos;
this directory is a consumer-side mirror for cmods builds. **Edit there,
sync here — never the reverse** (single-writer, same rule as lvgl):

- `0001…0008` (MicroPython series) → `PyDevices/micropython-pydevices`
  (`patches/`, with profiles and provenance).
- `adafruit_mp3/` → `PyDevices/audioif` (`patches/adafruit_mp3/`,
  applied by its `scripts/fetch_deps.sh`).
