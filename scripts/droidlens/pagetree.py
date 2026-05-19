#!/usr/bin/env python3
"""
pagetree.py — page-tree.json CRUD + path inference, project-agnostic.

Storage layout: buckets are keyed by device/app/display so one store can hold
multiple apps and resolutions.

  {
    "version": 1,
    "buckets": {
      "<package>@<vCode>+<WxH>@<density>": {
        "pages": {
          "<page_key>": {
            "title": "...",          # Top app bar title or sentinel text
            "activity": "...",       # optional
            "buttons": {
              "<button_key>": {"x": .., "y": .., "via": "text|desc|xy", "value": ".."}
            }
          }
        },
        "edges": [
          {"from": "<page>", "via": "<button_key>", "to": "<page>", "dynamic": false, "status": "active"}
        ]
      }
    }
  }

CLI used by shell scripts:

  pagetree.py path <STORE> <BUCKET>           - print the store path
  pagetree.py ensure <STORE> <BUCKET>         - ensure the bucket exists
  pagetree.py pages <STORE> <BUCKET>          - list all page keys in the bucket
  pagetree.py learn-btn <STORE> <BUCKET> <PAGE> <BUTTON_KEY> <X> <Y> [VIA] [VALUE]
  pagetree.py learn-page <STORE> <BUCKET> <PAGE> [TITLE] [ACTIVITY]
	  pagetree.py learn-edge <STORE> <BUCKET> <FROM> <BUTTON_KEY> <TO> [DYNAMIC]
	  pagetree.py mark-edge <STORE> <BUCKET> <FROM> <BUTTON_KEY> <TO> <STATUS> [REASON]
  pagetree.py route <STORE> <BUCKET> <FROM> <TO>
      - one step per line: "<from>\t<button_key>\t<x>\t<y>\t<to>\t<dynamic>"
      - exits with code 1 when no route is found
  pagetree.py dump <STORE> <BUCKET>           - dump the bucket as JSON for debugging
"""
from __future__ import annotations

import json
import os
import sys
import time
from collections import deque
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable


SCHEMA_VERSION = 1


def load(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        return {"version": SCHEMA_VERSION, "buckets": {}}
    if p.stat().st_size == 0:
        return {"version": SCHEMA_VERSION, "buckets": {}}
    try:
        data = json.loads(p.read_text("utf-8"))
    except json.JSONDecodeError as e:
        sys.exit(f"pagetree: failed to parse JSON at {path}: {e}")
    data.setdefault("version", SCHEMA_VERSION)
    data.setdefault("buckets", {})
    return data


def save(path: str, data: dict) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    tmp.replace(p)


@contextmanager
def store_lock(path: str):
    p = Path(path)
    lock = p.with_name(p.name + ".lock")
    lock_timeout = float(os.environ.get("DROIDLENS_STORE_LOCK_TIMEOUT", "10"))
    stale_after = float(os.environ.get("DROIDLENS_STORE_LOCK_STALE_SECONDS", "300"))
    deadline = time.monotonic() + lock_timeout
    while True:
        try:
            lock.mkdir(parents=True)
            (lock / "owner").write_text(
                f"pid={os.getpid()}\ntime={time.time()}\n",
                encoding="utf-8",
            )
            break
        except FileExistsError:
            try:
                age = time.time() - lock.stat().st_mtime
                if stale_after > 0 and age > stale_after:
                    for child in lock.iterdir():
                        child.unlink(missing_ok=True)
                    lock.rmdir()
                    continue
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise SystemExit(f"pagetree: store lock timeout: {lock}")
            time.sleep(0.05)
    try:
        yield
    finally:
        try:
            for child in lock.iterdir():
                child.unlink(missing_ok=True)
            lock.rmdir()
        except OSError:
            pass


def mutate_store(path: str, fn: Callable[[dict], Any]) -> Any:
    with store_lock(path):
        data = load(path)
        result = fn(data)
        save(path, data)
        return result


def ensure_bucket(data: dict, bucket: str) -> dict:
    bk = data["buckets"].setdefault(
        bucket, {"pages": {}, "edges": []}
    )
    bk.setdefault("pages", {})
    bk.setdefault("edges", [])
    return bk


def cmd_path(args: list[str]) -> int:
    store, _bucket = args
    print(store)
    return 0


def cmd_ensure(args: list[str]) -> int:
    store, bucket = args
    mutate_store(store, lambda data: ensure_bucket(data, bucket))
    return 0


def cmd_pages(args: list[str]) -> int:
    store, bucket = args
    data = load(store)
    bk = data["buckets"].get(bucket)
    if not bk:
        return 0
    for k in sorted(bk["pages"].keys()):
        print(k)
    return 0


def cmd_learn_page(args: list[str]) -> int:
    store, bucket, page = args[:3]
    title = args[3] if len(args) > 3 else page
    activity = args[4] if len(args) > 4 else ""

    def apply(data: dict) -> None:
        bk = ensure_bucket(data, bucket)
        p = bk["pages"].setdefault(page, {})
        p["title"] = title
        if activity:
            p["activity"] = activity
        p.setdefault("buttons", {})

    mutate_store(store, apply)
    return 0


def cmd_learn_btn(args: list[str]) -> int:
    store, bucket, page, btn_key, x, y = args[:6]
    via = args[6] if len(args) > 6 else "xy"
    value = args[7] if len(args) > 7 else ""

    def apply(data: dict) -> None:
        bk = ensure_bucket(data, bucket)
        p = bk["pages"].setdefault(page, {"buttons": {}})
        p.setdefault("buttons", {})
        entry: dict[str, Any] = {"x": int(x), "y": int(y), "via": via}
        if value:
            entry["value"] = value
        p["buttons"][btn_key] = entry

    mutate_store(store, apply)
    return 0


def cmd_learn_edge(args: list[str]) -> int:
    store, bucket, src, via, dst = args[:5]
    dynamic = bool(args[5] == "1") if len(args) > 5 else False

    def apply(data: dict) -> None:
        bk = ensure_bucket(data, bucket)
        upsert_edge(bk, src, via, dst, dynamic)

    mutate_store(store, apply)
    return 0


def upsert_edge(bucket: dict, src: str, via: str, dst: str, dynamic: bool) -> None:
    for edge in bucket["edges"]:
        if edge.get("from") == src and edge.get("via") == via and edge.get("to") == dst:
            edge["dynamic"] = dynamic
            edge["status"] = "active"
            edge["failCount"] = 0
            edge.pop("lastFailureReason", None)
            return
    bucket["edges"].append(
        {
            "from": src,
            "via": via,
            "to": dst,
            "dynamic": dynamic,
            "status": "active",
            "failCount": 0,
        }
    )


def cmd_learn_transition(args: list[str]) -> int:
    store, from_bucket, src, to_bucket, dst, btn_key, x, y, via, value, dynamic_raw = (
        args[:11]
    )
    dynamic = dynamic_raw == "1"

    def apply(data: dict) -> None:
        source_bucket = ensure_bucket(data, from_bucket)
        source_page = source_bucket["pages"].setdefault(src, {"buttons": {}})
        source_page.setdefault("buttons", {})
        if not dynamic:
            entry: dict[str, Any] = {"x": int(x), "y": int(y), "via": via}
            if value:
                entry["value"] = value
            source_page["buttons"][btn_key] = entry
        target_bucket = ensure_bucket(data, to_bucket)
        target_page = target_bucket["pages"].setdefault(dst, {})
        target_page["title"] = dst
        target_page.setdefault("buttons", {})
        upsert_edge(source_bucket, src, btn_key, dst, dynamic)

    mutate_store(store, apply)
    return 0


def cmd_alias_page(args: list[str]) -> int:
    store, bucket, alias, current_key, fp, activity, texts_json = args[:7]
    texts = json.loads(texts_json)
    merged_count = 0

    def apply(data: dict) -> None:
        nonlocal merged_count
        bk = ensure_bucket(data, bucket)
        pages = bk.setdefault("pages", {})
        edges = bk.setdefault("edges", [])
        to_merge: set[str] = set()
        if current_key and current_key != alias:
            to_merge.add(current_key)
        for key, page in list(pages.items()):
            if key != alias and fp and page.get("fingerprint") == fp:
                to_merge.add(key)

        alias_entry = pages.setdefault(alias, {"buttons": {}})
        alias_entry["fingerprint"] = fp
        alias_entry["texts"] = texts
        alias_entry["title"] = alias
        if activity:
            alias_entry["activity"] = activity

        for old_key in to_merge:
            if old_key not in pages:
                continue
            old_entry = pages.pop(old_key)
            for button_key, button in old_entry.get("buttons", {}).items():
                alias_entry.setdefault("buttons", {}).setdefault(button_key, button)
            for edge in edges:
                if edge.get("from") == old_key:
                    edge["from"] = alias
                if edge.get("to") == old_key:
                    edge["to"] = alias
            merged_count += 1

    mutate_store(store, apply)
    print(merged_count)
    return 0


def cmd_mark_edge(args: list[str]) -> int:
    store, bucket, src, via, dst, status = args[:6]
    reason = args[6] if len(args) > 6 else ""
    found = False

    def apply(data: dict) -> None:
        nonlocal found
        bk = data["buckets"].get(bucket)
        if not bk:
            return
        for edge in bk.get("edges", []):
            if edge.get("from") == src and edge.get("via") == via and edge.get("to") == dst:
                edge["status"] = status
                if status in {"stale", "disabled"}:
                    edge["failCount"] = int(edge.get("failCount", 0)) + 1
                    if reason:
                        edge["lastFailureReason"] = reason
                elif status == "active":
                    edge["failCount"] = 0
                    edge.pop("lastFailureReason", None)
                found = True
                return

    mutate_store(store, apply)
    return 0 if found else 1


def cmd_route(args: list[str]) -> int:
    store, bucket, src, dst = args
    data = load(store)
    bk = data["buckets"].get(bucket)
    if not bk:
        return 1
    if src == dst:
        return 0

    # BFS: node = page_key; edge = (via, button_xy).
    adj: dict[str, list[tuple[str, str, dict]]] = {}
    for e in bk["edges"]:
        if e.get("status", "active") in {"stale", "disabled"}:
            continue
        adj.setdefault(e["from"], []).append((e["via"], e["to"], e))

    queue = deque([(src, [])])
    visited = {src}
    while queue:
        cur, path = queue.popleft()
        if cur == dst:
            # Emit each route step.
            cur_p = src
            for step in path:
                via = step["via"]
                nxt = step["to"]
                dyn = "1" if step.get("dynamic") else "0"
                btn = bk["pages"].get(cur_p, {}).get("buttons", {}).get(via, {})
                x = btn.get("x", -1)
                y = btn.get("y", -1)
                print(f"{cur_p}\t{via}\t{x}\t{y}\t{nxt}\t{dyn}")
                cur_p = nxt
            return 0
        for via, nxt, e in adj.get(cur, []):
            if nxt in visited:
                continue
            visited.add(nxt)
            queue.append((nxt, path + [e]))
    return 1


def cmd_dump(args: list[str]) -> int:
    store, bucket = args
    data = load(store)
    bk = data["buckets"].get(bucket)
    json.dump(bk or {}, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    print()
    return 0


COMMANDS = {
    "path":       (cmd_path,       2),
    "ensure":     (cmd_ensure,     2),
    "pages":      (cmd_pages,      2),
    "learn-page": (cmd_learn_page, 3),  # also accepts 4 or 5
    "learn-btn":  (cmd_learn_btn,  6),  # also accepts 7 or 8
    "learn-edge": (cmd_learn_edge, 5),  # also accepts 6
    "learn-transition": (cmd_learn_transition, 11),
    "alias-page": (cmd_alias_page, 7),
    "mark-edge":  (cmd_mark_edge,  6),  # also accepts 7
    "route":      (cmd_route,      4),
    "dump":       (cmd_dump,       2),
}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    spec = COMMANDS.get(cmd)
    if not spec:
        sys.exit(f"pagetree: unknown subcommand: {cmd}")
    fn, min_args = spec
    args = argv[2:]
    if len(args) < min_args:
        sys.exit(f"pagetree: {cmd} requires at least {min_args} arguments")
    return fn(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
