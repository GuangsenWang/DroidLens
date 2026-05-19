#!/usr/bin/env bash
# observe.sh — classify current device/UI state for droidlens routing.
# Usage:
#   observe.sh [--app PKG/.ACTIVITY] [--store ~/.droidlens/page-tree.json]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STORE="${DROIDLENS_STORE:-$HOME/.droidlens/page-tree.json}"
APP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP="${2:?Usage: $0 --app PKG/.ACTIVITY}"
            shift 2
            ;;
        --store)
            STORE="${2:?Usage: $0 --store PATH}"
            shift 2
            ;;
        -h|--help)
            awk '/^set -euo/{exit} /^#!/{next} /^#/ {sub(/^# ?/, ""); print}' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

# whereami.sh should emit every field, but observe must stay robust when an
# older helper or interrupted dump returns a partial key=value set.
package=""
activity=""
device_key=""
page=""
title=""
fingerprint=""
match_kind="none"
jaccard="0.00"
texts_json="[]"

WHEREAMI_OUTPUT="$(DROIDLENS_STORE="$STORE" "$HERE/whereami.sh")"
eval "$WHEREAMI_OUTPUT"

read -r HAS_PERMISSION_TEXT HAS_CRASH_TEXT HAS_SYSTEM_OVERLAY_TEXT < <(python3 - "${texts_json:-[]}" <<'PY'
import json
import sys

try:
    texts = json.loads(sys.argv[1])
except Exception:
    texts = []

def has_any(markers):
    return any(marker in text for text in texts for marker in markers)

permission_markers = [
    "Don't allow",
    "While using the app",
    "\u4ec5\u5728\u4f7f\u7528\u8be5\u5e94\u7528\u65f6\u5141\u8bb8",
]
crash_markers = [
    "keeps stopping",
    "isn't responding",
    "Close app",
    "Wait",
    "\u65e0\u54cd\u5e94",
    "\u505c\u6b62\u8fd0\u884c",
]
system_overlay_markers = [
    "Android System notification",
    "Quick Settings",
]
print(
    int(has_any(permission_markers)),
    int(has_any(crash_markers)),
    int(has_any(system_overlay_markers)),
)
PY
)

TARGET_PKG=""
app_package=""
app_component=""
if [[ -z "$APP" && -n "${DROIDLENS_APP:-}" ]]; then
    APP="$DROIDLENS_APP"
fi
if [[ -n "$APP" ]]; then
    eval "$("$HERE/app.sh" resolve --app "$APP")"
    APP="$app_component"
    TARGET_PKG="$app_package"
fi

STATE="unknown_app_page"
ACTION="inspect_current"
REASON="page was not matched to learned fingerprints"
KNOWN=false
IN_TARGET=false

case "${match_kind:-none}" in
    exact|jaccard|title)
        KNOWN=true
        ;;
esac

if [[ -n "$TARGET_PKG" && "${package:-}" == "$TARGET_PKG" ]]; then
    IN_TARGET=true
elif [[ -z "$TARGET_PKG" ]]; then
    IN_TARGET=true
fi

if [[ "${package:-}" == "com.google.android.permissioncontroller" || "${package:-}" == "com.android.permissioncontroller" || "$HAS_PERMISSION_TEXT" == "1" ]]; then
    STATE="permission_dialog"
    ACTION="ask_user_or_policy"
    REASON="runtime permission dialog is visible"
elif [[ "$HAS_CRASH_TEXT" == "1" ]]; then
    STATE="crash_or_anr_dialog"
    ACTION="stop_and_collect_failure"
    REASON="crash or ANR dialog appears visible"
elif [[ "${package:-}" == "android" && "${activity:-}" == *"ResolverActivity"* || "${package:-}" == "com.android.intentresolver" ]]; then
    STATE="external_chooser"
    ACTION="ask_user_or_policy"
    REASON="external chooser/share sheet is visible"
elif [[ "${package:-}" == "com.android.systemui" || "${activity:-}" == *"SystemUI"* ]]; then
    STATE="system_overlay"
    ACTION="back_recover"
    REASON="system UI is foreground"
elif [[ "$HAS_SYSTEM_OVERLAY_TEXT" == "1" ]]; then
    STATE="system_overlay"
    ACTION="back_recover"
    REASON="system overlay or notification shade appears above the target app"
elif [[ "$IN_TARGET" != true ]]; then
    STATE="outside_target_app"
    ACTION="launch_app"
    REASON="foreground package does not match target"
elif [[ "$KNOWN" == true ]]; then
    STATE="known_app_page"
    ACTION="route_from_current"
    REASON="current page matched learned page"
elif [[ "${package:-}" == "com.android.launcher"* || "${activity:-}" == *"Launcher"* ]]; then
    STATE="launcher"
    ACTION="launch_app"
    REASON="device is at launcher"
else
    STATE="unknown_app_page"
    ACTION="back_recover"
    REASON="target app is foreground but page is unknown"
fi

python3 - "${package:-}" "${activity:-}" "${device_key:-}" "${page:-}" "${title:-}" "${fingerprint:-}" \
    "${match_kind:-none}" "${jaccard:-0.00}" "$TARGET_PKG" "$STATE" "$ACTION" "$REASON" "${texts_json:-[]}" <<'PY'
import json, sys
(
    package,
    activity,
    device_key,
    page,
    title,
    fingerprint,
    match_kind,
    jaccard,
    target_pkg,
    state,
    action,
    reason,
    texts_json,
) = sys.argv[1:14]
try:
    texts = json.loads(texts_json)
except Exception:
    texts = []
print(json.dumps({
    "package": package,
    "activity": activity,
    "deviceKey": device_key,
    "page": page,
    "title": title,
    "fingerprint": fingerprint,
    "matchKind": match_kind,
    "jaccard": jaccard,
    "targetPackage": target_pkg,
    "state": state,
    "knownPage": match_kind in {"exact", "jaccard", "title"},
    "recommendedAction": action,
    "reason": reason,
    "texts": texts,
}, ensure_ascii=False, indent=2))
PY
