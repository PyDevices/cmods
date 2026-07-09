#!/usr/bin/env bash
# List AGENTS.md at the root of each immediate git sibling under cmods.
#
# Usage (from cmods root):
#   ./scripts/list_subrepo_agents.sh           # markdown table (default)
#   ./scripts/list_subrepo_agents.sh --paths   # one existing path per line
#   ./scripts/list_subrepo_agents.sh --missing # sub-repos without AGENTS.md
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMODS="${CMODS:-$(cd "$SCRIPT_DIR/.." && pwd)}"

mode=table
case "${1:-}" in
    --paths) mode=paths ;;
    --missing) mode=missing ;;
    ""|--table) mode=table ;;
    -h|--help)
        sed -n '2,8p' "$0"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
esac

subrepos=()
for entry in "$CMODS"/*; do
    [[ -d "$entry/.git" ]] || continue
    subrepos+=("$(basename "$entry")")
done
IFS=$'\n' subrepos=($(sort <<<"${subrepos[*]}"))
unset IFS

case "$mode" in
    paths)
        for name in "${subrepos[@]}"; do
            path="$CMODS/$name/AGENTS.md"
            [[ -f "$path" ]] && printf '%s\n' "$path"
        done
        ;;
    missing)
        for name in "${subrepos[@]}"; do
            [[ -f "$CMODS/$name/AGENTS.md" ]] || printf '%s\n' "$name"
        done
        ;;
    table)
        printf '| Sub-repo | AGENTS.md |\n'
        printf '|----------|----------|\n'
        for name in "${subrepos[@]}"; do
            if [[ -f "$CMODS/$name/AGENTS.md" ]]; then
                printf '| `%s` | [`%s/AGENTS.md`](%s/AGENTS.md) |\n' \
                    "$name" "$name" "$name"
            else
                printf '| `%s` | — |\n' "$name"
            fi
        done
        ;;
esac
