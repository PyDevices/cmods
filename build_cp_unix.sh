#!/usr/bin/env bash
# Build CircuitPython unix port (coverage variant by default).
#
# Works on a clean release tree or after apply_cp_lvgl_patches.sh --apply.
# Does not patch the CP tree or regenerate bindings.
set -e

WORK_DIR=$(pwd)
CP_DIR="${CP_DIR:-$WORK_DIR/circuitpython}"
PORT_DIR="$CP_DIR/ports/unix"
VARIANT="${VARIANT:-coverage}"
BUILD_DIR="$PORT_DIR/build-$VARIANT"
COPY_TO=~/bin/circuitpython
PATCH_MARKER='# >>> cmods-lvgl begin (apply_cp_lvgl_patches.sh)'

if [ ! -d "$CP_DIR/.git" ]; then
    echo "CircuitPython not found at $CP_DIR"
    echo "See README.md first-time setup (clone, checkout 10.2.1, fetch submodules)."
    exit 1
fi

if [ ! -f "$PORT_DIR/Makefile" ]; then
    echo "Unix port not found: $PORT_DIR/Makefile"
    exit 1
fi

PATCHED=0
if grep -qF "$PATCH_MARKER" "$PORT_DIR/Makefile"; then
    PATCHED=1
fi

echo "CircuitPython: $CP_DIR"
echo "cmods:         $WORK_DIR"
echo "variant:       $VARIANT"
echo "LVGL patches:  $([ "$PATCHED" = 1 ] && echo present || echo not applied)"
echo

pushd "$PORT_DIR"
make -j clean VARIANT="$VARIANT"
make -j submodules VARIANT="$VARIANT"
make -j VARIANT="$VARIANT"
popd

echo
echo "The executable is:  $BUILD_DIR/micropython"
echo

echo "Do you want to copy the executable to $COPY_TO?"
read -p "[y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    mkdir -p ~/bin
    cp "$BUILD_DIR/micropython" "$COPY_TO"
    echo "Executable copied to $COPY_TO"
fi
echo
