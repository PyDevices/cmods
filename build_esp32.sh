#!/usr/bin/env bash

set -e

BOARD=ESP32_GENERIC_S3
VARIANT=SPIRAM_OCT

WORK_DIR=$(pwd)
PORT_DIR=$WORK_DIR/micropython/ports/esp32
MODULES=$WORK_DIR/micropython.cmake
MANIFEST=$WORK_DIR/manifest.py
BUILD_DIR=$PORT_DIR/build
if [ -n "$BOARD" ]; then
    BUILD_DIR=$BUILD_DIR-$BOARD
fi
if [ -n "$VARIANT" ]; then
    BUILD_DIR=$BUILD_DIR-$VARIANT
fi

IDF_DIR=$WORK_DIR/esp-idf
. $IDF_DIR/export.sh

pushd $PORT_DIR
make -j BOARD=$BOARD BOARD_VARIANT=$VARIANT clean
make -j BOARD=$BOARD BOARD_VARIANT=$VARIANT submodules
make -j BOARD=$BOARD BOARD_VARIANT=$VARIANT all USER_C_MODULES=$MODULES FROZEN_MANIFEST=$MANIFEST
popd

echo
echo "Flash command:"
echo "    esptool -b 460800 --before default_reset --after hard_reset write_flash 0x0 $BUILD_DIR/firmware.bin"
echo
echo "To flash your device now, put it in bootloader mode and press Y."
read -p "[y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    esptool -b 460800 --before default_reset --after hard_reset write_flash 0x0 $BUILD_DIR/firmware.bin
fi
echo
