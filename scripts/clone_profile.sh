#!/usr/bin/env bash
# Clone only the cmods sibling repos needed for a task.
#
# Usage:
#   ./scripts/clone_profile.sh PROFILE [PROFILE ...]
#   CMODS_PROFILE=mp,cpy ./scripts/clone_profile.sh
#
# Profiles:
#   minimal   cmods only (no sibling clones)
#   bindings  lv_bindings (+ lvgl submodule)
#   mp        micropython + LVGL MicroPython stack
#   cp        CircuitPython LVGL stack (defers heavy submodule fetch)
#   cpy       CPython LVGL extension
#   display   pydisplay + usdl2 + pydisplay_cmods
#             (pydisplay_android lives under ~/gh/pydevices/, not inside cmods)
#   graphics  graphics cmod (clone repo only; uses mp stack when building)
#   mip       micropython-lib
#   full      all repos + circuitpython submodules + venvs
#
# Environment:
#   CMODS                 workspace root (default: parent of scripts/)
#   FETCH_CP_SUBMODULES   1 to run make fetch-all-submodules for cp profile (default: 0)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMODS="${CMODS:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FETCH_CP_SUBMODULES="${FETCH_CP_SUBMODULES:-0}"

cd "$CMODS"
log() { printf '==> %s\n' "$*"; }

multi_repo_root() {
    [[ -d /agent/repos ]] && printf '%s' /agent/repos
}

link_multi_repo_sibling() {
    local dir=$1
    local root
    root=$(multi_repo_root)
    [[ -n "$root" && -d "$root/$dir/.git" ]] || return 1
    if [[ -e "$CMODS/$dir" ]]; then
        log "present: $dir"
        return 0
    fi
    log "linking $root/$dir -> $CMODS/$dir"
    ln -s "$root/$dir" "$CMODS/$dir"
}

clone_if_missing() {
    local dir=$1 url=$2
    shift 2
    if link_multi_repo_sibling "$dir"; then
        return 0
    fi
    if [[ -d "$dir/.git" ]]; then
        log "present: $dir"
        return 0
    fi
    log "cloning $url -> $dir"
    git clone "$@" "$url" "$dir"
}

sync_lvgl_pin() {
    [[ -d lv_bindings/.git ]] || return 0
    git -C lv_bindings submodule update --init lvgl
    local lvgl_pin
    lvgl_pin=$(git -C lv_bindings submodule status lvgl | awk '{print $1}' | tr -d '+-')
    [[ -n "$lvgl_pin" ]] || return 0

    if [[ -d lvgl/.git ]]; then
        log "checking out lvgl @ $lvgl_pin"
        git -C lvgl fetch --tags origin
        git -C lvgl checkout --detach "$lvgl_pin"
    fi
}

ensure_venv() {
    local dir=$1 req=$2
    [[ -f "$req" ]] || return 0

    if [[ "${SKIP_VENV:-0}" == "1" ]]; then
        log "skipped venv for $dir (SKIP_VENV=1)"
        return 0
    fi

    if ! python3 -c 'import ensurepip' 2>/dev/null; then
        echo "clone_profile: python3-venv is not installed (broken or missing ensurepip)." >&2
        echo "  Cloud VM: run ensure_system_deps in cloud_agent_setup.sh or apt install python3-venv" >&2
        echo "  Skipping venv for $dir; LVGL generator / pip builds will not work until fixed." >&2
        return 0
    fi

    if [[ ! -x "$dir/.venv/bin/pip" ]]; then
        [[ -d "$dir/.venv" ]] && rm -rf "$dir/.venv"
        log "creating $dir/.venv"
        if ! python3 -m venv "$dir/.venv"; then
            echo "clone_profile: failed to create $dir/.venv — install python3-venv" >&2
            return 1
        fi
    fi
    if [[ ! -x "$dir/.venv/bin/pip" ]]; then
        echo "clone_profile: $dir/.venv/bin/pip missing after venv create — install python3-venv" >&2
        return 1
    fi
    "$dir/.venv/bin/pip" install -q -r "$req"
}

profile_bindings() {
    clone_if_missing lv_bindings https://github.com/PyDevices/lv_bindings.git
    sync_lvgl_pin
    ensure_venv lv_bindings lv_bindings/requirements.txt
}

profile_mp() {
    profile_bindings
    clone_if_missing lv_micropython_cmod https://github.com/PyDevices/lv_micropython_cmod.git
    clone_if_missing micropython https://github.com/micropython/micropython.git
    clone_if_missing lvgl https://github.com/lvgl/lvgl.git
    sync_lvgl_pin
    log "initializing micropython submodules"
    git -C micropython submodule update --init --recursive
}

profile_cp() {
    profile_bindings
    clone_if_missing lv_circuitpython_mod https://github.com/PyDevices/lv_circuitpython_mod.git
    clone_if_missing circuitpython https://github.com/adafruit/circuitpython.git \
        --branch 10.2.1 --single-branch
    if [[ "$FETCH_CP_SUBMODULES" == "1" ]]; then
        log "fetching circuitpython submodules (slow; first cp-unix build needs this)"
        make -C circuitpython fetch-all-submodules
    else
        log "skipped circuitpython submodule fetch (set FETCH_CP_SUBMODULES=1 or run before cp-unix build)"
    fi
    ensure_venv lv_circuitpython_mod circuitpython/requirements-dev.txt
}

profile_cpy() {
    profile_bindings
    clone_if_missing lv_cpython_mod https://github.com/PyDevices/lv_cpython_mod.git --recurse-submodules
    ensure_venv lv_cpython_mod lv_cpython_mod/requirements.txt
}

profile_display() {
    clone_if_missing pydisplay https://github.com/PyDevices/pydisplay.git
    clone_if_missing usdl2 https://github.com/PyDevices/usdl2.git
    clone_if_missing pydisplay_cmods https://github.com/PyDevices/pydisplay_cmods.git
}

profile_graphics() {
    clone_if_missing graphics https://github.com/PyDevices/graphics.git
}

profile_mip() {
    clone_if_missing micropython-lib https://github.com/PyDevices/micropython-lib.git
}

profile_full() {
    FETCH_CP_SUBMODULES=1 profile_mp
    clone_if_missing lv_circuitpython_mod https://github.com/PyDevices/lv_circuitpython_mod.git
    clone_if_missing lv_cpython_mod https://github.com/PyDevices/lv_cpython_mod.git --recurse-submodules
    clone_if_missing usdl2 https://github.com/PyDevices/usdl2.git
    clone_if_missing pydisplay https://github.com/PyDevices/pydisplay.git
    clone_if_missing pydisplay_cmods https://github.com/PyDevices/pydisplay_cmods.git
    clone_if_missing micropython-lib https://github.com/PyDevices/micropython-lib.git
    profile_cp
    ensure_venv lv_cpython_mod lv_cpython_mod/requirements.txt
}

apply_profile() {
    case "$1" in
        minimal) log "minimal profile: cmods only" ;;
        bindings) profile_bindings ;;
        mp) profile_mp ;;
        cp) profile_cp ;;
        cpy) profile_cpy ;;
        display) profile_display ;;
        graphics) profile_graphics ;;
        mip) profile_mip ;;
        full) profile_full ;;
        *)
            echo "Unknown profile: $1" >&2
            echo "Profiles: minimal bindings mp cp cpy display mip full" >&2
            exit 1
            ;;
    esac
}

if [[ $# -eq 0 ]]; then
    if [[ -n "${CMODS_PROFILE:-}" ]]; then
        IFS=',' read -r -a profiles <<< "$CMODS_PROFILE"
    else
        echo "Usage: $0 PROFILE [PROFILE ...]" >&2
        exit 1
    fi
else
    profiles=("$@")
fi

for profile in "${profiles[@]}"; do
    profile="${profile// /}"
    [[ -n "$profile" ]] || continue
    log "profile: $profile"
    apply_profile "$profile"
done

log "done (CMODS=$CMODS)"
