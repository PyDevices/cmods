#!/usr/bin/env bash
# Build MicroPython/CircuitPython interpreters and install them under workspace bin/.
# Also installs applicable artifacts into sibling pydevices and PyDevices.github.io trees.
#
# Targets:
#   mp-unix     MicroPython unix / standard  → bin/micropython
#   mp-windows  MicroPython windows / dev    → bin/micropython.exe
#               and $MP_WINDOWS_INSTALL_DIR/micropython.exe (unless unset empty)
#   mp-wasm     MicroPython webassembly / pydevices
#               → bin/micropython.{mjs,wasm}
#                 and ../PyDevices.github.io/vendor/micropython/
#   cp-unix     CircuitPython unix / coverage → bin/circuitpython
#               (renamed from upstream build output named micropython)
#
# Opt-in target, never part of a bare run — name it with --only:
#   cp-oracle   CircuitPython unix / coverage built at
#               CIRCUITPY_SYNTHIO_MAX_CHANNELS=64
#               → bin/circuitpython-oracle-<cp-version>, and nowhere else.
#               That file is audiodsp's parity oracle: every golden in that
#               repository means "the bytes this binary rendered". Its sha256
#               is pinned in audiodsp's tests/test_voice_ceiling_consistency.py,
#               so re-pinning the hash there is part of running this target,
#               in the same change. bin/circuitpython is NOT the oracle — it
#               is cp-unix's, at the coverage variant's own 14-voice ceiling,
#               and this script overwrites it whenever anyone runs it.
#
# Usage:
#   ./build_interpreters.sh
#   ./build_interpreters.sh --install-only
#   ./build_interpreters.sh --only mp-unix,mp-wasm
#   ./build_interpreters.sh --only cp-oracle
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
MP_WASM_DIR="$WORKSPACE_DIR/micropython/ports/webassembly/build-pydevices"
CP_UNIX_SRC="$WORKSPACE_DIR/circuitpython/ports/unix/build-coverage/micropython"
# Optional extra Windows PATH install; default empty (skip).
MP_WINDOWS_INSTALL_DIR="${MP_WINDOWS_INSTALL_DIR-}"

ORG_DIR=$(cd "$WORKSPACE_DIR/.." && pwd)
PYDEVICES_BIN="$ORG_DIR/pydevices/bin"
PORTAL_WASM="$ORG_DIR/PyDevices.github.io/vendor/micropython"
# Workbench's in-browser VM transport loads this pair (src/pydevices/runtime.js).
WORKBENCH_WASM="$ORG_DIR/workbench/assets/pydevices"

ALL_TARGETS=(mp-unix mp-windows mp-wasm cp-unix)
# Opt-in: built and installed only when named with --only. A bare run must
# never write the oracle, because its bytes are pinned in another repository.
OPT_IN_TARGETS=(cp-oracle)
KNOWN_TARGETS=("${ALL_TARGETS[@]}" "${OPT_IN_TARGETS[@]}")
# The ceiling the oracle is built at, and the only way to set it on this
# variant: the coverage variant hardcodes -DCIRCUITPY_SYNTHIO_MAX_CHANNELS=14
# rather than taking circuitpy_mpconfig.mk's `?=`, and this build is -Werror,
# so a second -D is a redefinition error rather than a win. -U first.
CP_ORACLE_CFLAGS="-UCIRCUITPY_SYNTHIO_MAX_CHANNELS -DCIRCUITPY_SYNTHIO_MAX_CHANNELS=64"
CP_ORACLE_CHANNELS=64
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
            mp-unix|mp-windows|mp-wasm|cp-unix|cp-oracle) ONLY+=("$t") ;;
            *)
                echo "Unknown --only target: $t" >&2
                usage 1
                ;;
        esac
    done
}

is_opt_in() {
    local t="$1" x
    for x in "${OPT_IN_TARGETS[@]}"; do
        [[ "$x" == "$t" ]] && return 0
    done
    return 1
}

want() {
    local t="$1"
    if [[ ${#ONLY[@]} -eq 0 ]]; then
        # A bare run is every default target and none of the opt-in ones.
        is_opt_in "$t" && return 1
        return 0
    fi
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
    stamp_provenance "$dest_dir/$dest_name"
}

# Write bin/<name>.provenance beside a binary we just installed: every usermod
# in cmods with its commit, whether its tree was dirty, the overlay patches for
# the port, and the binary's own sha256 (cmods#27).
#
# WHY, in one sentence: bin/micropython was thirteen minutes older than an
# audiodsp C change once, and every parity run for a week certified a binary
# that did not contain the code the gate was about -- green the whole time,
# because the binary reports MicroPython's version and nothing about us.
#
# Written HERE rather than in build_mp.sh because this script is the one that
# decides what lands in bin/, and a stamp beside a binary nobody installed
# would describe a build directory instead of an artifact.
STAMP_TARGET=""
STAMP_PORT=""
stamp_provenance() {
    local binary="$1"
    local extra=()
    [[ "$INSTALL_ONLY" -eq 1 ]] && extra+=(--install-only)
    python3 "$SCRIPT_DIR/scripts/provenance.py" write "$binary" \
        --target "$STAMP_TARGET" --port "$STAMP_PORT" "${extra[@]}" || {
        # A missing stamp must not fail a build -- but it must be loud, because
        # the whole point is that a binary with no stamp cannot be trusted and
        # the check script refuses one.
        echo "WARNING: could not stamp $binary; gates will refuse it" >&2
    }
}

copy_wasm_pair() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    cp -f "$MP_WASM_DIR/micropython.mjs" "$MP_WASM_DIR/micropython.wasm" "$dest_dir/"
    # cp doesn't carry the exec bit the way `install -m` does elsewhere in
    # this script; bin/wasm.py and friends need it set or they fail rc=126.
    chmod 755 "$dest_dir/micropython.mjs" "$dest_dir/micropython.wasm"
    echo "Installed $dest_dir/micropython.{mjs,wasm}"
    # The .wasm carries the compiled usermods; the .mjs is its loader. One
    # stamp, on the half that holds the code.
    stamp_provenance "$dest_dir/micropython.wasm"
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

# cp-unix and cp-oracle are the same port and variant at two ceilings, so they
# share one build directory and the second build overwrites the first. Running
# both in one invocation would install whichever finished last as *both*.
if want cp-unix && want cp-oracle && [[ ${#ONLY[@]} -gt 0 ]]; then
    echo "cp-unix and cp-oracle share ports/unix/build-coverage; run them" \
         "one at a time." >&2
    exit 1
fi

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
            (cd "$WORKSPACE_DIR" && "$BUILD_MP" --port webassembly --variant pydevices)
            ;;
        cp-unix)
            (cd "$WORKSPACE_DIR" && "$BUILD_CP" --port unix --variant coverage)
            ;;
        cp-oracle)
            (cd "$WORKSPACE_DIR" \
                && CP_CFLAGS_EXTRA="$CP_ORACLE_CFLAGS" \
                   "$BUILD_CP" --port unix --variant coverage)
            ;;
    esac
}

#: The tag the CircuitPython tree is checked out at, which names the oracle.
cp_version() {
    local version
    version=$(git -C "$WORKSPACE_DIR/circuitpython" describe --tags --always \
                  2>/dev/null) || version=""
    [[ -n "$version" ]] || {
        echo "Cannot read the CircuitPython version from" \
             "$WORKSPACE_DIR/circuitpython" >&2
        exit 1
    }
    echo "$version"
}

#: The ceiling a built binary actually answers. The oracle is the ONLY thing
#: this script builds whose configuration is not visible in its own name, and
#: --install-only would happily copy whatever the coverage build directory
#: last held -- a 14-voice cp-unix build, say. Ask the binary instead.
cp_built_channels() {
    "$CP_UNIX_SRC" -c \
        'import synthio; print(synthio.Synthesizer().max_polyphony)' \
        2>/dev/null
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
            # Emscripten emits whitespace-only padding on generated lines. Keep
            # published JavaScript compatible with repository diff checks.
            sed -i 's/[[:space:]]\+$//' "$MP_WASM_DIR/micropython.mjs"
            copy_wasm_pair "$WORKSPACE_BIN"
            if [[ -d "$ORG_DIR/pydevices" ]]; then
                copy_wasm_pair "$PYDEVICES_BIN"
            fi
            if [[ -d "$ORG_DIR/PyDevices.github.io" ]]; then
                copy_wasm_pair "$PORTAL_WASM"
            fi
            if [[ -d "$WORKBENCH_WASM" ]]; then
                copy_wasm_pair "$WORKBENCH_WASM"
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
        cp-oracle)
            [[ -f "$CP_UNIX_SRC" ]] || {
                echo "Missing build output: $CP_UNIX_SRC" >&2
                exit 1
            }
            local channels
            channels=$(cp_built_channels)
            [[ "$channels" == "$CP_ORACLE_CHANNELS" ]] || {
                echo "Refusing to install the oracle: the coverage build" \
                     "answers $channels voices, not $CP_ORACLE_CHANNELS." >&2
                echo "That build is somebody else's (cp-unix builds at the" \
                     "variant's own 14). Build cp-oracle rather than" \
                     "installing what is lying there." >&2
                exit 1
            }
            # Workspace bin only, never the sibling pydevices tree: this is a
            # test fixture for audiodsp's parity gates, not an interpreter
            # anybody runs. Re-pin its sha256 in audiodsp's
            # tests/test_voice_ceiling_consistency.py in the same change.
            install_file "$CP_UNIX_SRC" "$WORKSPACE_BIN" \
                         "circuitpython-oracle-$(cp_version)"
            echo "Pin this in audiodsp tests/test_voice_ceiling_consistency.py:"
            sha256sum "$WORKSPACE_BIN/circuitpython-oracle-$(cp_version)"
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
    for t in "${KNOWN_TARGETS[@]}"; do
        want "$t" || continue
        echo "=== build $t ==="
        build_one "$t"
    done
fi

for t in "${KNOWN_TARGETS[@]}"; do
    want "$t" || continue
    echo "=== install $t ==="
    STAMP_TARGET="$t"
    case "$t" in
        mp-unix) STAMP_PORT=unix ;;
        mp-windows) STAMP_PORT=windows ;;
        mp-wasm) STAMP_PORT=webassembly ;;
        *) STAMP_PORT="" ;;
    esac
    install_one "$t"
done

echo "Done."
