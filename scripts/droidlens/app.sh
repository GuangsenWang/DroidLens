#!/usr/bin/env bash
# app.sh — resolve or launch a target Android app without project-specific code.
# Usage:
#   app.sh resolve [--app auto|PKG|PKG/.ACTIVITY] [--variant NAME] [--profile FILE] [--json]
#   app.sh launch  [--app auto|PKG|PKG/.ACTIVITY] [--variant NAME] [--profile FILE] [--fresh]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CMD="${1:-resolve}"
shift || true

APP_SPEC="${DROIDLENS_APP:-auto}"
VARIANT="${DROIDLENS_APP_VARIANT:-}"
ROOT="$(find_project_root)"
PROFILE="$(droidlens_profile_file "$ROOT")"
JSON=0
FRESH=0
app_package=""
app_activity=""
app_component=""
app_source=""

usage() {
    awk '/^set -euo/{exit} /^#!/{next} /^#/ {sub(/^# ?/, ""); print}' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_SPEC="${2:?Usage: app.sh $CMD --app SPEC}"
            shift 2
            ;;
        --variant)
            VARIANT="${2:?Usage: app.sh $CMD --variant NAME}"
            shift 2
            ;;
        --profile)
            PROFILE="${2:?Usage: app.sh $CMD --profile FILE}"
            shift 2
            ;;
        --root)
            ROOT="${2:?Usage: app.sh $CMD --root DIR}"
            shift 2
            ;;
        --json)
            JSON=1
            shift
            ;;
        --fresh)
            FRESH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

normalize_component() {
    local pkg="$1" activity="$2"
    [[ -z "$activity" ]] && return 0
    if [[ "$activity" == */* ]]; then
        printf '%s\n' "$activity"
    elif [[ "$activity" == .* ]]; then
        printf '%s/%s\n' "$pkg" "$activity"
    else
        printf '%s/%s\n' "$pkg" "$activity"
    fi
}

launcher_component_for_pkg() {
    local pkg="$1" line
    line="$(
        adb shell cmd package resolve-activity --brief \
            -a android.intent.action.MAIN \
            -c android.intent.category.LAUNCHER \
            "$pkg" 2>/dev/null \
            | tr -d '\r' \
            | awk '/^[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+/ {print; exit}'
    )"
    [[ -n "$line" ]] && printf '%s\n' "$line"
}

is_installed_pkg() {
    local pkg="$1"
    adb shell pm path "$pkg" >/dev/null 2>&1
}

emit_shell() {
    local pkg="$1" activity="$2" component="$3" source="$4"
    printf 'app_package=%q\n' "$pkg"
    printf 'app_activity=%q\n' "$activity"
    printf 'app_component=%q\n' "$component"
    printf 'app_source=%q\n' "$source"
}

emit_json() {
    local pkg="$1" activity="$2" component="$3" source="$4"
    py - "$pkg" "$activity" "$component" "$source" "$PROFILE" "$ROOT" <<'PY'
import json
import sys

pkg, activity, component, source, profile, root = sys.argv[1:7]
print(json.dumps({
    "package": pkg,
    "activity": activity,
    "component": component,
    "source": source,
    "profile": profile,
    "root": root,
}, ensure_ascii=False, indent=2))
PY
}

resolve_explicit() {
    local spec="$1" pkg activity component
    if [[ "$spec" == */* ]]; then
        pkg="${spec%%/*}"
        activity="${spec#*/}"
        component="$(normalize_component "$pkg" "$activity")"
        activity="${component#*/}"
    else
        pkg="$spec"
        component="$(launcher_component_for_pkg "$pkg" || true)"
        activity="${component#*/}"
    fi
    [[ -n "$pkg" ]] || die "app spec is empty"
    [[ -n "$component" ]] || die "failed to resolve launcher activity: $pkg"
    if [[ "$JSON" == "1" ]]; then
        emit_json "$pkg" "$activity" "$component" "explicit"
    else
        emit_shell "$pkg" "$activity" "$component" "explicit"
    fi
}

select_auto() {
    local current_pkg candidates selected
    current_pkg="$(current_package 2>/dev/null || true)"
    candidates="$(py "$HERE/app_resolver.py" --root "$ROOT" --profile "$PROFILE" --variant "$VARIANT")"
    selected="$(
        py - "$candidates" "$current_pkg" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
current = sys.argv[2]
candidates = data.get("candidates", [])
for c in candidates:
    if c.get("source", "").startswith("profile:"):
        print(json.dumps(c, ensure_ascii=False))
        raise SystemExit(0)
if current:
    for c in candidates:
        if c.get("package") == current:
            print(json.dumps(c, ensure_ascii=False))
            raise SystemExit(0)
for c in candidates:
    print(json.dumps(c, ensure_ascii=False))
    raise SystemExit(0)
PY
    )"
    if [[ -z "$selected" ]]; then
        die "failed to resolve app from profile/Gradle; pass --app PKG/.ACTIVITY or set DROIDLENS_APP"
    fi

    local pkg activity component source
    pkg="$(py -c 'import json,sys; print(json.loads(sys.argv[1]).get("package",""))' "$selected")"
    activity="$(py -c 'import json,sys; print(json.loads(sys.argv[1]).get("activity",""))' "$selected")"
    component="$(py -c 'import json,sys; print(json.loads(sys.argv[1]).get("component",""))' "$selected")"
    source="$(py -c 'import json,sys; print(json.loads(sys.argv[1]).get("source",""))' "$selected")"

    if ! is_installed_pkg "$pkg"; then
        if [[ "$source" == profile:* ]]; then
            die "profile package is not installed: $pkg. Install the app, update $PROFILE, or pass --app"
        fi
        # Gradle may list multiple flavors; pick the single installed candidate if possible.
        local installed
        installed="$(
            py - "$candidates" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
for c in data.get("candidates", []):
    print(c.get("package", ""))
PY
        )"
        local matches=()
        while IFS= read -r candidate_pkg; do
            [[ -z "$candidate_pkg" ]] && continue
            if is_installed_pkg "$candidate_pkg"; then
                matches+=("$candidate_pkg")
            fi
        done <<< "$installed"
        if [[ "${#matches[@]}" -eq 1 ]]; then
            pkg="${matches[0]}"
            activity=""
            component=""
            source="installed-candidate"
        elif [[ "${#matches[@]}" -gt 1 ]]; then
            die "multiple installed candidates resolved: ${matches[*]}. Set DROIDLENS_APP_VARIANT or --app"
        else
            die "candidate package is not installed: $pkg. Install the target app or pass --app"
        fi
    fi

    if [[ -z "$component" ]]; then
        component="$(launcher_component_for_pkg "$pkg" || true)"
        activity="${component#*/}"
    fi
    [[ -n "$component" ]] || die "failed to resolve launcher activity: $pkg"

    if [[ "$JSON" == "1" ]]; then
        emit_json "$pkg" "$activity" "$component" "$source"
    else
        emit_shell "$pkg" "$activity" "$component" "$source"
    fi
}

case "$CMD" in
    resolve)
        if [[ -n "$APP_SPEC" && "$APP_SPEC" != "auto" ]]; then
            resolve_explicit "$APP_SPEC"
        else
            select_auto
        fi
        ;;
    launch)
        RESOLVE_ARGS=(resolve --app "$APP_SPEC" --profile "$PROFILE" --root "$ROOT")
        [[ -n "$VARIANT" ]] && RESOLVE_ARGS+=(--variant "$VARIANT")
        eval "$("$0" "${RESOLVE_ARGS[@]}")"
        if [[ "$FRESH" == "1" ]]; then
            adb shell am force-stop "$app_package" >/dev/null 2>&1 || true
            sleep 0.3
        fi
        adb shell am start -n "$app_component" >/dev/null
        if [[ "$JSON" == "1" ]]; then
            emit_json "$app_package" "$app_activity" "$app_component" "$app_source"
        else
            printf 'launch → %s (%s)\n' "$app_component" "$app_source"
        fi
        ;;
    *) die "unknown command: $CMD (expected resolve / launch)" ;;
esac
