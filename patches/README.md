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
| `0007-micropython-webassembly-…jsffi…` | `webassembly` | Make jsffi callbacks inert across VM reinitialization (stale interpreter generation no longer resolves to an arbitrary recycled proxy) |
| `0008-micropython-webassembly-…lexer-eof…` | `webassembly` | Fix `single_input` on empty input: prime the lexer so EOF and the dummy `chr0/1/2` sentinel are distinguishable again, restoring the empty-line REPL Enter behavior |
| `0009-micropython-esp32-usbif-…tusb-config…` | `esp32` | usbif: `tusb_config.h` extension hook (`MICROPY_HW_USB_EXT_TUSB_CONFIG`) |
| `0010-micropython-esp32-usbif-…config-descriptor…` | `esp32` | usbif: append module descriptors to the built-in configuration descriptor |
| `0011-micropython-esp32-usbif-…runtime-selectable…` | `esp32` | usbif: weak hooks so the advertised built-in descriptor can vary at runtime (opt-in audio) |
| `0012-micropython-esp32-usbif-p4-board-…` | `esp32` | usbif: `ESP32_GENERIC_P4` board header opts into the extension hook (inert without the module) |

## Apply

From a clean `v1.28.0` checkout (or let `build_mp.sh` apply them):

```bash
git checkout v1.28.0
git apply /path/to/cmods/patches/0001-micropython-windows-*.patch
# Build, then return the checkout to clean state:
git apply --reverse /path/to/cmods/patches/0001-micropython-windows-*.patch
```

## Ownership moved (2026-08-29, modernization Phase 2)

The authoritative copies of everything here now live in public repos;
this directory is a consumer-side mirror for cmods builds. **Edit there,
sync here — never the reverse** (single-writer, same rule as lvgl):

- `0001…0008` (MicroPython series) → `PyDevices/micropython-pydevices`
  (`patches/`, with profiles and provenance).
- `0009…0011` (usbif series) → `PyDevices/usbif` (`patches/0001…0003`,
  with provenance; `apply_patches.sh` there applies them standalone).
- `0012` is cmods-local board integration (one `#define` in the P4 board
  header) and has no upstream home; it is authored here.
- `adafruit_mp3/` → `PyDevices/audioif` (`patches/adafruit_mp3/`,
  applied by its `scripts/fetch_deps.sh`).

## Regenerate

Regeneration happens **in the overlay repo, never here**. In a
`PyDevices/micropython-pydevices` checkout, on a tree with the new commits
atop the pinned upstream (`UPSTREAM`):

```bash
git format-patch -N -o patches/
# rename so each filename contains micropython-<port>
```

Then pull the change into cmods with `../scripts/sync_from_overlay.sh`
(pin the new commit in `MICROPYTHON_PYDEVICES_COMMIT`) — do not
`format-patch` or hand-edit patches directly in this directory.

## Why built interpreters report `-dirty`

The mailbox patches above are applied to the upstream checkout as
temporary overlays for the duration of the build and reversed on exit
(see build_mp.sh), so the tree is legitimately modified at compile time
and MicroPython embeds `-dirty` in its version string. It does not mean
the build came from uncommitted work: with the overlays reversed, a
clean checkout plus the pinned patch series reproduces the same build.
