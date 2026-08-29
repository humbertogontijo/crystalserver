#!/usr/bin/env bash
# Coolify custom compose build — host-bind vcpkg/ccache (survives builder prune).
#
# Coolify helper only has docker.sock + /data/idleot/cache. Artifact clones live
# inside the helper overlay, so we rsync the tree onto the shared host cache
# path before `docker run -v` (daemon resolves host paths).
#
# Set Coolify → idleot-server → "Docker Compose Custom Build Command" to:
#   bash deploy/coolify-build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Coolify injects app env here during compose builds.
for f in /artifacts/build-time.env "$ROOT/.env"; do
	if [[ -f "$f" ]]; then
		set -a
		# shellcheck disable=SC1090
		source "$f"
		set +a
	fi
done

CACHE="${IDLEOT_CACHE_ROOT:-/data/idleot/cache}"
WS="${IDLEOT_BUILD_WORKSPACE:-$CACHE/work/crystalserver}"
TOOLIMG="${IDLEOT_CRYSTAL_TOOLCHAIN_IMAGE:-idleot-crystal-toolchain}"

mkdir -p "$CACHE"/{vcpkg-binaries,vcpkg-downloads,vcpkg-src,ccache,work} "$WS" "$ROOT/out"
chmod +x "$ROOT/deploy/"*.sh

echo "[coolify-build] sync sources → $WS"
rm -rf "$WS"
mkdir -p "$WS"
# coolify-helper has no rsync — tar is enough
tar -C "$ROOT" \
	--exclude='.git' \
	--exclude='build' \
	--exclude='out' \
	--exclude='crystalserver' \
	--exclude='crystalserver-debug' \
	-cf - . | tar -C "$WS" -xf -

echo "[coolify-build] toolchain image ($TOOLIMG)"
docker build --network=host --target toolchain -t "$TOOLIMG" -f "$ROOT/Dockerfile" "$ROOT"

echo "[coolify-build] compile with host cache binds"
docker run --rm --network=host \
	-v "$CACHE/vcpkg-binaries:/var/cache/vcpkg-binaries" \
	-v "$CACHE/vcpkg-downloads:/var/cache/vcpkg-downloads" \
	-v "$CACHE/vcpkg-src:/var/cache/vcpkg-src" \
	-v "$CACHE/ccache:/var/cache/ccache" \
	-v "$WS:/src" \
	-w /src \
	"$TOOLIMG" \
	bash /src/deploy/compile.sh

echo "[coolify-build] collect out/"
mkdir -p "$ROOT/out"
cp -f "$WS/out/crystalserver" "$ROOT/out/crystalserver"
test -x "$ROOT/out/crystalserver"

echo "[coolify-build] package runtime image via compose"
compose=(docker compose)
[[ -f /artifacts/build-time.env ]] && compose+=(--env-file /artifacts/build-time.env)
project="${COOLIFY_RESOURCE_UUID:-ylqxualu8dxi0erh3tnojrqq}"
compose_file="$ROOT/docker-compose.yaml"
[[ -f "$ROOT/docker-compose.yaml" ]] || compose_file="$ROOT/compose.yaml"

"${compose[@]}" \
	--project-name "$project" \
	--project-directory "$ROOT" \
	-f "$compose_file" \
	build --pull

echo "[coolify-build] done"
