#!/usr/bin/env bash
# Build and smoke-test one LVGL consumer target.
#
# Usage:
#   ./build_target.sh [--smoke-only] TARGET
#
# Targets:
#   mp-unix      MicroPython unix / standard
#   mp-windows   MicroPython windows / dev
#   cp-unix      CircuitPython unix / coverage
#   cpy-unix     CPython WSL (.venv)
#   cpy-windows  CPython Windows (pip.exe / python.exe)
#
# Environment:
#   CMODS              Workspace root (default: directory containing this script)
#   LV_BINDINGS_DIR    lv_bindings path (default: $CMODS/lv_bindings)
#   SYNC_LVPY          1 to copy lvgl_python.c/lv_conf.h from lv_bindings before CPython build (default: 1)
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
MP_WIN="$CMODS/micropython/ports/windows/build-dev/micropython.exe"
CP_UNIX="$CMODS/circuitpython/ports/unix/build-coverage/micropython"
CPY_MOD="$CMODS/lv_cpython_mod"
CPY_LOCK="$CPY_MOD/.build.lock"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

SMOKE_ONLY=0
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke-only) SMOKE_ONLY=1; shift ;;
        -h|--help) usage 0 ;;
        mp-unix|mp-windows|cp-unix|cpy-unix|cpy-windows)
            if [[ -n "$TARGET" ]]; then
                echo "Unexpected extra argument: $1" >&2
                usage 1
            fi
            TARGET="$1"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage 1
            ;;
    esac
done
[[ -n "$TARGET" ]] || usage 1

[[ -f "$SMOKE_TEST" ]] || {
    echo "Missing smoke test: $SMOKE_TEST" >&2
    exit 1
}

sync_lvpy_from_bindings() {
    [[ "$SYNC_LVPY" == "1" ]] || return 0
    local src_c="$LV_BINDINGS_DIR/generated/lvgl_python.c"
    local src_h="$LV_BINDINGS_DIR/lv_conf.h"
    local dst_c="$CPY_MOD/generated/lvgl_python.c"
    [[ -f "$src_c" ]] || {
        echo "Missing $src_c — regenerate lv_bindings or set SYNC_LVPY=0" >&2
        return 1
    }
    mkdir -p "$CPY_MOD/generated"
    cp "$src_c" "$dst_c"
    [[ -f "$src_h" ]] && cp "$src_h" "$CPY_MOD/lv_conf.h"
    echo "Synced lvgl_python.c (and lv_conf.h if present) from $LV_BINDINGS_DIR"
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

require_executable() {
    local path=$1
    local label=$2
    [[ -x "$path" ]] || {
        echo "Missing $label (build first or drop --smoke-only): $path" >&2
        return 1
    }
}

smoke_mp_unix() {
    require_executable "$MP_UNIX" "MicroPython unix binary"
    "$MP_UNIX" "$SMOKE_TEST"
}

smoke_mp_windows() {
    require_executable "$MP_WIN" "MicroPython windows binary"
    "$MP_WIN" "$SMOKE_TEST"
}

smoke_cp_unix() {
    require_executable "$CP_UNIX" "CircuitPython unix binary"
    "$CP_UNIX" "$SMOKE_TEST"
}

smoke_cpy_unix() {
    cd "$CPY_MOD"
    [[ -x .venv/bin/python ]] || {
        echo "Missing CPython venv (build cpy-unix first or drop --smoke-only): $CPY_MOD/.venv/bin/python" >&2
        return 1
    }
    PYTHONPATH="$CPY_MOD" .venv/bin/python "$SMOKE_TEST"
}

build_mp_unix() {
    cd "$CMODS"
    ./build_mp.sh --port unix --variant standard
    smoke_mp_unix
}

build_mp_windows() {
    cd "$CMODS"
    ./build_mp.sh --port windows --variant dev
    smoke_mp_windows
}

build_cp_unix() {
    cd "$CMODS/lv_circuitpython_mod"
    ./build_cp.sh --port unix --variant coverage
    smoke_cp_unix
}

build_cpy_unix_body() {
    sync_lvpy_from_bindings
    cd "$CPY_MOD"
    { test -d .venv || python3 -m venv .venv; }
    .venv/bin/pip install -q -r requirements.txt
    .venv/bin/pip install -q -e .
    smoke_cpy_unix
}

run_cpy_windows_smoke() {
    PYTHONPATH="$(wslpath -w "$CPY_MOD")" python.exe "$SMOKE_TEST"
}

smoke_cpy_windows() {
    run_cpy_windows_smoke
}

build_cpy_windows_body() {
    sync_lvpy_from_bindings
    cd "$CPY_MOD"
    pip.exe install -q -e "$(wslpath -w "$CPY_MOD")"
    smoke_cpy_windows
}

build_cpy_unix() {
    with_cpy_lock build_cpy_unix_body
}

build_cpy_windows() {
    with_cpy_lock build_cpy_windows_body
}

if [[ "$SMOKE_ONLY" == "1" ]]; then
    echo "==> build_target: $TARGET (smoke only)"
else
    echo "==> build_target: $TARGET"
fi
case "$TARGET" in
    mp-unix)
        if [[ "$SMOKE_ONLY" == "1" ]]; then smoke_mp_unix; else build_mp_unix; fi
        ;;
    mp-windows)
        if [[ "$SMOKE_ONLY" == "1" ]]; then smoke_mp_windows; else build_mp_windows; fi
        ;;
    cp-unix)
        if [[ "$SMOKE_ONLY" == "1" ]]; then smoke_cp_unix; else build_cp_unix; fi
        ;;
    cpy-unix)
        if [[ "$SMOKE_ONLY" == "1" ]]; then smoke_cpy_unix; else build_cpy_unix; fi
        ;;
    cpy-windows)
        if [[ "$SMOKE_ONLY" == "1" ]]; then smoke_cpy_windows; else build_cpy_windows; fi
        ;;
esac
echo "==> build_target: $TARGET OK"
