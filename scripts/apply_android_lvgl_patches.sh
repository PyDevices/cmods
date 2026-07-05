#!/usr/bin/env bash
# Apply Android LVGL integration patches to sibling PyDevices repos.
# Run from the cmods workspace root (parent of lv_cpython_mod, usdl2, pydisplay).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$ROOT/patches/android-lvgl"

apply_series() {
  local repo="$1"
  local series_dir="$2"
  local branch="$3"
  if [[ ! -d "$repo/.git" ]]; then
    echo "skip $repo (not a git checkout)"
    return 0
  fi
  if [[ ! -d "$series_dir" ]] || [[ -z "$(ls -A "$series_dir"/*.patch 2>/dev/null)" ]]; then
    echo "skip $repo (no patches)"
    return 0
  fi
  echo "== $repo -> $branch =="
  (
    cd "$repo"
    git fetch origin main 2>/dev/null || true
    git checkout -B "$branch" origin/main 2>/dev/null || git checkout -B "$branch" main
    git am "$series_dir"/*.patch
    git push -u origin "$branch"
  )
}

apply_series "$ROOT/lv_cpython_mod" "$PATCHES/lv_cpython_mod" cursor/android-wheels-46b8
apply_series "$ROOT/usdl2" "$PATCHES/usdl2" cursor/android-p4a-46b8
apply_series "$ROOT/pydisplay" "$PATCHES/pydisplay" cursor/android-multimer-sdl2-46b8

echo "Done. Open PRs from the three cursor/* branches on GitHub."
