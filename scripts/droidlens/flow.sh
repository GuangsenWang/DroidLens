#!/usr/bin/env bash
# flow.sh - run a small DSL for UI navigation and regression steps.
# Steps can emit XML, summaries, screenshots, notes, and JSONL events.
#
# Usage:
#   flow.sh OUT_DIR FLOW_FILE
# Env:
#   DROIDLENS_SUMMARY_EVERY_STEP=1   # default: write step-NN.summary.json after each action
#   DROIDLENS_SNAP_EVERY_STEP=1      # compatibility: also write screenshots after each action
#   DROIDLENS_FLOW_SNAP_MODE=--thumb # screenshot mode: --ai/--thumb/--lossy/--png/--raw
#
# FLOW_FILE syntax. Blank lines and lines starting with # are ignored.
#   snap                       # capture the current screen
#   tap "Play next"            # tap by text
#   tap-desc "More options"    # tap by content-desc
#   tap-desc "Tab description" # first match by default
#   tap-nth 2 "More options"   # text mode with the second match
#   tap-xy X Y                 # device coordinates; prefer tap/tap-desc in reusable flows
#   key BACK                   # adb keyevent KEYCODE_BACK
#   sleep 2                    # wait 2 seconds
#   wait-text "Media Details"  # poll until text appears, default 10s
#   launch auto                # resolve app from profile, Gradle, or ADB
#   launch PACKAGE/.ACTIVITY   # explicit app component
#   note "free text"           # write a step note
#
# Put project-specific flows under .droidlens/flows/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

JSONL=0
if [[ "${1:-}" == "--jsonl" ]]; then
    JSONL=1
    shift
fi

OUT_DIR="${1:-}"
FLOW="${2:-}"
[[ -z "$OUT_DIR" || -z "$FLOW" ]] && die "Usage: $0 OUT_DIR FLOW_FILE"
[[ ! -f "$FLOW" ]] && die "FLOW_FILE does not exist: $FLOW"
mkdir -p "$OUT_DIR"
ensure_device_stayon

STEP=0
SUMMARY_EVERY_STEP="${DROIDLENS_SUMMARY_EVERY_STEP:-1}"
SNAP_EVERY_STEP="${DROIDLENS_SNAP_EVERY_STEP:-0}"
FLOW_SNAP_MODE="${DROIDLENS_FLOW_SNAP_MODE:---thumb}"

flow_event() {
    [[ "$JSONL" == "1" ]] || return 0
    py - "$@" <<'PY'
import json
import sys

payload = {}
for item in sys.argv[1:]:
    key, _, value = item.partition("=")
    if value in {"true", "false"}:
        payload[key] = value == "true"
    else:
        payload[key] = value
print(json.dumps(payload, ensure_ascii=False))
PY
}

flow_child_event() {
    [[ "$JSONL" == "1" ]] || return 0
    local event="$1" step="$2" child_json="$3"
    py - "$event" "$step" "$child_json" <<'PY'
import json
import sys

event, step, child_json = sys.argv[1:4]
payload = {"ok": True, "event": event}
if step:
    payload["step"] = step
try:
    result = json.loads(child_json)
    payload["result"] = result
    if isinstance(result, dict) and result.get("ok") is False:
        payload["ok"] = False
        if "errorCode" in result:
            payload["errorCode"] = result["errorCode"]
except json.JSONDecodeError:
    payload["ok"] = False
    payload["errorCode"] = "invalid_child_json"
    payload["raw"] = child_json
print(json.dumps(payload, ensure_ascii=False))
PY
}

flow_artifact_event() {
    [[ "$JSONL" == "1" ]] || return 0
    flow_event ok=true event=artifact step="$1" kind="$2" path="$3"
}

on_error() {
    local exit_code=$?
    flow_event ok=false event=error exitCode="$exit_code" line="${line:-}"
    exit "$exit_code"
}

if [[ "$JSONL" == "1" ]]; then
    trap on_error ERR
fi

snap_ext_for_mode() {
    case "$1" in
        --ai|--thumb|--lossy) printf 'webp\n' ;;
        --png|auto|"") printf 'png\n' ;;
        --raw) printf 'png\n' ;;
        *) die "unknown screenshot mode: $1" ;;
    esac
}

snap_mode_for_snap_sh() {
    case "$1" in
        --png) printf 'auto\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

do_snap() {
    STEP=$((STEP+1))
    local name ext snap_mode out snap_json
    name="$(printf 'step-%02d' "$STEP")"
    ext="$(snap_ext_for_mode "$FLOW_SNAP_MODE")"
    snap_mode="$(snap_mode_for_snap_sh "$FLOW_SNAP_MODE")"
    out="$OUT_DIR/$name.$ext"
    if [[ "$JSONL" == "1" ]]; then
        if ! snap_json="$("$HERE/snap.sh" "$out" "$snap_mode" --json)"; then
            flow_child_event snap "$name" "$snap_json"
            return 1
        fi
        flow_child_event snap "$name" "$snap_json"
    else
        "$HERE/snap.sh" "$out" "$snap_mode" | sed 's/^/    /'
    fi
}

capture_after_action() {
    STEP=$((STEP+1))
    local name xml
    name="$(printf 'step-%02d' "$STEP")"
    if [[ "$SUMMARY_EVERY_STEP" == "1" ]]; then
        xml="$OUT_DIR/$name.xml"
        dump_xml "$xml"
        py "$HERE/uixml.py" summary "$xml" --width "$(wm_width)" --height "$(wm_height)" \
            > "$OUT_DIR/$name.summary.json"
        flow_artifact_event "$name" xml "$xml"
        flow_artifact_event "$name" summary "$OUT_DIR/$name.summary.json"
    fi
    if [[ "$SNAP_EVERY_STEP" == "1" ]]; then
        local ext snap_mode out snap_json
        ext="$(snap_ext_for_mode "$FLOW_SNAP_MODE")"
        snap_mode="$(snap_mode_for_snap_sh "$FLOW_SNAP_MODE")"
        out="$OUT_DIR/$name.$ext"
        if [[ "$JSONL" == "1" ]]; then
            if ! snap_json="$("$HERE/snap.sh" "$out" "$snap_mode" --json)"; then
                flow_child_event snap "$name" "$snap_json"
                return 1
            fi
            flow_child_event snap "$name" "$snap_json"
        else
            "$HERE/snap.sh" "$out" "$snap_mode" | sed 's/^/    /'
        fi
    fi
}

run_tap() {
    if [[ "$JSONL" == "1" ]]; then
        local tap_json
        if ! tap_json="$("$HERE/tap.sh" --json "$@")"; then
            flow_child_event tap "" "$tap_json"
            return 1
        fi
        flow_child_event tap "" "$tap_json"
    else
        "$HERE/tap.sh" "$@"
    fi
}

wait_text() {
    local q="$1" timeout="${2:-10}"
    local xml end
    end=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < end )); do
        xml="$(mktemp -t droidlens.XXXXXX.xml)"
        dump_xml "$xml" >/dev/null 2>&1
        if py "$HERE/uixml.py" has "$xml" --by text --value "$q" \
            || py "$HERE/uixml.py" has "$xml" --by desc --value "$q"; then
            rm -f "$xml"
            flow_event ok=true event=wait-text query="$q" timeout="$timeout" found=true
            return 0
        fi
        rm -f "$xml"
        sleep 0.5
    done
    log "WARNING: wait-text '$q' timed out after ${timeout}s"
    flow_event ok=false event=wait-text query="$q" timeout="$timeout" found=false
    return 1
}

split_args() {
    SPLIT_ARGS=()
    local parsed part
    parsed="$(py "$HERE/uixml.py" split "$1")" || die "failed to parse DSL arguments: $1"
    while IFS= read -r part; do
        [[ -n "$part" ]] && SPLIT_ARGS+=("$part")
    done <<< "$parsed"
}

# Read the flow into an array so child commands cannot consume loop stdin.
FLOW_LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    FLOW_LINES+=("$line")
done < "$FLOW"

for line in "${FLOW_LINES[@]}"; do
    # Trim and skip comments/blank lines.
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # Parse command keyword.
    cmd="${line%% *}"
    args="${line#"$cmd"}"
    args="${args# }"

    log ">> $line"
    flow_event ok=true event=command command="$cmd" line="$line"
    case "$cmd" in
        snap)
            do_snap
            ;;
        tap)
            # Arguments may contain quotes.
            split_args "$args"
            run_tap "${SPLIT_ARGS[@]}"
            wait_ui_stable "${DROIDLENS_FLOW_STABLE_TIMEOUT:-4}" >/dev/null 2>&1 || sleep 0.5
            capture_after_action
            ;;
        tap-desc)
            split_args "$args"
            run_tap --desc "${SPLIT_ARGS[@]}"
            wait_ui_stable "${DROIDLENS_FLOW_STABLE_TIMEOUT:-4}" >/dev/null 2>&1 || sleep 0.5
            capture_after_action
            ;;
        tap-nth)
            # tap-nth N "Query"
            split_args "$args"
            N=${SPLIT_ARGS[0]:?tap-nth N QUERY}
            unset 'SPLIT_ARGS[0]'
            run_tap --nth "$N" "${SPLIT_ARGS[@]}"
            wait_ui_stable "${DROIDLENS_FLOW_STABLE_TIMEOUT:-4}" >/dev/null 2>&1 || sleep 0.5
            capture_after_action
            ;;
        tap-xy)
            split_args "$args"
            adb shell input tap "${SPLIT_ARGS[0]}" "${SPLIT_ARGS[1]}"
            flow_event ok=true event=tap-xy x="${SPLIT_ARGS[0]}" y="${SPLIT_ARGS[1]}"
            wait_ui_stable "${DROIDLENS_FLOW_STABLE_TIMEOUT:-4}" >/dev/null 2>&1 || sleep 0.5
            capture_after_action
            ;;
        key)
            adb shell input keyevent "KEYCODE_$args"
            flow_event ok=true event=key key="$args"
            wait_ui_stable "${DROIDLENS_FLOW_STABLE_TIMEOUT:-4}" >/dev/null 2>&1 || sleep 0.3
            capture_after_action
            ;;
        sleep)
            flow_event ok=true event=sleep seconds="$args"
            sleep "$args"
            ;;
        wait-text)
            split_args "$args"
            wait_text "${SPLIT_ARGS[@]}"
            capture_after_action
            ;;
        launch)
            if [[ "$args" == "auto" || "$args" != */* ]]; then
                if [[ "$JSONL" == "1" ]]; then
                    launch_json="$("$HERE/app.sh" launch --app "$args" --json)"
                    flow_child_event launch "" "$launch_json"
                else
                    "$HERE/app.sh" launch --app "$args" >/dev/null
                fi
            else
                adb shell am start -n "$args" >/dev/null
                flow_event ok=true event=launch component="$args"
            fi
            wait_ui_stable "${DROIDLENS_FLOW_STABLE_TIMEOUT:-6}" >/dev/null 2>&1 || sleep 2
            capture_after_action
            ;;
        note)
            STEP=$((STEP+1))
            note_path="$OUT_DIR/$(printf 'step-%02d.note.txt' "$STEP")"
            printf '%s\n' "$args" > "$note_path"
            flow_artifact_event "$(printf 'step-%02d' "$STEP")" note "$note_path"
            ;;
        *) die "unknown DSL command: $cmd (expected snap/tap/tap-desc/tap-nth/tap-xy/key/sleep/wait-text/launch/note)" ;;
    esac
done

ARTIFACT_COUNT="$(find "$OUT_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
log "complete. artifacts: $ARTIFACT_COUNT -> $OUT_DIR/"
flow_event ok=true event=complete outputDir="$OUT_DIR"
