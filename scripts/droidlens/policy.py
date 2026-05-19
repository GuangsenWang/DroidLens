#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path


SCHEMA_VERSION = 1


def now() -> int:
    return int(time.time())


def parse_ttl(value: str) -> int:
    raw = value.strip().lower()
    if not raw:
        raise ValueError("ttl is empty")
    unit = raw[-1]
    number = raw[:-1] if unit.isalpha() else raw
    multiplier = {
        "s": 1,
        "m": 60,
        "h": 60 * 60,
        "d": 24 * 60 * 60,
    }.get(unit, 1)
    if unit.isalpha() and unit not in {"s", "m", "h", "d"}:
        raise ValueError(f"unsupported ttl unit: {unit}")
    seconds = int(number) * multiplier
    if seconds <= 0:
        raise ValueError("ttl must be > 0")
    return seconds


@contextmanager
def file_lock(path: Path):
    lock = Path(str(path) + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + 10
    fd = None
    while fd is None:
        try:
            fd = os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode("utf-8"))
        except FileExistsError:
            if time.time() > deadline:
                raise TimeoutError(f"timeout waiting for lock: {lock}")
            time.sleep(0.05)
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)
        try:
            lock.unlink()
        except FileNotFoundError:
            pass


def load_policy(path: Path) -> dict:
    if not path.exists():
        return {"schemaVersion": SCHEMA_VERSION, "grants": []}
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("policy root must be an object")
    data.setdefault("schemaVersion", SCHEMA_VERSION)
    data.setdefault("grants", [])
    if not isinstance(data["grants"], list):
        raise ValueError("policy grants must be a list")
    return data


def save_policy(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(path) + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    tmp.replace(path)


def write_audit(path: Path, event: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"ts": now(), **event}
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")


def emit(payload: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        if payload.get("ok") is False:
            print(f"{payload.get('errorCode', 'error')}: {payload.get('message', '')}", file=sys.stderr)
        else:
            print(payload.get("message", json.dumps(payload, ensure_ascii=False)))


def is_active(grant: dict, t: int) -> bool:
    if grant.get("revokedAt"):
        return False
    if int(grant.get("expiresAt", 0)) <= t:
        return False
    max_runs = int(grant.get("maxRuns", 0))
    used_runs = int(grant.get("usedRuns", 0))
    return max_runs > 0 and used_runs < max_runs


def matches(grant: dict, action: str, app: str, serial: str, t: int) -> bool:
    if not is_active(grant, t):
        return False
    if grant.get("action") != action:
        return False
    grant_app = grant.get("app", "")
    grant_serial = grant.get("serial", "")
    if grant_app not in {"*", app}:
        return False
    return grant_serial in {"", "any", "*", serial}


def suggested_grant(action: str, app: str, serial: str) -> str:
    serial_arg = "" if not serial or serial == "any" else f" --serial {serial}"
    return (
        "scripts/droidlens/droidlens policy grant "
        f"--action {action} --app {app}{serial_arg} --ttl 30m --max-runs 1 "
        '--reason "approve this single AFK action"'
    )


def cmd_grant(args: argparse.Namespace) -> int:
    t = now()
    ttl_seconds = parse_ttl(args.ttl)
    max_runs = int(args.max_runs)
    if max_runs <= 0:
        raise ValueError("--max-runs must be > 0")
    grant = {
        "id": uuid.uuid4().hex[:12],
        "action": args.action,
        "app": args.app,
        "serial": args.serial or "any",
        "createdAt": t,
        "expiresAt": t + ttl_seconds,
        "ttlSeconds": ttl_seconds,
        "maxRuns": max_runs,
        "usedRuns": 0,
        "reason": args.reason or "",
        "createdBy": args.created_by,
    }
    with file_lock(args.policy):
        data = load_policy(args.policy)
        data["grants"].append(grant)
        save_policy(args.policy, data)
    write_audit(args.audit, {"event": "grant", "grant": grant})
    emit({"ok": True, "grant": grant, "message": f"granted {grant['id']}"}, args.json)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    data = load_policy(args.policy)
    t = now()
    grants = data.get("grants", [])
    if not args.all:
        grants = [grant for grant in grants if is_active(grant, t)]
    emit({"ok": True, "grants": grants}, args.json)
    return 0


def cmd_revoke(args: argparse.Namespace) -> int:
    if not args.id and not args.all:
        raise ValueError("revoke requires --id ID or --all")
    revoked = []
    with file_lock(args.policy):
        data = load_policy(args.policy)
        t = now()
        for grant in data.get("grants", []):
            if grant.get("revokedAt"):
                continue
            if args.all or grant.get("id") == args.id:
                grant["revokedAt"] = t
                revoked.append(grant)
        save_policy(args.policy, data)
    for grant in revoked:
        write_audit(args.audit, {"event": "revoke", "grant": grant})
    emit({"ok": True, "revoked": len(revoked), "grants": revoked}, args.json)
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    with file_lock(args.policy):
        data = load_policy(args.policy)
        t = now()
        picked = None
        for grant in data.get("grants", []):
            if matches(grant, args.action, args.app, args.serial or "any", t):
                picked = grant
                break
        if picked is not None and args.consume:
            picked["usedRuns"] = int(picked.get("usedRuns", 0)) + 1
            picked["lastUsedAt"] = t
            save_policy(args.policy, data)

    if picked is not None:
        event = {
            "event": "allow",
            "action": args.action,
            "app": args.app,
            "serial": args.serial or "any",
            "grantId": picked.get("id", ""),
            "reason": args.reason or "",
            "consumed": bool(args.consume),
        }
        write_audit(args.audit, event)
        emit({"ok": True, "approvedBy": "policy", "grant": picked}, args.json)
        return 0

    payload = {
        "ok": False,
        "errorCode": "approval_required",
        "action": args.action,
        "app": args.app,
        "serial": args.serial or "any",
        "risk": args.risk,
        "message": f"approval required for {args.action} on {args.app}",
        "suggestedGrant": suggested_grant(args.action, args.app, args.serial or "any"),
    }
    write_audit(args.audit, {"event": "deny", **payload})
    emit(payload, args.json)
    return 1


def cmd_audit(args: argparse.Namespace) -> int:
    events = []
    if args.audit.exists():
        with args.audit.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    events.append({"raw": line})
    if args.limit:
        events = events[-args.limit :]
    emit({"ok": True, "events": events}, args.json)
    return 0


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--json", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="DroidLens dangerous-action policy store")
    sub = parser.add_subparsers(dest="cmd", required=True)

    grant = sub.add_parser("grant")
    add_common(grant)
    grant.add_argument("--action", required=True)
    grant.add_argument("--app", required=True)
    grant.add_argument("--serial", default="any")
    grant.add_argument("--ttl", default="30m")
    grant.add_argument("--max-runs", default="1")
    grant.add_argument("--reason", default="")
    grant.add_argument("--created-by", default="user")
    grant.set_defaults(func=cmd_grant)

    list_cmd = sub.add_parser("list")
    add_common(list_cmd)
    list_cmd.add_argument("--all", action="store_true")
    list_cmd.set_defaults(func=cmd_list)

    revoke = sub.add_parser("revoke")
    add_common(revoke)
    revoke.add_argument("--id", default="")
    revoke.add_argument("--all", action="store_true")
    revoke.set_defaults(func=cmd_revoke)

    check = sub.add_parser("check")
    add_common(check)
    check.add_argument("--action", required=True)
    check.add_argument("--app", required=True)
    check.add_argument("--serial", default="any")
    check.add_argument("--risk", default="")
    check.add_argument("--reason", default="")
    check.add_argument("--consume", action="store_true")
    check.set_defaults(func=cmd_check)

    audit = sub.add_parser("audit")
    add_common(audit)
    audit.add_argument("--limit", type=int, default=0)
    audit.set_defaults(func=cmd_audit)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:
        payload = {"ok": False, "errorCode": "policy_error", "message": str(exc)}
        emit(payload, getattr(args, "json", False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
