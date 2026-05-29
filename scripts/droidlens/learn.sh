#!/usr/bin/env bash
# learn.sh - tap once and record a page-tree transition.
#
# Usage:
#   learn.sh tap         "Visible Text"          # tap by text and record
#   learn.sh tap-desc    "content-desc"          # tap by content-desc and record
#   learn.sh tap-xy      X Y                     # tap coordinates and record
#   learn.sh page-name   "Readable Name"         # alias current page to an explicit page key
#   learn.sh button-name "btn:PrimaryTab"        # name the last tap, overriding the default key
#
# Behavior:
#   - Marks hits inside scrollable containers as dynamic, so coordinates are not cached.
#   - Names button_key as "<via>:<value>", for example "desc:More options".
#   - Runs whereami before and after the tap to build a from->to edge.
#
# Env:
#   DROIDLENS_STORE   page-tree.json path, default ~/.droidlens/page-tree.json
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STORE="${DROIDLENS_STORE:-$HOME/.droidlens/page-tree.json}"
mkdir -p "$(dirname "$STORE")"

# Read current whereami state into page/bucket variables.
whereami_now() {
    page=""
    device_key=""
    fingerprint=""
    activity=""
    texts_json="[]"
    eval "$("$HERE/whereami.sh")"
}

case "${1:-}" in
    page-name|alias)
        whereami_now
        ALIAS="${2:?Usage: learn.sh page-name NAME}"
        MERGED="$(py "$HERE/pagetree.py" alias-page "$STORE" "$device_key" "$ALIAS" "$page" "$fingerprint" "$activity" "$texts_json")"
        printf '  merged %s old entries -> "%s"\n' "$MERGED" "$ALIAS" >&2
        printf 'learned: page-alias "%s" @ bucket "%s" (fingerprint=%s)\n' "$ALIAS" "$device_key" "$fingerprint"
        exit 0 ;;
esac

# tap / tap-desc / tap-xy run a tap and learn the transition.
ACTION="${1:?Usage: see learn.sh -h}"; shift

# 1) Before page.
whereami_now
FROM_PAGE="$page"
FROM_BUCKET="$device_key"

# 2) Find target bounds and keep metadata for dynamic-row detection.
XML="$(mktemp -t droidlens.XXXXXX.xml)"
trap 'rm -f "$XML"' EXIT
dump_xml "$XML"

LOOKUP_VIA=""
LOOKUP_VAL=""
HIT_X=""; HIT_Y=""; IS_DYNAMIC="0"

case "$ACTION" in
    tap)
        LOOKUP_VIA=text
        LOOKUP_VAL="${1:?Usage: learn.sh tap TEXT}"
        ;;
    tap-desc)
        LOOKUP_VIA=desc
        LOOKUP_VAL="${1:?Usage: learn.sh tap-desc DESC}"
        ;;
    tap-xy)
        LOOKUP_VIA=xy
        HIT_X="${1:?Usage: learn.sh tap-xy X Y}"
        HIT_Y="${2:?Usage: learn.sh tap-xy X Y}"
        ;;
    *) die "unknown action: $ACTION (expected tap / tap-desc / tap-xy / page-name / alias)" ;;
esac

# 3) Resolve coordinates and dynamic-row status.
# Heuristic: hits inside scrollable ancestors are dynamic; multiple same-screen hits also count.
if [[ "$LOOKUP_VIA" != "xy" ]]; then
    BY="$LOOKUP_VIA"
    [[ "$BY" == "desc" ]] && BY=desc
    if ! PARSED="$(py "$HERE/uixml.py" find "$XML" --by "$BY" --value "$LOOKUP_VAL" --nth 1 --json)"; then
        die "did not find $LOOKUP_VIA=\"$LOOKUP_VAL\" on the current page"
    fi
    IFS=$'\t' read -r HIT_X HIT_Y TOTAL IN_SCROLLABLE <<< "$(
        py - "$PARSED" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
picked = payload["picked"]
cx, cy = picked["center"]
print(f"{cx}\t{cy}\t{payload['total']}\t{1 if picked.get('inScrollable') else 0}")
PY
    )"
    [[ "$IN_SCROLLABLE" == "1" || "$TOTAL" -ge 2 ]] && IS_DYNAMIC="1"
fi

# 4) Perform tap.
tap_xy "$HIT_X" "$HIT_Y"
sleep 0.6

# 5) After page.
whereami_now
TO_PAGE="$page"
TO_BUCKET="$device_key"

# 6) Write page/button/edge in one transaction.
BUTTON_KEY="${LOOKUP_VIA}:${LOOKUP_VAL:-${HIT_X},${HIT_Y}}"
py "$HERE/pagetree.py" learn-transition \
    "$STORE" "$FROM_BUCKET" "$FROM_PAGE" "$TO_BUCKET" "$TO_PAGE" \
    "$BUTTON_KEY" "$HIT_X" "$HIT_Y" "$LOOKUP_VIA" "${LOOKUP_VAL:-}" "$IS_DYNAMIC"

printf 'learn: [%s] --%s--> [%s] @ (%s,%s) %s\n' \
    "$FROM_PAGE" "$BUTTON_KEY" "$TO_PAGE" "$HIT_X" "$HIT_Y" \
    "$([[ $IS_DYNAMIC == 1 ]] && echo '(dynamic, coordinates not cached)' || echo '(static, coordinates cached)')"
