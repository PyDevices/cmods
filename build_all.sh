#!/usr/bin/env bash
# Build and smoke-test all five LVGL consumer targets.
#
# Usage:
#   ./build_all.sh [--sequential]
#
# Default: parallel mp-unix, mp-windows, cp-unix, cpy-unix; wait; then cpy-windows alone.
# cpy-unix and cpy-windows never run concurrently (see build_target.sh flock).
#
# Environment:
#   CMODS    Workspace root (default: directory containing this script)
#   LOGDIR   Log directory (default: /tmp/cmods-build-all-$$)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMODS="${CMODS:-$SCRIPT_DIR}"
BUILD_TARGET="$SCRIPT_DIR/build_target.sh"
SEQUENTIAL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sequential) SEQUENTIAL=1; shift ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -x "$BUILD_TARGET" ]] || { echo "Missing executable: $BUILD_TARGET" >&2; exit 1; }

LOGDIR="${LOGDIR:-/tmp/cmods-build-all-$$}"
mkdir -p "$LOGDIR"
export CMODS

TARGETS=(mp-unix mp-windows cp-unix cpy-unix cpy-windows)

run_one() {
    local t=$1
    local log="$LOGDIR/$t.log"
    echo "==> starting $t (log: $log)"
    if "$BUILD_TARGET" "$t" >"$log" 2>&1; then
        echo 0 >"$LOGDIR/$t.exit"
        echo "==> $t OK"
    else
        echo $? >"$LOGDIR/$t.exit"
        echo "==> $t FAILED — see $log"
    fi
}

run_one_bg() {
    local t=$1
    (
        run_one "$t"
    ) &
}

if [[ "$SEQUENTIAL" == "1" ]]; then
    echo "LOGDIR=$LOGDIR"
    echo "=== Sequential build: ${TARGETS[*]} ==="
    for t in "${TARGETS[@]}"; do
        run_one "$t"
    done
else
    echo "LOGDIR=$LOGDIR"
    echo "=== Phase A: parallel mp-unix mp-windows cp-unix cpy-unix ==="
    for t in mp-unix mp-windows cp-unix cpy-unix; do
        run_one_bg "$t"
    done
    wait
    echo "=== Phase B: cpy-windows (alone) ==="
    run_one cpy-windows
fi

echo ""
echo "=== SUMMARY (LOGDIR=$LOGDIR) ==="
overall=0
for t in "${TARGETS[@]}"; do
    ec=$(cat "$LOGDIR/$t.exit" 2>/dev/null || echo 1)
    if [[ "$ec" == "0" ]]; then
        echo "  $t: OK"
    else
        echo "  $t: FAILED (exit $ec)"
        overall=1
    fi
done

if [[ "$overall" != "0" ]]; then
    echo ""
    echo "One or more targets failed. Tail of logs:"
    for t in "${TARGETS[@]}"; do
        ec=$(cat "$LOGDIR/$t.exit" 2>/dev/null || echo 1)
        if [[ "$ec" != "0" ]]; then
            echo "--- $t ---"
            tail -20 "$LOGDIR/$t.log" 2>/dev/null || true
        fi
    done
    exit 1
fi

echo "All consumer targets passed."
exit 0
