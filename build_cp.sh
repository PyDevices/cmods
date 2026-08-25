#!/usr/bin/env bash
# Build any CircuitPython port/board/variant (cmods workspace orchestrator).
#
# Usage:
#   ./build_cp.sh                                          # interactive
#   ./build_cp.sh [--port PORT] [--board BOARD] [--variant VARIANT]
#
# Environment: WORKSPACE_DIR, CP_DIR, PORT, BOARD, VARIANT, CP_BUILD_VENV
#
# Before make, auto-discovers and runs every sibling ``*/apply_cp_patches.sh``
# (set CP_SKIP_EXT="name1 name2" to leave some out)
# (optional — missing extensions are skipped). Each script also works
# standalone (circuitpython + that one repo as siblings; set CP_DIR if needed).
#
# Frozen Python: always uses \$WORKSPACE_DIR/manifest-circuitpython.py, which
# includes manifest-user.py, optional sibling ``*/manifest.py`` files, then
# FROZEN_MANIFEST_UPSTREAM (unix variant/port manifest, or generated
# BUILD/manifest.py when FROZEN_MPY_DIRS is nonempty).
#
# Creates \$WORKSPACE_DIR/.venv and installs circuitpython/requirements-dev.txt
# if needed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_CP="${BUILD_CP:-$SCRIPT_DIR/build_cp.sh}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$SCRIPT_DIR}"
CP_DIR="${CP_DIR:-$WORKSPACE_DIR/circuitpython}"
export WORKSPACE_DIR CP_DIR

# CircuitPython uses shared-bindings + circuitpython.mk, not MicroPython
# USER_C_MODULES. Clear a leaked env from sibling build_mp.sh / shells.
unset USER_C_MODULES FROZEN_MANIFEST

PORT="${PORT:-}"
BOARD="${BOARD:-}"
VARIANT="${VARIANT:-}"
CP_SKIP_EXT="${CP_SKIP_EXT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2"; shift 2 ;;
        --board)   BOARD="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--port PORT] [--board BOARD] [--variant VARIANT]"
            echo "  With no args (and a TTY), prompts for port / board / variant."
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -d "$CP_DIR/ports" ]] || { echo "CircuitPython not found: $CP_DIR" >&2; exit 1; }

CP_REQUIREMENTS_DEV="${CP_REQUIREMENTS_DEV:-$CP_DIR/requirements-dev.txt}"
CP_BUILD_VENV="${CP_BUILD_VENV:-$WORKSPACE_DIR/.venv}"
FROZEN_MANIFEST="$WORKSPACE_DIR/manifest-circuitpython.py"

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
        echo "If minify_html failed, install Rust (see $CP_DIR/building.md)." >&2
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
    # Include dir containing user_post_mpconfigport.mk (default: workspace root).
    local mk="${USER_POST_MPCONFIGPORT_MK:-$WORKSPACE_DIR/user_post_mpconfigport.mk}"
    if [[ -n "${CP_USER_CONFIG:-}" && -d "$CP_USER_CONFIG" ]]; then
        printf '%s' "-I $(cd "$CP_USER_CONFIG" && pwd)"
    elif [[ -f "$mk" ]]; then
        printf '%s' "-I $(cd "$(dirname "$mk")" && pwd)"
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

run_optional_cp_patches() {
    local script name
    local -a found=()
    # CP_SKIP_EXT: space/comma separated extension directory names to leave out
    # of this build, e.g. CP_SKIP_EXT=lvgl-circuitpython for a board that has no
    # room for LVGL (or where it does not compile).
    local skip=" ${CP_SKIP_EXT//,/ } "
    shopt -s nullglob
    for script in "$WORKSPACE_DIR"/*/apply_cp_patches.sh; do
        [[ -x "$script" ]] || continue
        name=$(basename "$(dirname "$script")")
        if [[ "$skip" == *" $name "* ]]; then
            echo "Skipping CP extension (CP_SKIP_EXT): $name"
            continue
        fi
        found+=("$script")
    done
    shopt -u nullglob

    if [[ ${#found[@]} -eq 0 ]]; then
        echo "No */apply_cp_patches.sh found under $WORKSPACE_DIR (extensions optional)."
        return 0
    fi

    local -a apply_args=(--apply --port "$PORT")
    [[ -n "$BOARD" ]] && apply_args+=(--board "$BOARD")
    [[ -n "$VARIANT" ]] && apply_args+=(--variant "$VARIANT")

    for script in "${found[@]}"; do
        echo "Applying CP patches: $script"
        "$script" "${apply_args[@]}"
    done
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

ensure_host_mpy_cross() {
    # Port make rebuilds mpy-cross via py/mkrules.mk. GNU make still forwards
    # FROZEN_MANIFEST from our command line, so a fresh tree links mpy-cross with
    # frozen qstr flags but no frozen pool. Clean first if a prior failed link
    # left objects built with FROZEN_MANIFEST set.
    make -C "$CP_DIR/mpy-cross" clean USER_C_MODULES= FROZEN_MANIFEST=
    make -C "$CP_DIR/mpy-cross" USER_C_MODULES= FROZEN_MANIFEST=
}

# Absolute path for a static unix variant/port freeze manifest.
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

# Ensure MCU generated BUILD/manifest.py exists when FROZEN_MPY_DIRS is set.
# Returns absolute path if present after the probe make, else empty.
ensure_mcu_generated_manifest() {
    local bdir rel
    bdir=$(build_dir)
    [[ -n "$bdir" ]] || return 0
    rel="${bdir#"$PORT_DIR"/}/manifest.py"

    # Probe without our aggregator override so circuitpy_mpconfig.mk can set
    # FROZEN_MANIFEST=$(BUILD)/manifest.py and build the generated file.
    # Both makes must keep stdout clean: this function's stdout is captured by
    # the caller as a path, and "make -C" prints Entering/Leaving directory
    # there, which ends up concatenated onto the manifest filename.
    if make -C "$PORT_DIR" -q "$rel" "${make_args_base[@]}" >/dev/null 2>&1; then
        :
    else
        make -C "$PORT_DIR" -j "$rel" "${make_args_base[@]}" >&2 || true
    fi

    if [[ -f "$bdir/manifest.py" ]]; then
        (cd "$bdir" && echo "$(pwd)/manifest.py")
    fi
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
PORT_DIR="$CP_DIR/ports/$PORT"
[[ -f "$PORT_DIR/Makefile" ]] || { echo "Invalid port: $PORT" >&2; exit 1; }

# 2) Board (only if this port has boards)
mapfile -t _boards < <(list_boards | sort)
if [[ ${#_boards[@]} -gt 0 ]]; then
    if [[ -z "$BOARD" && -t 0 ]]; then
        BOARD=$(pick "Boards for $PORT:" "${_boards[@]}")
    elif [[ -z "$BOARD" ]]; then
        echo "Board required for port $PORT (use --board or run interactively)." >&2
        exit 1
    fi
fi

# 3) Variant (only if a variants directory exists)
if _vdir=$(variants_dir); then
    mapfile -t _variants < <(list_variants "$_vdir" | sort)
    if [[ ${#_variants[@]} -gt 0 && -z "$VARIANT" && -t 0 ]]; then
        VARIANT=$(pick "Variants:" "${_variants[@]}")
    fi
fi

run_optional_cp_patches
print_rerun_hint
print_make_commands

make_args_base=()
user_config=$(cp_user_config_make_opts)
[[ -n "$user_config" ]] && make_args_base+=("$user_config")
[[ -n "$BOARD" ]] && make_args_base+=(BOARD="$BOARD")
[[ -n "$VARIANT" ]] && make_args_base+=(VARIANT="$VARIANT")

[[ -f "$FROZEN_MANIFEST" ]] || {
    echo "Frozen manifest not found: $FROZEN_MANIFEST" >&2
    exit 1
}

ensure_cp_python_env
ensure_espressif_env

echo "Building: port=$PORT${BOARD:+ board=$BOARD}${VARIANT:+ variant=$VARIANT}"
[[ -n "$user_config" ]] && echo "User config: $user_config"
echo

pushd "$PORT_DIR" >/dev/null
make -j clean "${make_args_base[@]}"
make -j submodules "${make_args_base[@]}"
popd >/dev/null

ensure_host_mpy_cross

export FROZEN_MANIFEST_UPSTREAM=""
if [[ "$PORT" == unix ]]; then
    FROZEN_MANIFEST_UPSTREAM=$(resolve_unix_frozen_manifest)
else
    FROZEN_MANIFEST_UPSTREAM=$(ensure_mcu_generated_manifest || true)
fi
export FROZEN_MANIFEST_UPSTREAM

make_args=("${make_args_base[@]}")
make_args+=(FROZEN_MANIFEST="$FROZEN_MANIFEST")
echo "Frozen manifest: $FROZEN_MANIFEST"
if [[ -n "$FROZEN_MANIFEST_UPSTREAM" ]]; then
    echo "  FROZEN_MANIFEST_UPSTREAM=$FROZEN_MANIFEST_UPSTREAM"
else
    echo "  FROZEN_MANIFEST_UPSTREAM=(none)"
fi

pushd "$PORT_DIR" >/dev/null
make -j "${make_args[@]}"
popd >/dev/null

print_build_outputs
