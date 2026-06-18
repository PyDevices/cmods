#!/usr/bin/env bash
# Return the Python interpreter for binding generation (prefers local .venv).
LV_BINDINGS_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -x "$LV_BINDINGS_DIR/.venv/bin/python3" ]; then
    echo "$LV_BINDINGS_DIR/.venv/bin/python3"
else
    echo python3
fi
