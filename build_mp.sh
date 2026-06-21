#!/usr/bin/env bash
# Build any MicroPython port/board/variant with cmods user C modules.
#
# Usage:
#   ./build_mp.sh [--port PORT] [--board BOARD] [--variant VARIANT]
#
# Environment: WORKSPACE_DIR, MP_DIR, IDF_DIR, PORT, BOARD, VARIANT,
#              USER_C_MODULES, FROZEN_MANIFEST
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_MP="${BUILD_MP:-$SCRIPT_DIR/build_mp.sh}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$SCRIPT_DIR}"
MP_DIR="${MP_DIR:-$WORKSPACE_DIR/micropython}"
USER_C_MODULES="${USER_C_MODULES:-$WORKSPACE_DIR}"
FROZEN_MANIFEST="${FROZEN_MANIFEST:-$WORKSPACE_DIR/manifest.py}"
IDF_DIR="${IDF_DIR:-$WORKSPACE_DIR/../esp-idf}"

PORT="${PORT:-}"
BOARD="${BOARD:-}"
VARIANT="${VARIANT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2"; shift 2 ;;
        --board)   BOARD="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
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
  USER_C_MODULES     Path passed to make (default: \$WORKSPACE_DIR)
  FROZEN_MANIFEST    Frozen manifest path (default: \$WORKSPACE_DIR/manifest.py)
  PORT, BOARD, VARIANT  Same as the corresponding options
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

make_target_args() {
    local -a args=(
        USER_C_MODULES="$USER_C_MODULES"
        FROZEN_MANIFEST="$FROZEN_MANIFEST"
    )
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

offer_esp32_flash() {
    [[ "$PORT" == esp32 ]] || return 0
    [[ -t 0 ]] || return 0

    local firmware
    firmware="$(build_dir)/firmware.bin"
    [[ -f "$firmware" ]] || return 0

    echo
    echo "Flash command:"
    echo "    esptool -b 460800 --before default_reset --after hard_reset write_flash 0x0 $firmware"
    echo
    echo "To flash your device now, put it in bootloader mode and press Y."
    read -r -p "[y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        esptool -b 460800 --before default_reset --after hard_reset write_flash 0x0 "$firmware"
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

print_rerun_hint
print_make_commands

make_args=(
    USER_C_MODULES="$USER_C_MODULES"
    FROZEN_MANIFEST="$FROZEN_MANIFEST"
)
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

echo "Building: port=$PORT${BOARD:+ board=$BOARD}${VARIANT:+ variant=$VARIANT}"
echo

pushd "$PORT_DIR" >/dev/null
make -j clean "${make_args[@]}"
make -j submodules "${make_args[@]}"
make -j all "${make_args[@]}"
popd >/dev/null

print_build_outputs
offer_esp32_flash
