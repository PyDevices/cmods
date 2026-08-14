# MicroPython patches

Mailbox patches for a stock
[micropython/micropython](https://github.com/micropython/micropython) tree
(`git am`).

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

## Apply

From a clean `v1.28.0` checkout (or let `build_mp.sh` apply them):

```bash
git checkout v1.28.0
git am 0001-micropython-windows-*.patch   # --port windows
git am 0002-micropython-unix-*.patch     # --port unix
```

## Regenerate

On a tree with these commits atop the base tag:

```bash
git format-patch -N -o .
# rename so each filename contains micropython-<port>
```
