#!/usr/bin/env bash
# Build and smoke-test one LVGL consumer target.
#
# Usage:
#   ./build_target.sh TARGET
#
# Targets:
#   mp-unix      MicroPython unix / standard
#   mp-windows   MicroPython windows / standard
#   cp-unix      CircuitPython unix / coverage
#   cpy-unix     CPython WSL (.venv)
#   cpy-windows  CPython Windows (pip.exe / python.exe)
#
# Environment:
#   CMODS              Workspace root (default: directory containing this script)
#   LV_BINDINGS_DIR    lv_bindings path (default: $CMODS/lv_bindings)
#   SYNC_LVPY          1 to copy lvpy.c/lv_conf.h from lv_bindings before CPython build (default: 1)
#
# CPython targets acquire a flock on lv_cpython_mod/.build.lock so cpy-unix and cpy-windows
# never run concurrently (shared editable-install tree).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMODS="${CMODS:-$SCRIPT_DIR}"
LV_BINDINGS_DIR="${LV_BINDINGS_DIR:-$CMODS/lv_bindings}"
SYNC_LVPY="${SYNC_LVPY:-1}"

SMOKE_TEST="$LV_BINDINGS_DIR/test_lvgl_smoke.py"
MP_UNIX="$CMODS/micropython/ports/unix/build-standard/micropython"
MP_WIN="$CMODS/micropython/ports/windows/build-standard/micropython.exe"
CP_UNIX="$CMODS/circuitpython/ports/unix/build-coverage/micropython"
CPY_MOD="$CMODS/lv_cpython_mod"
CPY_LOCK="$CPY_MOD/.build.lock"

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

TARGET="${1:-}"
[[ -n "$TARGET" ]] || usage 1
case "$TARGET" in
    -h|--help) usage 0 ;;
    mp-unix|mp-windows|cp-unix|cpy-unix|cpy-windows) ;;
    *)
        echo "Unknown target: $TARGET" >&2
        usage 1
        ;;
esac

[[ -f "$SMOKE_TEST" ]] || {
    echo "Missing smoke test: $SMOKE_TEST" >&2
    exit 1
}

sync_lvpy_from_bindings() {
    [[ "$SYNC_LVPY" == "1" ]] || return 0
    local src_c="$LV_BINDINGS_DIR/generated/lvpy.c"
    local src_h="$LV_BINDINGS_DIR/lv_conf.h"
    local dst_c="$CPY_MOD/generated/lvpy.c"
    [[ -f "$src_c" ]] || {
        echo "Missing $src_c — regenerate lv_bindings or set SYNC_LVPY=0" >&2
        return 1
    }
    mkdir -p "$CPY_MOD/generated"
    cp "$src_c" "$dst_c"
    [[ -f "$src_h" ]] && cp "$src_h" "$CPY_MOD/lv_conf.h"
    echo "Synced lvpy.c (and lv_conf.h if present) from $LV_BINDINGS_DIR"
}

with_cpy_lock() {
    mkdir -p "$CPY_MOD"
    exec 200>"$CPY_LOCK"
    if ! flock -n 200; then
        echo "Another CPython build holds $CPY_LOCK (cpy-unix and cpy-windows must not run concurrently)" >&2
        exit 1
    fi
    "$@"
}

build_mp_unix() {
    cd "$CMODS"
    ./build_mp.sh --port unix --variant standard
    "$MP_UNIX" "$SMOKE_TEST"
}

build_mp_windows() {
    cd "$CMODS"
    ./build_mp.sh --port windows --variant standard --no-os-dupterm
    "$MP_WIN" "$SMOKE_TEST"
}

build_cp_unix() {
    cd "$CMODS/lv_circuitpython_mod"
    ./build_cp.sh --port unix --variant coverage
    "$CP_UNIX" "$SMOKE_TEST"
}

build_cpy_unix_body() {
    sync_lvpy_from_bindings
    cd "$CPY_MOD"
    { test -d .venv || python3 -m venv .venv; }
    .venv/bin/pip install -q -r requirements.txt
    .venv/bin/pip install -q -e .
    PYTHONPATH="$CPY_MOD" .venv/bin/python "$SMOKE_TEST"
}

run_cpy_windows_smoke() {
    # WSL often reports exit 5 from python.exe after successful LVGL teardown (sys.exit(0)).
    local tmp
    tmp=$(mktemp)
    set +e
    PYTHONPATH="$(wslpath -w "$CPY_MOD")" python.exe "$SMOKE_TEST" 2>&1 | tee "$tmp"
    local ec=${PIPESTATUS[0]}
    set -e
    if grep -q '^FAIL:' "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if grep -q 'All LVGL smoke tests passed' "$tmp"; then
        rm -f "$tmp"
        if [[ $ec -ne 0 && $ec -ne 5 ]]; then
            echo "Smoke tests passed but python.exe exited $ec" >&2
            return "$ec"
        fi
        return 0
    fi
    rm -f "$tmp"
    return "${ec:-1}"
}

build_cpy_windows_body() {
    sync_lvpy_from_bindings
    cd "$CPY_MOD"
    pip.exe install -q -e "$(wslpath -w "$CPY_MOD")"
    run_cpy_windows_smoke
}

build_cpy_unix() {
    with_cpy_lock build_cpy_unix_body
}

build_cpy_windows() {
    with_cpy_lock build_cpy_windows_body
}

echo "==> build_target: $TARGET"
case "$TARGET" in
    mp-unix)     build_mp_unix ;;
    mp-windows)  build_mp_windows ;;
    cp-unix)     build_cp_unix ;;
    cpy-unix)    build_cpy_unix ;;
    cpy-windows) build_cpy_windows ;;
esac
echo "==> build_target: $TARGET OK"
