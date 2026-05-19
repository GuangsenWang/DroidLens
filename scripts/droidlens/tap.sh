#!/usr/bin/env bash
# tap.sh - locate a UI element by selector and tap its center.
#
# Usage:
#   tap.sh "Play next"            # exact text match by default
#   tap.sh --desc "More options"  # content-desc match, first match by default
#   tap.sh --re "Play.*"          # text regex match
#   tap.sh --id "com.foo:id/save" # resource-id match
#   tap.sh --xml dump.xml "Play"  # reuse an existing XML dump
#   tap.sh --nth 2 --desc "More"  # second match, 1-indexed
#   tap.sh --img 360x780 180 650  # map image coordinates to device coordinates
#   tap.sh --meta shot.meta.json 180 650  # preferred screenshot metadata mapping
#   tap.sh --dry-run --meta shot.meta.json 180 650  # print mapping without tapping
#
# Env:
#   DROIDLENS_TAP_DEBUG=1  # print matched bounds and parsing details
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

BY=text     # text | desc | resource-id | class
MATCH=exact # exact | regex | contains
NTH=1
XML=""
QUERY=""
CLICKABLE=""
ENABLED=""
IMG_SIZE=""
IMG_X=""
IMG_Y=""
META=""
DRY_RUN=0
JSON=0

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

perform_tap() {
    local x="$1" y="$2"
    if [[ "$DRY_RUN" == "1" ]]; then
        [[ "$JSON" == "1" ]] || printf 'dry-run tap @ (%d,%d)\n' "$x" "$y"
    else
        adb shell input tap "$x" "$y"
    fi
}

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

require_dangerous_tap_policy() {
    local app risk result
    [[ "${DROIDLENS_ALLOW_DANGEROUS:-0}" == "1" ]] && return 0
    app="$(current_package 2>/dev/null || true)"
    [[ -n "$app" ]] || app="*"
    risk="Taps text that looks destructive or privileged: $QUERY"
    if [[ "$JSON" == "1" ]]; then
        if ! result="$("$HERE/policy.sh" check --action tap-dangerous --app "$app" --consume --risk "$risk" --json 2>&1)"; then
            printf '%s\n' "$result"
            exit 1
        fi
    else
        "$HERE/policy.sh" check --action tap-dangerous --app "$app" --consume --risk "$risk" \
            || fail "approval_required" "dangerous tap requires approval: $QUERY"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --desc) BY=desc; shift ;;
        --id|--resource-id) BY=resource-id; shift ;;
        --class) BY=class; shift ;;
        --re)   MATCH=regex; shift ;;
        --contains) MATCH=contains; shift ;;
        --xml)  XML="$2";  shift 2 ;;
        --nth)  NTH="$2";  shift 2 ;;
        --clickable) CLICKABLE=true; shift ;;
        --enabled) ENABLED=true; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --json) JSON=1; shift ;;
        --meta)
            META="$2"
            IMG_X="$3"
            IMG_Y="$4"
            shift 4
            ;;
        --img|--image)
            IMG_SIZE="$2"
            IMG_X="$3"
            IMG_Y="$4"
            shift 4
            ;;
        -h|--help)
            sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --) shift; QUERY="$*"; break ;;
        *)  QUERY="$1"; shift ;;
    esac
done

if [[ -n "$META" ]]; then
    [[ -f "$META" ]] || fail "meta_not_found" "--meta file does not exist: $META"
    if ! is_uint "$IMG_X" || ! is_uint "$IMG_Y"; then
        fail "invalid_args" "Usage: $0 --meta shot.meta.json X Y"
    fi
    DEV_W="$(wm_width)"
    DEV_H="$(wm_height)"
    if ! MAPPED="$(python3 - "$META" "$IMG_X" "$IMG_Y" "$DEV_W" "$DEV_H" 2>&1 <<'PY'
import json
import sys

meta_path, img_x, img_y, cur_w, cur_h = sys.argv[1:6]
img_x, img_y, cur_w, cur_h = map(int, (img_x, img_y, cur_w, cur_h))
with open(meta_path, encoding="utf-8") as fh:
    meta = json.load(fh)
try:
    device_w = int(meta["deviceWidth"])
    device_h = int(meta["deviceHeight"])
    image_w = int(meta["imageWidth"])
    image_h = int(meta["imageHeight"])
except (KeyError, TypeError, ValueError) as exc:
    raise SystemExit(f"invalid meta fields: {exc}")
if image_w <= 0 or image_h <= 0 or device_w <= 0 or device_h <= 0:
    raise SystemExit("invalid zero/negative dimensions")
if (cur_w, cur_h) != (device_w, device_h):
    raise SystemExit(
        f"meta device {device_w}x{device_h} != current device {cur_w}x{cur_h}; "
        "recapture screenshot for this device/orientation"
    )
if not (0 <= img_x <= image_w and 0 <= img_y <= image_h):
    raise SystemExit(f"image coordinate ({img_x},{img_y}) outside {image_w}x{image_h}")
cx = (img_x * device_w + image_w // 2) // image_w
cy = (img_y * device_h + image_h // 2) // image_h
print(f"{cx}\t{cy}\t{image_w}\t{image_h}\t{device_w}\t{device_h}")
PY
    )"; then
        fail "meta_device_mismatch" "meta coordinate mapping failed: $MAPPED"
    fi
    IFS=$'\t' read -r CX CY IMG_W IMG_H DEV_W DEV_H <<< "$MAPPED"
    [[ -n "${DROIDLENS_TAP_DEBUG:-}" ]] && log "image ($IMG_X,$IMG_Y) / ${IMG_W}x${IMG_H} → device ($CX,$CY) / ${DEV_W}x${DEV_H} via $META"
    perform_tap "$CX" "$CY"
    if [[ "$JSON" == "1" ]]; then
        json_emit "ok=true" "action=tap-meta" "dryRun=$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
            "imageX=$IMG_X" "imageY=$IMG_Y" "imageWidth=$IMG_W" "imageHeight=$IMG_H" \
            "x=$CX" "y=$CY" "meta=$META"
    else
        printf 'tap-meta → (%d,%d) from %sx%s @ device (%d,%d)\n' "$IMG_X" "$IMG_Y" "$IMG_W" "$IMG_H" "$CX" "$CY"
    fi
    exit 0
fi

if [[ -n "$IMG_SIZE" ]]; then
    [[ "$IMG_SIZE" =~ ^[0-9]+x[0-9]+$ ]] || fail "invalid_args" "--img size must be WxH, for example 360x780"
    if ! is_uint "$IMG_X" || ! is_uint "$IMG_Y"; then
        fail "invalid_args" "Usage: $0 --img WxH X Y"
    fi
    IMG_W="${IMG_SIZE%x*}"
    IMG_H="${IMG_SIZE#*x}"
    [[ "$IMG_W" -gt 0 && "$IMG_H" -gt 0 ]] || fail "invalid_args" "--img size must be greater than 0"
    [[ "$IMG_X" -le "$IMG_W" && "$IMG_Y" -le "$IMG_H" ]] || fail "tap_coordinate_out_of_bounds" "image coordinate ($IMG_X,$IMG_Y) outside ${IMG_W}x${IMG_H}"
    DEV_W="$(wm_width)"
    DEV_H="$(wm_height)"
    CX=$(( (IMG_X * DEV_W + IMG_W / 2) / IMG_W ))
    CY=$(( (IMG_Y * DEV_H + IMG_H / 2) / IMG_H ))
    [[ -n "${DROIDLENS_TAP_DEBUG:-}" ]] && log "image ($IMG_X,$IMG_Y) / $IMG_SIZE → device ($CX,$CY) / ${DEV_W}x${DEV_H}"
    perform_tap "$CX" "$CY"
    if [[ "$JSON" == "1" ]]; then
        json_emit "ok=true" "action=tap-img" "dryRun=$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
            "imageX=$IMG_X" "imageY=$IMG_Y" "imageWidth=$IMG_W" "imageHeight=$IMG_H" "x=$CX" "y=$CY"
    else
        printf 'tap-img → (%d,%d) from %s @ device (%d,%d)\n' "$IMG_X" "$IMG_Y" "$IMG_SIZE" "$CX" "$CY"
    fi
    exit 0
fi

[[ -z "$QUERY" ]] && fail "invalid_args" "Usage: $0 [--desc|--id|--class|--re|--contains] [--nth N] [--xml FILE] QUERY"
if is_dangerous_action_text "$QUERY"; then
    require_dangerous_tap_policy
fi

# 1) Get XML.
if [[ -z "$XML" ]]; then
    XML="$(mktemp -t droidlens.XXXXXX.xml)"
    trap 'rm -f "$XML"' EXIT
    dump_xml "$XML" || fail "xml_dump_failed" "uiautomator XML dump failed"
fi

# 2) Find bounds in XML.
FIND_ARGS=(find "$XML" --by "$BY" --value "$QUERY" --match "$MATCH" --nth "$NTH")
[[ -n "$CLICKABLE" ]] && FIND_ARGS+=(--clickable "$CLICKABLE")
[[ -n "$ENABLED" ]] && FIND_ARGS+=(--enabled "$ENABLED")
if ! PICKED="$(python3 "$HERE/uixml.py" "${FIND_ARGS[@]}")"; then
    fail "tap_target_not_found" "no matching element found: by=$BY match=$MATCH query='$QUERY' nth=$NTH"
fi
IFS=$'\t' read -r CX CY TOTAL X1 Y1 X2 Y2 <<< "$PICKED"

[[ -n "${DROIDLENS_TAP_DEBUG:-}" ]] && log "match $NTH/$TOTAL by=$BY bounds=[$X1,$Y1][$X2,$Y2] → tap ($CX,$CY)"

perform_tap "$CX" "$CY"
if [[ "$DRY_RUN" != "1" ]]; then
    wait_ui_stable "${DROIDLENS_TAP_STABLE_TIMEOUT:-3}" >/dev/null 2>&1 || true
fi
if [[ "$JSON" == "1" ]]; then
    json_emit "ok=true" "action=tap" "dryRun=$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
        "by=$BY" "match=$MATCH" "query=$QUERY" "nth=$NTH" "total=$TOTAL" \
        "x=$CX" "y=$CY" "x1=$X1" "y1=$Y1" "x2=$X2" "y2=$Y2"
else
    printf 'tap → "%s" @ (%d,%d) [%d/%d]\n' "$QUERY" "$CX" "$CY" "$NTH" "$TOTAL"
fi
