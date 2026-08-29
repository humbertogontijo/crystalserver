#!/usr/bin/env bash
# Runtime config for IdleOT CrystalServer image.
# Expects host-synced datapack mounts at ./data and ./data-global.
set -euo pipefail

cd /crystalserver

MYSQL_HOST="${MYSQL_HOST:-${OT_DB_HOST:-127.0.0.1}}"
MYSQL_PORT="${MYSQL_PORT:-${OT_DB_PORT:-3306}}"
MYSQL_USER="${MYSQL_USER:-${OT_DB_USER:-crystal}}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-${OT_DB_PASSWORD:-crystal}}"
MYSQL_DATABASE="${MYSQL_DATABASE:-${OT_DB_DATABASE:-crystalserver}}"
SERVER_IP="${SERVER_IP:-${OT_SERVER_IP:-127.0.0.1}}"
STATUS_PORT="${STATUS_PORT:-7171}"
GAME_PORT="${GAME_PORT:-7172}"
# Crystal ProtocolStatus (otservlist / info XML) listens on worlds.port_status — not LOGIN_PORT.
# Keep 7173; do not point WebSocket here (upstream schema uses 7173 for status).
WORLD_STATUS_PORT="${WORLD_STATUS_PORT:-7173}"
WEBSOCKET_GAME_PORT="${WEBSOCKET_GAME_PORT:-7174}"
SERVER_NAME="${SERVER_NAME:-Idlebra}"
SERVER_MOTD="${SERVER_MOTD:-Welcome to IdleOT!}"
OWNER_NAME="${OWNER_NAME:-IdleOT}"
OWNER_EMAIL="${OWNER_EMAIL:-admin@idleot.com}"
SERVER_URL="${SERVER_URL:-https://www.idleot.com}"
# Host/IP advertised in ProtocolStatus XML (worlds.ip). Defaults to bind IP.
STATUS_ADVERTISE_IP="${STATUS_ADVERTISE_IP:-}"
COIN_IMAGES_URL="${COIN_IMAGES_URL:-}"
PRODUCT_DIR="${IDLEOT_PRODUCT_DIR:-/opt/idleot/product}"
MATERIALIZE="${IDLEOT_MATERIALIZE:-/opt/idleot/materialize-product.sh}"
SKIP_PRODUCT_APPLY="${IDLEOT_SKIP_PRODUCT_APPLY:-0}"

if [[ ! -f data-global/world/world.otbm ]]; then
  echo "[server] missing data-global/world/world.otbm" >&2
  echo "[server] sync host data first: ./scripts/deploy/sync-data.sh" >&2
  echo "[server] expected bind mount: /data/idleot/crystalserver/data-global → /crystalserver/data-global" >&2
  exit 1
fi

if [[ ! -d data/migrations ]]; then
  echo "[server] missing data/migrations — sync crystalserver core data" >&2
  exit 1
fi

# Apply product overlay into mounted datapack once (or when stamp mismatches image product).
if [[ "$SKIP_PRODUCT_APPLY" != "1" && -x "$MATERIALIZE" && -d "$PRODUCT_DIR" ]]; then
  STAMP="data-global/.idleot-product-stamp"
  PRODUCT_HASH="$(find "$PRODUCT_DIR" -type f -print0 2>/dev/null | sort -z | xargs -0 cat 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ ! -f "$STAMP" || "$(cat "$STAMP" 2>/dev/null)" != "$PRODUCT_HASH" ]]; then
    echo "[server] materializing product overlay into mounted datapack..."
    bash "$MATERIALIZE" /crystalserver/data-global "$PRODUCT_DIR" /crystalserver/data
    printf '%s\n' "$PRODUCT_HASH" > "$STAMP"
  else
    echo "[server] product overlay already applied ($STAMP)"
  fi
fi

echo "[server] waiting for MariaDB at ${MYSQL_HOST}:${MYSQL_PORT}..."
for i in $(seq 1 60); do
  if mysqladmin ping -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null; then
    echo "[server] MariaDB ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[server] MariaDB not reachable after 60s" >&2
    exit 1
  fi
  sleep 2
done

if ! mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    -D "$MYSQL_DATABASE" -N -e "SHOW TABLES LIKE 'server_config'" 2>/dev/null | grep -q server_config; then
  echo "[server] importing schema.sql"
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    -D "$MYSQL_DATABASE" < /crystalserver/schema.sql
fi

if [ "$SERVER_IP" = "auto" ]; then
  SERVER_IP="$(curl -fsS https://ifconfig.me/ip || curl -fsS https://api.ipify.org || echo 127.0.0.1)"
  echo "[server] discovered SERVER_IP=$SERVER_IP"
fi

patch_config() {
  local key="$1"
  local value="$2"
  local quoted="${3:-1}"
  if grep -qE "^${key}[[:space:]]*=" config.lua; then
    if [ "$quoted" = "1" ]; then
      sed -i -E "s|^${key}[[:space:]]*=.*|${key} = \"${value}\"|" config.lua
    else
      sed -i -E "s|^${key}[[:space:]]*=.*|${key} = ${value}|" config.lua
    fi
  else
    if [ "$quoted" = "1" ]; then
      echo "${key} = \"${value}\"" >> config.lua
    else
      echo "${key} = ${value}" >> config.lua
    fi
  fi
}

patch_config mysqlHost "$MYSQL_HOST"
patch_config mysqlUser "$MYSQL_USER"
patch_config mysqlPass "$MYSQL_PASSWORD"
patch_config mysqlPort "$MYSQL_PORT" 0
patch_config mysqlDatabase "$MYSQL_DATABASE"
patch_config ip "$SERVER_IP"
patch_config statusProtocolPort "$STATUS_PORT" 0
patch_config gameProtocolPort "$GAME_PORT" 0
patch_config loginProtocolPort "$STATUS_PORT" 0
patch_config websocketGamePort "$WEBSOCKET_GAME_PORT" 0
patch_config dataPackDirectory "data-global"
patch_config coreDirectory "data"
patch_config authType "session"
patch_config disableLegacyRaids true 0

if [ -n "$COIN_IMAGES_URL" ]; then
  patch_config coinImagesURL "$COIN_IMAGES_URL"
elif [ -n "${IDLEOT_ASSET_BASE:-}" ]; then
  patch_config coinImagesURL "${IDLEOT_ASSET_BASE%/}/assets/store/"
fi

patch_config serverName "$SERVER_NAME"
patch_config serverMotd "$SERVER_MOTD"
patch_config ownerName "$OWNER_NAME"
patch_config ownerEmail "$OWNER_EMAIL"
patch_config url "$SERVER_URL"
patch_config useAnyDatapackFolder "false" 0
patch_config maxPlayersOnlinePerAccount "4" 0
patch_config maxPlayersOutsidePZPerAccount "4" 0
patch_config maxPacketsPerSecond "50" 0
patch_config autoBank "true" 0
patch_config autoLoot "true" 0
patch_config toggleGoldPouchQuickLootOnly "true" 0
patch_config showLootsInBestiary "true" 0
patch_config rateUseStages "true" 0
patch_config freePremium "true" 0
patch_config vipSystemEnabled "true" 0
patch_config removeBeginningWeaponAmmunition "false" 0

# ProtocolStatus reads worlds.{name,ip,port_status} from MariaDB (createFirstWorld only
# inserts once). Sync every boot so otservlist sees the public host + Idlebra name.
ADVERTISE_IP="${STATUS_ADVERTISE_IP:-$SERVER_IP}"
ESC_NAME="$(printf '%s' "$SERVER_NAME" | sed "s/'/\\\\'/g")"
ESC_MOTD="$(printf '%s' "$SERVER_MOTD" | sed "s/'/\\\\'/g")"
ESC_IP="$(printf '%s' "$ADVERTISE_IP" | sed "s/'/\\\\'/g")"
echo "[server] syncing worlds row name=${SERVER_NAME} ip=${ADVERTISE_IP} port=${GAME_PORT} port_status=${WORLD_STATUS_PORT}"
mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  -D "$MYSQL_DATABASE" -e \
  "UPDATE worlds SET name='${ESC_NAME}', motd='${ESC_MOTD}', ip='${ESC_IP}', port=${GAME_PORT}, port_status=${WORLD_STATUS_PORT} WHERE id=1;" \
  || echo "[server] warning: worlds sync failed (table missing?)" >&2

echo "[server] starting crystalserver (cwd /crystalserver)"
ulimit -c unlimited || true
exec ./crystalserver
