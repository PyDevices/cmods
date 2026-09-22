# Partition tables for the esp32 port

One `<BOARD>[_<VARIANT>].csv` per board we build, and an optional
`<same>.sdkconfig` beside it for the settings that have to travel with the
table (flash size, coredump, anything else the board needs).
`build_mp.sh` picks the pair up by name and builds the image against it.

**These files are a board's data format, not a build artifact.** The app
partition's size decides where the filesystem starts, so changing it moves
the filesystem of every board already carrying an image built from this
table — and nothing at boot says so. A board whose flash holds a filesystem
at the old offset either comes up on a freshly formatted empty one, or hangs
in `inisetup.fs_corrupted()` before USB starts and reads as a dead board.
Both happened on 2026-09-21, which is [cmods#30](https://github.com/PyDevices/cmods/issues/30).

So: **no build writes these files.** If an image does not fit, the build
refuses, names the size that would fit, and leaves a table that fits in the
build directory for you to look at. Growing the partition is then a decision
you make and record here, followed by reflashing every board that carries
the old layout.

`MP_AUTOSIZE=1` gets you a one-off image built against the enlarged table,
kept inside the build directory. It prints what it did, twice, and it still
does not touch anything here. Use it to see whether something fits; do not
flash the result onto a board whose filesystem you want to keep.

## Growing one on purpose

1. Build, read the refusal, look at the suggested table it names.
2. Edit the `.csv` here, and write above the table why it moved and when.
3. Rebuild, and check the "esp32 partition layout in this image" the build
   prints against what you meant.
4. Reflash the boards. A board flashed with the old layout keeps its old
   filesystem offset until you erase it.

## How the table reaches the build

Through a generated board overlay in `.board-overlays/`, passed as
`BOARD_DIR=`, whose `mpconfigvariant` appends an sdkconfig fragment **last**
to `SDKCONFIG_DEFAULTS`. Not by patching the saved `sdkconfig`, which is
what it used to do: `idf.py` regenerates that file from the defaults on
every reconfigure and the board's own table wins
([cmods#29](https://github.com/PyDevices/cmods/issues/29)). Hand-written
board overlays live in [`../esp32_boards/`](../esp32_boards/README.md) and
compose with this one — the generated overlay includes yours.
