#!/usr/bin/env python3
"""Validate Crystal core migrations + idleot custom_migrations naming.

Usage:
  python3 apps/crystalserver/tools/migrations/check.py
"""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRYSTAL = HERE.parents[1]

NUMBERED = re.compile(r"^(\d+)\.lua$")
CUSTOM = re.compile(r"^(\d{14})_.+\.lua$")


def check_numbered(dir_path: Path, label: str) -> int:
    print(f"==> Checking numbered DB migrations in {dir_path} ({label})")
    if not dir_path.is_dir() or dir_path.parent.is_symlink():
        print(f"[skip] {dir_path} missing or still a submodule symlink")
        return 0
    numbered = sorted(
        (
            p.name
            for p in dir_path.iterdir()
            if p.is_file() and NUMBERED.match(p.name)
        ),
        key=lambda n: int(NUMBERED.match(n).group(1)),  # type: ignore[union-attr]
    )
    if not numbered:
        print(f"::error::no numbered migration files (N.lua) found in {dir_path}")
        return 1
    print(f"Found {len(numbered)} numbered migration(s).")
    nums = [NUMBERED.match(n).group(1) for n in numbered]  # type: ignore[union-attr]
    dups = [n for n, c in Counter(nums).items() if c > 1]
    if dups:
        print(f"::error::duplicate migration number(s) in {dir_path}:")
        for n in dups:
            print(f"  - {n}.lua")
        return 1
    print(f"[ok] no duplicate migration numbers ({label})")
    return 0


def check_custom(dir_path: Path, label: str) -> int:
    print(f"==> Checking custom_migrations timestamps in {dir_path} ({label})")
    if not dir_path.is_dir():
        print(f"[ok] {dir_path} absent (skip)")
        return 0
    files = sorted(
        p.name
        for p in dir_path.iterdir()
        if p.is_file() and p.suffix == ".lua"
    )
    if not files:
        print(f"[ok] no custom_migrations in {label}")
        return 0
    failed = 0
    timestamps: list[str] = []
    for name in files:
        m = CUSTOM.match(name)
        if not m:
            print(
                f"::error::custom_migration bad name "
                f"(want YYYYMMDDHHMMSS_desc.lua): {name}"
            )
            failed = 1
            continue
        timestamps.append(m.group(1))
    if not failed:
        print(f"Found {len(files)} custom_migration(s) ({label}).")
    dups = [t for t, c in Counter(timestamps).items() if c > 1]
    if dups:
        print(f"::error::duplicate custom_migration timestamp(s) ({label}):")
        for t in dups:
            print(f"  - {t}")
        failed = 1
    else:
        print(f"[ok] no duplicate custom_migration timestamps ({label})")
    return failed


def main() -> int:
    failed = 0
    stock = CRYSTAL / "data/migrations"
    product = CRYSTAL / "data-global/scripts/custom_migrations"

    failed |= check_numbered(stock, "crystal stock")
    failed |= check_custom(product, "idleot custom_migrations")

    if failed:
        return 1
    print("Migration checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
