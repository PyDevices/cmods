#!/usr/bin/env bash
# Build any MicroPython port/board/variant with cmods user C modules.
#
# Usage:
#   ./build_mp.sh [--port PORT] [--board BOARD] [--variant VARIANT]
#
# Environment: WORKSPACE_DIR, MP_DIR, IDF_DIR, EMSDK_DIR, PORT, BOARD, VARIANT,
#              USER_C_MODULES, FROZEN_MANIFEST, OS_DUPTERM, OS_DUPTERM_SLOTS
#
# FROZEN_MANIFEST defaults to this repo's manifest.py. build_mp.sh also exports
# FROZEN_MANIFEST_UPSTREAM to the MicroPython freeze file for the selected
# port/board/variant; manifest.py includes that path (no generated wrapper).
# Set FROZEN_MANIFEST explicitly to use a different top-level manifest.
#
# OS_DUPTERM defaults to 1 on unix and webassembly; the windows port disables it
# by default (link fails with undefined mp_interrupt_char). Set OS_DUPTERM=1 or
# pass --os-dupterm to force it on windows. On enabled desktop ports this passes
# -DMICROPY_PY_OS_DUPTERM=<slots> via CFLAGS_EXTRA (embedded ports usually
# enable it in mpconfigport.h already).
#
# webassembly: sources EMSDK_DIR/emsdk_env.sh (like esp32 + IDF_DIR/export.sh).
# Default EMSDK_DIR is $WORKSPACE_DIR/../../other/emsdk (gh/other/emsdk).
# LVGL user modules set -Wno-unused-function in CFLAGS_USERMOD, but the
# webassembly port appends -Werror after py.mk merges user-module flags; emcc
# then treats unused static inlines in generated lvgl_micropython.c as errors. The local
# patch in micropython/ports/webassembly/Makefile appends -Wno-unused-function
# after -Werror so it takes effect.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_MP="${BUILD_MP:-$SCRIPT_DIR/build_mp.sh}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$SCRIPT_DIR}"
MP_DIR="${MP_DIR:-$WORKSPACE_DIR/micropython}"
USER_C_MODULES="${USER_C_MODULES:-$WORKSPACE_DIR}"
IDF_DIR="${IDF_DIR:-$WORKSPACE_DIR/../esp-idf}"
EMSDK_DIR="${EMSDK_DIR:-$WORKSPACE_DIR/../../other/emsdk}"

# Track explicit FROZEN_MANIFEST before applying a default.
FROZEN_MANIFEST_EXPLICIT=0
if [[ -v FROZEN_MANIFEST ]]; then
    FROZEN_MANIFEST_EXPLICIT=1
else
    FROZEN_MANIFEST="$WORKSPACE_DIR/manifest.py"
fi

PORT="${PORT:-}"
BOARD="${BOARD:-}"
VARIANT="${VARIANT:-}"
OS_DUPTERM_EXPLICIT=0
if [[ -v OS_DUPTERM ]]; then
    OS_DUPTERM_EXPLICIT=1
else
    OS_DUPTERM=1
fi
OS_DUPTERM_SLOTS="${OS_DUPTERM_SLOTS:-1}"

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
        --no-os-dupterm) OS_DUPTERM=0; OS_DUPTERM_EXPLICIT=1; shift ;;
        --os-dupterm) OS_DUPTERM=1; OS_DUPTERM_EXPLICIT=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--port PORT] [--board BOARD] [--variant VARIANT]

Build MicroPython with user C modules from the cmods workspace.

Options:
  --port PORT        MicroPython port (e.g. unix, esp32, rp2)
  --board BOARD      Board name for board-based ports
  --variant VARIANT  Board variant (board ports) or build variant (unix, etc.)

Environment:
  WORKSPACE_DIR      cmods workspace root (default: script directory)
  MP_DIR             MicroPython tree (default: \$WORKSPACE_DIR/micropython)
  IDF_DIR            ESP-IDF install for esp32 (default: \$WORKSPACE_DIR/../esp-idf)
  EMSDK_DIR          Emscripten SDK for webassembly (default: \$WORKSPACE_DIR/../../other/emsdk)
  USER_C_MODULES     Path passed to make (default: \$WORKSPACE_DIR)
  FROZEN_MANIFEST    Top-level frozen manifest (default: \$WORKSPACE_DIR/manifest.py)
  FROZEN_MANIFEST_UPSTREAM  Set by this script to the MicroPython upstream freeze
                     file for the selected port/board/variant (read by manifest.py)
  PORT, BOARD, VARIANT  Same as the corresponding options
  OS_DUPTERM         Enable os.dupterm on unix/webassembly (default: 1); windows default: 0
  OS_DUPTERM_SLOTS   dupterm slot count for desktop ports (default: 1)
  SDL2_DEV           Unpacked SDL2 MinGW development ZIP root (windows port + usdl2)
  PICOTOOL_FETCH_FROM_GIT_PATH  Cache dir for prebuilt picotool (rp2 port)
  picotool_DIR       Prebuilt picotool cmake package dir (rp2 port)
  DISPLAYIF_SKIP_SPIRAM_CHECK  Set to 1 to skip esp32 PSRAM warning when displayif is present

Options:
  --no-os-dupterm    Disable os.dupterm (same as OS_DUPTERM=0)
  --os-dupterm       Enable os.dupterm (override windows default)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

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
            if [[ -n "$VARIANT" && -f "$PORT_DIR/variants/$VARIANT/manifest.py" ]]; then
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
    local other_dir="$WORKSPACE_DIR/../../other"
    local -a candidates=()
    [[ -n "${SDL2_DEV:-}" ]] && candidates+=("$SDL2_DEV")
    shopt -s nullglob
    candidates+=("$other_dir"/SDL2-[0-9]*)
    shopt -u nullglob
    [[ -d "$other_dir/SDL2" ]] && candidates+=("$other_dir/SDL2")
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
            echo "Windows port + usdl2 requires the SDL2 MinGW development ZIP." >&2
            echo "Unpack it (e.g. to \$WORKSPACE_DIR/../../other/SDL2-2.30.10) and run:" >&2
            echo "  export SDL2_DEV=\$WORKSPACE_DIR/../../other/SDL2-2.30.10" >&2
            echo "See usdl2/README.md" >&2
            exit 1
        fi
    fi

    local prefix="$SDL2_DEV/$triplet"
    if [[ ! -f "$prefix/include/SDL2/SDL.h" || ! -f "$prefix/lib/libSDL2.a" ]]; then
        echo "SDL2 MinGW development tree not found under: $prefix" >&2
        echo "Unpack the SDL2 MinGW development ZIP and set SDL2_DEV to its root." >&2
        echo "See usdl2/README.md" >&2
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
        echo "Set IDF_DIR or clone ESP-IDF beside the workspace." >&2
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

    local board_dir sdkconfig board_defaults merged
    board_dir="$PORT_DIR/boards/$BOARD"
    sdkconfig="$PORT_DIR/build-$BOARD/sdkconfig"
    board_defaults="$board_dir/sdkconfig.board"

  if [[ -f "$board_defaults" ]]; then
      merged="$board_defaults"
  elif [[ -f "$board_dir/sdkconfig.defaults" ]]; then
      merged="$board_dir/sdkconfig.defaults"
  else
      merged=""
  fi

  local needs_psram=0
  case "${BOARD:-}" in
      ESP32_GENERIC_P4|ESP32_GENERIC_S3|*S3*|*P4*) needs_psram=1 ;;
  esac

  if [[ $needs_psram -eq 0 ]]; then
      return 0
  fi

  local spiram_ok=0
  if [[ -f "$sdkconfig" ]] && grep -qE '^CONFIG_SPIRAM=y' "$sdkconfig" 2>/dev/null; then
      spiram_ok=1
  elif [[ -n "$merged" ]] && grep -qE '^CONFIG_SPIRAM=y' "$merged" 2>/dev/null; then
      spiram_ok=1
  fi

  if [[ $spiram_ok -eq 1 ]]; then
      echo "displayif preflight: CONFIG_SPIRAM enabled for $BOARD"
      return 0
  fi

  echo "warning: displayif large framebuffers (rgbframebuffer, mipidsi) expect PSRAM on $BOARD." >&2
  echo "  Enable CONFIG_SPIRAM in the board sdkconfig / menuconfig before building with displayif." >&2
  if [[ -n "$merged" ]]; then
      echo "  Checked: $merged" >&2
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

rp2_picotool_platform_asset() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64) echo "picotool-2.1.1-x86_64-lin.tar.gz" ;;
                aarch64|arm64) echo "picotool-2.1.1-aarch64-lin.tar.gz" ;;
            esac
            ;;
        Darwin) echo "picotool-2.1.1-mac.zip" ;;
        MINGW*|MSYS*|CYGWIN*) echo "picotool-2.1.1-x64-win.zip" ;;
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
        if picotool version 2>/dev/null | grep -Eq 'v2\.(1\.[1-9]|[2-9])'; then
            echo "Using installed picotool: $(command -v picotool)"
            return 0
        fi
    fi

    local cache_root asset url archive extract_dir picotool_cfg
    cache_root="${PICOTOOL_FETCH_FROM_GIT_PATH:-${WORKSPACE_DIR}/.cache/picotool}"
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

    url="https://github.com/raspberrypi/pico-sdk-tools/releases/download/v2.1.1-0/$asset"
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
        echo "Set EMSDK_DIR (default: \$WORKSPACE_DIR/../../other/emsdk)." >&2
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

make_target_args() {
    local -a args=(
        USER_C_MODULES="$USER_C_MODULES"
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
            ;;
        variants)
            [[ -n "$VARIANT" ]] && args+=(VARIANT="$VARIANT")
            ;;
    esac
    printf '%q ' "${args[@]}"
}

print_rerun_hint() {
    local -a cmd=("$BUILD_MP")
    cmd+=(--port "$PORT")
    [[ -n "$BOARD" ]] && cmd+=(--board "$BOARD")
    [[ -n "$VARIANT" ]] && cmd+=(--variant "$VARIANT")

    local reset="" bold="" cyan=""
    if [[ -t 1 ]]; then
        reset=$(tput sgr0)
        bold=$(tput bold)
        cyan=$(tput setaf 6)
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
        reset=$(tput sgr0)
        bold=$(tput bold)
        yellow=$(tput setaf 3)
        dim=$(tput dim)
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

# Point the static cmods/manifest.py at the upstream freeze make would pick.
export FROZEN_MANIFEST_UPSTREAM
FROZEN_MANIFEST_UPSTREAM=$(resolve_upstream_frozen_manifest)
if [[ "$FROZEN_MANIFEST_EXPLICIT" -eq 0 ]]; then
    FROZEN_MANIFEST="$WORKSPACE_DIR/manifest.py"
fi
echo "Frozen manifest: $FROZEN_MANIFEST"
echo "  FROZEN_MANIFEST_UPSTREAM=$FROZEN_MANIFEST_UPSTREAM"

ensure_windows_cross_compile
ensure_windows_sdl2_env

print_rerun_hint
print_make_commands

make_args=(
    USER_C_MODULES="$USER_C_MODULES"
    FROZEN_MANIFEST="$FROZEN_MANIFEST"
)
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
        ;;
    variants)
        [[ -n "$VARIANT" ]] && make_args+=(VARIANT="$VARIANT")
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
make -j clean "${make_args[@]}"
make -j submodules "${make_args[@]}"
make -j all "${make_args[@]}"
popd >/dev/null

print_build_outputs
offer_esp32_flash
