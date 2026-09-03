#!/usr/bin/env bash
# Copy product islands into a Crystal datapack (no overlay engine).
#
# Usage: sync-product.sh <datapack-dir> [product-src]
#
# product-src is either:
#   - Crystal checkout (contains data-global/lib/idleot, …)
#   - a staged product tree (lib/idleot, scripts/idleot, …) e.g. /opt/product
#
# Optional: ASSETS_TIBIA — occupancy masks to copy to datapack tibia/
set -euo pipefail

TARGET="${1:?datapack dir}"
SRC="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "$SRC" ]]; then
  if [[ -f "$HERE/../CMakeLists.txt" ]]; then
    SRC="$(cd "$HERE/.." && pwd)"
  else
    echo "[product] missing product source (pass crystal checkout or /opt/product)" >&2
    exit 1
  fi
fi

if [[ -d "$SRC/data-global/lib/idleot" ]]; then
  PACK="$SRC/data-global"
elif [[ -d "$SRC/lib/idleot" ]]; then
  PACK="$SRC"
else
  echo "[product] no lib/idleot under $SRC (or $SRC/data-global)" >&2
  exit 1
fi

if [[ ! -d "$TARGET" ]]; then
  echo "[product] missing datapack $TARGET" >&2
  exit 1
fi

sync_tree() {
  local from="$1"
  local to="$2"
  local label="$3"
  if [[ ! -d "$from" ]]; then
    echo "[product] skip $label (missing $from)"
    return 0
  fi
  mkdir -p "$to"
  rsync -a --delete "$from/" "$to/"
  echo "[product] synced $label"
}

sync_tree "$PACK/lib/idleot" "$TARGET/lib/idleot" "lib/idleot"
sync_tree "$PACK/scripts/idleot" "$TARGET/scripts/idleot" "scripts/idleot"
sync_tree "$PACK/npc/idleot" "$TARGET/npc/idleot" "npc/idleot"
sync_tree "$PACK/scripts/custom_migrations" "$TARGET/scripts/custom_migrations" "scripts/custom_migrations"

if [[ -f "$PACK/lib/lib.lua" ]]; then
  mkdir -p "$TARGET/lib"
  cp "$PACK/lib/lib.lua" "$TARGET/lib/lib.lua"
  echo "[product] copied lib/lib.lua"
fi

# Optional occupancy masks (umbrella assets/tibia). Skip in Coolify images.
if [[ -z "${ASSETS_TIBIA:-}" && -d "$SRC/../../assets/tibia" ]]; then
  ASSETS_TIBIA="$(cd "$SRC/../../assets/tibia" && pwd)"
fi
if [[ -n "${ASSETS_TIBIA:-}" && -d "$ASSETS_TIBIA" ]]; then
  mkdir -p "$TARGET/tibia"
  rsync -a --delete "$ASSETS_TIBIA/" "$TARGET/tibia/"
  echo "[product] synced tibia/ occupancy"
fi

echo "[product] sync done → $TARGET"
