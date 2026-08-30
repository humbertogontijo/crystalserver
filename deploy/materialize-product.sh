#!/usr/bin/env bash
# Copy data/product into a datapack (no symlinks — Docker-safe).
# Usage: materialize-product.sh <datapack-dir> <product-dir> <core-data-dir>
set -euo pipefail

TARGET="${1:?datapack dir}"
PRODUCT="${2:?product dir}"
CORE_DATA="${3:?core data dir}"

if [[ ! -d "$TARGET" || ! -d "$PRODUCT" ]]; then
  echo "[product] missing target or product" >&2
  exit 1
fi

echo "[product] materializing → $TARGET (core → $CORE_DATA)"

# GNU cp refuses to write through dangling symlinks (common after rsync of
# product-apply links that pointed at a local data/product tree).
safe_cp_file() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -f "$dest"
  fi
  cp -a "$src" "$dest"
}

copy_tree() {
  local src="$1"
  local dest="$2"
  local label="$3"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dest"
  cp -a "$src"/. "$dest"/
  echo "[product] copied $label"
}

# lib/custom
if [[ -d "$PRODUCT/lib/custom" ]]; then
  mkdir -p "$TARGET/lib"
  rm -rf "$TARGET/lib/custom"
  cp -a "$PRODUCT/lib/custom" "$TARGET/lib/custom"
  echo "[product] copied lib/custom"
fi

# tibia masks
if [[ -d "$PRODUCT/tibia" ]]; then
  rm -rf "$TARGET/tibia"
  cp -a "$PRODUCT/tibia" "$TARGET/tibia"
  echo "[product] copied tibia"
fi

# scripts/custom/<feature>
mkdir -p "$TARGET/scripts/custom"
for feature in combat_automation expeditions player_home remote_hireling hireling remote_dialog \
  autoloot team social promotion quests remote_blessings soulpit_expedition instance_world \
  npcsell reward_chest; do
  if [[ -d "$PRODUCT/scripts/$feature" ]]; then
    rm -rf "$TARGET/scripts/custom/$feature"
    cp -a "$PRODUCT/scripts/$feature" "$TARGET/scripts/custom/$feature"
    echo "[product] copied scripts/custom/$feature"
  fi
done

# npc/custom
if [[ -f "$PRODUCT/npc/remote_hireling_trader.lua" ]]; then
  mkdir -p "$TARGET/npc/custom"
  safe_cp_file "$PRODUCT/npc/remote_hireling_trader.lua" "$TARGET/npc/custom/remote_hireling_trader.lua"
  echo "[product] copied npc/custom/remote_hireling_trader.lua"
fi

# patches overwrite stock — prefer coreDirectory for creaturescripts/actions so they
# replace engine scripts (datapack-only copies may not override core registrations).
if [[ -d "$PRODUCT/patches" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$PRODUCT/patches/"}"
    safe_cp_file "$f" "$TARGET/$rel"
    echo "[product] patch $rel → datapack"
    # Also apply into core data when the path is under scripts/ (creaturescripts, actions, ...).
    if [[ "$rel" == scripts/* ]]; then
      safe_cp_file "$f" "$CORE_DATA/$rel"
      echo "[product] patch $rel → core"
    fi
  done < <(find "$PRODUCT/patches" -type f -print0)
fi

# core overlays
if [[ -d "$PRODUCT/core" ]]; then
  mkdir -p "$CORE_DATA"
  while IFS= read -r -d '' f; do
    rel="${f#"$PRODUCT/core/"}"
    safe_cp_file "$f" "$CORE_DATA/$rel"
    echo "[product] core $rel"
  done < <(find "$PRODUCT/core" -type f -print0)
fi

# lib.lua hooks
LIB="$TARGET/lib/lib.lua"
APPEND="$PRODUCT/hooks/lib.lua.append"
if [[ -f "$LIB" && -f "$APPEND" ]]; then
  if grep -q 'lib/custom/load.lua' "$LIB"; then
    echo "[product] lib/lib.lua already has product hooks"
  else
    cat "$APPEND" >> "$LIB"
    echo "[product] appended hooks to lib/lib.lua"
  fi
fi

# Migrations: stock already in CORE_DATA; append product numbered migrations
MIG_DIR="$CORE_DATA/migrations"
mkdir -p "$MIG_DIR"
MANIFEST="$PRODUCT/migrations/manifest.txt"
STOCK_MAX=0
for stock in "$MIG_DIR"/[0-9]*.lua; do
  [[ -f "$stock" ]] || continue
  n=$(basename "$stock" .lua)
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  if [[ "$n" -gt "$STOCK_MAX" ]]; then STOCK_MAX=$n; fi
done
RUNTIME_MAX=$STOCK_MAX
if [[ -f "$MANIFEST" ]]; then
  while IFS=$'\t ' read -r num file _; do
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    [[ "$file" == *.product ]] || continue
    src="$PRODUCT/migrations/$file"
    [[ -f "$src" ]] || continue
    cp -a "$src" "$MIG_DIR/${num}.lua"
    echo "[product] migration → ${num}.lua from $file"
    if [[ "$num" -gt "$RUNTIME_MAX" ]]; then RUNTIME_MAX=$num; fi
  done < <(grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' || true)
fi
NEXT=$((RUNTIME_MAX + 1))
for prod in "$PRODUCT"/migrations/*.product; do
  [[ -f "$prod" ]] || continue
  base=$(basename "$prod")
  if [[ -f "$MANIFEST" ]] && grep -qF "$base" "$MANIFEST"; then
    continue
  fi
  cp -a "$prod" "$MIG_DIR/${NEXT}.lua"
  echo "[product] migration → ${NEXT}.lua from $base"
  NEXT=$((NEXT + 1))
done

echo "[product] done"
