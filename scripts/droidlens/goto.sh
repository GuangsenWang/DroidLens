#!/usr/bin/env bash
# goto.sh — recover from arbitrary device state and navigate by learned page-tree.
#
# Usage:
#   goto.sh [--app PKG/.ACTIVITY] [--fresh|--resume] [--recover|--no-recover] TARGET_PAGE [OUT_SNAP]
#
# Defaults:
#   - if --app is supplied and foreground package differs, launch app without force-stop
#   - if target app is foreground but page is unknown, press BACK up to --max-back times
#   - if recovery fails, force-stop + relaunch when --fresh-if-unknown is enabled
#   - every cached edge is verified; failed edge is marked stale and a repair bundle is saved
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STORE="${DROIDLENS_STORE:-$HOME/.droidlens/page-tree.json}"
APP=""
FRESH=0
RECOVER=1
FRESH_IF_UNKNOWN=1
MAX_BACK=5
MAX_LAUNCHES="${DROIDLENS_MAX_LAUNCHES:-3}"
LAUNCH_COUNT=0
OUT_SNAP=""
JSON=0

usage() {
    awk '/^set -euo/{exit} /^#!/{next} /^#/ {sub(/^# ?/, ""); print}' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP="${2:?Usage: goto.sh --app PKG/.ACT TARGET_PAGE}"
            shift 2
            ;;
        --launch)
            # Backward compatible: old --launch meant force-stop + relaunch.
            APP="${2:?Usage: goto.sh --launch PKG/.ACT TARGET_PAGE}"
            FRESH=1
            shift 2
            ;;
        --fresh)
            FRESH=1
            shift
            ;;
        --resume)
            FRESH=0
            shift
            ;;
        --recover)
            RECOVER=1
            shift
            ;;
        --no-recover)
            RECOVER=0
            shift
            ;;
        --fresh-if-unknown)
            FRESH_IF_UNKNOWN=1
            shift
            ;;
        --no-fresh-if-unknown)
            FRESH_IF_UNKNOWN=0
            shift
            ;;
        --max-back)
            MAX_BACK="${2:?Usage: goto.sh --max-back N TARGET_PAGE}"
            shift 2
            ;;
        --json)
            JSON=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown argument: $1"
            ;;
        *)
            break
            ;;
    esac
done

TARGET="${1:?Usage: goto.sh [--app PKG/.ACT] TARGET_PAGE [OUT_SNAP]}"
OUT_SNAP="${2:-}"
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

is_known_page() {
    case "${match_kind:-}" in
        exact|jaccard|title) return 0 ;;
        *) return 1 ;;
    esac
}

read_whereami() {
    package=""
    _activity=""
    device_key=""
    page=""
    _title=""
    _fingerprint=""
    match_kind="none"
    _jaccard="0.00"
    _texts_json="[]"
    eval "$("$HERE/whereami.sh")"
}

launch_app() {
    [[ -n "$APP" ]] || fail_goto "app_not_resolved" "current foreground app is unknown and --app PKG/.ACTIVITY was not provided"
    local reason="$1"
    if [[ "$LAUNCH_COUNT" -ge "$MAX_LAUNCHES" ]]; then
        fail_goto "launch_loop_guard" "app launch attempted $LAUNCH_COUNT times; stopping to avoid a launch loop. Last reason: $reason"
    fi
    LAUNCH_COUNT=$((LAUNCH_COUNT + 1))
    log "launch app ($reason): $APP"
    if [[ "$FRESH" == "1" || "$reason" == "fresh-if-unknown" ]]; then
        adb shell am force-stop "$TARGET_PKG" >/dev/null 2>&1 || true
        sleep 0.3
    fi
    adb shell am start -n "$APP" >/dev/null
    sleep 2
}

fail_goto() {
    local code="$1" message="$2" bundle=""
    bundle="$(failure_bundle "$code" "$message" "$APP" 2>/dev/null || true)"
    if [[ "$JSON" == "1" ]]; then
        json_emit "ok=false" "errorCode=$code" "message=$message" "bundle=$bundle" \
            "page=${page:-}" "target=$TARGET"
        exit 1
    fi
    die "$message${bundle:+ (bundle=$bundle)}"
}

snap_out() {
    local out="$1"
    [[ -z "$out" ]] && return 0
    case "$out" in
        *.webp) "$HERE/snap.sh" "$out" --thumb ;;
        *.png) "$HERE/snap.sh" "$out" --png ;;
        *) "$HERE/snap.sh" "$out.webp" --thumb ;;
    esac
}

mark_edge_stale() {
    local from="$1" via="$2" to="$3" reason="$4"
    python3 "$HERE/pagetree.py" mark-edge "$STORE" "$BUCKET" "$from" "$via" "$to" stale "$reason" \
        >/dev/null 2>&1 || true
}

verify_page() {
    local expected="$1"
    read_whereami
    [[ "$page" == "$expected" ]]
}

# 0) Optional fresh start.
if [[ "$FRESH" == "1" && -n "$APP" ]]; then
    launch_app "fresh"
fi

# 1) Observe current state. It may be launcher, another app, target app unknown page, or learned page.
read_whereami

if [[ -n "$TARGET_PKG" && "$package" != "$TARGET_PKG" ]]; then
    launch_app "outside-target-app"
    read_whereami
fi

# 2) If target app is foreground but page unknown, try least destructive BACK recovery first.
if ! is_known_page; then
    if [[ "$RECOVER" == "1" ]]; then
        tries=0
        while ! is_known_page && [[ "$tries" -lt "$MAX_BACK" ]]; do
            log "current page [$page] match=$match_kind is unknown; pressing BACK to search for a known page"
            adb shell input keyevent KEYCODE_BACK
            sleep 0.8
            read_whereami
            if [[ -n "$TARGET_PKG" && "$package" != "$TARGET_PKG" ]]; then
                log "BACK left the target app; stopping BACK recovery and launching the target app if needed"
                break
            fi
            tries=$((tries + 1))
        done
    fi

    if ! is_known_page && [[ "$FRESH_IF_UNKNOWN" == "1" && -n "$APP" ]]; then
        if [[ "$package" == "$TARGET_PKG" ]]; then
            launch_app "fresh-if-unknown"
        else
            launch_app "outside-after-back-recover"
        fi
        read_whereami
    fi
fi

if ! is_known_page; then
    fail_goto "unknown_page" "failed to identify current page [$page] match=$match_kind. Learn a start page with learn.sh page-name, or provide --app and ensure the launch page is learned."
fi

CUR="$page"
BUCKET="$device_key"
log "from=[$CUR] to=[$TARGET] bucket=$BUCKET match=$match_kind"

if [[ "$CUR" == "$TARGET" ]]; then
    log "already at target page"
    snap_out "$OUT_SNAP"
    if [[ "$JSON" == "1" ]]; then
        json_emit "ok=true" "from=$CUR" "target=$TARGET" "steps=0" "alreadyThere=true"
    fi
    exit 0
fi

# 3) BFS route, excluding stale/disabled edges.
ROUTE="$(python3 "$HERE/pagetree.py" route "$STORE" "$BUCKET" "$CUR" "$TARGET" || true)"
if [[ -z "$ROUTE" ]]; then
    fail_goto "route_not_found" "no usable page-tree route from [$CUR] to [$TARGET]. Learn a route or repair stale edges."
fi

log "route: $(echo "$ROUTE" | wc -l | tr -d ' ') steps"

STEPS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && STEPS+=("$line")
done <<< "$ROUTE"

STEP=0
for step_line in "${STEPS[@]}"; do
    STEP=$((STEP + 1))
    IFS=$'\t' read -r FROM_P VIA X Y TO_P DYNAMIC <<< "$step_line"

    if [[ "$DYNAMIC" == "1" || "$X" == "-1" ]]; then
        TAG="${VIA%%:*}"
        VAL="${VIA#*:}"
        log "[step $STEP] [$FROM_P] -- $VIA (selector) --> [$TO_P]"
        case "$TAG" in
            text) "$HERE/tap.sh" "$VAL" >/dev/null ;;
            desc) "$HERE/tap.sh" --desc "$VAL" >/dev/null ;;
            xy)   tap_xy "$X" "$Y" ;;
            *)    fail_goto "invalid_route_edge" "unknown via tag: $TAG" ;;
        esac
    else
        log "[step $STEP] [$FROM_P] -- $VIA --> [$TO_P] blind tap ($X,$Y)"
        tap_xy "$X" "$Y"
    fi
    wait_ui_stable "${DROIDLENS_GOTO_STABLE_TIMEOUT:-4}" >/dev/null 2>&1 || sleep 0.6

    if ! verify_page "$TO_P"; then
        mark_edge_stale "$FROM_P" "$VIA" "$TO_P" "verify_failed_expected_${TO_P}_actual_${page}"
        fail_goto "edge_stale" "step $STEP verification failed: expected [$TO_P], actual [$page]. Edge was marked stale."
    fi
done

if [[ "$page" != "$TARGET" ]]; then
    fail_goto "terminal_mismatch" "terminal verification failed: expected [$TARGET], actual [$page]"
fi

log "arrived at [$TARGET]"
snap_out "$OUT_SNAP"
if [[ "$JSON" == "1" ]]; then
    json_emit "ok=true" "from=$CUR" "target=$TARGET" "steps=${#STEPS[@]}" "alreadyThere=false"
fi
