#!/usr/bin/env bash
# Risk-tiered, documented ADB subset for AI-driven UI debugging.
#
# This wrapper intentionally exposes bounded commands needed by droidlens.
# It has safe UI commands, managed test-lifecycle commands, and dangerous
# commands that require a DroidLens policy grant or a single-command escape hatch.
#
# Safe:
#   adbctl.sh devices|current|wm|density|wake|back|home
#   adbctl.sh key BACK
#   adbctl.sh text "query"
#   adbctl.sh tap PCT_X PCT_Y
#   adbctl.sh swipe FROM_X FROM_Y TO_X TO_Y [MS]
#
# Managed:
#   adbctl.sh install-apk PATH.apk [--downgrade] [--grant] [--json]
#   adbctl.sh start-app --app auto|PKG|PKG/.ACTIVITY [--fresh] [--json]
#   adbctl.sh force-stop --app auto|PKG|PKG/.ACTIVITY [--json]
#
# Dangerous:
#   adbctl.sh clear-app-data --app auto|PKG|PKG/.ACTIVITY [--json]
#   adbctl.sh uninstall --app auto|PKG [--json]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
    awk '/^set -euo/{exit} /^#!/{next} /^#/ {sub(/^# ?/, ""); print}' "$0"
}

JSON=0
APP_SPEC="${DROIDLENS_APP:-auto}"
FRESH=0
INSTALL_DOWNGRADE=0
INSTALL_GRANT=0

require_keycode() {
    local key="$1"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "KEY must be a KEYCODE suffix, for example BACK / HOME / WAKEUP"
}

require_pct() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge 0 && "$value" -le 100 ]] \
        || die "$name must be an integer percentage from 0 to 100: $value"
}

pct_to_px() {
    local pct="$1" total="$2"
    printf '%s\n' $(( total * pct / 100 ))
}

emit_json() {
    json_emit "$@"
}

maybe_json_ok() {
    if [[ "$JSON" == "1" ]]; then
        emit_json "$@"
    fi
}

fail_adbctl() {
    local code="$1" message="$2"
    if [[ "$JSON" == "1" ]]; then
        emit_json "ok=false" "errorCode=$code" "message=$message"
        exit 1
    fi
    die "$message"
}

resolve_app_package() {
    app_package=""
    eval "$("$HERE/app.sh" resolve --app "$APP_SPEC")"
}

require_dangerous_policy() {
    local action="$1" risk="$2" result
    if [[ "${DROIDLENS_ALLOW_DANGEROUS:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "$JSON" == "1" ]]; then
        if ! result="$("$HERE/policy.sh" check --action "$action" --app "$app_package" --consume --risk "$risk" --json 2>&1)"; then
            printf '%s\n' "$result"
            exit 1
        fi
    else
        "$HERE/policy.sh" check --action "$action" --app "$app_package" --consume --risk "$risk" \
            || die "$action requires approval. Use a DroidLens policy grant or a single-command DROIDLENS_ALLOW_DANGEROUS=1 escape hatch"
    fi
}

parse_managed_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                APP_SPEC="${2:?--app requires SPEC}"
                shift 2
                ;;
            --fresh)
                FRESH=1
                shift
                ;;
            --downgrade)
                INSTALL_DOWNGRADE=1
                shift
                ;;
            --grant)
                INSTALL_GRANT=1
                shift
                ;;
            --json)
                JSON=1
                shift
                ;;
            *)
                fail_adbctl "invalid_args" "unknown argument: $1"
                ;;
        esac
    done
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 2; }
shift || true

case "$cmd" in
    -h|--help|help)
        usage
        ;;
    devices)
        authorized_devices
        ;;
    current)
        _current_component
        ;;
    wm|size)
        wm_size
        ;;
    density)
        wm_density
        ;;
    wake)
        wake_device
        ;;
    back)
        adb shell input keyevent KEYCODE_BACK >/dev/null
        ;;
    home)
        adb shell input keyevent KEYCODE_HOME >/dev/null
        ;;
    key)
        key="${1:?Usage: adbctl.sh key BACK|HOME|WAKEUP|...}"
        require_keycode "$key"
        adb shell input keyevent "KEYCODE_$key" >/dev/null
        ;;
    text)
        text="${1:?Usage: adbctl.sh text TEXT}"
        escaped_text="$(python3 - "$text" <<'PY'
import sys

value = sys.argv[1]
escaped = (
    value.replace("%", "%25")
    .replace(" ", "%s")
    .replace("&", r"\&")
    .replace("<", r"\<")
    .replace(">", r"\>")
    .replace(";", r"\;")
    .replace("(", r"\(")
    .replace(")", r"\)")
    .replace("|", r"\|")
)
print(escaped)
PY
)"
        adb shell input text "$escaped_text" >/dev/null
        ;;
    tap)
        x_pct="${1:?Usage: adbctl.sh tap PCT_X PCT_Y}"
        y_pct="${2:?Usage: adbctl.sh tap PCT_X PCT_Y}"
        require_pct PCT_X "$x_pct"
        require_pct PCT_Y "$y_pct"
        x="$(pct_to_px "$x_pct" "$(wm_width)")"
        y="$(pct_to_px "$y_pct" "$(wm_height)")"
        adb shell input tap "$x" "$y" >/dev/null
        ;;
    swipe)
        from_x_pct="${1:?Usage: adbctl.sh swipe FROM_X FROM_Y TO_X TO_Y [MS]}"
        from_y_pct="${2:?Usage: adbctl.sh swipe FROM_X FROM_Y TO_X TO_Y [MS]}"
        to_x_pct="${3:?Usage: adbctl.sh swipe FROM_X FROM_Y TO_X TO_Y [MS]}"
        to_y_pct="${4:?Usage: adbctl.sh swipe FROM_X FROM_Y TO_X TO_Y [MS]}"
        duration_ms="${5:-300}"
        require_pct FROM_X "$from_x_pct"
        require_pct FROM_Y "$from_y_pct"
        require_pct TO_X "$to_x_pct"
        require_pct TO_Y "$to_y_pct"
        [[ "$duration_ms" =~ ^[0-9]+$ && "$duration_ms" -le 5000 ]] \
            || die "MS must be an integer from 0 to 5000: $duration_ms"
        w="$(wm_width)"
        h="$(wm_height)"
        adb shell input swipe \
            "$(pct_to_px "$from_x_pct" "$w")" "$(pct_to_px "$from_y_pct" "$h")" \
            "$(pct_to_px "$to_x_pct" "$w")" "$(pct_to_px "$to_y_pct" "$h")" \
            "$duration_ms" >/dev/null
        ;;
    install-apk)
        apk="${1:?Usage: adbctl.sh install-apk PATH.apk [--downgrade] [--grant] [--json]}"
        shift
        parse_managed_flags "$@"
        [[ -f "$apk" ]] || fail_adbctl "apk_not_found" "APK does not exist: $apk"
        [[ "$apk" == *.apk ]] || fail_adbctl "invalid_apk" "install-apk only accepts .apk files: $apk"
        install_args=(-r)
        [[ "$INSTALL_DOWNGRADE" == "1" ]] && install_args+=(-d)
        [[ "$INSTALL_GRANT" == "1" ]] && install_args+=(-g)
        if adb install "${install_args[@]}" "$apk" >/dev/null; then
            maybe_json_ok "ok=true" "action=install-apk" "apk=$apk" \
                "downgrade=$([[ "$INSTALL_DOWNGRADE" == "1" ]] && echo true || echo false)" \
                "grant=$([[ "$INSTALL_GRANT" == "1" ]] && echo true || echo false)"
        else
            fail_adbctl "install_failed" "adb install failed: $apk"
        fi
        ;;
    start-app)
        parse_managed_flags "$@"
        if [[ "$JSON" == "1" ]]; then
            "$HERE/app.sh" launch --app "$APP_SPEC" ${FRESH:+--fresh} --json
        else
            "$HERE/app.sh" launch --app "$APP_SPEC" ${FRESH:+--fresh}
        fi
        ;;
    force-stop)
        parse_managed_flags "$@"
        resolve_app_package
        adb shell am force-stop "$app_package" >/dev/null
        maybe_json_ok "ok=true" "action=force-stop" "package=$app_package"
        ;;
    clear-app-data)
        parse_managed_flags "$@"
        resolve_app_package
        require_dangerous_policy "clear-app-data" "Deletes app databases, preferences, cache, session state, and local test data."
        adb shell pm clear "$app_package" >/dev/null
        maybe_json_ok "ok=true" "action=clear-app-data" "package=$app_package"
        ;;
    uninstall)
        parse_managed_flags "$@"
        resolve_app_package
        require_dangerous_policy "uninstall" "Uninstalls the target app and may remove app-local data."
        adb uninstall "$app_package" >/dev/null
        maybe_json_ok "ok=true" "action=uninstall" "package=$app_package"
        ;;
    *)
        die "unknown adbctl command: $cmd. Run adbctl.sh --help for command tiers"
        ;;
esac
