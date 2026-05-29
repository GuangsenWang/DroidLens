#!/usr/bin/env bash
# policy.sh — bounded dangerous-action grants for AFK DroidLens runs.
# Usage:
#   policy.sh grant --action ACTION --app auto|PKG|* [--ttl 30m] [--max-runs 1] [--reason TEXT] [--json]
#   policy.sh list [--all] [--json]
#   policy.sh revoke --id ID [--json]
#   policy.sh revoke --all [--json]
#   policy.sh check --action ACTION --app PKG [--consume] [--risk TEXT] [--json]
#   policy.sh audit [--limit N] [--json]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CMD="${1:-}"
[[ -n "$CMD" ]] || { sed -n '1,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift || true

POLICY_FILE="${DROIDLENS_POLICY_FILE:-$(find_project_root)/.droidlens/policy.json}"
AUDIT_FILE="${DROIDLENS_AUDIT_FILE:-$(find_project_root)/.droidlens/audit.jsonl}"
JSON=0
ACTION=""
APP_SPEC=""
APP_PACKAGE=""
SERIAL=""
TTL="30m"
MAX_RUNS="1"
REASON=""
GRANT_ID=""
ALL=0
CONSUME=0
RISK=""
LIMIT=""

policy_serial() {
    if [[ -n "$SERIAL" ]]; then
        printf '%s\n' "$SERIAL"
        return 0
    fi
    if [[ -n "${DROIDLENS_SERIAL:-}" ]]; then
        printf '%s\n' "$DROIDLENS_SERIAL"
        return 0
    fi
    local devices first second
    devices="$(authorized_devices 2>/dev/null || true)"
    first="$(printf '%s\n' "$devices" | sed -n '1p')"
    second="$(printf '%s\n' "$devices" | sed -n '2p')"
    if [[ -n "$first" && -z "$second" ]]; then
        printf '%s\n' "$first"
    else
        printf 'any\n'
    fi
}

resolve_policy_app() {
    local spec="$1"
    if [[ "$spec" == "*" ]]; then
        printf '*\n'
        return 0
    fi
    if [[ "$spec" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$ ]]; then
        printf '%s\n' "$spec"
        return 0
    fi
    app_package=""
    eval "$("$HERE/app.sh" resolve --app "$spec")"
    printf '%s\n' "$app_package"
}

base_args() {
    printf '%s\0' --policy "$POLICY_FILE" --audit "$AUDIT_FILE"
    [[ "$JSON" == "1" ]] && printf '%s\0' --json
}

run_policy_py() {
    local -a args=()
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < <(base_args)
    py "$HERE/policy.py" "$CMD" "${args[@]}" "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action) ACTION="${2:?--action requires value}"; shift 2 ;;
        --app) APP_SPEC="${2:?--app requires value}"; shift 2 ;;
        --serial) SERIAL="${2:?--serial requires value}"; shift 2 ;;
        --ttl) TTL="${2:?--ttl requires value}"; shift 2 ;;
        --max-runs) MAX_RUNS="${2:?--max-runs requires value}"; shift 2 ;;
        --reason) REASON="${2:?--reason requires value}"; shift 2 ;;
        --id) GRANT_ID="${2:?--id requires value}"; shift 2 ;;
        --all) ALL=1; shift ;;
        --consume) CONSUME=1; shift ;;
        --risk) RISK="${2:?--risk requires value}"; shift 2 ;;
        --limit) LIMIT="${2:?--limit requires value}"; shift 2 ;;
        --json) JSON=1; shift ;;
        -h|--help) sed -n '1,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown policy argument: $1" ;;
    esac
done

case "$CMD" in
    grant)
        [[ -n "$ACTION" ]] || die "policy grant requires --action"
        [[ -n "$APP_SPEC" ]] || die "policy grant requires --app"
        APP_PACKAGE="$(resolve_policy_app "$APP_SPEC")"
        run_policy_py --action "$ACTION" --app "$APP_PACKAGE" --serial "$(policy_serial)" \
            --ttl "$TTL" --max-runs "$MAX_RUNS" --reason "$REASON"
        ;;
    check)
        [[ -n "$ACTION" ]] || die "policy check requires --action"
        [[ -n "$APP_SPEC" ]] || die "policy check requires --app"
        APP_PACKAGE="$(resolve_policy_app "$APP_SPEC")"
        args=(--action "$ACTION" --app "$APP_PACKAGE" --serial "$(policy_serial)" --risk "$RISK" --reason "$REASON")
        [[ "$CONSUME" == "1" ]] && args+=(--consume)
        run_policy_py "${args[@]}"
        ;;
    list)
        if [[ "$ALL" == "1" ]]; then
            run_policy_py --all
        else
            run_policy_py
        fi
        ;;
    revoke)
        if [[ "$ALL" == "1" && -n "$GRANT_ID" ]]; then
            run_policy_py --all --id "$GRANT_ID"
        elif [[ "$ALL" == "1" ]]; then
            run_policy_py --all
        elif [[ -n "$GRANT_ID" ]]; then
            run_policy_py --id "$GRANT_ID"
        else
            run_policy_py
        fi
        ;;
    audit)
        if [[ -n "$LIMIT" ]]; then
            run_policy_py --limit "$LIMIT"
        else
            run_policy_py
        fi
        ;;
    *)
        die "unknown policy command: $CMD"
        ;;
esac
