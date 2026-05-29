#!/usr/bin/env bash
# snap.sh - capture a device screenshot and optionally compress/resize it.
# Usage:
#   snap.sh OUT.png            # pngquant 65-80 if installed, otherwise original PNG
#   snap.sh OUT.png --png      # explicit PNG
#   snap.sh OUT.webp --ai      # 540px-wide WebP q55
#   snap.sh OUT.webp --thumb   # 360px-wide WebP q45
#   snap.sh OUT.webp --lossy   # original-size WebP q80
#   snap.sh OUT.png --raw      # uncompressed original PNG from ADB
# Each output writes OUT.meta.json with device/image dimensions for tap.sh --meta.
# Env:
#   DROIDLENS_ADB / ANDROID_HOME  adb discovery
#   DROIDLENS_SERIAL              target serial for multi-device sessions
#   DROIDLENS_AI_MAX_WIDTH        --ai output width, default 540
#   DROIDLENS_THUMB_MAX_WIDTH     --thumb output width, default 360
#   DROIDLENS_AI_WEBP_Q           --ai WebP quality, default 55
#   DROIDLENS_THUMB_WEBP_Q        --thumb WebP quality, default 45
#   DROIDLENS_MAX_IMAGE_BYTES     max bytes for non-raw screenshots, default 256000; 0 disables
#   DROIDLENS_ALLOW_LARGE_IMAGE=1 allow oversized output explicitly
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

OUT=""
MODE="auto"
JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1; shift ;;
        --ai|--thumb|--lossy|--png|--raw) MODE="$1"; shift ;;
        -h|--help)
            sed -n '1,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            if [[ -z "$OUT" ]]; then
                OUT="$1"
            else
                MODE="$1"
            fi
            shift ;;
    esac
done

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

reject_oversized_image() {
    local max_bytes="$1" bytes="$2"
    rm -f "$OUT"
    if [[ "$JSON" == "1" ]]; then
        json_emit "ok=false" "errorCode=image_too_large" \
            "message=image exceeds size limit: ${bytes}B > ${max_bytes}B. Use --thumb, lower quality, or set DROIDLENS_ALLOW_LARGE_IMAGE=1 explicitly" \
            "path=$OUT" "mode=$MODE" "bytes=$bytes" "maxBytes=$max_bytes" "rejected=true"
        exit 1
    fi
    die "image exceeds size limit: ${bytes}B > ${max_bytes}B. Use --thumb, lower quality, or set DROIDLENS_ALLOW_LARGE_IMAGE=1 explicitly"
}

[[ -z "$OUT" ]] && fail "invalid_args" "Usage: $0 OUT [--ai|--thumb|--lossy|--png|--raw] [--json]"
mkdir -p "$(dirname "$OUT")"

TMP="$(mktemp -t droidlens.XXXXXX.png)"
trap 'rm -f "$TMP"' EXIT

if ! adb_retry --tries "${DROIDLENS_ADB_RETRIES:-3}" exec-out screencap -p > "$TMP"; then
    fail "screencap_failed" "adb screencap failed"
fi
ORIG=$(wc -c < "$TMP" | tr -d ' ')
if [[ "$ORIG" -lt 1000 ]]; then
    log "WARNING: screencap output is only ${ORIG}B; waking device and retrying"
    wake_device || true
    sleep 0.5
    if ! adb_retry --tries "${DROIDLENS_ADB_RETRIES:-3}" exec-out screencap -p > "$TMP"; then
        fail "screencap_failed" "adb screencap failed after wake"
    fi
    ORIG=$(wc -c < "$TMP" | tr -d ' ')
fi

read_png_size() {
    py - "$1" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as fh:
    data = fh.read(24)
if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
    raise SystemExit("not a png screencap")
width, height = struct.unpack(">II", data[16:24])
print(f"{width} {height}")
PY
}

write_meta() {
    local image="$1" mode="$2" device_w="$3" device_h="$4" image_w="$5" image_h="$6" meta
    meta="${image%.*}.meta.json"
    py - "$image" "$meta" "$mode" "$device_w" "$device_h" "$image_w" "$image_h" <<'PY'
import json
import os
import sys

image, meta, mode = sys.argv[1:4]
device_w, device_h, image_w, image_h = map(int, sys.argv[4:8])
payload = {
    "image": os.path.abspath(image),
    "mode": mode,
    "coordinateSystem": "device pixels from adb screencap/uiautomator bounds",
    "deviceWidth": device_w,
    "deviceHeight": device_h,
    "imageWidth": image_w,
    "imageHeight": image_h,
    "scaleX": device_w / image_w,
    "scaleY": device_h / image_h,
}
with open(meta, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(meta)
PY
}

read -r SRC_W SRC_H < <(read_png_size "$TMP")
OUT_W="$SRC_W"
OUT_H="$SRC_H"

ensure_webp_out() {
    [[ "$OUT" == *.webp ]] || fail "invalid_output_extension" "$MODE outputs WebP; use a .webp suffix: $OUT"
}

encode_webp() {
    local quality="$1"
    local width="$2"
    have_cwebp || fail "image_tool_missing" "cwebp is not installed; $(install_hint cwebp)"
    if [[ "$width" -gt 0 ]]; then
        if [[ "$width" -gt "$SRC_W" ]]; then
            width="$SRC_W"
        fi
        OUT_W="$width"
        OUT_H=$(( (SRC_H * width + SRC_W / 2) / SRC_W ))
        cwebp -quiet -q "$quality" -m 6 -resize "$width" 0 "$TMP" -o "$OUT"
    else
        OUT_W="$SRC_W"
        OUT_H="$SRC_H"
        cwebp -quiet -q "$quality" -m 6 "$TMP" -o "$OUT"
    fi
}

case "$MODE" in
    --raw)
        cp "$TMP" "$OUT"
        ;;
    --lossy)
        ensure_webp_out
        encode_webp "${DROIDLENS_WEBP_Q:-80}" 0
        ;;
    --ai)
        ensure_webp_out
        encode_webp "${DROIDLENS_AI_WEBP_Q:-55}" "${DROIDLENS_AI_MAX_WIDTH:-540}"
        ;;
    --thumb)
        ensure_webp_out
        encode_webp "${DROIDLENS_THUMB_WEBP_Q:-45}" "${DROIDLENS_THUMB_MAX_WIDTH:-360}"
        ;;
    --png|auto|"")
        if have_pngquant; then
            if ! pngquant --quality 65-80 --speed 3 --strip --force --output "$OUT" "$TMP"; then
                log "WARNING: pngquant compression failed; falling back to original PNG"
                cp "$TMP" "$OUT"
            fi
        else
            log "pngquant is not installed; keeping original PNG. Install it for smaller PNG output: $(install_hint pngquant)"
            cp "$TMP" "$OUT"
        fi
        ;;
    *) fail "invalid_args" "unknown mode: $MODE (expected --ai / --thumb / --lossy / --png / --raw / empty default)" ;;
esac

NEW=$(wc -c < "$OUT" | tr -d ' ')
MAX_IMAGE_BYTES="${DROIDLENS_MAX_IMAGE_BYTES:-256000}"
if [[ "$MODE" != "--raw" && "${DROIDLENS_ALLOW_LARGE_IMAGE:-0}" != "1" && "$MAX_IMAGE_BYTES" != "0" ]]; then
    [[ "$MAX_IMAGE_BYTES" =~ ^[0-9]+$ ]] || fail "invalid_config" "DROIDLENS_MAX_IMAGE_BYTES must be a non-negative integer: $MAX_IMAGE_BYTES"
    if [[ "$NEW" -gt "$MAX_IMAGE_BYTES" ]]; then
        reject_oversized_image "$MAX_IMAGE_BYTES" "$NEW"
    fi
fi
RATIO=$(awk "BEGIN{ if ($NEW>0) printf \"%.1f\", $ORIG/$NEW; else printf \"-\" }")
META="$(write_meta "$OUT" "$MODE" "$SRC_W" "$SRC_H" "$OUT_W" "$OUT_H")"
if [[ "$JSON" == "1" ]]; then
    json_emit "ok=true" "path=$OUT" "meta=$META" "mode=$MODE" "originalBytes=$ORIG" \
        "bytes=$NEW" "ratio=$RATIO" "deviceWidth=$SRC_W" "deviceHeight=$SRC_H" \
        "imageWidth=$OUT_W" "imageHeight=$OUT_H"
else
    printf 'snap → %s  (%d → %d B, %sx, mode=%s, size=%sx%s, meta=%s)\n' "$OUT" "$ORIG" "$NEW" "$RATIO" "$MODE" "$OUT_W" "$OUT_H" "$META"
fi
