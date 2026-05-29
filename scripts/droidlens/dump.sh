#!/usr/bin/env bash
# dump.sh - capture a screenshot and uiautomator XML together.
# Outputs STEM.<image> + STEM.xml. The XML can be consumed by tap.sh.
# Usage:
#   dump.sh OUT_STEM            # -> OUT_STEM.xml + OUT_STEM.webp (default thumb)
#   dump.sh OUT_STEM --thumb    # -> OUT_STEM.xml + OUT_STEM.webp
#   dump.sh OUT_STEM --png      # -> OUT_STEM.xml + OUT_STEM.png
#   dump.sh OUT_STEM --raw      # -> OUT_STEM.xml + OUT_STEM.png (raw PNG)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STEM=""
MODE="--thumb"
JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --ai|--thumb|--lossy|--png|--raw) MODE="$1"; shift ;;
        -h|--help)
            sed -n '1,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            if [[ -z "$STEM" ]]; then
                STEM="$1"
            else
                MODE="$1"
            fi
            shift ;;
    esac
done

fail() {
    local code="$1" message="$2" bundle=""
    if [[ "$JSON" == "1" ]]; then
        if [[ "${DROIDLENS_IN_FAILURE_BUNDLE:-0}" != "1" ]]; then
            bundle="$(failure_bundle "$code" "$message" 2>/dev/null || true)"
        fi
        json_emit "ok=false" "errorCode=$code" "message=$message" "bundle=$bundle"
        exit 1
    fi
    die "$message"
}

[[ -z "$STEM" ]] && fail "invalid_args" "Usage: $0 OUT_STEM [--ai|--thumb|--lossy|--png|--raw] [--json]"
mkdir -p "$(dirname "$STEM")"

# 1) UI XML.
if ! dump_xml "$STEM.xml"; then
    fail "xml_dump_failed" "uiautomator XML dump failed"
fi

# 2) Screenshot via snap.sh.
EXT=webp
SNAP_MODE="$MODE"
case "$MODE" in
    --ai|--thumb|--lossy) EXT=webp ;;
    --png|auto|"") EXT=png; SNAP_MODE=auto ;;
    --raw) EXT=png ;;
    *) fail "invalid_args" "unknown mode: $MODE (expected --ai / --thumb / --lossy / --png / --raw)" ;;
esac
if [[ "$JSON" == "1" ]]; then
    if ! SNAP_JSON="$("$HERE/snap.sh" "$STEM.$EXT" "$SNAP_MODE" --json)"; then
        if py -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$SNAP_JSON" 2>/dev/null; then
            printf '%s\n' "$SNAP_JSON"
            exit 1
        fi
        fail "screencap_failed" "snap failed"
    fi
    py - "$STEM" "$EXT" "$STEM.xml" "$SNAP_JSON" <<'PY'
import json
import sys

stem, ext, xml, snap_json = sys.argv[1:5]
snap = json.loads(snap_json)
print(json.dumps({
    "ok": True,
    "stem": stem,
    "xml": xml,
    "screen": f"{stem}.{ext}",
    "snap": snap,
}, ensure_ascii=False, indent=2))
PY
else
    "$HERE/snap.sh" "$STEM.$EXT" "$SNAP_MODE" | sed 's/^/    /'
    printf 'dump → %s.xml + %s.%s\n' "$STEM" "$STEM" "$EXT"
fi
