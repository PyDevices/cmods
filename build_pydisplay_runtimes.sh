#!/usr/bin/env bash
# Build MicroPython/CircuitPython runtimes used by pydisplay and install them.
#
# Targets:
#   mp-unix     MicroPython unix / standard  → pydisplay/bin/micropython
#   mp-windows  MicroPython windows / dev    → pydisplay/bin/micropython.exe
#               and $MP_WINDOWS_INSTALL_DIR/micropython.exe (unless unset empty)
#   mp-wasm     MicroPython webassembly / pyscript
#               → pydisplay/web/pyscript/vendor/micropython/{micropython.mjs,micropython.wasm}
#   cp-unix     CircuitPython unix / coverage → pydisplay/bin/circuitpython
#               (renamed from upstream build output named micropython)
#
# Usage:
#   ./build_pydisplay_runtimes.sh
#   ./build_pydisplay_runtimes.sh --install-only
#   ./build_pydisplay_runtimes.sh --only mp-unix,mp-wasm
#
# Environment:
#   CMODS                   Workspace root (default: directory containing this script)
#   PYDISPLAY_DIR           pydisplay checkout (default: $CMODS/../pydisplay)
#   EMSDK_DIR               Emscripten SDK for mp-wasm (see build_mp.sh; default: $CMODS/../../other/emsdk)
#   MP_WINDOWS_INSTALL_DIR  Extra install dir for micropython.exe (WSL path to the
#                           Windows PATH entry). Default: /mnt/c/Users/bradb/.local/bin
#                           Set empty to skip the extra copy.
#
# Run this after changing any usermod compiled into these binaries (graphics,
# usdl2, lv_micropython_cmod, lv_circuitpython_mod / regenerated lv_bindings,
# displayif when present, frozen manifest trees, or port/build config that
# affects them). Distinct from build_all.sh (LVGL smoke matrix; no install).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMODS="${CMODS:-$SCRIPT_DIR}"
PYDISPLAY_DIR="${PYDISPLAY_DIR:-$CMODS/../pydisplay}"
BUILD_MP="$CMODS/build_mp.sh"
BUILD_CP="$CMODS/lv_circuitpython_mod/build_cp.sh"

MP_UNIX_SRC="$CMODS/micropython/ports/unix/build-standard/micropython"
MP_WIN_SRC="$CMODS/micropython/ports/windows/build-dev/micropython.exe"
MP_WASM_DIR="$CMODS/micropython/ports/webassembly/build-pyscript"
CP_UNIX_SRC="$CMODS/circuitpython/ports/unix/build-coverage/micropython"
# Windows PE on PATH for cmd/PowerShell (WSL mount of C:\Users\bradb\.local\bin).
MP_WINDOWS_INSTALL_DIR="${MP_WINDOWS_INSTALL_DIR-/mnt/c/Users/bradb/.local/bin}"

BIN_DIR=""
VENDOR_MP=""

ALL_TARGETS=(mp-unix mp-windows mp-wasm cp-unix)
INSTALL_ONLY=0
ONLY=()

usage() {
    sed -n '2,29p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

resolve_pydisplay() {
    if [[ ! -d "$PYDISPLAY_DIR" ]]; then
        echo "pydisplay not found: $PYDISPLAY_DIR" >&2
        echo "Set PYDISPLAY_DIR to the pydisplay checkout." >&2
        exit 1
    fi
    PYDISPLAY_DIR=$(cd "$PYDISPLAY_DIR" && pwd)
    BIN_DIR="$PYDISPLAY_DIR/bin"
    VENDOR_MP="$PYDISPLAY_DIR/web/pyscript/vendor/micropython"
}

parse_only() {
    local spec="$1"
    local IFS=,
    local -a parts
    read -r -a parts <<<"$spec"
    local t
    for t in "${parts[@]}"; do
        case "$t" in
            mp-unix|mp-windows|mp-wasm|cp-unix) ONLY+=("$t") ;;
            *)
                echo "Unknown --only target: $t" >&2
                usage 1
                ;;
        esac
    done
}

want() {
    local t="$1"
    [[ ${#ONLY[@]} -eq 0 ]] && return 0
    local x
    for x in "${ONLY[@]}"; do
        [[ "$x" == "$t" ]] && return 0
    done
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-only) INSTALL_ONLY=1; shift ;;
        --only)
            [[ $# -ge 2 ]] || { echo "--only needs a value" >&2; usage 1; }
            parse_only "$2"
            shift 2
            ;;
        -h|--help) usage 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage 1
            ;;
    esac
done

resolve_pydisplay

[[ -x "$BUILD_MP" ]] || { echo "Missing build_mp.sh: $BUILD_MP" >&2; exit 1; }
[[ -x "$BUILD_CP" ]] || { echo "Missing build_cp.sh: $BUILD_CP" >&2; exit 1; }

build_one() {
    local t="$1"
    case "$t" in
        mp-unix)
            (cd "$CMODS" && "$BUILD_MP" --port unix --variant standard)
            ;;
        mp-windows)
            (cd "$CMODS" && "$BUILD_MP" --port windows --variant dev)
            ;;
        mp-wasm)
            (cd "$CMODS" && "$BUILD_MP" --port webassembly --variant pyscript)
            ;;
        cp-unix)
            (cd "$CMODS/lv_circuitpython_mod" && "$BUILD_CP" --port unix --variant coverage)
            ;;
    esac
}

install_one() {
    local t="$1"
    case "$t" in
        mp-unix)
            [[ -f "$MP_UNIX_SRC" ]] || {
                echo "Missing build output: $MP_UNIX_SRC" >&2
                exit 1
            }
            mkdir -p "$BIN_DIR"
            install -m 755 "$MP_UNIX_SRC" "$BIN_DIR/micropython"
            echo "Installed $BIN_DIR/micropython"
            ;;
        mp-windows)
            [[ -f "$MP_WIN_SRC" ]] || {
                echo "Missing build output: $MP_WIN_SRC" >&2
                exit 1
            }
            mkdir -p "$BIN_DIR"
            install -m 755 "$MP_WIN_SRC" "$BIN_DIR/micropython.exe"
            echo "Installed $BIN_DIR/micropython.exe"
            if [[ -n "$MP_WINDOWS_INSTALL_DIR" ]]; then
                mkdir -p "$MP_WINDOWS_INSTALL_DIR"
                install -m 755 "$MP_WIN_SRC" "$MP_WINDOWS_INSTALL_DIR/micropython.exe"
                echo "Installed $MP_WINDOWS_INSTALL_DIR/micropython.exe"
            fi
            ;;
        mp-wasm)
            [[ -f "$MP_WASM_DIR/micropython.mjs" && -f "$MP_WASM_DIR/micropython.wasm" ]] || {
                echo "Missing wasm build outputs under $MP_WASM_DIR" >&2
                exit 1
            }
            mkdir -p "$VENDOR_MP"
            cp -f "$MP_WASM_DIR/micropython.mjs" "$MP_WASM_DIR/micropython.wasm" "$VENDOR_MP/"
            echo "Installed $VENDOR_MP/micropython.{mjs,wasm}"
            ;;
        cp-unix)
            [[ -f "$CP_UNIX_SRC" ]] || {
                echo "Missing build output: $CP_UNIX_SRC" >&2
                exit 1
            }
            mkdir -p "$BIN_DIR"
            # Upstream unix coverage binary is named micropython; install as circuitpython.
            install -m 755 "$CP_UNIX_SRC" "$BIN_DIR/circuitpython"
            echo "Installed $BIN_DIR/circuitpython"
            ;;
    esac
}

echo "pydisplay: $PYDISPLAY_DIR"
if [[ "$INSTALL_ONLY" -eq 0 ]]; then
    for t in "${ALL_TARGETS[@]}"; do
        want "$t" || continue
        echo "=== build $t ==="
        build_one "$t"
    done
fi

for t in "${ALL_TARGETS[@]}"; do
    want "$t" || continue
    echo "=== install $t ==="
    install_one "$t"
done

echo "Done."
