# Board overlays for the esp32 port

A board here is a small directory that **includes** one of MicroPython's own
boards and changes one thing. Nothing under `micropython/` is edited, so the
shared checkout stays pristine and the overlay survives a bump of the pin.

Build one by naming the stock board and pointing `BOARD_DIR` at the overlay:

```bash
cd cmods
MP_MAKE_EXTRA="BOARD_DIR=$PWD/esp32_boards/LILYGO_T_EMBED_S3" \
  ./build_mp.sh --port esp32 --board ESP32_GENERIC_S3 --variant SPIRAM_OCT
```

**The build directory is still the stock board's**, because the board *name*
is what names it. Two agents building `ESP32_GENERIC_S3` therefore share one
directory and one artifact, and an overlay build leaves an overlaid image
sitting in it. Copy your artifact out immediately and rebuild the plain image
after, or you hand somebody else a firmware they did not ask for.

`build_mp.sh` builds a second, throwaway overlay of its own on top of yours
(in `.board-overlays/`) to carry the partition table, so the two compose:
yours is included first, the table's fragment is appended after it. You do
not have to do anything for that — but it is why the rule below matters to
your file as much as to the generated one.

## The one rule that is not obvious

`list(APPEND SDKCONFIG_DEFAULTS ...)` has to come **after** the stock
variant's include. kconfgen takes the last assignment, so a fragment listed
first is silently overridden — and the build then succeeds with the feature
simply absent, which is the expensive kind of failure. The long version, and
the partition-table half of the same trap, is in
[cmods#29](https://github.com/PyDevices/cmods/issues/29).

## LILYGO_T_EMBED_S3

Flash auto-suspend, and nothing else. It cuts what a flash write costs the
audio pump on this board from 42–46 ms of stopped audio to 12.7–13.8 ms,
measured with a same-session control on 2026-09-21, for 176 bytes of app.

**It cannot go on `ESP32_GENERIC_S3`.** The switch is only correct for flash
parts the IDF grants `SPI_FLASH_CHIP_CAP_SUSPEND`, and a generic image ships
on whatever part the vendor bought. The T-Embed's GigaDevice GD25Q128 is one
of the three families the IDF documents as supported; a board whose part is
not gets the feature quietly withheld by the driver, which is safe but is not
what the fragment says it is doing. The ESP32-P4 cannot have it at all — the
IDF's list is S3, C2, C3, C6 and H2.

Why it works: the cache stays on for both cores during an erase and the
hardware arbitrates SPI0 against SPI1, which is what this board needs,
because the PSRAM the audio graph lives in is behind that same cache. The
IDF's own warning is worth carrying: the feature "relies heavily on strict
timing", and an ISR firing more often than the ~40 µs resume window can stop
an erase from ever finishing. Our I2S interrupt fires every 2.7 ms at a
4 × 128 ring, which is sixty times that.

Background: [cmods#32](https://github.com/PyDevices/cmods/issues/32).
