#!/usr/bin/env bash
# summary.sh - extract a structured text fingerprint from the current screen:
#   - top_strip: text + content-desc in the top 12% of the screen
#   - bottom_strip: text + content-desc in the bottom 10%, usually bottom navigation
#   - statics: text outside scrollable containers, usually page structure
#   - dynamics: text inside scrollable containers, usually volatile list data
#
# Writes JSON to stdout. Prefer this before reading screenshots.
#
# Usage:
#   summary.sh                        # dump current screen
#   summary.sh --xml file.xml         # reuse an existing XML dump
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

XML=""
if [[ "${1:-}" == "--xml" ]]; then
    XML="$2"
else
    XML="$(mktemp -t droidlens.XXXXXX.xml)"
    trap 'rm -f "$XML"' EXIT
    dump_xml "$XML"
fi

W="$(wm_width)"
H="$(wm_height)"

py "$HERE/uixml.py" summary "$XML" --width "$W" --height "$H"
