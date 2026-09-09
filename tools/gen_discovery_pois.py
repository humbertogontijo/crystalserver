#!/usr/bin/env python3
"""Build discovery_pois.generated.lua from tibiamaps flag markers × DiscoveryGeometry.

Only icon="flag" entries are Measuring Tibia viewpoints. Other tibiamaps icons
(up/down/red */crossmark/star/…) are navigation annotations and are ignored.

Usage:
  python3 tools/gen_discovery_pois.py
  python3 tools/gen_discovery_pois.py --markers /path/to/markers.json

Default markers URL (cached to --markers if missing):
  https://raw.githubusercontent.com/tibiamaps/tibia-map-data/refs/heads/main/extra/points-of-interest/markers.json
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GEO = ROOT / "data" / "scripts" / "discovery_geometry.lua"
OUT = ROOT / "data" / "scripts" / "discovery_pois.generated.lua"
DEFAULT_URL = (
    "https://raw.githubusercontent.com/tibiamaps/tibia-map-data/refs/heads/main/"
    "extra/points-of-interest/markers.json"
)
DEFAULT_CACHE = ROOT / "tools" / "cache" / "tibiamaps-poi-markers.json"


def parse_geometry(text: str) -> tuple[dict, dict]:
    subs: dict[int, dict] = {}
    pat = re.compile(
        r"\[(\d+)\]\s*=\s*\{\s*--[^\n]*\n"
        r'\s*name\s*=\s*"([^"]*)"\s*,\s*\n'
        r"\s*mainArea\s*=\s*(\d+)\s*,\s*\n"
        r"\s*bbox\s*=\s*\{\s*x1\s*=\s*(\d+)\s*,\s*y1\s*=\s*(\d+)\s*,\s*x2\s*=\s*(\d+)\s*,\s*y2\s*=\s*(\d+)\s*\}\s*,\s*\n"
        r'\s*rects\s*=\s*"([^"]*)"',
        re.M,
    )
    for m in pat.finditer(text):
        sid = int(m.group(1))
        rects = []
        for chunk in m.group(8).split():
            parts = chunk.split(",")
            if len(parts) == 4:
                rects.append(tuple(map(int, parts)))
        subs[sid] = {
            "name": m.group(2),
            "mainArea": int(m.group(3)),
            "bbox": (int(m.group(4)), int(m.group(5)), int(m.group(6)), int(m.group(7))),
            "rects": rects,
        }

    approx: dict[int, dict] = {}
    approx_section = re.search(r"approx\s*=\s*\{", text)
    if approx_section:
        apat = re.compile(
            r"\[(\d+)\]\s*=\s*\{\s*--[^\n]*\n"
            r'\s*name\s*=\s*"([^"]*)"\s*,\s*\n'
            r"\s*mainArea\s*=\s*(\d+)\s*,\s*\n"
            r"\s*floors\s*=\s*\{([^}]*)\}\s*,\s*\n"
            r"\s*box\s*=\s*\{\s*x1\s*=\s*(\d+)\s*,\s*y1\s*=\s*(\d+)\s*,\s*x2\s*=\s*(\d+)\s*,\s*y2\s*=\s*(\d+)\s*\}",
            re.M,
        )
        for m in apat.finditer(text, approx_section.start()):
            sid = int(m.group(1))
            floors = {int(x) for x in re.findall(r"\d+", m.group(4))}
            approx[sid] = {
                "name": m.group(2),
                "mainArea": int(m.group(3)),
                "floors": floors,
                "box": (int(m.group(5)), int(m.group(6)), int(m.group(7)), int(m.group(8))),
            }
    return subs, approx


def in_rects(x: int, y: int, rects: list[tuple[int, int, int, int]]) -> bool:
    for x1, y1, x2, y2 in rects:
        if x1 <= x <= x2 and y1 <= y <= y2:
            return True
    return False


def load_markers(path: Path, url: str) -> list[dict]:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        print(f"fetching {url}")
        with urllib.request.urlopen(url, timeout=60) as resp:
            path.write_bytes(resp.read())
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--markers", type=Path, default=DEFAULT_CACHE)
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--geometry", type=Path, default=GEO)
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()

    subs, approx = parse_geometry(args.geometry.read_text(encoding="utf-8"))
    markers = load_markers(args.markers, args.url)
    flags = [m for m in markers if m.get("icon") == "flag"]
    surface_ids = sorted(subs.keys())
    approx_ids = sorted(approx.keys())

    by_sub: dict[int, list[tuple[int, int, int]]] = defaultdict(list)
    unassigned = 0
    for m in flags:
        x, y, z = int(m["x"]), int(m["y"]), int(m["z"])
        assigned = None
        for sid in surface_ids:
            s = subs[sid]
            bx1, by1, bx2, by2 = s["bbox"]
            if bx1 <= x <= bx2 and by1 <= y <= by2 and in_rects(x, y, s["rects"]):
                assigned = sid
                break
        if assigned is None:
            for sid in approx_ids:
                a = approx[sid]
                if z not in a["floors"]:
                    continue
                x1, y1, x2, y2 = a["box"]
                if x1 <= x <= x2 and y1 <= y <= y2:
                    assigned = sid
                    break
        if assigned is None:
            unassigned += 1
            continue
        by_sub[assigned].append((x, y, z))

    for sid in list(by_sub.keys()):
        by_sub[sid] = sorted(set(by_sub[sid]))

    lines = [
        "-- AUTO-GENERATED from tibiamaps points-of-interest markers.json",
        '-- Only icon="flag" entries are viewpoints. Other icons (up/down/red */crossmark/star/...)',
        "-- are navigation / annotation markers, not Measuring Tibia POIs.",
        "-- Source: https://github.com/tibiamaps/tibia-map-data/blob/main/extra/points-of-interest/markers.json",
        "-- Regenerate: python3 tools/gen_discovery_pois.py",
        "DiscoveryPois = {",
    ]
    for sid in sorted(by_sub.keys()):
        name = (subs.get(sid) or approx.get(sid) or {}).get("name", "")
        pts = by_sub[sid]
        lines.append(f"\t[{sid}] = {{ -- {name} ({len(pts)} flags)")
        for x, y, z in pts:
            lines.append(f"\t\t{{ x = {x}, y = {y}, z = {z} }},")
        lines.append("\t},")
    lines.append("}")
    lines.append("")
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"wrote {args.out} ({args.out.stat().st_size} bytes); "
        f"flags={len(flags)} assigned_subs={len(by_sub)} unassigned={unassigned}"
    )


if __name__ == "__main__":
    main()
