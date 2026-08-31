#!/usr/bin/env bash
# Apply idleot/ overlay MOVEs + APPENDs + datapack/core .patch into a datapack.
# Engine src/ .patch files are NOT applied here (see scripts/forks/apply.sh).
#
# Usage: bash scripts/idleot/apply-overlay.sh <datapack-dir> [core-data-dir]
#        (also copied to apps/crystalserver/deploy/ for Coolify)
# Env: IDLEOT_APP_ROOT — engine checkout containing idleot/
#      IDLEOT_LIB — path to lib.py (default: sibling idleot-lib.py or scripts/idleot/lib.py)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$HERE/idleot-lib.py" ]]; then
  ENGINE_ROOT="$(cd "$HERE/.." && pwd)"
  ROOT="${IDLEOT_MONOREPO:-$ENGINE_ROOT}"
  export IDLEOT_APP_ROOT="${IDLEOT_APP_ROOT:-$ENGINE_ROOT}"
  export IDLEOT_LIB="${IDLEOT_LIB:-$HERE/idleot-lib.py}"
else
  ROOT="$(cd "$HERE/../.." && pwd)"
  export IDLEOT_APP_ROOT="${IDLEOT_APP_ROOT:-$ROOT/apps/crystalserver}"
  export IDLEOT_LIB="${IDLEOT_LIB:-$ROOT/scripts/idleot/lib.py}"
fi
TARGET="${1:-}"
CORE_DATA="${2:-}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "usage: $0 <path-to-datapack-dir> [core-data-dir]" >&2
  exit 1
fi
if [ ! -d "$IDLEOT_APP_ROOT/idleot" ]; then
  echo "[idleot] missing $IDLEOT_APP_ROOT/idleot" >&2
  exit 1
fi

if [ -z "$CORE_DATA" ]; then
  if [ -d "$ROOT/run/crystalserver/data" ] && [ ! -L "$ROOT/run/crystalserver/data" ]; then
    CORE_DATA="$ROOT/run/crystalserver/data"
  elif [ -d "$TARGET/../data" ] && [ ! -L "$TARGET/../data" ]; then
    CORE_DATA="$(cd "$TARGET/../data" && pwd)"
  fi
fi

echo "[idleot] applying overlays → $TARGET (core=${CORE_DATA:-none} from $IDLEOT_APP_ROOT/idleot)"

python3 - "$ROOT" "$TARGET" "${CORE_DATA:-}" <<'PY'
import os, sys, shutil, subprocess, tempfile
from pathlib import Path
import importlib.util

root, target, core = sys.argv[1:4]
core = core or None
spec = importlib.util.spec_from_file_location(
    "idleot_lib", os.environ.get("IDLEOT_LIB", os.path.join(root, "scripts", "idleot", "lib.py"))
)
mod = importlib.util.module_from_spec(spec)
sys.modules["idleot_lib"] = mod
spec.loader.exec_module(mod)

entries = [e for e in mod.walk_feature_entries(Path(root)) if e.app == "crystalserver"]
errs = mod.check_dest_uniqueness(entries)
if errs:
    for e in errs:
        print(f"[idleot] ERROR: {e}", file=sys.stderr)
    sys.exit(1)

def link_rel(link_path, target_abs):
    os.makedirs(os.path.dirname(link_path), exist_ok=True)
    if os.path.lexists(link_path):
        if os.path.isdir(link_path) and not os.path.islink(link_path):
            shutil.rmtree(link_path)
        else:
            os.unlink(link_path)
    rel = os.path.relpath(target_abs, os.path.dirname(link_path))
    os.symlink(rel, link_path)

def apply_patch_file(patch_path: Path, worktree: str) -> None:
    raw = patch_path.read_bytes()
    if b"diff --git" not in raw:
        return
    # strip mail header if any
    idx = raw.find(b"diff --git")
    body = raw[idx:]
    with tempfile.NamedTemporaryFile("wb", suffix=".patch", delete=False) as fh:
        fh.write(body)
        tmp = fh.name
    try:
        r = subprocess.run(
            ["git", "apply", "--whitespace=nowarn", tmp],
            cwd=worktree,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            # fallback: patch -p1
            r2 = subprocess.run(
                ["patch", "-p1", "--forward", "--reject-file=-", "-i", tmp],
                cwd=worktree,
                capture_output=True,
                text=True,
            )
            if r2.returncode not in (0, 1):
                print(f"[idleot] WARN patch failed {patch_path}: {r.stderr or r2.stderr}", file=sys.stderr)
            else:
                print(f"[idleot] patch {patch_path.name}")
        else:
            print(f"[idleot] patch {patch_path.name}")
    finally:
        os.unlink(tmp)

moves = [e for e in entries if e.behavior == "move" and e.overlay]
appends = [e for e in entries if e.behavior == "append"]
# Datapack/core patches (not src/)
runtime_patches = [
    e for e in entries
    if e.behavior == "patch"
    and (
        e.dest.startswith("data/")
        or e.dest.startswith("data-global/")
        or e.dest.startswith("lib/")
        or e.dest.startswith("scripts/")
        or e.dest.startswith("npc/")
    )
]

lib_custom_files = []
script_files = []
npc_files = []

for e in moves:
    d = e.dest.replace("\\", "/")
    if d.startswith("data-global/"):
        d = d[len("data-global/") :]
    if d.startswith("lib/custom/"):
        lib_custom_files.append((e, d))
    elif d.startswith("scripts/custom/"):
        script_files.append((e, d))
    elif d.startswith("npc/custom/"):
        npc_files.append((e, d))
    elif d.startswith("data/") and core:
        rel = d[len("data/") :]
        dest = os.path.join(core, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(e.source, dest)
        print(f"[idleot] core MOVE {rel}")
    else:
        dest_file = os.path.join(target, d)
        os.makedirs(os.path.dirname(dest_file), exist_ok=True)
        link_rel(dest_file, str(e.source))
        print(f"[idleot] MOVE {d}")

lib_dest = os.path.join(target, "lib", "custom")
if os.path.lexists(lib_dest) and (os.path.islink(lib_dest) or os.path.isfile(lib_dest)):
    os.unlink(lib_dest)
os.makedirs(lib_dest, exist_ok=True)
for e, d in lib_custom_files:
    rel = d[len("lib/custom/") :]
    dest_file = os.path.join(lib_dest, rel)
    os.makedirs(os.path.dirname(dest_file), exist_ok=True)
    link_rel(dest_file, str(e.source))
print(f"[idleot] linked lib/custom ({len(lib_custom_files)} files)")

scripts_root = os.path.join(target, "scripts", "custom")
os.makedirs(scripts_root, exist_ok=True)
by_feat = {}
for e, d in script_files:
    rel = d[len("scripts/custom/") :]
    feat = rel.split("/", 1)[0]
    by_feat.setdefault(feat, []).append((e, rel))
for feat, items in by_feat.items():
    for e, rel in items:
        dest_file = os.path.join(scripts_root, rel)
        os.makedirs(os.path.dirname(dest_file), exist_ok=True)
        link_rel(dest_file, str(e.source))
    print(f"[idleot] linked scripts/custom/{feat} ({len(items)} files)")

for e, d in npc_files:
    dest_file = os.path.join(target, d)
    os.makedirs(os.path.dirname(dest_file), exist_ok=True)
    link_rel(dest_file, str(e.source))
    print(f"[idleot] link {d}")

assets_tibia = os.path.join(root, "assets", "tibia")
if os.path.isdir(assets_tibia):
    link_rel(os.path.join(target, "tibia"), assets_tibia)
    print("[idleot] link tibia → assets/tibia")

for e in appends:
    d = e.dest.replace("\\", "/")
    if d.startswith("data-global/"):
        d = d[len("data-global/") :]
    dest_file = os.path.join(target, d)
    if not os.path.isfile(dest_file):
        print(f"[idleot] WARN: APPEND missing dest {d}", file=sys.stderr)
        continue
    text = open(dest_file, encoding="utf-8").read()
    if "lib/custom/load.lua" in text:
        print(f"[idleot] {d} already has product hooks")
    else:
        with open(dest_file, "a", encoding="utf-8") as fh:
            fh.write(open(e.source, encoding="utf-8").read())
        print(f"[idleot] appended → {d}")

# Runtime patches: data-global → target parent layout; data/ → core
# Worktree for data-global patches is the datapack's parent if paths include data-global/
run_root = os.path.dirname(target.rstrip("/"))
for e in runtime_patches:
    d = e.dest.replace("\\", "/")
    if d.startswith("data-global/"):
        # patch paths are data-global/...; cwd = run_root which contains data-global/
        if os.path.basename(target) == "data-global":
            apply_patch_file(e.source, run_root)
        else:
            # target IS the datapack; rewrite by applying with strip
            apply_patch_file(e.source, run_root if os.path.isdir(os.path.join(run_root, "data-global")) else target)
    elif d.startswith("data/") and core:
        # cwd should be parent of data/
        core_parent = os.path.dirname(core.rstrip("/"))
        apply_patch_file(e.source, core_parent)
    else:
        # relative to datapack root (lib/, scripts/, npc/)
        apply_patch_file(e.source, target)

# Sync stock numbered core migrations only (product scripts are custom_migrations).
if core:
    mig_dir = os.path.join(core, "migrations")
    stock_mig = os.path.join(os.environ.get("IDLEOT_APP_ROOT", os.path.join(root, "apps", "crystalserver")), "data", "migrations")
    os.makedirs(mig_dir, exist_ok=True)
    if os.path.isdir(stock_mig):
        for stock in sorted(Path(stock_mig).glob("[0-9]*.lua")):
            shutil.copy2(stock, os.path.join(mig_dir, stock.name))
        stock_names = {p.name for p in Path(stock_mig).glob("[0-9]*.lua")}
        for extra in Path(mig_dir).glob("[0-9]*.lua"):
            if extra.name not in stock_names:
                extra.unlink()
                print(f"[idleot] removed leftover numbered migration {extra.name}")
        print("[idleot] synced stock migrations")

# Drop retired product migration path (renamed game_migrations → custom_migrations).
stale_migrations = os.path.join(target, "scripts", "game_migrations")
if os.path.lexists(stale_migrations):
    if os.path.isdir(stale_migrations) and not os.path.islink(stale_migrations):
        shutil.rmtree(stale_migrations)
    else:
        os.unlink(stale_migrations)
    print("[idleot] removed stale scripts/game_migrations")

print("[idleot] overlay apply done")
PY

for kits in scripts/actions/other/kits.lua scripts/actions/other/construction_kits.lua; do
  f="$TARGET/$kits"
  if [ -f "$f" ] && ! grep -q 'PlayerHome.isHouseCapableTile' "$f"; then
    if grep -q 'getHouse()' "$f"; then
      perl -i -pe 's/if not fromPosition:getTile\(\):getHouse\(\) then/if not fromPosition:getTile():getHouse()\n\t\tand not (PlayerHome and PlayerHome.isHouseCapableTile and PlayerHome.isHouseCapableTile(fromPosition:getTile()))\n\tthen/g' "$f"
      echo "[idleot] patched house-capable check in $kits"
    fi
  fi
done

if [ -n "${CORE_DATA:-}" ]; then
  LOGIN_LUA="$CORE_DATA/scripts/creaturescripts/player/login.lua"
  if [ -f "$LOGIN_LUA" ] && grep -q 'sendOutfitWindow' "$LOGIN_LUA"; then
    perl -i -0pe 's/\t\tloginStr = "Please choose your outfit\."\n\t\tplayer:sendOutfitWindow\(\)/\t\tloginStr = string.format("Welcome to %s!", SERVER_NAME)/s' "$LOGIN_LUA"
    if ! grep -q 'sendOutfitWindow' "$LOGIN_LUA"; then
      echo "[idleot] patched first-login welcome in login.lua"
    fi
  fi
fi

echo "[idleot] done"
