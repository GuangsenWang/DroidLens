#!/usr/bin/env python3
"""Small XML helpers for droidlens shell scripts."""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Optional, Tuple


BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def parse_xml(path: str) -> list[dict[str, str]]:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise SystemExit(f"uixml: XML parse failed: {path}: {exc}") from exc
    return [dict(node.attrib) for node in root.iter("node")]


def iter_nodes_with_context(path: str) -> list[tuple[dict[str, str], bool]]:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise SystemExit(f"uixml: XML parse failed: {path}: {exc}") from exc
    nodes: list[tuple[dict[str, str], bool]] = []

    def visit(element: ET.Element, in_scrollable: bool) -> None:
        attrs = dict(element.attrib)
        class_name = attrs.get("class", "")
        self_scrollable = attrs.get("scrollable") == "true" or any(
            token in class_name
            for token in (
                "RecyclerView",
                "ScrollView",
                "HorizontalScrollView",
                "ListView",
                "GridView",
                "ViewPager",
            )
        )
        now_scrollable = in_scrollable or self_scrollable
        if element.tag == "node":
            nodes.append((attrs, now_scrollable))
        for child in element:
            visit(child, now_scrollable)

    visit(root, False)
    return nodes


def parse_bounds(value: str) -> Optional[Tuple[int, int, int, int]]:
    match = BOUNDS_RE.fullmatch(value or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def node_text(node: dict[str, str]) -> str | None:
    text = (node.get("text") or "").strip()
    if text and len(text) > 1 and not text.isdigit():
        return text
    desc = (node.get("content-desc") or "").strip()
    if desc and len(desc) > 1:
        return desc
    return None


def match_value(actual: str, expected: str, mode: str) -> bool:
    if mode == "exact":
        return actual == expected
    if mode == "contains":
        return expected in actual
    if mode == "regex":
        return re.search(expected, actual) is not None
    raise SystemExit(f"uixml: unknown match mode: {mode}")


def node_attr(node: dict[str, str], by: str) -> str:
    if by == "desc":
        return node.get("content-desc", "")
    if by == "resource-id":
        return node.get("resource-id", "")
    return node.get(by, "")


def cmd_find(args: argparse.Namespace) -> int:
    nodes = iter_nodes_with_context(args.xml)
    hits: list[dict[str, Any]] = []
    for node, in_scrollable in nodes:
        if args.clickable is not None and node.get("clickable") != args.clickable:
            continue
        if args.enabled is not None and node.get("enabled") != args.enabled:
            continue
        value = node_attr(node, args.by)
        if not match_value(value, args.value, args.match):
            continue
        bounds = parse_bounds(node.get("bounds", ""))
        if not bounds:
            continue
        x1, y1, x2, y2 = bounds
        hits.append(
            {
                "center": [(x1 + x2) // 2, (y1 + y2) // 2],
                "bounds": [x1, y1, x2, y2],
                "text": node.get("text", ""),
                "content_desc": node.get("content-desc", ""),
                "resource_id": node.get("resource-id", ""),
                "class": node.get("class", ""),
                "clickable": node.get("clickable", ""),
                "enabled": node.get("enabled", ""),
                "inScrollable": in_scrollable,
            }
        )

    if not hits:
        return 1
    if args.nth < 1 or args.nth > len(hits):
        print(f"uixml: nth {args.nth} out of range; matches={len(hits)}", file=sys.stderr)
        return 2
    picked = hits[args.nth - 1]
    if args.json:
        print(json.dumps({"total": len(hits), "picked": picked, "matches": hits}, ensure_ascii=False))
    else:
        cx, cy = picked["center"]
        x1, y1, x2, y2 = picked["bounds"]
        print(f"{cx}\t{cy}\t{len(hits)}\t{x1}\t{y1}\t{x2}\t{y2}")
    return 0


def cmd_has(args: argparse.Namespace) -> int:
    nodes = parse_xml(args.xml)
    for node in nodes:
        if match_value(node_attr(node, args.by), args.value, args.match):
            return 0
    return 1


def cmd_summary(args: argparse.Namespace) -> int:
    nodes = iter_nodes_with_context(args.xml)
    top_y = args.height * 12 // 100
    bottom_y = args.height * 88 // 100
    top: set[str] = set()
    bottom: set[str] = set()
    statics: set[str] = set()
    dynamics: set[str] = set()

    for node, in_scrollable in nodes:
        text = node_text(node)
        bounds = parse_bounds(node.get("bounds", ""))
        if not text or not bounds:
            continue
        _x1, y1, _x2, y2 = bounds
        cy = (y1 + y2) // 2
        if cy < top_y:
            top.add(text)
        elif cy > bottom_y:
            bottom.add(text)
        elif in_scrollable:
            dynamics.add(text)
        else:
            statics.add(text)

    print(
        json.dumps(
            {
                "top_strip": sorted(top),
                "bottom_strip": sorted(bottom),
                "statics": sorted(statics),
                "dynamics": sorted(dynamics),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def cmd_split(args: argparse.Namespace) -> int:
    import shlex

    try:
        parts = shlex.split(args.line, posix=True)
    except ValueError as exc:
        print(f"uixml: flow parse failed: {exc}", file=sys.stderr)
        return 2
    for part in parts:
        print(part)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=Path(__file__).name)
    sub = parser.add_subparsers(dest="cmd", required=True)

    find = sub.add_parser("find")
    find.add_argument("xml")
    find.add_argument("--by", choices=["text", "desc", "resource-id", "class"], default="text")
    find.add_argument("--value", required=True)
    find.add_argument("--match", choices=["exact", "contains", "regex"], default="exact")
    find.add_argument("--nth", type=int, default=1)
    find.add_argument("--clickable", choices=["true", "false"])
    find.add_argument("--enabled", choices=["true", "false"])
    find.add_argument("--json", action="store_true")
    find.set_defaults(func=cmd_find)

    has = sub.add_parser("has")
    has.add_argument("xml")
    has.add_argument("--by", choices=["text", "desc", "resource-id", "class"], default="text")
    has.add_argument("--value", required=True)
    has.add_argument("--match", choices=["exact", "contains", "regex"], default="exact")
    has.set_defaults(func=cmd_has)

    summary = sub.add_parser("summary")
    summary.add_argument("xml")
    summary.add_argument("--width", type=int, required=True)
    summary.add_argument("--height", type=int, required=True)
    summary.set_defaults(func=cmd_summary)

    split = sub.add_parser("split")
    split.add_argument("line")
    split.set_defaults(func=cmd_split)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
