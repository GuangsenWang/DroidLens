#!/usr/bin/env bash
# Shared helpers for the DroidLens ADB UI workflow.
# Sourced by snap.sh / dump.sh / tap.sh / flow.sh / doctor.sh.
#
# Goals:
#   - No hardcoded ADB path: probe $PATH, $ANDROID_HOME, $ANDROID_SDK_ROOT, common SDK locations.
#   - No silent failure on missing native tools: prefer pngquant; gracefully degrade if absent.
#   - Cross-platform: macOS (zsh/bash) + Linux (bash) + WSL.
set -euo pipefail

DROIDLENS_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_droidlens_source_optional_env() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    # shellcheck source=/dev/null
    . "$file"
}

_droidlens_source_env_files() {
    _droidlens_source_optional_env "$HOME/.droidlens/config.env"

    local start dir
    for start in "$PWD" "$DROIDLENS_LIB_HERE"; do
        dir="$start"
        while [[ "$dir" != "/" && -n "$dir" ]]; do
            if [[ -f "$dir/.droidlens/env.sh" ]]; then
                _droidlens_source_optional_env "$dir/.droidlens/env.sh"
                return 0
            fi
            dir="$(dirname "$dir")"
        done
    done
}

_droidlens_source_env_files

# ------------------------------------------------------------------ ADB
# Print absolute path to `adb`. Honors $DROIDLENS_ADB > SDK env/common dirs > $PATH.
# Probe SDK paths before PATH to avoid shell aliases/functions.
adb_bin() {
    if [[ -n "${DROIDLENS_ADB:-}" && -x "$DROIDLENS_ADB" ]]; then
        printf '%s\n' "$DROIDLENS_ADB"
        return 0
    fi

    local sdk sdk_path exe converted
    for sdk in \
        "${ANDROID_HOME:-}" \
        "${ANDROID_SDK_ROOT:-}" \
        "${LOCALAPPDATA:-}/Android/Sdk" \
        "${USERPROFILE:-}/AppData/Local/Android/Sdk" \
        "$HOME/Library/Android/sdk" \
        "$HOME/Android/Sdk" \
        "$HOME/AppData/Local/Android/Sdk" \
        "/opt/android-sdk" \
        "/usr/local/share/android-sdk"; do
        [[ -z "$sdk" ]] && continue
        converted=""
        if command -v cygpath >/dev/null 2>&1; then
            converted="$(cygpath -u "$sdk" 2>/dev/null || true)"
        fi
        for sdk_path in "$sdk" "$converted"; do
            [[ -z "$sdk_path" ]] && continue
            for exe in adb adb.exe; do
                if [[ -x "$sdk_path/platform-tools/$exe" ]]; then
                    printf '%s\n' "$sdk_path/platform-tools/$exe"
                    return 0
                fi
            done
        done
    done
    # PATH is the final fallback. `type -p` accepts executable files only.
    local p
    for exe in adb adb.exe; do
        p="$(type -p "$exe" 2>/dev/null || true)"
        if [[ -n "$p" && -x "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# Wrapper: `adb` -> resolved binary, with -s $DROIDLENS_SERIAL when set.
adb() {
    local bin
    bin="$(adb_bin)" || { echo "adb not found (set DROIDLENS_ADB / ANDROID_HOME)" >&2; return 127; }
    if [[ -n "${DROIDLENS_SERIAL:-}" ]]; then
        "$bin" -s "$DROIDLENS_SERIAL" "$@"
    else
        "$bin" "$@"
    fi
}

# ------------------------------------------------------------------ Device
authorized_devices() {
    local bin
    bin="$(adb_bin)" || return 127
    "$bin" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'
}

# Connected, AUTHORIZED device count (filters "unauthorized" / "offline").
device_count() {
    if [[ -n "${DROIDLENS_SERIAL:-}" ]]; then
        authorized_devices | awk -v serial="$DROIDLENS_SERIAL" '$1 == serial {found=1} END {print found ? 1 : 0}'
    else
        authorized_devices | wc -l | tr -d ' '
    fi
}

require_device_ready() {
    local cnt
    cnt="$(device_count)"
    if [[ -n "${DROIDLENS_SERIAL:-}" ]]; then
        [[ "$cnt" == "1" ]] || die "DROIDLENS_SERIAL=$DROIDLENS_SERIAL is not connected or authorized"
        return 0
    fi
    [[ "$cnt" == "1" ]] || die "expected exactly one authorized device; found $cnt. Set DROIDLENS_SERIAL when multiple devices are connected"
}

find_project_root() {
    if [[ -n "${DROIDLENS_PROJECT_ROOT:-}" ]]; then
        cd "$DROIDLENS_PROJECT_ROOT" && pwd
        return 0
    fi

    local start dir
    for start in "$PWD" "${HERE:-$DROIDLENS_LIB_HERE}"; do
        dir="$start"
        while [[ "$dir" != "/" && -n "$dir" ]]; do
            if [[ -f "$dir/settings.gradle" || -f "$dir/settings.gradle.kts" || -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
                printf '%s\n' "$dir"
                return 0
            fi
            dir="$(dirname "$dir")"
        done
    done
    pwd
}

droidlens_profile_file() {
    local root="${1:-$(find_project_root)}"
    printf '%s\n' "${DROIDLENS_PROFILE:-$root/.droidlens/profile.json}"
}

# Current device input coordinate size cache. Returns "WxH", for example 1080x2340.
# Prefer the active display rect because `wm size` may report natural orientation in landscape.
# Fall back to `wm size`; prefer override size when present.
wm_size() {
    if [[ -z "${DROIDLENS_WM_SIZE:-}" ]]; then
        DROIDLENS_WM_SIZE="$(adb shell dumpsys display 2>/dev/null | tr -d '\r' | python3 -c '
import re
import sys

data = sys.stdin.read()
match = re.search(r"mCurrentDisplayRect=Rect\(\s*0,\s*0\s*-\s*(\d+),\s*(\d+)\)", data)
if match:
    print(f"{match.group(1)}x{match.group(2)}")
')"
        if [[ -z "$DROIDLENS_WM_SIZE" ]]; then
            DROIDLENS_WM_SIZE="$(adb shell dumpsys window displays 2>/dev/null | tr -d '\r' | python3 -c '
import re
import sys

data = sys.stdin.read()
match = re.search(r"\bcur=(\d+)x(\d+)\b", data) or re.search(r"\bDisplayFrames w=(\d+) h=(\d+)\b", data)
if match:
    print(f"{match.group(1)}x{match.group(2)}")
')"
        fi
        if [[ -z "$DROIDLENS_WM_SIZE" ]]; then
            DROIDLENS_WM_SIZE="$(
                adb shell wm size 2>/dev/null \
                    | tr -d '\r' \
                    | awk -F': ' '
                        /Override size:/ {override=$2}
                        /Physical size:/ {physical=$2}
                        END {print override ? override : physical}
                    '
            )"
        fi
        [[ "$DROIDLENS_WM_SIZE" =~ ^[0-9]+x[0-9]+$ ]] || die "failed to read device size; adb shell wm size returned unexpected output"
        export DROIDLENS_WM_SIZE
    fi
    printf '%s\n' "$DROIDLENS_WM_SIZE"
}

wm_width()  { wm_size | cut -dx -f1; }
wm_height() { wm_size | cut -dx -f2; }

# Device density cache.
wm_density() {
    if [[ -z "${DROIDLENS_DENSITY:-}" ]]; then
        DROIDLENS_DENSITY="$(adb shell wm density 2>/dev/null | awk -F': ' '/Physical density/{print $2}' | tr -d '\r')"
        export DROIDLENS_DENSITY
    fi
    printf '%s\n' "$DROIDLENS_DENSITY"
}

# Current top resumed package/activity.
# Example: topResumedActivity=ActivityRecord{... u0 com.foo.bar/com.foo.bar.MainActivity t...}
_current_component() {
    # Use Python instead of awk for consistent BSD/GNU behavior and clearer regex handling.
    {
        adb shell 'dumpsys activity activities' 2>/dev/null
        adb shell 'dumpsys window windows' 2>/dev/null
    } | python3 -c '
import re, sys
interesting = (
    "topResumedActivity=",
    "mResumedActivity",
    "ResumedActivity",
    "mCurrentFocus",
    "mFocusedApp",
)
component_re = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_$]+)+)/(\.?[A-Za-z_$][A-Za-z0-9_.$]*)")
for line in sys.stdin:
    if not any(token in line for token in interesting):
        continue
    m = component_re.search(line)
    if m:
        pkg, act = m.group(1), m.group(2)
        if act.startswith("."):
            act = pkg + act
        print(f"{pkg}/{act}")
        break
'
}
current_package()  { _current_component | cut -d/ -f1; }
current_activity() { _current_component | cut -d/ -f2; }
current_version_code() {
    local pkg="$1"
    adb shell "dumpsys package $pkg" 2>/dev/null | awk -F'=' '/versionCode=/{print $2; exit}' | awk '{print $1}'
}

# Device/app bucket key for page-tree storage.
device_key() {
    local pkg="${1:-$(current_package)}"
    local vc; vc="$(current_version_code "$pkg")"
    local sz; sz="$(wm_size)"
    local d;  d="$(wm_density)"
    printf '%s@%s+%s@%s\n' "${pkg:-unknown}" "${vc:-0}" "${sz:-?}" "${d:-?}"
}

# Wake the device and dismiss a swipe-up lockscreen. Idempotent and size-relative.
wake_device() {
    local state
    state="$(adb shell dumpsys display 2>/dev/null | awk '/mScreenState=/ {print $1; exit}')"
    if [[ "$state" != *"ON"* ]]; then
        adb shell input keyevent KEYCODE_POWER >/dev/null
        sleep 0.6
    fi
    # Swipe from bottom to upper screen area using height-relative coordinates.
    local w h cx y1 y2
    w="$(wm_width)"
    h="$(wm_height)"
    cx=$(( w / 2 ))
    y1=$(( h * 90 / 100 ))   # start at 90% height
    y2=$(( h * 25 / 100 ))   # end at 25% height
    adb shell input swipe "$cx" "$y1" "$cx" "$y2" 200 >/dev/null 2>&1 || true
}

ensure_device_stayon() {
    [[ "${DROIDLENS_STAY_AWAKE:-1}" == "1" ]] || return 0
    adb_bin >/dev/null 2>&1 || return 0
    [[ "$(device_count 2>/dev/null || echo 0)" == "1" ]] || return 0
    if adb shell svc power stayon true >/dev/null 2>&1; then
        export DROIDLENS_STAYON_APPLIED=1
    else
        log "WARNING: failed to enable device stay-awake via 'svc power stayon true'"
    fi
}

# Tap in device coordinate space. Callers provide normalized or pixel coordinates.
tap_xy() { adb shell input tap "$1" "$2" >/dev/null; }
tap_xy_pct() {  # percentage (0-100)
    local pct_x=$1 pct_y=$2
    local x y
    x=$(( $(wm_width) * pct_x / 100 ))
    y=$(( $(wm_height) * pct_y / 100 ))
    adb shell input tap "$x" "$y" >/dev/null
}

# ------------------------------------------------------------------ Reliability
run_with_timeout() {
    local seconds="${1:?run_with_timeout SECONDS CMD...}"
    shift
    python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    completed = subprocess.run(cmd, timeout=timeout)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(completed.returncode)
PY
}

adb_retry() {
    local tries=3 delay=0.35
    if [[ "${1:-}" == "--tries" ]]; then
        tries="$2"
        shift 2
    fi
    if [[ "${1:-}" == "--delay" ]]; then
        delay="$2"
        shift 2
    fi
    local i=1
    while true; do
        if adb_with_timeout "$@"; then
            return 0
        fi
        [[ "$i" -ge "$tries" ]] && return 1
        sleep "$delay"
        i=$((i + 1))
    done
}

adb_with_timeout() {
    local bin timeout
    timeout="${DROIDLENS_ADB_TIMEOUT:-15}"
    bin="$(adb_bin)" || return 127
    if [[ -n "${DROIDLENS_SERIAL:-}" ]]; then
        run_with_timeout "$timeout" "$bin" -s "$DROIDLENS_SERIAL" "$@"
    else
        run_with_timeout "$timeout" "$bin" "$@"
    fi
}

ui_fingerprint_from_xml() {
    local xml="${1:?ui_fingerprint_from_xml FILE}"
    python3 - "$xml" <<'PY'
import hashlib
import re
import sys

src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
items = []
for attr in ("text", "content-desc", "resource-id", "class", "bounds"):
    items.extend(f"{attr}:{m.group(1)}" for m in re.finditer(attr + r'="([^"]*)"', src))
print(hashlib.sha1("\n".join(items).encode("utf-8")).hexdigest()[:16])
PY
}

wait_ui_stable() {
    local timeout="${1:-5}" interval="${2:-0.35}" end prev="" current="" xml
    end=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < end )); do
        xml="$(mktemp -t droidlens-stable.XXXXXX.xml)"
        if dump_xml "$xml" >/dev/null 2>&1; then
            current="$(ui_fingerprint_from_xml "$xml" 2>/dev/null || true)"
        fi
        rm -f "$xml"
        if [[ -n "$current" && "$current" == "$prev" ]]; then
            return 0
        fi
        prev="$current"
        sleep "$interval"
    done
    return 1
}

is_dangerous_action_text() {
    local value="$1"
    [[ "${DROIDLENS_ALLOW_DANGEROUS:-0}" == "1" ]] && return 1
    python3 - "$value" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower()
patterns = [
    r"\bdelete\b", r"\bremove\b", r"\berase\b", r"\bclear\b", r"\breset\b",
    r"\bpurchase\b", r"\bbuy\b", r"\bpay\b", r"\bsubscribe\b",
    r"\ballow\b", r"\bgrant\b", r"\binstall\b", r"\buninstall\b",
    "\u5220\u9664", "\u79fb\u9664", "\u6e05\u7a7a", "\u91cd\u7f6e", "\u8d2d\u4e70",
    "\u652f\u4ed8", "\u8ba2\u9605", "\u5141\u8bb8", "\u6388\u6743", "\u5b89\u88c5", "\u5378\u8f7d",
]
raise SystemExit(0 if any(re.search(p, value) for p in patterns) else 1)
PY
}

# ------------------------------------------------------------------ Tooling
have_pngquant() { command -v pngquant >/dev/null 2>&1; }
have_cwebp()    { command -v cwebp    >/dev/null 2>&1; }

dump_xml() {
    local out="${1:?dump_xml OUT.xml}"
    local tag user remote
    user="${USER:-droidlens}"
    tag="${user//[^A-Za-z0-9_.-]/_}.$$.$RANDOM"
    remote="/data/local/tmp/droidlens-$tag.xml"

    if ! adb_retry --tries "${DROIDLENS_ADB_RETRIES:-3}" shell uiautomator dump "$remote" >/dev/null; then
        adb shell rm -f "$remote" >/dev/null 2>&1 || true
        return 1
    fi
    if ! adb_retry --tries "${DROIDLENS_ADB_RETRIES:-3}" exec-out cat "$remote" > "$out"; then
        adb shell rm -f "$remote" >/dev/null 2>&1 || true
        return 1
    fi
    adb shell rm -f "$remote" >/dev/null 2>&1 || true
}

# Install hint for missing tool, per OS.
install_hint() {
    local tool=$1
    case "$(uname -s)" in
        Darwin) echo "macOS:   brew install $tool" ;;
        Linux)
            local pkg=$tool
            [[ $tool == cwebp ]] && pkg=webp
            echo "Debian:  sudo apt install $pkg"
            echo "Arch:    sudo pacman -S $tool"
            echo "Fedora:  sudo dnf install $tool"
            ;;
        MINGW*|MSYS*|CYGWIN*) echo "Windows: choco install $tool   (or scoop install $tool)" ;;
        *) echo "Install $tool manually using its official documentation." ;;
    esac
}

# ------------------------------------------------------------------ Output
log()  { printf '[droidlens] %s\n' "$*" >&2; }
die()  { printf '[droidlens] ERROR: %s\n' "$*" >&2; exit 1; }

json_emit() {
    python3 - "$@" <<'PY'
import json
import sys

payload = {}
for item in sys.argv[1:]:
    key, _, value = item.partition("=")
    if value in {"true", "false"}:
        payload[key] = value == "true"
    else:
        try:
            payload[key] = int(value)
        except ValueError:
            payload[key] = value
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

write_json_file() {
    local out="$1"
    shift
    python3 - "$out" "$@" <<'PY'
import json
import sys

out = sys.argv[1]
payload = {}
for item in sys.argv[2:]:
    key, _, value = item.partition("=")
    if value in {"true", "false"}:
        payload[key] = value == "true"
    else:
        payload[key] = value
with open(out, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

failure_bundle() {
    local code="${1:?failure_bundle CODE MESSAGE}" message="${2:?failure_bundle CODE MESSAGE}" app="${3:-}"
    local root stem dir xml screen mode
    root="${DROIDLENS_OUTPUT_DIR:-/tmp}"
    stem="droidlens-failure-$(date +%Y%m%d-%H%M%S)-$$"
    dir="$root/$stem"
    mkdir -p "$dir"
    write_json_file "$dir/reason.json" \
        "ok=false" "errorCode=$code" "message=$message" "recommendedAction=inspect_bundle"
    if [[ -n "$app" && -x "$DROIDLENS_LIB_HERE/observe.sh" ]]; then
        "$DROIDLENS_LIB_HERE/observe.sh" --app "$app" > "$dir/observe.json" 2>"$dir/observe.err" || true
    elif [[ -x "$DROIDLENS_LIB_HERE/observe.sh" ]]; then
        "$DROIDLENS_LIB_HERE/observe.sh" > "$dir/observe.json" 2>"$dir/observe.err" || true
    fi
    xml="$dir/hierarchy.xml"
    if dump_xml "$xml" >"$dir/dump_xml.log" 2>&1; then
        if [[ "${DROIDLENS_REDACT_TEXT:-0}" != "1" && -x "$DROIDLENS_LIB_HERE/uixml.py" ]]; then
            python3 "$DROIDLENS_LIB_HERE/uixml.py" summary "$xml" --width "$(wm_width)" --height "$(wm_height)" \
                > "$dir/summary.json" 2>"$dir/summary.err" || true
        fi
    fi
    screen="$dir/screen.webp"
    mode="${DROIDLENS_FAILURE_SNAP_MODE:---thumb}"
    if [[ -x "$DROIDLENS_LIB_HERE/snap.sh" ]]; then
        DROIDLENS_IN_FAILURE_BUNDLE=1 "$DROIDLENS_LIB_HERE/snap.sh" "$screen" "$mode" --json > "$dir/snap.json" 2>"$dir/snap.err" || true
    fi
    printf '%s\n' "$dir"
}
