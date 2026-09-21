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

**Base (current patches):** tag `v1.29.0` (`0fd6c573e`).

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
| `0009-micropython-esp32s3-add-SPIRAM_OCT_DEBUG-variant.patch` | `esp32` | An `ESP32_GENERIC_S3` debug variant: USB device stack off so Serial-JTAG keeps the PHY, flash coredump on |
| `0010-micropython-esp32-i2s-mck-pin.patch` | `esp32` | Define `MICROPY_PY_MACHINE_I2S_MCK` and wire `mck=` into `gpio_cfg.mclk`, so a codec's MCLK comes off the same PLL as BCLK and LRCK. extmod already carries the keyword; the port hardcoded `I2S_GPIO_UNUSED`. Inert without `mck=` |

## Apply

From a clean `v1.29.0` checkout (or let `build_mp.sh` apply them):

```bash
git checkout v1.29.0
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
- `adafruit_mp3/` → `PyDevices/audiodsp` (`patches/adafruit_mp3/`,
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

`patches/cameraif-NN-*.patch` follows the same rule and for the same reason:
outside the numbered series so the mirror cannot claim or delete it, still
matched by `build_mp.sh` because the name contains `micropython-esp32`.

| Patch | Port | Purpose |
|-------|------|---------|
| `cameraif-01-…camera-sensor-component` | `esp32` | Add `espressif/esp_cam_sensor` to `idf_component.yml` for P4 targets. ESP-IDF ships the CSI controller but no sensor drivers |
| `usbif-01-…tinyusb-builtin-interface-hook` | `esp32` | `shared/tinyusb`: let a user C module contribute and vary the built-in USB interfaces |
| `usbif-02-…boards-enable-tusb-ext` | `esp32` | The P4 and S3 board headers opt into the usbif hook (inert without the module) |
| `usbif-03-…otg-phy-handoff` | `esp32` | Let a user C module borrow the OTG controller for host mode, and hand the PHY back |

**Verified on the shared bus when `cameraif-02` carried that change** — it
altered `machine.I2C` for every device on the P4 panel's GPIO7/8, not just
the camera. The patch itself is gone: v1.29.0 put the esp32 port on
`i2c_master` upstream, so it was dropped in the rebase (`911d073`). The
evidence stays because the bus behaviour it describes is the board's, not
the patch's: bus scan answers 0x18 / 0x36 / 0x40 / 0x5d; the GT911 reads 10/10
with a camera open (0/10 before the fix); the ES7210 captures real non-zero
audio; and the ES8311 played 440/660/880 Hz tones that Brad confirmed
hearing.

Ear-verified rather than inferred, and there is no way around that on this
board. `playing == True` is a flag set before a sample reaches the codec and
reads true with the speaker unplugged. The obvious alternative -- play a tone
and record it on the ES7210 -- cannot work either: both directions construct
`I2S(0)`, one as TX and one as RX, and one peripheral id cannot be both
(pydevices#23), so a capture taken during playback is not evidence of
anything. An earlier version of this note claimed the loopback proved the
mic cannot hear the speaker. It proved no such thing; that experiment had no
working capture path to begin with, and which of the two reasons applied was
never established here.
