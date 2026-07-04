#!/usr/bin/env bash
# Bootstrap the cmods workspace: upstream trees, PyDevices repos, and lvgl.
set -euo pipefail

WORKSPACE="${CMODS:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$WORKSPACE"

log() { printf '==> %s\n' "$*"; }

clone_if_missing() {
    local dir=$1 url=$2
    shift 2
  if [[ -d "$dir/.git" ]]; then
    log "present: $dir"
    return 0
  fi
  log "cloning $url -> $dir"
  git clone "$@" "$url" "$dir"
}

# PyDevices repositories consumed by cmods (siblings of this repo root).
PYDEVICES_REPOS=(
  lv_bindings
  lv_micropython_cmod
  lv_circuitpython_mod
  lv_cpython_mod
  usdl2
  pydisplay
  pydisplay_cmods
  micropython-lib
)

for repo in "${PYDEVICES_REPOS[@]}"; do
  clone_if_missing "$repo" "https://github.com/PyDevices/${repo}.git"
done

# Upstream runtimes and LVGL.
clone_if_missing micropython https://github.com/micropython/micropython.git
clone_if_missing circuitpython https://github.com/adafruit/circuitpython.git --branch 10.2.1 --single-branch
clone_if_missing lvgl https://github.com/lvgl/lvgl.git

# lv_bindings carries the pinned LVGL submodule used by generated bindings.
log "initializing lv_bindings/lvgl submodule"
git -C lv_bindings submodule update --init lvgl

lvgl_pin=$(git -C lv_bindings submodule status lvgl | awk '{print $1}' | tr -d '+-')
if [[ -n "$lvgl_pin" ]]; then
  log "checking out lvgl @ $lvgl_pin (matches lv_bindings submodule)"
  git -C lvgl fetch --tags origin
  git -C lvgl checkout --detach "$lvgl_pin"
fi

log "initializing lv_cpython_mod/lvgl submodule"
git -C lv_cpython_mod submodule update --init lvgl

log "initializing micropython submodules"
git -C micropython submodule update --init --recursive

log "fetching circuitpython submodules (may take a few minutes)"
make -C circuitpython fetch-all-submodules

# Python venvs used by generator and CPython mod builds.
if [[ ! -d lv_bindings/.venv ]]; then
  log "creating lv_bindings/.venv"
  python3 -m venv lv_bindings/.venv
fi
lv_bindings/.venv/bin/pip install -q -r lv_bindings/requirements.txt

if [[ ! -d lv_cpython_mod/.venv ]]; then
  log "creating lv_cpython_mod/.venv"
  python3 -m venv lv_cpython_mod/.venv
fi
lv_cpython_mod/.venv/bin/pip install -q -r lv_cpython_mod/requirements.txt

# CircuitPython build tooling venv is created by build_cp.sh on first use.
if [[ ! -d lv_circuitpython_mod/.venv ]]; then
  log "creating lv_circuitpython_mod/.venv"
  python3 -m venv lv_circuitpython_mod/.venv
fi
lv_circuitpython_mod/.venv/bin/pip install -q -r circuitpython/requirements-dev.txt

cat <<EOF

Workspace ready under: $WORKSPACE

Sibling trees:
  micropython/ circuitpython/ lvgl/
  ${PYDEVICES_REPOS[*]}

Quick checks:
  ./build_target.sh mp-unix
  ./build_target.sh cp-unix
  ./build_target.sh cpy-unix

Regenerate bindings after lvgl/ or binding/ changes:
  ./lv_bindings/regenerate_all.sh

Note: mp-windows needs the SDL2 MinGW dev ZIP (export SDL2_DEV=...).
      cpy-windows needs Windows Python + MSVC and is not supported inside this Linux container.

EOF
