#!/usr/bin/env bash
# Verify build_mp.sh upstream frozen-manifest resolution matches a manual
# MicroPython build selection, and that cmods/manifest.py + FROZEN_MANIFEST_UPSTREAM
# freezes a superset of the upstream modules (no generated wrapper).
#
# Usage (from cmods root):
#   ./scripts/verify_frozen_manifest_parity.sh
set -euo pipefail

CMODS="$(cd "$(dirname "$0")/.." && pwd)"
MP_DIR="${MP_DIR:-$CMODS/micropython}"
export WORKSPACE_DIR="$CMODS"

eval "$(
  sed -n '/^resolve_upstream_frozen_manifest()/,/^}/p;/^port_kind()/,/^}/p' \
    "$CMODS/build_mp.sh"
)"

list_frozen_targets() {
  local manifest=$1 port_dir=$2 board_dir=${3:-}
  python3 - "$manifest" "$MP_DIR" "$port_dir" "$board_dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[2] + "/tools")
import manifestfile

manifest, mpy_dir, port_dir, board_dir = sys.argv[1:5]
vars = {
    "MPY_DIR": mpy_dir,
    "PORT_DIR": port_dir,
    "BOARD_DIR": board_dir,
    "MPY_LIB_DIR": mpy_dir + "/lib/micropython-lib",
}
m = manifestfile.ManifestFile(manifestfile.MODE_FREEZE, vars)
m.include(manifest)
for f in sorted({x.target_path for x in m.files()}):
    print(f)
PY
}

make_native_manifest() {
  local port=$1
  shift
  local port_dir="$MP_DIR/ports/$port"
  local variant="" board="" board_variant=""
  local arg build_target
  for arg in "$@"; do
    case "$arg" in
      VARIANT=*) variant=${arg#VARIANT=} ;;
      BOARD=*) board=${arg#BOARD=} ;;
      BOARD_VARIANT=*) board_variant=${arg#BOARD_VARIANT=} ;;
    esac
  done
  if [[ -n "$variant" && -z "$board" ]]; then
    build_target="build-${variant}/frozen_content.c"
  elif [[ -n "$board" && -n "$board_variant" ]]; then
    build_target="build-${board}-${board_variant}/frozen_content.c"
  elif [[ -n "$board" ]]; then
    build_target="build-${board}/frozen_content.c"
  else
    build_target="frozen_content.c"
  fi

  local line rel
  line=$(
    make -C "$port_dir" -n "$@" "$build_target" 2>/dev/null \
      | grep -F 'makemanifest.py' | tail -1 || true
  )
  if [[ -z "$line" ]]; then
    return 1
  fi
  rel=${line##* }
  if [[ "$rel" = /* ]]; then
    echo "$rel"
  else
    (cd "$port_dir" && echo "$(pwd)/$rel")
  fi
}

cmake_expected_manifest() {
  local port=$1 board=$2
  local board_dir="$MP_DIR/ports/$port/boards/$board"
  local f
  if [[ -f "$board_dir/mpconfigboard.cmake" ]]; then
    f=$(
      python3 - "$board_dir/mpconfigboard.cmake" "$board_dir" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
board_dir = sys.argv[2]
m = re.search(r"set\s*\(\s*MICROPY_FROZEN_MANIFEST\s+([^)]+)\)", text)
if not m:
    raise SystemExit(0)
expr = m.group(1).strip()
expr = expr.replace("${MICROPY_BOARD_DIR}", board_dir)
expr = expr.replace("${CMAKE_CURRENT_LIST_DIR}", board_dir)
print(expr)
PY
    )
    if [[ -n "$f" && -f "$f" ]]; then
      (cd "$(dirname "$f")" && echo "$(pwd)/$(basename "$f")")
      return 0
    fi
  fi
  if [[ -f "$board_dir/manifest.py" ]]; then
    (cd "$board_dir" && echo "$(pwd)/manifest.py")
  elif [[ -f "$MP_DIR/ports/$port/boards/manifest.py" ]]; then
    (cd "$MP_DIR/ports/$port/boards" && echo "$(pwd)/manifest.py")
  else
    return 1
  fi
}

check_combo() {
  local label=$1 port=$2
  shift 2
  local -a make_vars=("$@")

  echo
  echo "=== $label ==="

  PORT="$port"
  PORT_DIR="$MP_DIR/ports/$port"
  PORT_KIND=$(port_kind)
  BOARD=""
  VARIANT=""
  local arg
  for arg in "${make_vars[@]}"; do
    case "$arg" in
      BOARD=*) BOARD=${arg#BOARD=} ;;
      BOARD_VARIANT=*) VARIANT=${arg#BOARD_VARIANT=} ;;
      VARIANT=*) VARIANT=${arg#VARIANT=} ;;
    esac
  done

  local upstream expected
  upstream=$(resolve_upstream_frozen_manifest)

  if expected=$(make_native_manifest "$port" "${make_vars[@]}"); then
    :
  elif [[ "$PORT_KIND" == boards ]] && expected=$(cmake_expected_manifest "$port" "$BOARD"); then
    echo "(cmake port — expected path from board/cmake defaults)"
  else
    echo "FAIL could not determine native/expected manifest for $label" >&2
    return 1
  fi

  if [[ "$(realpath "$upstream")" != "$(realpath "$expected")" ]]; then
    echo "FAIL path mismatch" >&2
    echo "  resolve:  $upstream" >&2
    echo "  expected: $expected" >&2
    return 1
  fi
  echo "OK  upstream path matches manual selection:"
  echo "    $upstream"

  export FROZEN_MANIFEST_UPSTREAM="$upstream"
  local cmods_manifest="$CMODS/manifest.py"
  local board_dir=""
  [[ -n "$BOARD" ]] && board_dir="$PORT_DIR/boards/$BOARD"

  local upstream_list wrapper_list missing
  upstream_list=$(list_frozen_targets "$upstream" "$PORT_DIR" "$board_dir")
  wrapper_list=$(list_frozen_targets "$cmods_manifest" "$PORT_DIR" "$board_dir")

  missing=$(comm -23 <(echo "$upstream_list") <(echo "$wrapper_list") || true)
  if [[ -n "$missing" ]]; then
    echo "FAIL cmods manifest missing upstream modules:" >&2
    echo "$missing" >&2
    return 1
  fi

  local u_count w_count
  u_count=$(grep -c . <<<"$upstream_list" || true)
  w_count=$(grep -c . <<<"$wrapper_list" || true)
  echo "OK  freeze parity: upstream=$u_count modules, cmods=$w_count (superset)"
}

fail=0
check_combo "unix / standard" unix VARIANT=standard || fail=1
check_combo "unix / coverage" unix VARIANT=coverage || fail=1
check_combo "windows / dev" windows VARIANT=dev || fail=1
check_combo "webassembly / pyscript" webassembly VARIANT=pyscript || fail=1
check_combo "esp32 / ESP32_GENERIC_P4 / C6_WIFI" esp32 BOARD=ESP32_GENERIC_P4 BOARD_VARIANT=C6_WIFI || fail=1
check_combo "esp32 / M5STACK_ATOM" esp32 BOARD=M5STACK_ATOM || fail=1
check_combo "rp2 / RPI_PICO" rp2 BOARD=RPI_PICO || fail=1

echo
if [[ "$fail" -eq 0 ]]; then
  echo "All frozen-manifest parity checks passed."
else
  echo "Some checks failed." >&2
  exit 1
fi
