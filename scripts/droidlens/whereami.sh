#!/usr/bin/env bash
# whereami.sh - infer the current page id using app-agnostic heuristics and learned fingerprints.
#
# Output as eval-safe key=value lines:
#   package=...
#   activity=...
#   device_key=...
#   page=...           # matched page key, learned or best-effort heuristic
#   title=...          # inferred top app bar title text
#
# Usage:
#   eval "$(./whereami.sh)"
#   echo "$page"  # → learned page alias
#
# Env:
#   DROIDLENS_STORE=/path/to/page-tree.json  # default ~/.droidlens/page-tree.json
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STORE="${DROIDLENS_STORE:-$HOME/.droidlens/page-tree.json}"

PKG="$(current_package)"
ACT="$(current_activity)"
DK="$(device_key "$PKG")"

# Dump XML and extract title candidates from the top 25% of the screen.
TMP="$(mktemp -t droidlens.XXXXXX.xml)"
trap 'rm -f "$TMP"' EXIT
dump_xml "$TMP"

H="$(wm_height)"
TOP=$(( H / 4 ))   # top quarter of the screen

# Heuristic: non-empty text within the top area, preferring the widest bounds.
# XML example: text="Page title" bounds="[L,T][R,B]"
TITLE="$(py - "$TMP" "$TOP" <<'PY'
import re, sys
xml_path, top_y = sys.argv[1], int(sys.argv[2])
src = open(xml_path, encoding="utf-8", errors="replace").read()
# Split node-like chunks defensively.
nodes = re.findall(r"<node\b[^/]*?/>", src)
best = ("", -1)
for n in nodes:
    m_t = re.search(r'text="([^"]*)"', n)
    m_b = re.search(r'bounds="\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]"', n)
    if not m_t or not m_b:
        continue
    text = m_t.group(1)
    if not text.strip():
        continue
    x1, y1, x2, y2 = map(int, m_b.groups())
    # Top area only.
    if y2 > top_y:
        continue
    # Filter very short text to avoid one-letter icon labels.
    if len(text.strip()) < 2:
        continue
    # Filter numeric or punctuation-only text.
    if text.strip().isdigit():
        continue
    w = x2 - x1
    if w > best[1]:
        best = (text, w)
print(best[0])
PY
)"

# Collect all visible text and content-desc values for fingerprint/Jaccard matching.
# Output both the exact hash and the JSON text set used for similarity matching.
read -r FP TEXTS_JSON < <(py - "$TMP" <<'PY'
import re, sys, hashlib, json
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
texts = set()
for m in re.finditer(r'\btext="([^"]+)"', src):
    t = m.group(1).strip()
    if not t or t.isdigit() or len(t) == 1: continue
    texts.add(t)
for m in re.finditer(r'\bcontent-desc="([^"]+)"', src):
    t = m.group(1).strip()
    if t and len(t) > 1:
        texts.add(t)
texts = sorted(texts)
fp = hashlib.sha1("\n".join(texts).encode("utf-8")).hexdigest()[:16]
print(fp, json.dumps(texts, ensure_ascii=False))
PY
)

PAGE=""
MATCH_KIND="none"
JACCARD="0.00"
if [[ -s "$STORE" ]] && command -v python3 >/dev/null 2>&1; then
    # Matching strategy, in reliability order:
    #   1. Exact fingerprint match.
    #   2. Jaccard similarity >= 0.6 for list/content changes.
    #   3. Activity + inferred title heuristic.
    PAGE_INFO="$(py - "$STORE" "$DK" "$FP" "$TITLE" "$ACT" "$TEXTS_JSON" <<'PY'
import json, sys
store, bucket, fp, title, act, texts_json = sys.argv[1:7]
try:
    data = json.load(open(store, encoding="utf-8"))
except Exception:
    sys.exit(0)
bk = data.get("buckets", {}).get(bucket, {})
pages = bk.get("pages", {})
current = set(json.loads(texts_json))
# 1) Exact fingerprint match.
for k, p in pages.items():
    if p.get("fingerprint") == fp:
        print(f"{k}\texact\t1.00"); sys.exit(0)
# 2) Jaccard similarity.
best = ("", 0.0)
for k, p in pages.items():
    stored = set(p.get("texts", []))
    if not stored: continue
    inter = len(current & stored)
    union = len(current | stored)
    if union == 0: continue
    j = inter / union
    if j > best[1]:
        best = (k, j)
THR = 0.60
if best[1] >= THR:
    print(f"{best[0]}\tjaccard\t{best[1]:.2f}"); sys.exit(0)
# 3) Title match.
if title:
    for k, p in pages.items():
        if p.get("title") == title:
            print(f"{k}\ttitle\t0.00"); sys.exit(0)
PY
)"
    if [[ -n "$PAGE_INFO" ]]; then
        IFS=$'\t' read -r PAGE MATCH_KIND JACCARD <<< "$PAGE_INFO"
    fi
fi

# Fallback page key: title, or short activity name when title is empty.
if [[ -z "$PAGE" ]]; then
    PAGE="${TITLE:-${ACT##*.}}"
    MATCH_KIND="heuristic"
fi

# Output eval-safe shell assignments. `printf %q` escapes spaces and quotes.
printf 'package=%q\n'     "$PKG"
printf 'activity=%q\n'    "$ACT"
printf 'device_key=%q\n'  "$DK"
printf 'page=%q\n'        "$PAGE"
printf 'title=%q\n'       "$TITLE"
printf 'fingerprint=%q\n' "$FP"
printf 'match_kind=%q\n'  "$MATCH_KIND"
printf 'jaccard=%q\n'     "$JACCARD"
printf 'texts_json=%q\n'  "$TEXTS_JSON"
