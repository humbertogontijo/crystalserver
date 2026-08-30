#!/usr/bin/env bash
# Coolify custom compose build — host-bind vcpkg/ccache (survives builder prune).
#
# Coolify helper only has docker.sock + /data/idleot/cache. Artifact clones live
# inside the helper overlay, so we sync onto the shared host cache path before
# `docker run -v` (daemon resolves host paths).
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

echo "[coolify-build] toolchain image ($TOOLIMG)"
# Coolify's default compose path uses --no-cache; this custom script must not.
# Toolchain stage has no COPY — only rebuild when the Dockerfile changes or the
# tagged image is missing.
df_hash="$(sha256sum "$ROOT/Dockerfile" | awk '{print $1}')"
df_marker="$CACHE/crystal-toolchain.dockerfile.sha256"
if docker image inspect "$TOOLIMG" >/dev/null 2>&1 \
	&& [[ -f "$df_marker" && "$(cat "$df_marker")" == "$df_hash" ]]; then
	echo "[coolify-build] toolchain up to date (Dockerfile $df_hash) — skip docker build"
else
	DOCKER_BUILDKIT=1 docker build --network=host --target toolchain \
		-t "$TOOLIMG" -f "$ROOT/Dockerfile" "$ROOT"
	echo "$df_hash" >"$df_marker"
fi

echo "[coolify-build] sync sources → $WS"
# Artifact clones live in the Coolify helper overlay. `docker run -v "$ROOT:..."`
# resolves on the *host*, where /artifacts/<uuid> is empty — rsync --delete then
# wipes the workspace. Stream the overlay tree into a toolchain container that
# only bind-mounts the host cache workspace, then checksum-rsync (keeps mtimes).
mkdir -p "$WS"
tar -C "$ROOT" \
	--exclude='.git' \
	--exclude='./build' \
	--exclude='./out' \
	--exclude='./crystalserver' \
	--exclude='./crystalserver-debug' \
	-cf - . | docker run --rm -i \
	-v "$WS:/dst" \
	"$TOOLIMG" \
	bash -c 'set -euo pipefail
		stage=$(mktemp -d)
		trap "rm -rf \"$stage\"" EXIT
		tar -C "$stage" -xf -
		rsync -a --delete --checksum \
			--exclude ".git/" \
			--exclude "build/" \
			--exclude "out/" \
			--exclude "crystalserver" \
			--exclude "crystalserver-debug" \
			"$stage"/ /dst/'
if [[ -d "$WS/build" ]]; then
	echo "[coolify-build] keeping build/ ($(du -sh "$WS/build" | awk '{print $1}'))"
else
	echo "[coolify-build] no prior build/ — cold cmake this run"
fi

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
	build

echo "[coolify-build] done"
