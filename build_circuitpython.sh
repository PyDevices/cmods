#!/usr/bin/env bash
# Build CircuitPython with LVGL bindings (requires wired board + CP tree).
set -e

WORK_DIR=$(pwd)
CP_DIR="${CP_DIR:-$WORK_DIR/circuitpython}"
CMODS_DIR="${CMODS_DIR:-$WORK_DIR}"
LVMP_DIR="$CMODS_DIR/lv_micropython_cmod"
BOARD="${BOARD:-espressif_esp32p4_function_ev}"

if [ ! -d "$CP_DIR/.git" ]; then
    echo "CircuitPython not found at $CP_DIR"
    echo
    echo "Clone it first (do not use --recursive; submodules are fetched via make):"
    echo "    git clone https://github.com/adafruit/circuitpython.git $CP_DIR"
    echo "    cd $CP_DIR"
    echo "    cd ports/espressif && make fetch-port-submodules"
    echo
    echo "Or fetch all submodules from the repo root:"
    echo "    cd $CP_DIR && make fetch-all-submodules"
    echo
    echo "If submodules are broken, reset and refetch:"
    echo "    cd $CP_DIR && make remove-all-submodules && make fetch-all-submodules"
    echo
    echo "Or set CP_DIR to an existing clone."
    exit 1
fi

echo "CircuitPython: $CP_DIR"
echo "cmods:         $CMODS_DIR"
echo

# --- Step 1: regenerate bindings / metadata ---
if [ -x "$LVMP_DIR/regenerate_lvcp.sh" ]; then
    echo "==> Regenerating LVCP bindings/metadata..."
    "$LVMP_DIR/regenerate_lvcp.sh"
    echo
fi

# --- Step 2: board selection (BOARD defaults to ESP32-P4 Function EV) ---
if [ -z "$BOARD" ]; then
    echo "Set BOARD to a CircuitPython board id (e.g. espressif_esp32p4_function_ev)."
    exit 1
fi

if [ ! -f "$LVMP_DIR/generated/lvcp.c" ]; then
    echo "Missing $LVMP_DIR/generated/lvcp.c — run regenerate_lvcp.sh first."
    exit 1
fi

PORT_DIR="${PORT_DIR:-$CP_DIR/ports/espressif}"
PATCH_MARKER='# >>> cmods-lvgl begin (apply_cp_lvgl_patches.sh)'

if [ "${CMODS_SKIP_CP_PATCH:-0}" != 1 ] && [ -x "$LVMP_DIR/apply_cp_lvgl_patches.sh" ]; then
    if [ -f "$PORT_DIR/Makefile" ] && grep -qF "$PATCH_MARKER" "$PORT_DIR/Makefile"; then
        echo "==> CP LVGL patches already applied"
    else
        echo "==> Applying CP LVGL patches..."
        "$LVMP_DIR/apply_cp_lvgl_patches.sh" --apply
    fi
    echo
elif [ ! -f "$PORT_DIR/Makefile" ] || ! grep -qF "$PATCH_MARKER" "$PORT_DIR/Makefile"; then
    echo "CP tree is not patched for LVGL. Run:"
    echo "    $LVMP_DIR/apply_cp_lvgl_patches.sh --apply"
    echo "Or set CMODS_SKIP_CP_PATCH=1 to skip (build will fail until wired)."
    exit 1
fi

echo "Checklist:   $LVMP_DIR/circuitpython_board.snippet.mk"
echo "Emitter phases: $LVMP_DIR/binding/circuitpython_emit_plan.md"
echo

# --- Step 3: build ---
if [ ! -f "$PORT_DIR/Makefile" ]; then
    echo "Port Makefile not found: $PORT_DIR/Makefile"
    echo "Set PORT_DIR to the correct CircuitPython port directory."
    exit 1
fi

echo "==> Building BOARD=$BOARD (PORT_DIR=$PORT_DIR)"
make -C "$PORT_DIR" BOARD="$BOARD" CMODS_DIR="$CMODS_DIR" \
    CMODS_LVGL_ALLOW_MISSING_BINDINGS="${CMODS_LVGL_ALLOW_MISSING_BINDINGS:-1}"
