#!/usr/bin/env bash
# Build MicroPython/CircuitPython interpreters and install them under workspace bin/.
# Also installs applicable artifacts into sibling pydevices and PyDevices.github.io trees.
#
# Targets:
#   mp-unix     MicroPython unix / standard  → bin/micropython
#   mp-windows  MicroPython windows / dev    → bin/micropython.exe
#               and $MP_WINDOWS_INSTALL_DIR/micropython.exe (unless unset empty)
#   mp-wasm     MicroPython webassembly / pyscript
#               → bin/micropython.{mjs,wasm}
#                 and ../PyDevices.github.io/vendor/micropython/
#   cp-unix     CircuitPython unix / coverage → bin/circuitpython
#               (renamed from upstream build output named micropython)
#
# Usage:
#   ./build_interpreters.sh
#   ./build_interpreters.sh --install-only
#   ./build_interpreters.sh --only mp-unix,mp-wasm
#
# Environment:
#   WORKSPACE_DIR           Workspace root (default: directory containing this script)
#   EMSDK_DIR               Emscripten SDK for mp-wasm (see build_mp.sh; default: $WORKSPACE_DIR/emsdk)
#   MP_WINDOWS_INSTALL_DIR  Optional extra install dir for micropython.exe
#                           (WSL path to a Windows PATH entry, e.g.
#                           /mnt/c/Users/<you>/.local/bin). Unset/empty skips
#                           the extra copy (workspace bin/ is always updated).
#
# Run this after changing any usermod compiled into these binaries (pygraphics,
# lvgl-micropython, lvgl-circuitpython / regenerated lvgl-bindings,
# displayif when present — including desktop usdl2 — frozen manifest trees, or
# port/build config that affects them).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORKSPACE_DIR="${WORKSPACE_DIR:-$SCRIPT_DIR}"
BUILD_MP="$WORKSPACE_DIR/build_mp.sh"
BUILD_CP="$WORKSPACE_DIR/build_cp.sh"
WORKSPACE_BIN="$WORKSPACE_DIR/bin"

MP_UNIX_SRC="$WORKSPACE_DIR/micropython/ports/unix/build-standard/micropython"
MP_WIN_SRC="$WORKSPACE_DIR/micropython/ports/windows/build-dev/micropython.exe"
MP_WASM_DIR="$WORKSPACE_DIR/micropython/ports/webassembly/build-pyscript"
CP_UNIX_SRC="$WORKSPACE_DIR/circuitpython/ports/unix/build-coverage/micropython"
# Optional extra Windows PATH install; default empty (skip).
MP_WINDOWS_INSTALL_DIR="${MP_WINDOWS_INSTALL_DIR-}"

ORG_DIR=$(cd "$WORKSPACE_DIR/.." && pwd)
PYDEVICES_BIN="$ORG_DIR/pydevices/bin"
PORTAL_WASM="$ORG_DIR/PyDevices.github.io/vendor/micropython"

ALL_TARGETS=(mp-unix mp-windows mp-wasm cp-unix)
INSTALL_ONLY=0
ONLY=()

usage() {
    sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
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

install_file() {
    local src="$1"
    local dest_dir="$2"
    local dest_name="$3"
    mkdir -p "$dest_dir"
    install -m 755 "$src" "$dest_dir/$dest_name"
    echo "Installed $dest_dir/$dest_name"
}

copy_wasm_pair() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    cp -f "$MP_WASM_DIR/micropython.mjs" "$MP_WASM_DIR/micropython.wasm" "$dest_dir/"
    echo "Installed $dest_dir/micropython.{mjs,wasm}"
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

[[ -x "$BUILD_MP" ]] || { echo "Missing build_mp.sh: $BUILD_MP" >&2; exit 1; }
[[ -x "$BUILD_CP" ]] || { echo "Missing build_cp.sh: $BUILD_CP" >&2; exit 1; }

build_one() {
    local t="$1"
    case "$t" in
        mp-unix)
            (cd "$WORKSPACE_DIR" && "$BUILD_MP" --port unix --variant standard)
            ;;
        mp-windows)
            (cd "$WORKSPACE_DIR" && "$BUILD_MP" --port windows --variant dev)
            ;;
        mp-wasm)
            (cd "$WORKSPACE_DIR" && "$BUILD_MP" --port webassembly --variant pyscript)
            ;;
        cp-unix)
            (cd "$WORKSPACE_DIR" && "$BUILD_CP" --port unix --variant coverage)
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
            install_file "$MP_UNIX_SRC" "$WORKSPACE_BIN" "micropython"
            if [[ -d "$ORG_DIR/pydevices" ]]; then
                install_file "$MP_UNIX_SRC" "$PYDEVICES_BIN" "micropython"
            fi
            ;;
        mp-windows)
            [[ -f "$MP_WIN_SRC" ]] || {
                echo "Missing build output: $MP_WIN_SRC" >&2
                exit 1
            }
            install_file "$MP_WIN_SRC" "$WORKSPACE_BIN" "micropython.exe"
            if [[ -d "$ORG_DIR/pydevices" ]]; then
                install_file "$MP_WIN_SRC" "$PYDEVICES_BIN" "micropython.exe"
            fi
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
            copy_wasm_pair "$WORKSPACE_BIN"
            if [[ -d "$ORG_DIR/pydevices" ]]; then
                copy_wasm_pair "$PYDEVICES_BIN"
            fi
            if [[ -d "$ORG_DIR/PyDevices.github.io" ]]; then
                copy_wasm_pair "$PORTAL_WASM"
            fi
            ;;
        cp-unix)
            [[ -f "$CP_UNIX_SRC" ]] || {
                echo "Missing build output: $CP_UNIX_SRC" >&2
                exit 1
            }
            # Upstream unix coverage binary is named micropython; install as circuitpython.
            install_file "$CP_UNIX_SRC" "$WORKSPACE_BIN" "circuitpython"
            if [[ -d "$ORG_DIR/pydevices" ]]; then
                install_file "$CP_UNIX_SRC" "$PYDEVICES_BIN" "circuitpython"
            fi
            ;;
    esac
}

echo "workspace bin: $WORKSPACE_BIN"
if [[ -d "$ORG_DIR/pydevices" ]]; then
    echo "pydevices (sibling): $ORG_DIR/pydevices"
fi
if [[ -d "$ORG_DIR/PyDevices.github.io" ]]; then
    echo "PyDevices.github.io (sibling): $ORG_DIR/PyDevices.github.io"
fi


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
