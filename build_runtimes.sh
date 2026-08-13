#!/usr/bin/env bash
# Build MicroPython/CircuitPython runtimes and install them under workspace bin/.
# When pydevices is a sibling of this workspace, also install into that tree.
#
# Targets:
#   mp-unix     MicroPython unix / standard  → bin/micropython
#   mp-windows  MicroPython windows / dev    → bin/micropython.exe
#               and $MP_WINDOWS_INSTALL_DIR/micropython.exe (unless unset empty)
#   mp-wasm     MicroPython webassembly / pyscript
#               → bin/micropython.{mjs,wasm}
#   cp-unix     CircuitPython unix / coverage → bin/circuitpython
#               (renamed from upstream build output named micropython)
#
# Usage:
#   ./build_runtimes.sh
#   ./build_runtimes.sh --install-only
#   ./build_runtimes.sh --only mp-unix,mp-wasm
#
# Environment:
#   WORKSPACE_DIR           Workspace root (default: directory containing this script)
#   PYDEVICES_DIR           Optional pydevices checkout. Used only when it is a
#                           sibling of WORKSPACE_DIR (same parent directory). Default:
#                           $WORKSPACE_DIR/../pydevices when that directory exists.
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

# Capture optional override before resolve clears PYDEVICES_DIR when not sibling.
PYDEVICES_DIR_OVERRIDE="${PYDEVICES_DIR-}"
PYDEVICES_DIR=""
PYDEVICES_BIN=""

ALL_TARGETS=(mp-unix mp-windows mp-wasm cp-unix)
INSTALL_ONLY=0
ONLY=()

usage() {
    sed -n '2,34p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

# Install into pydevices only when it shares a parent directory with the workspace.
resolve_pydevices_sibling() {
    local candidate="${PYDEVICES_DIR_OVERRIDE:-$WORKSPACE_DIR/../pydevices}"
    PYDEVICES_DIR=""
    PYDEVICES_BIN=""
    [[ -d "$candidate" ]] || return 0
    candidate=$(cd "$candidate" && pwd)
    local workspace_parent py_parent
    workspace_parent=$(cd "$WORKSPACE_DIR/.." && pwd)
    py_parent=$(cd "$candidate/.." && pwd)
    if [[ "$workspace_parent" != "$py_parent" ]]; then
        echo "Skipping pydevices install: $candidate is not a sibling of $WORKSPACE_DIR" >&2
        return 0
    fi
    PYDEVICES_DIR="$candidate"
    PYDEVICES_BIN="$PYDEVICES_DIR/bin"
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

resolve_pydevices_sibling

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
            if [[ -n "$PYDEVICES_BIN" ]]; then
                install_file "$MP_UNIX_SRC" "$PYDEVICES_BIN" "micropython"
            fi
            ;;
        mp-windows)
            [[ -f "$MP_WIN_SRC" ]] || {
                echo "Missing build output: $MP_WIN_SRC" >&2
                exit 1
            }
            install_file "$MP_WIN_SRC" "$WORKSPACE_BIN" "micropython.exe"
            if [[ -n "$PYDEVICES_BIN" ]]; then
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
            if [[ -n "$PYDEVICES_BIN" ]]; then
                copy_wasm_pair "$PYDEVICES_BIN"
            fi
            ;;
        cp-unix)
            [[ -f "$CP_UNIX_SRC" ]] || {
                echo "Missing build output: $CP_UNIX_SRC" >&2
                exit 1
            }
            # Upstream unix coverage binary is named micropython; install as circuitpython.
            install_file "$CP_UNIX_SRC" "$WORKSPACE_BIN" "circuitpython"
            if [[ -n "$PYDEVICES_BIN" ]]; then
                install_file "$CP_UNIX_SRC" "$PYDEVICES_BIN" "circuitpython"
            fi
            ;;
    esac
}

echo "workspace bin: $WORKSPACE_BIN"
if [[ -n "$PYDEVICES_DIR" ]]; then
    echo "pydevices (sibling): $PYDEVICES_DIR"
else
    echo "pydevices: not a sibling (installing to workspace bin/ only)"
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
