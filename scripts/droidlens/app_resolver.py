#!/usr/bin/env python3
"""Resolve Android app package candidates from project-local data."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


def normalize_component(package: str, activity: str | None) -> str:
    if not activity:
        return ""
    if "/" in activity:
        return activity
    if activity.startswith("."):
        return f"{package}/{activity}"
    return f"{package}/{activity}"


def add_candidate(
    candidates: list[dict[str, str]],
    *,
    source: str,
    package: str,
    activity: str = "",
    variant: str = "",
    module: str = "",
) -> None:
    package = package.strip()
    activity = activity.strip()
    if not package:
        return
    component = normalize_component(package, activity)
    item = {
        "source": source,
        "package": package,
        "activity": activity,
        "component": component,
        "variant": variant,
        "module": module,
    }
    key = (item["package"], item["activity"], item["source"], item["variant"], item["module"])
    existing = {
        (c["package"], c["activity"], c["source"], c["variant"], c["module"])
        for c in candidates
    }
    if key not in existing:
        candidates.append(item)


def load_profile(path: Path) -> list[dict[str, str]]:
    candidates: list[dict[str, str]] = []
    if not path.is_file():
        return candidates
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"app_resolver: invalid profile JSON: {path}: {exc}") from exc
    app = data.get("app", {})
    if not isinstance(app, dict):
        return candidates
    component = str(app.get("component") or "").strip()
    package = str(app.get("package") or app.get("applicationId") or "").strip()
    activity = str(app.get("activity") or app.get("launchActivity") or "").strip()
    variant = str(app.get("variant") or "").strip()
    if component and "/" in component:
        package, activity = component.split("/", 1)
    add_candidate(
        candidates,
        source=f"profile:{path}",
        package=package,
        activity=activity,
        variant=variant,
    )
    return candidates


def string_values(pattern: str, src: str) -> list[str]:
    return [m.group(1).strip() for m in re.finditer(pattern, src, re.MULTILINE)]


def block_candidates(src: str) -> list[tuple[str, str]]:
    """Return loose (name, applicationIdSuffix) pairs from Gradle flavor/build blocks."""
    pairs: list[tuple[str, str]] = []
    patterns = [
        r'create\("([^"]+)"\)\s*\{(.*?)\n\s*\}',
        r"create\('([^']+)'\)\s*\{(.*?)\n\s*\}",
        r"\b([A-Za-z][A-Za-z0-9_]*)\s*\{(.*?)\n\s*\}",
    ]
    suffix_re = re.compile(
        r'applicationIdSuffix\s*(?:=|\(?\s*)\s*["\']([^"\']+)["\']',
        re.MULTILINE,
    )
    for pattern in patterns:
        for name, body in re.findall(pattern, src, re.DOTALL):
            if name in {"android", "defaultConfig", "productFlavors", "buildTypes", "plugins"}:
                continue
            for suffix in suffix_re.findall(body):
                pairs.append((name, suffix))
    return pairs


def parse_gradle(root: Path) -> list[dict[str, str]]:
    candidates: list[dict[str, str]] = []
    files = [
        path
        for path in root.rglob("build.gradle*")
        if "build" not in path.parts and ".gradle" not in path.parts
    ]
    for path in files:
        try:
            src = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        app_ids = string_values(r'applicationId\s*(?:=|\(?\s*)\s*["\']([^"\']+)["\']', src)
        if not app_ids:
            continue
        module = str(path.parent.relative_to(root)) if path.parent != root else "."
        base = app_ids[0]
        add_candidate(candidates, source=f"gradle:{path}", package=base, module=module)
        for name, suffix in block_candidates(src):
            add_candidate(
                candidates,
                source=f"gradle:{path}",
                package=f"{base}{suffix}",
                variant=name,
                module=module,
            )
    return candidates


def filter_variant(candidates: list[dict[str, str]], variant: str) -> list[dict[str, str]]:
    if not variant:
        return candidates
    needle = variant.lower()
    filtered = [
        c
        for c in candidates
        if c.get("variant", "").lower() and c.get("variant", "").lower() in needle
    ]
    return filtered or candidates


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=Path(__file__).name)
    parser.add_argument("--root", default=".")
    parser.add_argument("--profile", default="")
    parser.add_argument("--variant", default="")
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv[1:])
    root = Path(args.root).resolve()
    profile = Path(args.profile).resolve() if args.profile else root / ".droidlens" / "profile.json"
    candidates: list[dict[str, str]] = []
    candidates.extend(load_profile(profile))
    candidates.extend(parse_gradle(root))
    candidates = filter_variant(candidates, args.variant)
    print(json.dumps({"candidates": candidates}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
