#!/usr/bin/env bash
# Bootstrap the cmods workspace inside a dev container.
set -euo pipefail

WORKSPACE="${CMODS:-$(cd "$(dirname "$0")/.." && pwd)}"
export CMODS_PROFILE="${CMODS_PROFILE:-mp,cpy}"
export CMODS="$WORKSPACE"

exec "$WORKSPACE/scripts/clone_profile.sh"
