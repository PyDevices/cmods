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
| `0012-micropython-esp32-usbif-p4-board-…` | `esp32` | usbif: `ESP32_GENERIC_P4` board header opts into the extension hook and enables `MICROPY_HW_USB_MSC` (inert without the module) |
| `0013-micropython-esp32-usbif-otg-phy-…` | `esp32` | usbif: OTG PHY release/restore helpers in `usb.c` so a module can borrow the controller for host mode (mirror of usbif `patches/0004`) |
| `0014-micropython-esp32-usbif-s3-board-…` | `esp32` | usbif: `ESP32_GENERIC_S3` board header opts into the extension hook and enables `MICROPY_HW_USB_MSC` (inert without the module) |

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
- `0009…0011`, `0013` (usbif series) → `PyDevices/usbif` (`patches/0001…0004`,
  with provenance; `apply_patches.sh` there applies them standalone).
- `0012` and `0014` are cmods-local board integration (the P4 and S3 board
  headers, respectively) and have no upstream home; they are authored here.
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

## Two patch series, two owners

`patches/[0-9][0-9][0-9][0-9]-*.patch` is a **mirror**. `scripts/sync_from_overlay.sh`
owns that entire glob: it deletes every file matching it and re-copies from
`micropython-pydevices` at the pinned commit. Edit those in the source repo,
never here.

`patches/usbif-NN-*.patch` is **local to cmods**. These are the usbif module's
integration patches (the TinyUSB config-extension hook, the descriptor hooks,
the esp32 OTG PHY handoff, and the P4/S3 board headers), authored in
`usbif/patches/` and mirrored here by hand.

They are deliberately outside the numbered series. The two globs are
independent -- the sync script claims a four-digit prefix, while `build_mp.sh`
matches `*micropython-<port>*` anywhere in the name -- so the usbif series is
invisible to the mirror and still picked up by the build, applying after the
numbered series because digits sort before letters.

This is not cosmetic. These six lived inside the mirrored glob until
2026-09-01, which kept `mirror-drift` red and, worse, meant the resync the
failure message recommends would have deleted them. Losing them does not
break the build: it produces firmware whose USB functions are silently
absent. Keep new usbif patches in the `usbif-` series.
