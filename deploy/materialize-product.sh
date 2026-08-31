#!/usr/bin/env bash
# Copy idleot overlays into a datapack (no symlinks — Docker-safe).
# Usage: materialize-product.sh <datapack-dir> [idleot-dir] <core-data-dir>
set -euo pipefail

TARGET="${1:?datapack dir}"
PRODUCT_DIR="${2:-}"
CORE_DATA="${3:?core data dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ -n "$PRODUCT_DIR" && -d "$PRODUCT_DIR" ]]; then
  if [[ -d "$PRODUCT_DIR/idleot" ]]; then
    export IDLEOT_APP_ROOT="$(cd "$PRODUCT_DIR" && pwd)"
  else
    export IDLEOT_APP_ROOT="$(cd "$PRODUCT_DIR/.." && pwd)"
  fi
elif [[ -d /crystalserver/idleot ]]; then
  export IDLEOT_APP_ROOT=/crystalserver
elif [[ -d /src/idleot ]]; then
  export IDLEOT_APP_ROOT=/src
fi

APPLY=""
if [[ -f "$HERE/apply-overlay.sh" ]]; then
  APPLY="$HERE/apply-overlay.sh"
  export IDLEOT_LIB="${IDLEOT_LIB:-$HERE/idleot-lib.py}"
elif [[ -n "${IDLEOT_MONOREPO:-}" && -f "$IDLEOT_MONOREPO/scripts/idleot/apply-overlay.sh" ]]; then
  APPLY="$IDLEOT_MONOREPO/scripts/idleot/apply-overlay.sh"
fi

if [[ ! -d "$TARGET" ]]; then
  echo "[idleot] missing target $TARGET" >&2
  exit 1
fi
if [[ -z "${IDLEOT_APP_ROOT:-}" || ! -d "$IDLEOT_APP_ROOT/idleot" ]]; then
  echo "[idleot] missing idleot tree (set IDLEOT_APP_ROOT)" >&2
  exit 1
fi
if [[ -z "$APPLY" ]]; then
  echo "[idleot] missing apply-overlay.sh next to materialize (keep it in engine deploy/)" >&2
  exit 1
fi

echo "[idleot] materializing → $TARGET (core → $CORE_DATA) from $IDLEOT_APP_ROOT/idleot"
bash "$APPLY" "$TARGET" "$CORE_DATA"

python3 - "$TARGET" <<'PY' || true
import os, shutil, sys
target = sys.argv[1]

def deref_tree(path: str):
    if not os.path.isdir(path):
        return
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in files:
            p = os.path.join(root, name)
            if os.path.islink(p):
                real = os.path.realpath(p)
                os.unlink(p)
                if os.path.isfile(real):
                    shutil.copy2(real, p)

for sub in ("lib/custom", "scripts/custom", "scripts/custom_migrations", "npc/custom", "tibia"):
    deref_tree(os.path.join(target, sub))
print("[idleot] dereferenced symlinks for Docker")
PY

echo "[idleot] materialize done"
