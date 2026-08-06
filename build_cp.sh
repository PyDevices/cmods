#!/usr/bin/env bash
# Build any CircuitPython port/board/variant (cmods workspace orchestrator).
#
# Usage:
#   ./build_cp.sh [--port PORT] [--board BOARD] [--variant VARIANT]
#
# Environment: WORKSPACE_DIR, CP_DIR, LV_CP_MOD_DIR, PORT, BOARD, VARIANT,
#              CP_BUILD_VENV
#
# Before make, always applies (when present / required):
#   1. usdl2/apply_cp_unix_usdl_patches.sh          (unix only)
#   2. pygraphics/apply_cp_unix_pygraphics_patches.sh (unix only)
#   3. lv_circuitpython_mod/apply_cp_lvgl_patches.sh
#
# Each apply script also works standalone (circuitpython + that one repo as
# siblings; set CP_DIR if needed) — no cmods required for manual patch+make.
#
# Creates $LV_CP_MOD_DIR/.venv and installs circuitpython/requirements-dev.txt
# if needed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_CP="${BUILD_CP:-$SCRIPT_DIR/build_cp.sh}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$SCRIPT_DIR}"
CP_DIR="${CP_DIR:-$WORKSPACE_DIR/circuitpython}"
LV_CP_MOD_DIR="${LV_CP_MOD_DIR:-$WORKSPACE_DIR/lv_circuitpython_mod}"

# CircuitPython uses shared-bindings + circuitpython.mk, not MicroPython
# USER_C_MODULES. Clear a leaked env from sibling build_mp.sh / shells so
# lv_micropython_cmod is not pulled into the CP compile.
# FROZEN_MANIFEST is re-set below for unix only (see resolve_unix_frozen_manifest).
unset USER_C_MODULES FROZEN_MANIFEST

PORT="${PORT:-}"
BOARD="${BOARD:-}"
VARIANT="${VARIANT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2"; shift 2 ;;
        --board)   BOARD="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--port PORT] [--board BOARD] [--variant VARIANT]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -d "$CP_DIR/ports" ]] || { echo "CircuitPython not found: $CP_DIR" >&2; exit 1; }

CP_REQUIREMENTS_DEV="${CP_REQUIREMENTS_DEV:-$CP_DIR/requirements-dev.txt}"
CP_BUILD_VENV="${CP_BUILD_VENV:-$LV_CP_MOD_DIR/.venv}"

ensure_espressif_env() {
    [[ "$PORT" == espressif ]] || return 0

    local idf_export="$PORT_DIR/esp-idf/export.sh"
    [[ -f "$idf_export" ]] || {
        echo "ESP-IDF export script not found: $idf_export" >&2
        exit 1
    }

    echo "Activating ESP-IDF environment..."
    # shellcheck disable=SC1090
    if ! . "$idf_export"; then
        echo "Failed to activate ESP-IDF. Install tools with:" >&2
        echo "  cd $PORT_DIR/esp-idf && ./install.sh" >&2
        exit 1
    fi
    # IDF export owns python3 (cmake / idf_component_manager). CircuitPython
    # make recipes use $(PYTHON) for qstr / web-workflow — keep the CP venv.
    if [[ -x "$CP_BUILD_VENV/bin/python" ]]; then
        export PYTHON="$CP_BUILD_VENV/bin/python"
    fi
}

ensure_cp_python_env() {
    [[ -f "$CP_REQUIREMENTS_DEV" ]] || {
        echo "CircuitPython dev requirements not found: $CP_REQUIREMENTS_DEV" >&2
        exit 1
    }

    if [[ ! -d "$CP_BUILD_VENV" ]]; then
        echo "Creating Python venv: $CP_BUILD_VENV"
        python3 -m venv "$CP_BUILD_VENV"
    fi

    echo "Ensuring CircuitPython dev requirements in venv..."
    if ! "$CP_BUILD_VENV/bin/pip" install -r "$CP_REQUIREMENTS_DEV"; then
        echo "Failed to install dev requirements." >&2
        echo "If minify_html failed, install Rust (see $CP_DIR/BUILDING.md)." >&2
        exit 1
    fi

    export PATH="$CP_BUILD_VENV/bin:$PATH"
}

pick() {
    local label="$1"; shift
    local -a items=("$@")
    local n i

    # Menu on stderr so stdout is only the chosen value (for VAR=$(pick ...)).
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
    for p in "$CP_DIR"/ports/*; do
        [[ -f "$p/Makefile" ]] && basename "$p"
    done
}

list_boards() {
    local port_dir="$CP_DIR/ports/$PORT" d
    for d in "$port_dir/boards"/*; do
        [[ -f "$d/mpconfigboard.mk" ]] && basename "$d"
    done
}

variants_dir() {
    local port_dir="$CP_DIR/ports/$PORT"
    if [[ -n "$BOARD" && -d "$port_dir/boards/$BOARD/variants" ]]; then
        echo "$port_dir/boards/$BOARD/variants"
    elif [[ -d "$port_dir/variants" ]]; then
        echo "$port_dir/variants"
    fi
}

list_variants() {
    local dir="$1" d
    for d in "$dir"/*; do
        [[ -f "$d/mpconfigvariant.mk" ]] && basename "$d"
    done
}

print_rerun_hint() {
    local -a cmd=("$BUILD_CP")
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

cp_user_config_make_opts() {
    CP_USER_CONFIG="${CP_USER_CONFIG:-$WORKSPACE_DIR/cp-user-config}"
    if [[ -d "$CP_USER_CONFIG" ]]; then
        printf '%s' "-I $(cd "$CP_USER_CONFIG" && pwd)"
    fi
}

print_make_commands() {
    local -a args=()
    local user_config
    user_config=$(cp_user_config_make_opts)
    [[ -n "$user_config" ]] && args+=("$user_config")
    [[ -n "$BOARD" ]] && args+=(BOARD="$BOARD")
    [[ -n "$VARIANT" ]] && args+=(VARIANT="$VARIANT")

    local reset="" bold="" yellow="" dim=""
    if [[ -t 1 ]]; then
        reset=$(tput sgr0)
        bold=$(tput bold)
        yellow=$(tput setaf 3)
        dim=$(tput dim)
    fi

    local quoted=""
    if [[ ${#args[@]} -gt 0 ]]; then
        quoted=" $(printf '%q ' "${args[@]}")"
    fi

    printf '\n\n'
    printf '%s%sRun make manually:%s\n' "$bold" "$yellow" "$reset"
    printf '%s  cd %q%s\n' "$dim" "$PORT_DIR" "$reset"
    if [[ "$PORT" == espressif ]]; then
        printf '%s  . ./esp-idf/export.sh%s\n' "$dim" "$reset"
    fi
    printf '%s  make -j clean%s%s\n' "$dim" "$quoted" "$reset"
    printf '%s  make -j submodules%s%s\n' "$dim" "$quoted" "$reset"
    printf '%s  make -j%s%s\n' "$dim" "$quoted" "$reset"
    printf '\n\n'
}

run_usdl2_patches() {
    [[ "$PORT" == unix ]] || return 0
    local usdl2_patch="$WORKSPACE_DIR/usdl2/apply_cp_unix_usdl_patches.sh"
    [[ -x "$usdl2_patch" ]] || {
        echo "usdl2 patch script not found: $usdl2_patch" >&2
        echo "Clone https://github.com/PyDevices/usdl2 as a sibling under WORKSPACE_DIR=$WORKSPACE_DIR." >&2
        exit 1
    }
    local -a patch_args=(--apply)
    if [[ -n "$VARIANT" ]]; then
        VARIANT="$VARIANT" "$usdl2_patch" "${patch_args[@]}"
    else
        "$usdl2_patch" "${patch_args[@]}"
    fi
}

run_pygraphics_patches() {
    [[ "$PORT" == unix ]] || return 0
    local pygraphics_patch="$WORKSPACE_DIR/pygraphics/apply_cp_unix_pygraphics_patches.sh"
    [[ -x "$pygraphics_patch" ]] || {
        echo "pygraphics patch script not found: $pygraphics_patch" >&2
        echo "Clone https://github.com/PyDevices/pygraphics as a sibling under WORKSPACE_DIR=$WORKSPACE_DIR." >&2
        exit 1
    }
    local -a patch_args=(--apply)
    if [[ -n "$VARIANT" ]]; then
        VARIANT="$VARIANT" "$pygraphics_patch" "${patch_args[@]}"
    else
        "$pygraphics_patch" "${patch_args[@]}"
    fi
}

run_lvgl_patches() {
    local lvgl_patch="$LV_CP_MOD_DIR/apply_cp_lvgl_patches.sh"
    [[ -x "$lvgl_patch" ]] || {
        echo "LVGL patch script not found: $lvgl_patch" >&2
        echo "Clone https://github.com/PyDevices/lv_circuitpython_mod as LV_CP_MOD_DIR (default: $WORKSPACE_DIR/lv_circuitpython_mod)." >&2
        exit 1
    }
    local -a apply_args=(--apply --port "$PORT")
    [[ -n "$BOARD" ]] && apply_args+=(--board "$BOARD")
    [[ -n "$VARIANT" ]] && apply_args+=(--variant "$VARIANT")

    "$lvgl_patch" "${apply_args[@]}"
}

build_dir() {
    if [[ -n "$VARIANT" ]]; then
        echo "$PORT_DIR/build-$VARIANT"
    elif [[ -n "$BOARD" ]]; then
        echo "$PORT_DIR/build-$BOARD"
    fi
}

print_build_outputs() {
    local dir
    dir=$(build_dir)
    [[ -n "$dir" && -d "$dir" ]] || return 0

    local -a outputs=()
    local name f
    for name in firmware.uf2 firmware.bin micropython circuitpython.uf2; do
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

# 1) Port
if [[ -z "$PORT" ]]; then
    mapfile -t _ports < <(list_ports | sort)
    [[ ${#_ports[@]} -gt 0 ]] || { echo "No ports found." >&2; exit 1; }
    PORT=$(pick "Ports:" "${_ports[@]}")
fi
PORT_DIR="$CP_DIR/ports/$PORT"
[[ -f "$PORT_DIR/Makefile" ]] || { echo "Invalid port: $PORT" >&2; exit 1; }

# 2) Board (only if this port has boards)
mapfile -t _boards < <(list_boards | sort)
if [[ ${#_boards[@]} -gt 0 && -z "$BOARD" ]]; then
    BOARD=$(pick "Boards for $PORT:" "${_boards[@]}")
fi

# 3) Variant (only if a variants directory exists)
if _vdir=$(variants_dir); then
    mapfile -t _variants < <(list_variants "$_vdir" | sort)
    if [[ ${#_variants[@]} -gt 0 && -z "$VARIANT" ]]; then
        VARIANT=$(pick "Variants:" "${_variants[@]}")
    fi
fi

run_usdl2_patches
run_pygraphics_patches
run_lvgl_patches
print_rerun_hint
print_make_commands

# Unix coverage/standard use variant manifests. Wrap them so we can freeze
# lib/display_driver.py. MCU ports keep CircuitPython's generated BUILD/manifest.py
# — do not override FROZEN_MANIFEST there.
resolve_unix_frozen_manifest() {
    local path=""
    if [[ -n "$VARIANT" && -f "$PORT_DIR/variants/$VARIANT/manifest.py" ]]; then
        path="$PORT_DIR/variants/$VARIANT/manifest.py"
    elif [[ -f "$PORT_DIR/variants/manifest.py" ]]; then
        path="$PORT_DIR/variants/manifest.py"
    else
        echo "No unix frozen manifest for variant=${VARIANT:-}" >&2
        exit 1
    fi
    (cd "$(dirname "$path")" && echo "$(pwd)/$(basename "$path")")
}

make_args=()
user_config=$(cp_user_config_make_opts)
[[ -n "$user_config" ]] && make_args+=("$user_config")
[[ -n "$BOARD" ]] && make_args+=(BOARD="$BOARD")
[[ -n "$VARIANT" ]] && make_args+=(VARIANT="$VARIANT")

if [[ "$PORT" == unix ]]; then
    export FROZEN_MANIFEST_UPSTREAM
    FROZEN_MANIFEST_UPSTREAM=$(resolve_unix_frozen_manifest)
    FROZEN_MANIFEST="$LV_CP_MOD_DIR/manifest.py"
    [[ -f "$FROZEN_MANIFEST" ]] || {
        echo "Frozen manifest not found: $FROZEN_MANIFEST" >&2
        exit 1
    }
    make_args+=(FROZEN_MANIFEST="$FROZEN_MANIFEST")
    echo "Frozen manifest: $FROZEN_MANIFEST"
    echo "  FROZEN_MANIFEST_UPSTREAM=$FROZEN_MANIFEST_UPSTREAM"
fi

ensure_cp_python_env
ensure_espressif_env

echo "Building: port=$PORT${BOARD:+ board=$BOARD}${VARIANT:+ variant=$VARIANT}"
[[ -n "$user_config" ]] && echo "User config: -I ${CP_USER_CONFIG:-$WORKSPACE_DIR/cp-user-config}"
echo

pushd "$PORT_DIR" >/dev/null
make -j clean "${make_args[@]}"
make -j submodules "${make_args[@]}"
make -j "${make_args[@]}"
popd >/dev/null

print_build_outputs
