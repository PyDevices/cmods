#!/usr/bin/env bash
# Sync the consumer-side mirror trees in this repo from their authoritative
# public repos:
#
#   PyDevices/micropython-pydevices  ->  patches/000*.patch
#                                         wasmbridge/
#                                         variants/webassembly/pydevices/
#   PyDevices/audioif                ->  patches/adafruit_mp3/
#
# Edit those files in the source repo, never here (single-writer, same rule
# as lvgl-python/scripts/sync_from_lvgl_bindings.sh).
#
# Usage:
#   ./scripts/sync_from_overlay.sh                 # sync using pinned refs
#   ./scripts/sync_from_overlay.sh --mp-ref <ref>   # sync micropython-pydevices at <ref>
#   ./scripts/sync_from_overlay.sh --audioif-ref <ref>
#   ./scripts/sync_from_overlay.sh --check          # diff mirrors against pinned refs; exit nonzero on drift
#
# <ref> is an exact 40-character commit SHA or a tag. If a sibling checkout
# (../micropython-pydevices, ../audioif) exists next to this workspace, it is
# used directly (after fetching the ref if not already present locally);
# otherwise a shallow temp clone is made from GitHub.
#
# After syncing, commit the updated mirror files and the *_COMMIT pin files.

set -euo pipefail

MP_REPO_URL="${MICROPYTHON_PYDEVICES_REPO:-https://github.com/PyDevices/micropython-pydevices.git}"
AUDIOIF_REPO_URL="${AUDIOIF_REPO:-https://github.com/PyDevices/audioif.git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMODS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$CMODS_DIR/.." && pwd)"

MP_SIBLING="$WORKSPACE_DIR/micropython-pydevices"
AUDIOIF_SIBLING="$WORKSPACE_DIR/audioif"

MP_PIN_FILE="$CMODS_DIR/MICROPYTHON_PYDEVICES_COMMIT"
AUDIOIF_PIN_FILE="$CMODS_DIR/AUDIOIF_PATCHES_COMMIT"

CHECK=0
MP_REF=""
AUDIOIF_REF=""

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mp-ref)
            MP_REF=$2
            shift 2
            ;;
        --audioif-ref)
            AUDIOIF_REF=$2
            shift 2
            ;;
        --check)
            CHECK=1
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

CLONE_DIRS=()
cleanup() {
    for d in "${CLONE_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}
trap cleanup EXIT


# Resolve $2 (a ref, possibly empty) against repo $1 / sibling checkout $3,
# populate directory $4 with the tree at that ref, and print the resolved
# 40-char SHA on stdout. All progress goes to stderr.
resolve_and_export() {
    local repo_url="$1" ref="$2" sibling_dir="$3" outdir="$4"
    local workdir resolved

    if [[ -d "$sibling_dir/.git" ]]; then
        workdir="$sibling_dir"
        echo "Using sibling checkout: $sibling_dir" >&2
        if ! git -C "$workdir" cat-file -e "${ref}^{commit}" 2> /dev/null; then
            echo "Fetching ${ref} into sibling checkout..." >&2
            git -C "$workdir" fetch origin "$ref" >&2
        fi
    else
        workdir=$(mktemp -d)
        CLONE_DIRS+=("$workdir")
        echo "Cloning ${repo_url} (no sibling checkout at ${sibling_dir})..." >&2
        git clone --filter=blob:none --no-checkout "$repo_url" "$workdir" >&2
        git -C "$workdir" fetch origin "$ref" >&2
    fi

    if git -C "$workdir" cat-file -e "${ref}^{commit}" 2> /dev/null; then
        resolved=$(git -C "$workdir" rev-parse "${ref}^{commit}")
    else
        resolved=$(git -C "$workdir" rev-parse 'FETCH_HEAD^{commit}')
    fi

    mkdir -p "$outdir"
    git -C "$workdir" archive "$resolved" | tar -x -C "$outdir"
    echo "$resolved"
}

diff_tree() {
    # diff_tree <src-dir> <dest-dir> <label>  -> returns nonzero if they differ
    local src="$1" dest="$2" label="$3"
    if ! diff -rq "$src" "$dest" > /tmp/sync_from_overlay.diff.$$ 2>&1; then
        echo "DRIFT: $label"
        sed 's/^/  /' /tmp/sync_from_overlay.diff.$$
        rm -f /tmp/sync_from_overlay.diff.$$
        return 1
    fi
    rm -f /tmp/sync_from_overlay.diff.$$
    return 0
}

DRIFT=0

# ---------------------------------------------------------------------------
# micropython-pydevices -> patches/000*.patch, wasmbridge/, variants/webassembly/pydevices/
# ---------------------------------------------------------------------------
if [[ "$CHECK" -eq 1 ]]; then
    [[ -f "$MP_PIN_FILE" ]] || {
        echo "Error: $MP_PIN_FILE missing; run without --check first to establish pins." >&2
        exit 1
    }
    MP_REF=$(tr -d '[:space:]' < "$MP_PIN_FILE")
elif [[ -z "$MP_REF" ]]; then
    if [[ -f "$MP_PIN_FILE" ]]; then
        MP_REF=$(tr -d '[:space:]' < "$MP_PIN_FILE")
    elif [[ -d "$MP_SIBLING/.git" ]]; then
        MP_REF=$(git -C "$MP_SIBLING" rev-parse HEAD)
    else
        echo "Error: no MICROPYTHON_PYDEVICES_COMMIT pin, no --mp-ref, and no sibling checkout to default from." >&2
        exit 1
    fi
fi

MP_TMP=$(mktemp -d)
CLONE_DIRS+=("$MP_TMP")
MP_RESOLVED=$(resolve_and_export "$MP_REPO_URL" "$MP_REF" "$MP_SIBLING" "$MP_TMP")

if [[ ! -d "$MP_TMP/patches" ]]; then
    echo "Error: patches/ not found in micropython-pydevices @ ${MP_RESOLVED}." >&2
    exit 1
fi

MP_STAGE=$(mktemp -d)
CLONE_DIRS+=("$MP_STAGE")
mkdir -p "$MP_STAGE/patches" "$MP_STAGE/wasmbridge" "$MP_STAGE/variants/webassembly/pydevices"
cp "$MP_TMP"/patches/[0-9][0-9][0-9][0-9]-*.patch "$MP_STAGE/patches/"
cp -a "$MP_TMP/usermods/wasmbridge/." "$MP_STAGE/wasmbridge/"
cp -a "$MP_TMP/variants/webassembly/pydevices/." "$MP_STAGE/variants/webassembly/pydevices/"

if [[ "$CHECK" -eq 1 ]]; then
    DEST_PATCHES_STAGE=$(mktemp -d)
    CLONE_DIRS+=("$DEST_PATCHES_STAGE")
    cp "$CMODS_DIR"/patches/[0-9][0-9][0-9][0-9]-*.patch "$DEST_PATCHES_STAGE/" 2> /dev/null || true
    diff_tree "$MP_STAGE/patches" "$DEST_PATCHES_STAGE" "patches/ (numbered series) vs micropython-pydevices@${MP_RESOLVED}" || DRIFT=1
    diff_tree "$MP_STAGE/wasmbridge" "$CMODS_DIR/wasmbridge" "wasmbridge/ vs micropython-pydevices@${MP_RESOLVED}" || DRIFT=1
    diff_tree "$MP_STAGE/variants/webassembly/pydevices" "$CMODS_DIR/variants/webassembly/pydevices" "variants/webassembly/pydevices/ vs micropython-pydevices@${MP_RESOLVED}" || DRIFT=1
else
    rm -f "$CMODS_DIR"/patches/[0-9][0-9][0-9][0-9]-*.patch
    cp "$MP_STAGE"/patches/[0-9][0-9][0-9][0-9]-*.patch "$CMODS_DIR/patches/"
    rm -rf "$CMODS_DIR/wasmbridge"
    mkdir -p "$CMODS_DIR/wasmbridge"
    cp -a "$MP_STAGE/wasmbridge/." "$CMODS_DIR/wasmbridge/"
    rm -rf "$CMODS_DIR/variants/webassembly/pydevices"
    mkdir -p "$CMODS_DIR/variants/webassembly/pydevices"
    cp -a "$MP_STAGE/variants/webassembly/pydevices/." "$CMODS_DIR/variants/webassembly/pydevices/"
    printf '%s\n' "$MP_RESOLVED" > "$MP_PIN_FILE"
    echo "Synced patches/, wasmbridge/, variants/webassembly/pydevices/ from micropython-pydevices@${MP_RESOLVED}"
fi

# ---------------------------------------------------------------------------
# audioif -> patches/adafruit_mp3/
# ---------------------------------------------------------------------------
if [[ "$CHECK" -eq 1 ]]; then
    [[ -f "$AUDIOIF_PIN_FILE" ]] || {
        echo "Error: $AUDIOIF_PIN_FILE missing; run without --check first to establish pins." >&2
        exit 1
    }
    AUDIOIF_REF=$(tr -d '[:space:]' < "$AUDIOIF_PIN_FILE")
elif [[ -z "$AUDIOIF_REF" ]]; then
    if [[ -f "$AUDIOIF_PIN_FILE" ]]; then
        AUDIOIF_REF=$(tr -d '[:space:]' < "$AUDIOIF_PIN_FILE")
    elif [[ -d "$AUDIOIF_SIBLING/.git" ]]; then
        AUDIOIF_REF=$(git -C "$AUDIOIF_SIBLING" rev-parse HEAD)
    else
        echo "Error: no AUDIOIF_PATCHES_COMMIT pin, no --audioif-ref, and no sibling checkout to default from." >&2
        exit 1
    fi
fi

AUDIOIF_TMP=$(mktemp -d)
CLONE_DIRS+=("$AUDIOIF_TMP")
AUDIOIF_RESOLVED=$(resolve_and_export "$AUDIOIF_REPO_URL" "$AUDIOIF_REF" "$AUDIOIF_SIBLING" "$AUDIOIF_TMP")

if [[ ! -d "$AUDIOIF_TMP/patches/adafruit_mp3" ]]; then
    echo "Error: patches/adafruit_mp3/ not found in audioif @ ${AUDIOIF_RESOLVED}." >&2
    exit 1
fi

if [[ "$CHECK" -eq 1 ]]; then
    diff_tree "$AUDIOIF_TMP/patches/adafruit_mp3" "$CMODS_DIR/patches/adafruit_mp3" "patches/adafruit_mp3/ vs audioif@${AUDIOIF_RESOLVED}" || DRIFT=1
else
    rm -rf "$CMODS_DIR/patches/adafruit_mp3"
    mkdir -p "$CMODS_DIR/patches/adafruit_mp3"
    cp -a "$AUDIOIF_TMP/patches/adafruit_mp3/." "$CMODS_DIR/patches/adafruit_mp3/"
    printf '%s\n' "$AUDIOIF_RESOLVED" > "$AUDIOIF_PIN_FILE"
    echo "Synced patches/adafruit_mp3/ from audioif@${AUDIOIF_RESOLVED}"
fi

if [[ "$CHECK" -eq 1 ]]; then
    if [[ "$DRIFT" -ne 0 ]]; then
        echo
        echo "Mirror drift detected against pinned commits. Re-run without --check to resync," >&2
        echo "or bump MICROPYTHON_PYDEVICES_COMMIT / AUDIOIF_PATCHES_COMMIT after verifying the source change." >&2
        exit 1
    fi
    echo "No drift: mirrors match pinned commits."
    echo "  micropython-pydevices @ ${MP_RESOLVED}"
    echo "  audioif @ ${AUDIOIF_RESOLVED}"
else
    echo
    echo "Commit when ready:"
    echo "  git add MICROPYTHON_PYDEVICES_COMMIT AUDIOIF_PATCHES_COMMIT patches wasmbridge variants/webassembly/pydevices"
    echo "  git commit -m \"Sync overlay mirrors from micropython-pydevices@${MP_RESOLVED:0:12} / audioif@${AUDIOIF_RESOLVED:0:12}.\""
fi
