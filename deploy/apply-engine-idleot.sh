#!/usr/bin/env bash
# Apply idleot/ engine PATCH + MOVE onto the checkout before compile (Docker/CI).
# Idempotent: skips patches that are already applied and MOVE files that match.
set -euo pipefail

ROOT="${IDLEOT_APP_ROOT:-/src}"
export IDLEOT_APP_ROOT="$ROOT"

python3 - "$ROOT" <<'PY'
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import importlib.util

root = Path(sys.argv[1])
lib = root / "deploy" / "idleot-lib.py"
spec = importlib.util.spec_from_file_location("idleot_lib", lib)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

entries = [
    e
    for e in mod.walk_idleot_app(root, "crystalserver")
    if not e.overlay
    and not e.dest.startswith("data/")
    and not e.dest.startswith("data-global/")
]
errs = mod.check_dest_uniqueness(entries)
if errs:
    for e in errs:
        print(f"::error::{e}", file=sys.stderr)
    sys.exit(1)

patches = sorted([e for e in entries if e.behavior == "patch"], key=lambda e: e.dest)
moves = sorted([e for e in entries if e.behavior == "move"], key=lambda e: e.dest)
appends = [e for e in entries if e.behavior == "append"]

applied_p = skipped_p = applied_m = skipped_m = 0


def apply_patch(e) -> None:
    global applied_p, skipped_p
    raw = e.source.read_bytes()
    if b"diff --git" not in raw:
        if raw.lstrip().startswith(b"# empty"):
            skipped_p += 1
            return
        print(f"::error::no diff in {e.source}", file=sys.stderr)
        sys.exit(1)
    body = raw[raw.find(b"diff --git") :]
    with tempfile.NamedTemporaryFile("wb", suffix=".patch", delete=False) as fh:
        fh.write(body)
        tmp = fh.name
    try:
        check = subprocess.run(
            ["git", "-C", str(root), "apply", "--check", "--whitespace=nowarn", tmp],
            capture_output=True,
            text=True,
        )
        if check.returncode != 0:
            skipped_p += 1
            print(f"[engine-idleot] skip PATCH {e.dest} (already applied or upstream drift)")
            return
        subprocess.run(
            ["git", "-C", str(root), "apply", "--whitespace=nowarn", tmp],
            check=True,
            capture_output=True,
            text=True,
        )
        applied_p += 1
        print(f"[engine-idleot] PATCH {e.dest}")
    finally:
        os.unlink(tmp)


for e in patches:
    apply_patch(e)

for e in moves:
    dest = root / e.dest
    src_bytes = e.source.read_bytes()
    if dest.is_file() and dest.read_bytes() == src_bytes:
        skipped_m += 1
        continue
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(e.source, dest)
    applied_m += 1
    print(f"[engine-idleot] MOVE {e.dest}")

for e in appends:
    dest = root / e.dest
    if not dest.is_file():
        print(f"::error::APPEND missing dest {e.dest}", file=sys.stderr)
        sys.exit(1)
    extra = e.source.read_text(encoding="utf-8")
    if extra and extra not in dest.read_text(encoding="utf-8"):
        dest.write_text(dest.read_text(encoding="utf-8") + extra, encoding="utf-8")
        print(f"[engine-idleot] APPEND {e.dest}")

print(
    f"[engine-idleot] done: {applied_p} patches, {skipped_p} skipped patches, "
    f"{applied_m} moves, {skipped_m} skipped moves"
)
PY
