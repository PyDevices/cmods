#!/usr/bin/env bash
# Build CircuitPython unix port (coverage variant). NOT the P4 LVGL target.
#
# First LVGL on CircuitPython: espressif + espressif_esp32p4_function_ev via
# build_circuitpython.sh (after apply_cp_lvgl_patches.sh --apply).
#
# LVGL on CP unix is experimental only (CMODS_CP_UNIX=1); the unix port does not
# include circuitpython.mk until wired separately.
set -e

WORK_DIR=$(pwd)
CP_DIR="${CP_DIR:-$WORK_DIR/circuitpython}"
PORT_DIR=$CP_DIR/ports/unix
# CP unix defaults to coverage; standard breaks because objringio.c uses the
# old MicroPython ringbuf API while CircuitPython's ringbuf was reworked.
VARIANT="${VARIANT:-coverage}"
# LVGL user modules use circuitpython.mk (board ports), not micropython.mk.
# Set CMODS_CP_UNIX=1 once the unix port includes circuitpython.mk.
BUILD_DIR=$PORT_DIR/build-$VARIANT
COPY_TO=~/bin/circuitpython

if [ ! -d "$PORT_DIR" ]; then
    echo "CircuitPython unix port not found at $PORT_DIR"
    echo "Clone CircuitPython first or set CP_DIR to your tree."
    exit 1
fi

pushd $PORT_DIR
make -j clean VARIANT=$VARIANT
make -j submodules VARIANT=$VARIANT
if [ "${CMODS_CP_UNIX:-0}" = 1 ]; then
    make -j VARIANT=$VARIANT CMODS_DIR=$WORK_DIR CMODS_LVGL_ALLOW_MISSING_BINDINGS="${CMODS_LVGL_ALLOW_MISSING_BINDINGS:-1}"
else
    make -j VARIANT=$VARIANT
fi
popd

echo
echo "The executable is:  $BUILD_DIR/micropython"
echo

echo "Do you want to copy the executable to $COPY_TO?"
read -p "[y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    mkdir -p ~/bin
    cp $BUILD_DIR/micropython $COPY_TO
    echo "Executable copied to $COPY_TO"
fi
echo
