#!/usr/bin/env bash
# Build any MicroPython port/board/variant with cmods user C modules.
#
# Usage:
#   ./build_mp.sh [--port PORT] [--board BOARD] [--variant VARIANT] [--debug]
#                 [--icon PATH]
#
# Environment: WORKSPACE_DIR, MP_DIR, IDF_DIR, EMSDK_DIR, PORT, BOARD, VARIANT,
#              OS_DUPTERM, OS_DUPTERM_SLOTS, MP_BUILD_DEBUG, MP_AUTOSIZE,
#              MP_CLEAN,
#              MP_OVERLAY_SKIP (patch numbers excluded from the mailbox
#              overlays, e.g. "0001 0003"), MP_MAKE_EXTRA (extra VAR=VALUE
#              words appended to the make command line), MP_ICON (same as
#              --icon: the .ico the windows port's executable wears)
#
# USER_C_MODULES and FROZEN_MANIFEST are always cleared at startup so a prior
# shell export cannot stick across port/board/variant builds. FROZEN_MANIFEST
# then defaults to \$WORKSPACE_DIR/manifest-micropython.py. USER_C_MODULES is
# never passed: since MicroPython 1.29 the manifest names every C module it
# wants with c_module(), and each sibling's manifest.py names its own. The
# aggregator micropython.cmake that used to glob the workspace is gone.
#
# FROZEN_MANIFEST defaults to this repo's manifest-micropython.py. build_mp.sh
# also exports FROZEN_MANIFEST_UPSTREAM to the MicroPython freeze file for the
# selected port/board/variant; the aggregator includes that path (no generated
# wrapper).
#
# OS_DUPTERM defaults to 1 on unix and webassembly; the windows port disables it
# by default (link fails with undefined mp_interrupt_char). Set OS_DUPTERM=1 or
# pass --os-dupterm to force it on windows. On enabled desktop ports this passes
# -DMICROPY_PY_OS_DUPTERM=<slots> via CFLAGS_EXTRA (embedded ports usually
# enable it in mpconfigport.h already).
#
# webassembly: sources EMSDK_DIR/emsdk_env.sh (like esp32 + IDF_DIR/export.sh).
# Default EMSDK_DIR is $WORKSPACE_DIR/emsdk.
# LVGL user modules set -Wno-unused-function in CFLAGS_USERMOD, but the
# webassembly port appends -Werror after py.mk merges user-module flags; emcc
# then treats unused static inlines in generated lvgl_micropython.c as errors. The local
# patch in micropython/ports/webassembly/Makefile appends -Wno-unused-function
# after -Werror so it takes effect.
#
# patches/*micropython-<port>* — temporary mailbox overlays on a clean upstream
# checkout when the selected PORT matches. The script reverses its overlays on
# every exit and never creates commits inside micropython/. See patches/README.md.
set -euo pipefail

APPLIED_MP_PATCHES=()
# Set by apply_micropython_icon: where the port's own micropython.rc was put
# while ours stood in its place.
MP_ICON_RC_BACKUP=""

restore_micropython_overlay() {
    local index
    # The icon first: it is a plain file copy and cannot fail the way a patch
    # reversal can, so doing it here means a patch that will not reverse still
    # leaves the resource script as MicroPython wrote it.
    if [[ -n "$MP_ICON_RC_BACKUP" && -f "$MP_ICON_RC_BACKUP" ]]; then
        # Copied back rather than moved-with-timestamp on purpose: the restored
        # file is NEWER than the .res built from ours, so the next build without
        # --icon rebuilds the resource and the port's own logo returns. The icon
        # is per-invocation, never sticky - this checkout is shared.
        cp "$MP_ICON_RC_BACKUP" "$MP_DIR/ports/windows/micropython.rc"
        rm -f "$MP_ICON_RC_BACKUP"
        MP_ICON_RC_BACKUP=""
    fi
    for ((index=${#APPLIED_MP_PATCHES[@]}-1; index>=0; index--)); do
        git -C "$MP_DIR" apply --reverse "${APPLIED_MP_PATCHES[index]}" || {
            echo "error: failed to remove MicroPython overlay ${APPLIED_MP_PATCHES[index]}" >&2
            return 1
        }
    done
}

trap restore_micropython_overlay EXIT

# Drop inherited overrides every run (all ports/boards/variants). Stale exports
# from a previous slim/custom build must not affect this invocation.
unset USER_C_MODULES FROZEN_MANIFEST

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_MP="${BUILD_MP:-$SCRIPT_DIR/build_mp.sh}"

# One build at a time, whatever the target. Every run transacts the mailbox
# overlays through the same micropython/ checkout (applied, built, reversed),
# so two overlapping runs do not collide on build directories -- they collide
# on that tree, and the failure is a *successful* build of half-patched
# sources. The lock is held for this process's lifetime and released by the
# kernel on exit, so a killed build cannot leave it behind. MP_BUILD_LOCK_WAIT
# is the seconds to wait for another build before giving up (default two
# hours, 0 to fail at once).
exec 9>"$SCRIPT_DIR/.build.lock"
if ! flock -w "${MP_BUILD_LOCK_WAIT:-7200}" 9; then
    echo "error: another build_mp.sh holds $SCRIPT_DIR/.build.lock; waited ${MP_BUILD_LOCK_WAIT:-7200}s" >&2
    exit 1
fi
WORKSPACE_DIR="${WORKSPACE_DIR:-$SCRIPT_DIR}"
MP_DIR="${MP_DIR:-$WORKSPACE_DIR/micropython}"
IDF_DIR="${IDF_DIR:-$WORKSPACE_DIR/esp-idf}"
EMSDK_DIR="${EMSDK_DIR:-$WORKSPACE_DIR/emsdk}"
FROZEN_MANIFEST="$WORKSPACE_DIR/manifest-micropython.py"
FROZEN_MANIFEST_EXPLICIT=0

PORT="${PORT:-}"
BOARD="${BOARD:-}"
VARIANT="${VARIANT:-}"
VARIANT_DIR=""
MP_BUILD_DEBUG="${MP_BUILD_DEBUG:-0}"
OS_DUPTERM_EXPLICIT=0
if [[ -v OS_DUPTERM ]]; then
    OS_DUPTERM_EXPLICIT=1
else
    OS_DUPTERM=1
fi
OS_DUPTERM_SLOTS="${OS_DUPTERM_SLOTS:-1}"
MP_AUTOSIZE="${MP_AUTOSIZE:-0}"
MP_CLEAN="${MP_CLEAN:-1}"

is_truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2"; shift 2 ;;
        --board)   BOARD="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --debug)   MP_BUILD_DEBUG=1; shift ;;
        --icon)    MP_ICON="$2"; shift 2 ;;
        --no-os-dupterm) OS_DUPTERM=0; OS_DUPTERM_EXPLICIT=1; shift ;;
        --os-dupterm) OS_DUPTERM=1; OS_DUPTERM_EXPLICIT=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--port PORT] [--board BOARD] [--variant VARIANT] [--debug]
          [--icon PATH]

Build MicroPython with user C modules from the cmods workspace.

Options:
  --port PORT        MicroPython port (e.g. unix, esp32, rp2)
  --board BOARD      Board name for board-based ports
  --variant VARIANT  Board variant (board ports) or build variant (unix, etc.)
  --icon PATH        windows: .ico the built executable wears, in place of
                     the port's own logo. Restored after the build.
  --debug            esp32: UART REPL + USB Serial/JTAG debug console
                     (ESP32_GENERIC_S3/SPIRAM_OCT → SPIRAM_OCT_DEBUG).
                     USB jack = IDF secondary console / ESP_LOG; UART jack = REPL.

Environment:
  WORKSPACE_DIR      cmods workspace root (default: script directory)
  MP_DIR             MicroPython tree (default: \$WORKSPACE_DIR/micropython)
  IDF_DIR            ESP-IDF install for esp32 (default: \$WORKSPACE_DIR/esp-idf)
  EMSDK_DIR          Emscripten SDK for webassembly (default: \$WORKSPACE_DIR/emsdk)
  USER_C_MODULES     Never passed; the manifest names C modules (c_module())
  FROZEN_MANIFEST    Always \$WORKSPACE_DIR/manifest-micropython.py (inherited env is unset)
  FROZEN_MANIFEST_UPSTREAM  Set by this script to the MicroPython upstream freeze
                     file for the selected port/board/variant (read by manifest-micropython.py)
  PORT, BOARD, VARIANT  Same as the corresponding options
  MP_BUILD_DEBUG     Same as --debug when set to 1/true/yes/on
  MP_ICON            Same as --icon (windows only)
  OS_DUPTERM         Enable os.dupterm on unix/webassembly (default: 1); windows default: 0
  OS_DUPTERM_SLOTS   dupterm slot count for desktop ports (default: 1)
  SDL2_DEV           Unpacked SDL2 MinGW development ZIP root (windows; required when displayif usdl2 links)
  PICOTOOL_FETCH_FROM_GIT_PATH  Cache dir for prebuilt picotool (rp2 port)
  picotool_DIR       Prebuilt picotool cmake package dir (rp2 port)
  DISPLAYIF_SKIP_SPIRAM_CHECK  Set to 1 to skip esp32 PSRAM warning when displayif is present
  MP_AUTOSIZE        esp32: when the app overflows its partition, build once against an
                     enlarged table kept in the build directory only (default: 0 = refuse
                     and print the table that would fit). The pinned table in
                     esp32_partitions/ is never rewritten either way; growing the app
                     partition moves the filesystem, which is a decision (cmods#30).
  MP_CLEAN           Run 'make clean' before building (default: 1). On esp32 that is
                     'idf.py fullclean', which deletes the whole port's managed_components/
                     -- it is skipped automatically when the build directory does not
                     exist yet, and MP_CLEAN=0 skips it always (cmods#29).

Options:
  --no-os-dupterm    Disable os.dupterm (same as OS_DUPTERM=0)
  --os-dupterm       Enable os.dupterm (override windows default)
  --debug            Dual-port debug firmware (esp32; see above)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if is_truthy "$MP_BUILD_DEBUG"; then
    MP_BUILD_DEBUG=1
else
    MP_BUILD_DEBUG=0
fi

[[ -d "$MP_DIR/ports" ]] || { echo "MicroPython not found: $MP_DIR" >&2; exit 1; }

pick() {
    local label="$1"; shift
    local -a items=("$@")
    local n i

    echo >&2
    echo "$label" >&2
    for i in "${!items[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2
    done
    while true; do
        read -r -p "Select [1-${#items[@]}]: " n
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#items[@]} )); then
            echo "${items[$((n - 1))]}"
            return
        fi
        echo "Invalid selection." >&2
    done
}

list_ports() {
    local p
    for p in "$MP_DIR"/ports/*; do
        [[ -f "$p/Makefile" ]] && basename "$p"
    done
}

list_boards() {
    local d
    for d in "$PORT_DIR/boards"/*; do
        [[ -f "$d/mpconfigboard.mk" || -f "$d/mpconfigboard.cmake" ]] && basename "$d"
    done
}

list_board_variants() {
    local board_dir="$1"
    local f name
    shopt -s nullglob
    for f in "$board_dir"/mpconfigvariant_*.mk "$board_dir"/mpconfigvariant_*.cmake; do
        name=$(basename "$f")
        name=${name#mpconfigvariant_}
        name=${name%.mk}
        name=${name%.cmake}
        echo "$name"
    done
    shopt -u nullglob
}

list_port_variants() {
    local d
    for d in "$PORT_DIR/variants"/*; do
        [[ -f "$d/mpconfigvariant.mk" ]] && basename "$d"
    done
    if [[ "$PORT" == webassembly ]]; then
        for d in "$WORKSPACE_DIR/variants/webassembly"/*; do
            [[ -f "$d/mpconfigvariant.mk" ]] && basename "$d"
        done
    fi
}

port_kind() {
    if [[ -d "$PORT_DIR/boards" ]]; then
        echo boards
    elif [[ -d "$PORT_DIR/variants" ]]; then
        echo variants
    else
        echo plain
    fi
}

# Path MicroPython would use for FROZEN_MANIFEST without a cmods override
# (variant/board mpconfig sets the most-specific file; parents are include()d).
resolve_upstream_frozen_manifest() {
    local path=""
    case "$PORT_KIND" in
        variants)
            if [[ -n "$VARIANT_DIR" && -f "$VARIANT_DIR/manifest.py" ]]; then
                path="$VARIANT_DIR/manifest.py"
            elif [[ -n "$VARIANT" && -f "$PORT_DIR/variants/$VARIANT/manifest.py" ]]; then
                path="$PORT_DIR/variants/$VARIANT/manifest.py"
            elif [[ -f "$PORT_DIR/variants/manifest.py" ]]; then
                path="$PORT_DIR/variants/manifest.py"
            fi
            ;;
        boards)
            if [[ -n "$BOARD" && -n "$VARIANT" && -f "$PORT_DIR/boards/$BOARD/manifest_${VARIANT}.py" ]]; then
                path="$PORT_DIR/boards/$BOARD/manifest_${VARIANT}.py"
            elif [[ -n "$BOARD" && -f "$PORT_DIR/boards/$BOARD/manifest.py" ]]; then
                path="$PORT_DIR/boards/$BOARD/manifest.py"
            elif [[ -f "$PORT_DIR/boards/manifest.py" ]]; then
                path="$PORT_DIR/boards/manifest.py"
            fi
            ;;
        plain)
            if [[ -f "$PORT_DIR/manifest.py" ]]; then
                path="$PORT_DIR/manifest.py"
            fi
            ;;
    esac
    if [[ -z "$path" ]]; then
        echo "No upstream frozen manifest for port=$PORT${BOARD:+ board=$BOARD}${VARIANT:+ variant=$VARIANT}" >&2
        exit 1
    fi
    (cd "$(dirname "$path")" && echo "$(pwd)/$(basename "$path")")
}

find_sdl2_dev_root() {
    local candidate triplet="${1:-x86_64-w64-mingw32}"
    local -a candidates=()
    [[ -n "${SDL2_DEV:-}" ]] && candidates+=("$SDL2_DEV")
    shopt -s nullglob
    candidates+=("$WORKSPACE_DIR"/SDL2-[0-9]*)
    shopt -u nullglob
    [[ -d "$WORKSPACE_DIR/SDL2" ]] && candidates+=("$WORKSPACE_DIR/SDL2")
    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" && -d "$candidate" ]] || continue
        if [[ -f "$candidate/$triplet/include/SDL2/SDL.h" && -f "$candidate/$triplet/lib/libSDL2.a" ]]; then
            # Canonicalize so make sees an absolute path.
            (cd "$candidate" && pwd)
            return 0
        fi
    done
    return 1
}

ensure_windows_sdl2_env() {
    [[ "$PORT" == windows ]] || return 0

    local triplet=x86_64-w64-mingw32
    if [[ "${CROSS_COMPILE:-}" == i686-w64-mingw32- ]]; then
        triplet=i686-w64-mingw32
    fi

    if [[ -z "${SDL2_DEV:-}" ]]; then
        if SDL2_DEV=$(find_sdl2_dev_root "$triplet"); then
            export SDL2_DEV
            echo "Auto-detected SDL2_DEV=$SDL2_DEV (triplet $triplet)"
        else
            echo "Windows port requires the SDL2 MinGW development ZIP (displayif usdl2)." >&2
            echo "Download SDL2-devel-*-mingw.zip from https://github.com/libsdl-org/SDL/releases" >&2
            echo "Unpack it (e.g. to \$WORKSPACE_DIR/SDL2-2.30.10) and run:" >&2
            echo "  export SDL2_DEV=\$WORKSPACE_DIR/SDL2-2.30.10" >&2
            echo "See displayif/tools/sdl2_dev_env.sh" >&2
            exit 1
        fi
    fi

    local prefix="$SDL2_DEV/$triplet"
    if [[ ! -f "$prefix/include/SDL2/SDL.h" || ! -f "$prefix/lib/libSDL2.a" ]]; then
        echo "SDL2 MinGW development tree not found under: $prefix" >&2
        echo "Unpack the SDL2 MinGW development ZIP and set SDL2_DEV to its root." >&2
        echo "See displayif/tools/sdl2_dev_env.sh and https://github.com/libsdl-org/SDL/releases" >&2
        exit 1
    fi

    echo "Using SDL2_DEV=$SDL2_DEV (triplet $triplet)"
}

ensure_windows_cross_compile() {
    [[ "$PORT" == windows ]] || return 0
    [[ -n "${CROSS_COMPILE:-}" ]] && return 0

    case "$(uname -s)" in
        Linux|Darwin)
            if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
                CROSS_COMPILE=x86_64-w64-mingw32-
            elif command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
                CROSS_COMPILE=i686-w64-mingw32-
            else
                echo "Windows port on Linux requires MinGW-w64 cross tools." >&2
                echo "Install: sudo apt-get install gcc-mingw-w64" >&2
                exit 1
            fi
            echo "Using CROSS_COMPILE=$CROSS_COMPILE for windows port"
            ;;
    esac
}

ensure_idf_env() {
    [[ "$PORT" == esp32 ]] || return 0

    local idf_export="$IDF_DIR/export.sh"
    [[ -f "$idf_export" ]] || {
        echo "ESP-IDF export script not found: $idf_export" >&2
        echo "Set IDF_DIR or clone ESP-IDF under \$WORKSPACE_DIR/esp-idf." >&2
        exit 1
    }

    echo "Activating ESP-IDF environment..."
    # shellcheck disable=SC1090
    if ! . "$idf_export"; then
        echo "Failed to activate ESP-IDF from: $idf_export" >&2
        exit 1
    fi
}

esp32_displayif_preflight() {
    [[ "$PORT" == esp32 ]] || return 0
    [[ -d "$WORKSPACE_DIR/displayif" ]] || return 0

    local board_dir sdkconfig candidates c
    board_dir="$PORT_DIR/boards/$BOARD"
    # Variant builds land in build-$BOARD-$VARIANT/; plain boards use build-$BOARD/.
    if [[ -n "${VARIANT:-}" && -f "$PORT_DIR/build-$BOARD-$VARIANT/sdkconfig" ]]; then
        sdkconfig="$PORT_DIR/build-$BOARD-$VARIANT/sdkconfig"
    else
        sdkconfig="$PORT_DIR/build-$BOARD/sdkconfig"
    fi

  local needs_psram=0
  case "${BOARD:-}" in
      ESP32_GENERIC_P4|ESP32_GENERIC_S3|*S3*|*P4*) needs_psram=1 ;;
  esac

  if [[ $needs_psram -eq 0 ]]; then
      return 0
  fi

  # Board-local defaults, then MicroPython shared targets (P4 SPIRAM lives in
  # boards/sdkconfig.p4, not ESP32_GENERIC_P4/sdkconfig.board).
  candidates=()
  [[ -f "$sdkconfig" ]] && candidates+=("$sdkconfig")
  [[ -f "$board_dir/sdkconfig.board" ]] && candidates+=("$board_dir/sdkconfig.board")
  [[ -f "$board_dir/sdkconfig.defaults" ]] && candidates+=("$board_dir/sdkconfig.defaults")
  case "${BOARD:-}" in
      ESP32_GENERIC_P4|*P4*)
          [[ -f "$PORT_DIR/boards/sdkconfig.p4" ]] && candidates+=("$PORT_DIR/boards/sdkconfig.p4")
          ;;
      ESP32_GENERIC_S3|*S3*)
          for c in sdkconfig.spiram_oct sdkconfig.spiram_quad sdkconfig.spiram; do
              [[ -f "$PORT_DIR/boards/$c" ]] && candidates+=("$PORT_DIR/boards/$c")
          done
          ;;
  esac

  local spiram_ok=0
  for c in "${candidates[@]}"; do
      if grep -qE '^CONFIG_SPIRAM=y' "$c" 2>/dev/null; then
          spiram_ok=1
          echo "displayif preflight: CONFIG_SPIRAM enabled for $BOARD ($c)"
          return 0
      fi
  done

  echo "warning: displayif large framebuffers (rgbframebuffer, mipidsi) expect PSRAM on $BOARD." >&2
  echo "  Enable CONFIG_SPIRAM in the board sdkconfig / menuconfig before building with displayif." >&2
  if [[ ${#candidates[@]} -gt 0 ]]; then
      echo "  Checked: ${candidates[*]}" >&2
  fi
  if [[ ! -t 0 ]]; then
      echo "  Non-interactive build continuing (set DISPLAYIF_SKIP_SPIRAM_CHECK=1 to silence)." >&2
      return 0
  fi
  if [[ "${DISPLAYIF_SKIP_SPIRAM_CHECK:-}" == 1 ]]; then
      return 0
  fi
  read -r -p "Continue without SPIRAM check? [y/N]: " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Kept in one place, and used in the cache path as well as the asset name: the
# pico-sdk MicroPython pins refuses to configure against an older picotool
# ("Incompatible picotool installation found: Requires version 2.3.0, you have
# version 2.1.1"), and a cache holding the wrong one used to satisfy the check
# below and fail the build anyway.
PICOTOOL_VERSION=2.3.0
PICOTOOL_RELEASE=v2.3.0-1

rp2_picotool_platform_asset() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64) echo "picotool-${PICOTOOL_VERSION}-x86_64-lin.tar.gz" ;;
                aarch64|arm64) echo "picotool-${PICOTOOL_VERSION}-aarch64-lin.tar.gz" ;;
            esac
            ;;
        Darwin) echo "picotool-${PICOTOOL_VERSION}-mac.zip" ;;
        MINGW*|MSYS*|CYGWIN*) echo "picotool-${PICOTOOL_VERSION}-x64-win.zip" ;;
    esac
}

ensure_rp2_picotool() {
    [[ "$PORT" == rp2 ]] || return 0

    if [[ -n "${picotool_DIR:-}" && -f "${picotool_DIR}/picotoolConfig.cmake" ]]; then
        export PICOTOOL_FETCH_FROM_GIT_PATH="${PICOTOOL_FETCH_FROM_GIT_PATH:-$(dirname "$picotool_DIR")}"
        echo "Using picotool_DIR=$picotool_DIR"
        return 0
    fi

    if command -v picotool >/dev/null 2>&1; then
        if picotool version 2>/dev/null | grep -Eq "v${PICOTOOL_VERSION}"; then
            echo "Using installed picotool: $(command -v picotool)"
            return 0
        fi
    fi

    local cache_root asset url archive extract_dir picotool_cfg
    cache_root="${PICOTOOL_FETCH_FROM_GIT_PATH:-${WORKSPACE_DIR}/.cache/picotool-${PICOTOOL_VERSION}}"
    picotool_cfg="$cache_root/picotool/picotoolConfig.cmake"
    if [[ -f "$picotool_cfg" ]]; then
        export PICOTOOL_FETCH_FROM_GIT_PATH="$cache_root"
        export picotool_DIR="$cache_root/picotool"
        echo "Using cached picotool at $picotool_DIR"
        return 0
    fi

    asset=$(rp2_picotool_platform_asset)
    if [[ -z "$asset" ]]; then
        echo "No prebuilt picotool for $(uname -s)/$(uname -m); using CC=gcc CXX=g++ for host tools." >&2
        export CC="${CC:-gcc}"
        export CXX="${CXX:-g++}"
        return 0
    fi

    url="https://github.com/raspberrypi/pico-sdk-tools/releases/download/${PICOTOOL_RELEASE}/$asset"
    echo "Fetching prebuilt picotool ($asset)..."
    mkdir -p "$cache_root"
    archive="$cache_root/$asset"
    if [[ ! -f "$archive" ]]; then
        if ! curl -fsSL -o "$archive" "$url"; then
            echo "Failed to download picotool from $url" >&2
            echo "Falling back to CC=gcc CXX=g++ for host picotool build." >&2
            export CC="${CC:-gcc}"
            export CXX="${CXX:-g++}"
            return 0
        fi
    fi

    extract_dir="$cache_root/extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    case "$asset" in
        *.tar.gz) tar -xzf "$archive" -C "$extract_dir" ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -q "$archive" -d "$extract_dir"
            else
                echo "unzip required to extract $asset" >&2
                export CC="${CC:-gcc}"
                export CXX="${CXX:-g++}"
                return 0
            fi
            ;;
    esac

    if [[ -d "$extract_dir/picotool" ]]; then
        rm -rf "$cache_root/picotool"
        mv "$extract_dir/picotool" "$cache_root/picotool"
    fi
    rm -rf "$extract_dir"

    if [[ ! -f "$cache_root/picotool/picotoolConfig.cmake" ]]; then
        echo "Prebuilt picotool layout not found under $cache_root/picotool" >&2
        export CC="${CC:-gcc}"
        export CXX="${CXX:-g++}"
        return 0
    fi

    export PICOTOOL_FETCH_FROM_GIT_PATH="$cache_root"
    export picotool_DIR="$cache_root/picotool"
    export PATH="$cache_root/picotool:$PATH"
    echo "Using prebuilt picotool at $picotool_DIR"
}

ensure_emsdk_env() {
    [[ "$PORT" == webassembly ]] || return 0

    # See header comment: LVGL needs -Wno-unused-function after the port's -Werror.
    local emsdk_env="$EMSDK_DIR/emsdk_env.sh"
    [[ -f "$emsdk_env" ]] || {
        echo "Emscripten emsdk_env.sh not found: $emsdk_env" >&2
        echo "Set EMSDK_DIR (default: \$WORKSPACE_DIR/emsdk)." >&2
        exit 1
    }

    echo "Activating Emscripten environment..."
    # shellcheck disable=SC1090
    if ! . "$emsdk_env"; then
        echo "Failed to activate Emscripten from: $emsdk_env" >&2
        exit 1
    fi
}

ensure_host_mpy_cross() {
    # Port make rebuilds mpy-cross via py/mkrules.mk with only USER_C_MODULES=
    # cleared. GNU make still forwards FROZEN_MANIFEST from our command line,
    # so a fresh tree links mpy-cross with frozen qstr flags but no frozen pool.
    make -C "$MP_DIR/mpy-cross" USER_C_MODULES= FROZEN_MANIFEST=
}

# --icon / MP_ICON: give the built executable our own icon instead of the
# port's. ports/windows/micropython.rc is a single line naming an .ico, and the
# windows Makefile compiles it to micropython.res and links that into $(PROG)
# whatever the program is named - so rewriting that one line is the entire
# mechanism. Deliberately not a patch and deliberately no stored copy of the
# resource script: the original is stashed and the EXIT trap puts it back, the
# same transactional shape the mailbox overlays use.
apply_micropython_icon() {
    [[ -n "${MP_ICON:-}" ]] || return 0

    if [[ "$PORT" != windows ]]; then
        echo "error: --icon is only meaningful for --port windows - an ELF binary" >&2
        echo "  has nowhere to carry one. Port requested: $PORT" >&2
        return 1
    fi

    local icon
    icon=$(realpath -e -- "$MP_ICON" 2>/dev/null) || {
        echo "error: --icon: no such file: $MP_ICON" >&2
        return 1
    }
    # Checked here because windres reports a bad file as a parse error minutes
    # into the build, and a .png renamed .ico is the mistake everyone makes
    # once. An ICONDIR opens 00 00 01 00: reserved, then resource type 1.
    local magic
    magic=$(od -An -tx1 -N4 -- "$icon" | tr -d ' \n')
    if [[ "$magic" != "00000100" ]]; then
        echo "error: --icon: not a Windows .ico (header reads $magic): $icon" >&2
        return 1
    fi

    local rc="$MP_DIR/ports/windows/micropython.rc"
    [[ -f "$rc" ]] || {
        echo "error: --icon: the windows port has no micropython.rc at $rc" >&2
        return 1
    }

    MP_ICON_RC_BACKUP=$(mktemp)
    cp "$rc" "$MP_ICON_RC_BACKUP"
    printf 'app     ICON    "%s"\n' "$icon" > "$rc"
    echo "Icon: $icon"
    echo "  ports/windows/micropython.rc rewritten for this build; restored on exit"
}

apply_micropython_cmods_patches() {
    # Apply mailbox patches whose names contain micropython-<PORT> as temporary
    # working-tree overlays. No matches means there is nothing to do.
    # MP_OVERLAY_SKIP ("0001 0003") excludes listed patch numbers — used by
    # builds that must not inherit an overlay (the vst3 engine drops the
    # windows networking and FFI patches so shipped plugin content cannot
    # reach the network or arbitrary DLLs).
    local patch_dir="$WORKSPACE_DIR/patches"
    [[ -d "$patch_dir" ]] || return 0

    local -a patches=()
    local p
    shopt -s nullglob
    patches=("$patch_dir"/*"micropython-${PORT}"*)
    shopt -u nullglob

    if [[ -n "${MP_OVERLAY_SKIP:-}" ]]; then
        local -a kept=()
        local skip base
        for p in "${patches[@]}"; do
            base=$(basename "$p")
            for skip in ${MP_OVERLAY_SKIP}; do
                if [[ "$base" == "$skip"-* ]]; then
                    echo "  overlay skipped (MP_OVERLAY_SKIP): $base"
                    base=""
                    break
                fi
            done
            [[ -n "$base" ]] && kept+=("$p")
        done
        patches=("${kept[@]+"${kept[@]}"}")
    fi
    [[ ${#patches[@]} -gt 0 ]] || return 0

    # Stable apply order (0001 before 0002, …).
    IFS=$'\n' patches=($(printf '%s\n' "${patches[@]}" | sort))
    unset IFS

    # `-d .git` is false for a git WORKTREE, where .git is a file pointing at
    # the real gitdir - so this used to refuse to build from a worktree, which
    # is exactly how a pin move builds a new upstream version without
    # disturbing the pinned clone. Ask git instead of looking at the filename.
    git -C "$MP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "error: MP_DIR is not a git checkout: $MP_DIR" >&2
        exit 1
    }

    echo "MicroPython patches (port=$PORT, name contains micropython-${PORT}):"
    for p in "${patches[@]}"; do
        [[ -f "$p" ]] || continue
        local base
        base=$(basename "$p")
        if git -C "$MP_DIR" apply --reverse --check "$p" >/dev/null 2>&1; then
            echo "  skip (already applied): $base"
            continue
        fi
        if ! git -C "$MP_DIR" apply --check "$p" >/dev/null 2>&1; then
            echo "error: cannot apply $base to $MP_DIR" >&2
            git -C "$MP_DIR" apply --check "$p" 2>&1 | head -30 >&2
            echo "Use a stock micropython/micropython tree, or see patches/README.md" >&2
            exit 1
        fi
        if git -C "$MP_DIR" apply "$p"; then
            APPLIED_MP_PATCHES+=("$p")
            echo "  overlaid: $base"
        else
            echo "error: git apply failed for $base" >&2
            exit 1
        fi
    done
}

make_target_args() {
    local -a args=(
        FROZEN_MANIFEST="$FROZEN_MANIFEST"
    )
    [[ -n "${CROSS_COMPILE:-}" ]] && args+=(CROSS_COMPILE="$CROSS_COMPILE")
    [[ -n "${SDL2_DEV:-}" ]] && args+=(SDL2_DEV="$SDL2_DEV")
    if is_truthy "$OS_DUPTERM" && [[ "$PORT" == unix || "$PORT" == windows || "$PORT" == webassembly ]]; then
        args+=(CFLAGS_EXTRA="-DMICROPY_PY_OS_DUPTERM=${OS_DUPTERM_SLOTS}")
    fi
    case "$PORT_KIND" in
        boards)
            [[ -n "$BOARD" ]] && args+=(BOARD="$BOARD")
            [[ -n "$VARIANT" ]] && args+=(BOARD_VARIANT="$VARIANT")
            [[ -n "${ESP32_OVERLAY_DIR:-}" ]] && args+=(BOARD_DIR="$ESP32_OVERLAY_DIR")
            ;;
        variants)
            if [[ -n "$VARIANT_DIR" ]]; then
                args+=(VARIANT_DIR="$VARIANT_DIR")
            elif [[ -n "$VARIANT" ]]; then
                args+=(VARIANT="$VARIANT")
            fi
            ;;
    esac
    printf '%q ' "${args[@]}"
}

apply_esp32_debug_variant() {
    # Map common variants onto *_DEBUG board cmake overlays (UART REPL +
    # USB-Serial/JTAG secondary console). See boards/sdkconfig.debug_usb_jtag.
    [[ "$PORT" == esp32 ]] || {
        echo "error: --debug is only supported for --port esp32" >&2
        exit 1
    }
    [[ -n "$BOARD" ]] || {
        echo "error: --debug requires --board (e.g. ESP32_GENERIC_S3)" >&2
        exit 1
    }

    local boards="$MP_DIR/ports/esp32/boards"
    local want=""

    if [[ "$BOARD" == "ESP32_GENERIC_S3" ]]; then
        if [[ -z "$VARIANT" || "$VARIANT" == "SPIRAM_OCT" ]]; then
            want="SPIRAM_OCT_DEBUG"
        elif [[ "$VARIANT" == "SPIRAM" ]]; then
            want="SPIRAM_DEBUG"
        elif [[ "$VARIANT" == *_DEBUG ]]; then
            want="$VARIANT"
        elif [[ -f "$boards/$BOARD/mpconfigvariant_${VARIANT}_DEBUG.cmake" ]]; then
            want="${VARIANT}_DEBUG"
        fi
    elif [[ -n "$VARIANT" && -f "$boards/$BOARD/mpconfigvariant_${VARIANT}_DEBUG.cmake" ]]; then
        want="${VARIANT}_DEBUG"
    elif [[ -n "$VARIANT" && "$VARIANT" == *_DEBUG && -f "$boards/$BOARD/mpconfigvariant_${VARIANT}.cmake" ]]; then
        want="$VARIANT"
    fi

    if [[ -z "$want" ]]; then
        echo "error: --debug: no debug variant for board=$BOARD variant=${VARIANT:-<none>}" >&2
        echo "  Add boards/$BOARD/mpconfigvariant_<VARIANT>_DEBUG.cmake (see ESP32_GENERIC_S3/SPIRAM_OCT_DEBUG)." >&2
        exit 1
    fi
    if [[ ! -f "$boards/$BOARD/mpconfigvariant_${want}.cmake" ]]; then
        echo "error: --debug: missing $boards/$BOARD/mpconfigvariant_${want}.cmake" >&2
        exit 1
    fi
    if [[ "$VARIANT" != "$want" ]]; then
        echo "debug: selecting BOARD_VARIANT=$want (UART REPL + USB Serial/JTAG console)"
        VARIANT="$want"
    else
        echo "debug: BOARD_VARIANT=$VARIANT (UART REPL + USB Serial/JTAG console)"
    fi
}

print_rerun_hint() {
    local -a cmd=("$BUILD_MP")
    cmd+=(--port "$PORT")
    [[ -n "$BOARD" ]] && cmd+=(--board "$BOARD")
    # Prefer the user-facing base variant in the hint when we auto-selected *_DEBUG.
    local hint_variant="$VARIANT"
    if [[ "$MP_BUILD_DEBUG" -eq 1 && "$VARIANT" == *_DEBUG ]]; then
        hint_variant="${VARIANT%_DEBUG}"
        [[ -n "$hint_variant" ]] || hint_variant="$VARIANT"
    fi
    [[ -n "$hint_variant" ]] && cmd+=(--variant "$hint_variant")
    [[ "$MP_BUILD_DEBUG" -eq 1 ]] && cmd+=(--debug)

    local reset="" bold="" cyan=""
    if [[ -t 1 ]]; then
        reset=$(tput sgr0 2>/dev/null || true)
        bold=$(tput bold 2>/dev/null || true)
        cyan=$(tput setaf 6 2>/dev/null || true)
    fi

    printf '\n\n'
    printf '%s%sRun again without prompts:%s\n' "$bold" "$cyan" "$reset"
    printf '  %s\n' "$(printf '%q ' "${cmd[@]}")"
    printf '\n\n'
}

print_make_commands() {
    local quoted
    quoted=$(make_target_args)

    local reset="" bold="" yellow="" dim=""
    if [[ -t 1 ]]; then
        reset=$(tput sgr0 2>/dev/null || true)
        bold=$(tput bold 2>/dev/null || true)
        yellow=$(tput setaf 3 2>/dev/null || true)
        dim=$(tput dim 2>/dev/null || true)
    fi

    printf '\n\n'
    printf '%s%sRun make manually:%s\n' "$bold" "$yellow" "$reset"
    printf '%s  cd %q%s\n' "$dim" "$PORT_DIR" "$reset"
    if [[ "$PORT" == esp32 ]]; then
        printf '%s  . %q/export.sh%s\n' "$dim" "$IDF_DIR" "$reset"
    elif [[ "$PORT" == webassembly ]]; then
        printf '%s  . %q/emsdk_env.sh%s\n' "$dim" "$EMSDK_DIR" "$reset"
    fi
    if [[ -n "${FROZEN_MANIFEST_UPSTREAM:-}" ]]; then
        printf '%s  export FROZEN_MANIFEST_UPSTREAM=%q%s\n' "$dim" "$FROZEN_MANIFEST_UPSTREAM" "$reset"
    fi
    printf '%s  make -j clean %s%s\n' "$dim" "$quoted" "$reset"
    printf '%s  make -j submodules %s%s\n' "$dim" "$quoted" "$reset"
    printf '%s  make -j all %s%s\n' "$dim" "$quoted" "$reset"
    printf '\n\n'
}

build_dir() {
    # A BUILD= passed in MP_MAKE_EXTRA is where make will actually put the
    # build, so everything that looks into the build directory -- the partition
    # override, the sdkconfig check, the "Build output:" line -- has to follow
    # it. (Note the standing rule that esp32 builds must not pass BUILD=: the
    # mpy-cross sub-make inherits it and pollutes the qstr fragments. This is
    # here so the machinery is honest when somebody does it anyway.)
    local word override=""
    for word in ${MP_MAKE_EXTRA:-}; do
        [[ "$word" == BUILD=* ]] && override="${word#BUILD=}"
    done
    # ...and a BUILD in the environment reaches make just the same (the vst3
    # engine build exports BUILD=build-vst-engine rather than passing it).
    [[ -z "$override" ]] && override="${BUILD:-}"
    if [[ -n "$override" ]]; then
        if [[ "$override" == /* ]]; then
            echo "$override"
        else
            echo "$PORT_DIR/$override"
        fi
        return 0
    fi
    case "$PORT_KIND" in
        boards)
            if [[ -n "$BOARD" && -n "$VARIANT" ]]; then
                echo "$PORT_DIR/build-$BOARD-$VARIANT"
            elif [[ -n "$BOARD" ]]; then
                echo "$PORT_DIR/build-$BOARD"
            fi
            ;;
        variants)
            [[ -n "$VARIANT" ]] && echo "$PORT_DIR/build-$VARIANT"
            ;;
        plain)
            echo "$PORT_DIR/build"
            ;;
    esac
}

esp32_partition_override() {
    local suffix="$BOARD"
    [[ -n "$VARIANT" ]] && suffix="${suffix}_${VARIANT}"
    echo "$WORKSPACE_DIR/esp32_partitions/${suffix}.csv"
}

esp32_base_board_dir() {
    # The board this build overlays: a BOARD_DIR= the caller passed in
    # MP_MAKE_EXTRA (esp32_boards/ overlays do this), else the port's own.
    local word
    for word in ${MP_MAKE_EXTRA:-}; do
        if [[ "$word" == BOARD_DIR=* ]]; then
            readlink -f "${word#BOARD_DIR=}"
            return 0
        fi
    done
    echo "$PORT_DIR/boards/$BOARD"
}

esp32_overlay_dir() {
    local suffix="$BOARD"
    [[ -n "$VARIANT" ]] && suffix="${suffix}_${VARIANT}"
    echo "$WORKSPACE_DIR/.board-overlays/$suffix"
}

# Build a throwaway board overlay that carries the partition table, and hand it
# to make as BOARD_DIR=.
#
# Why not patch $BUILD/sdkconfig, which is what this used to do: idf.py
# regenerates the saved sdkconfig from SDKCONFIG_DEFAULTS whenever it
# reconfigures, and a fresh build directory always reconfigures. kconfgen then
# takes the board's own partitions-4MiBplus.csv back and the packaging step
# fails with "app partition is too small" -- or, worse, succeeds against a table
# nobody chose. A fragment appended LAST to SDKCONFIG_DEFAULTS is on the winning
# side of that regeneration, because kconfgen takes the last assignment.
# (cmods#29.)
#
# The flash-size settings travel with the table: without the sibling
# .sdkconfig fragment gen_esp32part.py refuses the table itself ("occupies
# 7.9MB of flash which does not fit in configured flash size 4MB"), so both
# halves go into the same fragment.
esp32_prepare_board_overlay() {
    local table="$1" fragment="$2" base overlay
    base=$(esp32_base_board_dir)
    overlay=$(esp32_overlay_dir)
    python3 - "$base" "$overlay" "${VARIANT:-}" "$table" "$fragment" <<'PY'
import os
import shutil
import sys
from pathlib import Path

base, overlay, variant, table, fragment = sys.argv[1:6]
base = Path(base)
overlay = Path(overlay)
if not (base / "mpconfigboard.cmake").is_file():
    raise SystemExit(f"no board at {base}")

variant_name = f"mpconfigvariant_{variant}.cmake" if variant else "mpconfigvariant.cmake"
generated = {"mpconfigboard.cmake", "mpconfigboard.h", variant_name,
             "partitions.csv", "sdkconfig.partition"}

if overlay.exists():
    shutil.rmtree(overlay)
overlay.mkdir(parents=True)

# Everything else the board directory holds is linked through, because
# ${MICROPY_BOARD_DIR} is an include directory and some board cmake files
# name files inside it (pins.csv, sdkconfig.board, board_init.c, manifest.py).
for entry in sorted(base.iterdir()):
    if entry.name in generated:
        continue
    (overlay / entry.name).symlink_to(entry.resolve())

(overlay / "mpconfigboard.cmake").write_text(
    "# Generated by build_mp.sh. The board below, unchanged; the partition\n"
    "# table arrives through the variant file beside this one.\n"
    f"include({base.as_posix()}/mpconfigboard.cmake)\n",
    encoding="utf-8",
)
base_header = base / "mpconfigboard.h"
if base_header.is_file():
    (overlay / "mpconfigboard.h").write_text(
        "// Generated by build_mp.sh: the board's own header, unchanged.\n"
        f'#include "{base_header.as_posix()}"\n',
        encoding="utf-8",
    )

base_variant = base / variant_name
lines = [
    "# Generated by build_mp.sh.",
    "#",
    "# The append has to come LAST: kconfgen takes the last assignment in",
    "# SDKCONFIG_DEFAULTS, so a fragment listed before the board's own is",
    "# silently overridden -- and the build then succeeds against the board's",
    "# default partition table, which is the expensive kind of failure.",
]
if base_variant.is_file():
    lines.append(f"include({base_variant.as_posix()})")
elif not variant:
    lines.append(f"include({base_variant.as_posix()} OPTIONAL)")
else:
    raise SystemExit(f"no {variant_name} in {base}")

if table:
    src = Path(table)
    dest = overlay / "partitions.csv"
    shutil.copyfile(src, dest)
    body = [
        "# Generated by build_mp.sh from",
        f"#   {src}",
        "# This copy is what the image is built against. Nothing writes back to",
        "# the file above: growing the app partition moves the filesystem, and",
        "# that is a decision, not a build fix-up (cmods#30).",
        "CONFIG_PARTITION_TABLE_CUSTOM=y",
        f'CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="{dest.resolve().as_posix()}"',
        f'CONFIG_PARTITION_TABLE_FILENAME="{dest.resolve().as_posix()}"',
    ]
    if fragment and Path(fragment).is_file():
        body.append(f"# from {fragment}")
        body.extend(
            line.strip()
            for line in Path(fragment).read_text("utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        )
    (overlay / "sdkconfig.partition").write_text("\n".join(body) + "\n", encoding="utf-8")
    lines.append(
        f"list(APPEND SDKCONFIG_DEFAULTS {(overlay / 'sdkconfig.partition').as_posix()})"
    )

(overlay / variant_name).write_text("\n".join(lines) + "\n", encoding="utf-8")
print(overlay)
PY
}

# The table the build is actually configured against, read back out of the
# saved sdkconfig. A build whose sdkconfig names anything but our copy has lost
# the override again -- exactly the cmods#29 regression -- and that has to be
# loud, because the image it produces looks fine and boots onto the wrong
# filesystem offset.
esp32_check_partition_sdkconfig() {
    local build_path="$1" expected="$2" got
    [[ -f "$build_path/sdkconfig" ]] || return 0
    got=$(sed -n 's/^CONFIG_PARTITION_TABLE_FILENAME="\(.*\)"$/\1/p' "$build_path/sdkconfig" | tail -n1)
    [[ -n "$got" ]] || got="(unset)"
    if [[ "$got" != "$expected" ]]; then
        echo >&2
        echo "error: the build is configured against a partition table we did not choose." >&2
        echo "  wanted: $expected" >&2
        echo "  got:    $got" >&2
        echo "  The sdkconfig override was lost on a reconfigure (cmods#29). Delete" >&2
        echo "  $build_path/sdkconfig and build again; if that does not fix it, the" >&2
        echo "  board overlay is not reaching SDKCONFIG_DEFAULTS last." >&2
        return 1
    fi
    return 0
}

esp32_print_partition_layout() {
    local used="$1" pinned="$2"
    [[ -f "$used" ]] || return 0
    echo
    echo "esp32 partition layout in this image:"
    grep -v '^[[:space:]]*#' "$used" | grep -v '^[[:space:]]*$' | sed 's/^/  /'
    if [[ -f "$pinned" ]] && ! diff -q "$used" "$pinned" >/dev/null 2>&1; then
        echo
        echo "  WARNING: this is NOT the pinned table in $pinned." >&2
        echo "  A board flashed with this image gets a different filesystem offset" >&2
        echo "  from one flashed with an image built against the pinned table, and" >&2
        echo "  nothing at boot will say so (cmods#30)." >&2
    fi
    echo
}

# Work out the table that would fit and write it to a destination of the
# caller's choosing. It never writes the file it read: that file is a board's
# data format, not a build artifact (cmods#30).
esp32_resize_partition_table() {
    local log_file="$1" source_csv="$2" dest_csv="$3"
    python3 - "$log_file" "$source_csv" "$dest_csv" <<'PY'
import re
import sys
from pathlib import Path

log_path, override, dest = map(Path, sys.argv[1:])
text = log_path.read_text("utf-8", "replace")
image_match = re.search(
    r"app partition is too small for binary \S+ size (0x[0-9a-fA-F]+)", text
)
if not image_match:
    raise SystemExit(1)
part_match = re.search(
    r"Part '([^']+)'.*?@\s*(0x[0-9a-fA-F]+)\s+size\s+"
    r"(0x[0-9a-fA-F]+)\s+\(overflow\s+(0x[0-9a-fA-F]+)\)",
    text,
)
part_name = part_match.group(1) if part_match else "factory"

if not override.is_file():
    raise SystemExit(1)
source = override

def number(value):
    value = value.strip()
    if value.lower().endswith("k"):
        return int(value[:-1], 0) * 1024
    if value.lower().endswith("m"):
        return int(value[:-1], 0) * 1024 * 1024
    return int(value, 0)

rows = []
for raw in source.read_text("utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    fields = [field.strip() for field in line.split(",")]
    fields.extend([""] * (6 - len(fields)))
    rows.append(fields[:6])

index = next((i for i, row in enumerate(rows) if row[0] == part_name), None)
if index is None:
    index = next((i for i, row in enumerate(rows) if row[1] == "app"), None)
if index is None:
    raise SystemExit(1)

align = 0x10000
headroom = 0x40000
image_size = int(image_match.group(1), 16)
new_size = (image_size + align - 1) & ~(align - 1)
new_size = (new_size + headroom + align - 1) & ~(align - 1)
rows[index][4] = hex(new_size)
cursor = number(rows[index][3]) + new_size
for row in rows[index + 1 :]:
    row[3] = hex(cursor)
    cursor += number(row[4])

dest.parent.mkdir(parents=True, exist_ok=True)
body = [
    "# Name, Type, SubType, Offset, Size, Flags",
    f"# Generated by build_mp.sh from {source}: '{rows[index][0]}' grown to",
    f"# {hex(new_size)} for an image of {hex(image_size)}. Every partition after it",
    "# moved, including the filesystem.",
    "",
]
body.extend(", ".join(row).rstrip(", ") for row in rows)
dest.write_text("\n".join(body) + "\n", encoding="utf-8")
print(hex(new_size))
PY
}

print_build_outputs() {
    local dir
    dir=$(build_dir)
    [[ -n "$dir" && -d "$dir" ]] || return 0

    local -a outputs=()
    local name f
    for name in firmware.uf2 firmware.bin firmware.hex micropython; do
        f="$dir/$name"
        [[ -f "$f" ]] && outputs+=("$f")
    done

    if [[ ${#outputs[@]} -eq 0 ]]; then
        while IFS= read -r -d '' f; do
            outputs+=("$f")
        done < <(find "$dir" -maxdepth 1 -type f \( -name 'firmware.*' -o -name '*.uf2' \) -print0 2>/dev/null | sort -z)
    fi

    [[ ${#outputs[@]} -gt 0 ]] || return 0

    echo
    echo "Build output:"
    for f in "${outputs[@]}"; do
        echo "  $f"
    done
    echo
}

esp32_board_flash_offset() {
  local board_json offset="0x0"
  [[ -n "$BOARD" ]] || { echo "$offset"; return 0; }
  board_json="$PORT_DIR/boards/$BOARD/board.json"
  [[ -f "$board_json" ]] || { echo "$offset"; return 0; }
  offset=$(python3 - "$board_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

print(data.get("deploy_options", {}).get("flash_offset", "0x0"))
PY
) || offset="0x0"
  echo "$offset"
}

offer_esp32_flash() {
    [[ "$PORT" == esp32 ]] || return 0
    [[ -t 0 ]] || return 0

    local firmware flash_offset
    firmware="$(build_dir)/firmware.bin"
    [[ -f "$firmware" ]] || return 0

    flash_offset=$(esp32_board_flash_offset)

    echo
    echo "Flash command:"
    echo "    esptool -b 460800 --before default_reset --after hard_reset write_flash $flash_offset $firmware"
    echo
    echo "To flash your device now, put it in bootloader mode and press Y."
    read -r -p "[y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        esptool -b 460800 --before default_reset --after hard_reset write_flash "$flash_offset" "$firmware"
    fi
    echo
}

# 1) Port
if [[ -z "$PORT" && -t 0 ]]; then
    mapfile -t _ports < <(list_ports | sort)
    [[ ${#_ports[@]} -gt 0 ]] || { echo "No ports found." >&2; exit 1; }
    PORT=$(pick "Ports:" "${_ports[@]}")
elif [[ -z "$PORT" ]]; then
    echo "Port required (use --port or run interactively)." >&2
    exit 1
fi
PORT_DIR="$MP_DIR/ports/$PORT"
[[ -f "$PORT_DIR/Makefile" ]] || { echo "Invalid port: $PORT" >&2; exit 1; }

if [[ "$OS_DUPTERM_EXPLICIT" -eq 0 && "$PORT" == windows ]]; then
    OS_DUPTERM=0
fi

PORT_KIND=$(port_kind)

if [[ "$PORT" == webassembly && -n "$VARIANT" && -f "$WORKSPACE_DIR/variants/webassembly/$VARIANT/mpconfigvariant.mk" ]]; then
    VARIANT_DIR="$WORKSPACE_DIR/variants/webassembly/$VARIANT"
fi

# 2) Board or variant selection
case "$PORT_KIND" in
    boards)
        mapfile -t _boards < <(list_boards | sort)
        [[ ${#_boards[@]} -gt 0 ]] || { echo "No boards found for port: $PORT" >&2; exit 1; }
        if [[ -z "$BOARD" && -t 0 ]]; then
            BOARD=$(pick "Boards for $PORT:" "${_boards[@]}")
        elif [[ -z "$BOARD" ]]; then
            echo "Board required for port $PORT (use --board or run interactively)." >&2
            exit 1
        fi
        mapfile -t _variants < <(list_board_variants "$PORT_DIR/boards/$BOARD" | sort)
        if [[ ${#_variants[@]} -gt 0 && -z "$VARIANT" && -t 0 ]]; then
            VARIANT=$(pick "Board variants for $BOARD:" "${_variants[@]}")
        fi
        ;;
    variants)
        mapfile -t _variants < <(list_port_variants | sort)
        [[ ${#_variants[@]} -gt 0 ]] || { echo "No variants found for port: $PORT" >&2; exit 1; }
        if [[ -z "$VARIANT" && -t 0 ]]; then
            VARIANT=$(pick "Variants for $PORT:" "${_variants[@]}")
        elif [[ -z "$VARIANT" ]]; then
            VARIANT=standard
        fi
        ;;
esac

if [[ "$MP_BUILD_DEBUG" -eq 1 ]]; then
    apply_esp32_debug_variant
fi

# Point the static cmods/manifest-micropython.py at the upstream freeze make would pick.
export FROZEN_MANIFEST_UPSTREAM
FROZEN_MANIFEST_UPSTREAM=$(resolve_upstream_frozen_manifest)
if [[ "$FROZEN_MANIFEST_EXPLICIT" -eq 0 ]]; then
    FROZEN_MANIFEST="$WORKSPACE_DIR/manifest-micropython.py"
fi
echo "Frozen manifest: $FROZEN_MANIFEST"
echo "  FROZEN_MANIFEST_UPSTREAM=$FROZEN_MANIFEST_UPSTREAM"

# What this firmware is being built from, frozen into it, so a board can be
# asked the question the desktop gates can already ask of a bin/ binary
# (cmods#36). A board has no file beside it; the answer has to be inside the
# image or it does not exist.
#
# Here rather than anywhere else because this is the point where the target
# and the overlay set are both known and nothing has been compiled yet, and
# because this script already knows every linked usermod -- the same set
# provenance.py derives, never a list somebody maintains.
#
# `|| true`, and the generator swallows its own failures as well: a build that
# cannot say what it is made of is worse than one that can, and far better
# than a build that does not happen. manifest-micropython.py freezes the file
# only if it is there, so the whole feature fails to nothing.
if [[ -x "$(command -v python3 || true)" ]]; then
    python3 "$WORKSPACE_DIR/scripts/provenance.py" freeze \
        --target "$PORT${BOARD:+/$BOARD}${VARIANT:+/$VARIANT}" \
        --port "$PORT" || true
fi

ensure_windows_cross_compile
ensure_windows_sdl2_env
apply_micropython_cmods_patches
apply_micropython_icon

# The esp32 partition table reaches the build as a generated board overlay
# (BOARD_DIR=), so it has to exist before the make command line is assembled or
# printed.
ESP32_OVERLAY_DIR=""
esp32_override=""
if [[ "$PORT" == esp32 && -n "$BOARD" ]]; then
    esp32_override=$(esp32_partition_override)
    if [[ -f "$esp32_override" ]]; then
        echo "esp32 partition table: $esp32_override"
        ESP32_OVERLAY_DIR=$(esp32_prepare_board_overlay "$esp32_override" "${esp32_override%.csv}.sdkconfig")
        echo "esp32 board overlay:   $ESP32_OVERLAY_DIR"
    else
        echo "WARNING: no esp32 partition table found at $esp32_override (BOARD=${BOARD}${VARIANT:+ VARIANT=$VARIANT}); building with the port's default partition table."
    fi
fi

print_rerun_hint
print_make_commands

make_args=(
    FROZEN_MANIFEST="$FROZEN_MANIFEST"
)
# MP_MAKE_EXTRA: extra VAR=VALUE words for the make command line (word-split
# on purpose). Needed where an env var cannot override a port's plain `=`
# assignment — e.g. the vst3 unix engine passes MICROPY_PY_SOCKET=0
# MICROPY_PY_SSL=0 MICROPY_PY_FFI=0 against ports/unix/mpconfigport.mk.
# A BOARD_DIR= in here is the board our generated overlay includes, so it must
# not also reach make -- the overlay replaces it.
if [[ -n "${MP_MAKE_EXTRA:-}" ]]; then
    for _extra_word in ${MP_MAKE_EXTRA}; do
        if [[ "$_extra_word" == BOARD_DIR=* && -n "$ESP32_OVERLAY_DIR" ]]; then
            continue
        fi
        make_args+=("$_extra_word")
    done
    unset _extra_word
fi
[[ -n "${CROSS_COMPILE:-}" ]] && make_args+=(CROSS_COMPILE="$CROSS_COMPILE")
[[ -n "${SDL2_DEV:-}" ]] && make_args+=(SDL2_DEV="$SDL2_DEV")
if is_truthy "$OS_DUPTERM" && [[ "$PORT" == unix || "$PORT" == windows || "$PORT" == webassembly ]]; then
    make_args+=(CFLAGS_EXTRA="-DMICROPY_PY_OS_DUPTERM=${OS_DUPTERM_SLOTS}")
    echo "os.dupterm: enabled (${OS_DUPTERM_SLOTS} slot(s))"
elif is_truthy "$OS_DUPTERM"; then
    echo "os.dupterm: enabled in port mpconfig (no CFLAGS override)"
else
    if [[ "$PORT" == windows && "$OS_DUPTERM_EXPLICIT" -eq 0 ]]; then
        echo "os.dupterm: disabled (windows port default)"
    else
        echo "os.dupterm: disabled (OS_DUPTERM=0)"
    fi
fi
case "$PORT_KIND" in
    boards)
        [[ -n "$BOARD" ]] && make_args+=(BOARD="$BOARD")
        [[ -n "$VARIANT" ]] && make_args+=(BOARD_VARIANT="$VARIANT")
        [[ -n "$ESP32_OVERLAY_DIR" ]] && make_args+=(BOARD_DIR="$ESP32_OVERLAY_DIR")
        ;;
    variants)
        if [[ -n "$VARIANT_DIR" ]]; then
            make_args+=(VARIANT_DIR="$VARIANT_DIR")
        elif [[ -n "$VARIANT" ]]; then
            make_args+=(VARIANT="$VARIANT")
        fi
        ;;
esac

ensure_idf_env
esp32_displayif_preflight
ensure_emsdk_env
ensure_rp2_picotool
ensure_host_mpy_cross

echo "Building: port=$PORT${BOARD:+ board=$BOARD}${VARIANT:+ variant=$VARIANT}"
echo

pushd "$PORT_DIR" >/dev/null

# A failed CMake *configure* leaves a build directory with no CMakeCache.txt.
# idf.py then refuses to clean it -- "doesn't seem to be a CMake build
# directory. Refusing to automatically delete files in this directory" -- and
# make reports that as a bare "Error 2", which reads like a compile failure
# rather than "delete this directory". Every later run fails the same way until
# someone removes it by hand. Remove the husk here instead; there is nothing in
# it worth keeping.
# ...and only on the CMake-driven ports. A Makefile port's build directory has
# no CMakeCache.txt and never will, so the test below would call every healthy
# unix/windows build directory a husk and delete it.
stale_build_dir=$(build_dir)
if [[ "$PORT" != esp32 && "$PORT" != rp2 ]]; then
    stale_build_dir_is_cmake=0
else
    stale_build_dir_is_cmake=1
fi
if [[ "$stale_build_dir_is_cmake" -eq 1 && -n "$stale_build_dir" && -d "$stale_build_dir" && ! -f "$stale_build_dir/CMakeCache.txt" ]]; then
    echo "removing an incomplete build directory left by a failed configure: $stale_build_dir"
    rm -rf "$stale_build_dir"
fi

# On esp32 `make clean` is `idf.py fullclean`, which deletes
# managed_components/ for the WHOLE port rather than for this build directory.
# A build directory that does not exist yet has nothing to clean, so paying that
# is pure loss (cmods#29).
if ! is_truthy "$MP_CLEAN"; then
    echo "clean: skipped (MP_CLEAN=0)"
elif [[ -n "$stale_build_dir" && ! -d "$stale_build_dir" ]]; then
    echo "clean: skipped (nothing at $stale_build_dir yet)"
else
    make -j clean "${make_args[@]}"
fi
make -j submodules "${make_args[@]}"
build_rc=0
if [[ "$PORT" == esp32 ]]; then
    esp32_build_dir=$(build_dir)
    # An sdkconfig left in the build directory is treated by the IDF as the
    # user's current configuration and beats SDKCONFIG_DEFAULTS, so one failed
    # run can pin the wrong table for every run after it. Ours is generated;
    # drop it and let the defaults win.
    rm -f "$esp32_build_dir/sdkconfig"
    if [[ -n "$ESP32_OVERLAY_DIR" ]]; then
        esp32_overlay_table="$ESP32_OVERLAY_DIR/partitions.csv"
    else
        esp32_overlay_table=""
    fi
    esp32_build_log=$(mktemp /tmp/build-mp-esp32.XXXXXX.log)
    set +e
    make -j all "${make_args[@]}" 2>&1 | tee "$esp32_build_log"
    build_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$build_rc" -ne 0 && -n "$esp32_overlay_table" ]]; then
        esp32_suggested="$esp32_build_dir/partitions-autosized.csv"
        if new_app_size=$(esp32_resize_partition_table "$esp32_build_log" "$esp32_overlay_table" "$esp32_suggested"); then
            if is_truthy "$MP_AUTOSIZE"; then
                cp "$esp32_suggested" "$esp32_overlay_table"
                echo
                echo "esp32 autosize: app -> $new_app_size, in this build's own copy of the table."
                echo "  $esp32_override is unchanged. The image now has a DIFFERENT layout"
                echo "  from one built against the pinned table -- do not mix them on a board"
                echo "  whose filesystem you want to keep (cmods#30)."
                echo
                set +e
                make -j all "${make_args[@]}"
                build_rc=$?
                set -e
            else
                echo >&2
                echo "error: the app does not fit the partition table this board is pinned to." >&2
                echo "  pinned table: $esp32_override" >&2
                echo "  'factory' would have to grow to $new_app_size" >&2
                echo "  a table that fits: $esp32_suggested" >&2
                echo >&2
                echo "  Growing the app partition slides every partition after it, including" >&2
                echo "  the filesystem, so a board flashed with the new layout comes up on a" >&2
                echo "  different (usually empty, sometimes unmountable) filesystem and" >&2
                echo "  nothing says so. That is a decision, not a build fix-up (cmods#30)." >&2
                echo >&2
                echo "  Either edit $esp32_override by hand and reflash every board that" >&2
                echo "  carries it, or re-run with MP_AUTOSIZE=1 for a one-off image built" >&2
                echo "  against the enlarged table, leaving the pinned one alone." >&2
                echo >&2
            fi
        fi
    fi
    unlink "$esp32_build_log"
    if [[ "$build_rc" -eq 0 && -n "$esp32_overlay_table" ]]; then
        esp32_check_partition_sdkconfig "$esp32_build_dir" "$(readlink -f "$esp32_overlay_table")" || build_rc=1
    fi
else
    make -j all "${make_args[@]}"
fi
popd >/dev/null

if [[ "$build_rc" -ne 0 ]]; then
    exit "$build_rc"
fi

if [[ "$PORT" == esp32 && -n "${esp32_overlay_table:-}" ]]; then
    esp32_print_partition_layout "$esp32_overlay_table" "$esp32_override"
fi

print_build_outputs
offer_esp32_flash
