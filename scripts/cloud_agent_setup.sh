#!/usr/bin/env bash
# Cloud agent environment hooks for PyDevices cross-repo work.
#
# Cursor injects PYDEVICES_GH_TOKEN from Dashboard → Cloud Agents → Secrets.
# This script exports it as GH_TOKEN so gh/git use your PAT instead of
# cursor[bot] (which cannot create org repos or push sibling repos).
#
# Multi-repo dashboard environment should include:
#   PyDevices/cmods, pydisplay, lv_circuitpython_mod, lv_cpython_mod,
#   usdl2, multimer, graphics, lv_bindings
#
# Usage (called from .cursor/environment.json):
#   bash scripts/cloud_agent_setup.sh install
#   bash scripts/cloud_agent_setup.sh start
#   bash scripts/cloud_agent_setup.sh verify
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMODS="${CMODS:-$ROOT}"

log() { printf 'cloud_agent_setup: %s\n' "$*"; }

ensure_system_deps() {
    python3 -c 'import ensurepip' 2>/dev/null && return 0
    command -v apt-get >/dev/null 2>&1 || {
        log "python3-venv missing and apt-get unavailable; install may fail for mp/cp/cpy profiles"
        return 0
    }
    log "installing python3-venv (required for lv_bindings / CP build venvs)"
    if [[ "$(id -u)" -eq 0 ]]; then
        apt-get update -qq
        apt-get install -y -qq python3-venv python3-pip
    elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq python3-venv python3-pip
    else
        log "cannot install python3-venv (no root/sudo); set CMODS_PROFILE=minimal for pydisplay-only work"
    fi
}

default_cmods_profile() {
    if [[ -n "${CMODS_PROFILE:-}" ]]; then
        printf '%s' "$CMODS_PROFILE"
        return
    fi
    # Multi-repo cloud VMs already mount siblings at /agent/repos/*.
    if [[ -d /agent/repos ]]; then
        printf '%s' "minimal"
    else
        printf '%s' "mp,cpy,display"
    fi
}

setup_gh() {
    if [[ -z "${PYDEVICES_GH_TOKEN:-}" ]]; then
        echo "cloud_agent_setup: PYDEVICES_GH_TOKEN not set (add in Cloud Agents Secrets)" >&2
        return 0
    fi
    export GH_TOKEN="$PYDEVICES_GH_TOKEN"
    if command -v gh >/dev/null 2>&1; then
        printf '%s\n' "$GH_TOKEN" | gh auth login --with-token 2>/dev/null || true
        gh auth setup-git 2>/dev/null || true
    fi
}

cmd_install() {
    setup_gh
    ensure_system_deps
    cd "$CMODS"
    if [[ -x "$CMODS/scripts/clone_profile.sh" ]]; then
        profile=$(default_cmods_profile)
        log "CMODS_PROFILE=$profile"
        CMODS_PROFILE="$profile" "$CMODS/scripts/clone_profile.sh"
    fi
}

cmd_start() {
    setup_gh
}

cmd_verify() {
    setup_gh
    echo "== PYDEVICES_GH_TOKEN =="
    if [[ -n "${PYDEVICES_GH_TOKEN:-}" ]]; then
        echo "set (value hidden)"
    else
        echo "not set"
    fi
    echo "== gh auth =="
    gh auth status 2>&1 || true
    echo "== gh api user =="
    gh api user -q .login 2>&1 || true
    echo "== multi-repo siblings =="
    if [[ -d /agent/repos ]]; then
        ls -d /agent/repos/*/ 2>/dev/null | sed 's|/agent/repos/||; s|/$||' | head -20 || true
    else
        ls -d "$CMODS"/*/ 2>/dev/null | sed "s|$CMODS/||; s|/$||" | head -20 || true
    fi
    echo "== gh repo view PyDevices/multimer =="
    gh repo view PyDevices/multimer --json name -q .name 2>&1 || true
}

case "${1:-start}" in
    install) cmd_install ;;
    start)   cmd_start ;;
    verify)  cmd_verify ;;
    *)
        echo "usage: $0 {install|start|verify}" >&2
        exit 1
        ;;
esac
