#!/usr/bin/env bash
# Coolify entrypoint helper: copy product islands into the mounted datapack.
# Usage: materialize-product.sh <datapack-dir> [product-src] [core-data-dir]
set -euo pipefail

TARGET="${1:?datapack dir}"
PRODUCT_SRC="${2:-${IDLEOT_PRODUCT_DIR:-/opt/product}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/sync-product.sh" "$TARGET" "$PRODUCT_SRC"
