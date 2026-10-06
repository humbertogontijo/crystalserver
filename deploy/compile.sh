#!/usr/bin/env bash
# Compile CrystalServer (Dockerfile builder stage or local toolchain container).
# Expects WORKDIR /src and BuildKit/host caches at:
#   /var/cache/vcpkg-{src,binaries,downloads}  /var/cache/ccache
# Writes binary to /src/out/crystalserver.
#
# Set IDLEOT_SKIP_VCPKG_INSTALL=1 when a prior Docker layer already ran
# deploy/vcpkg-install.sh (binary cache + /opt/vcpkg).
set -euo pipefail

cd /src

mkdir -p /var/cache/ccache /src/out
export CCACHE_DIR=/var/cache/ccache \
	CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}" \
	VCPKG_ROOT="${VCPKG_ROOT:-/opt/vcpkg}" \
	VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg-binaries \
	VCPKG_DOWNLOADS=/var/cache/vcpkg-downloads \
	VCPKG_BINARY_SOURCES="clear;files,/var/cache/vcpkg-binaries,readwrite"

if [[ "${IDLEOT_SKIP_VCPKG_INSTALL:-}" != 1 ]]; then
	bash /src/deploy/vcpkg-install.sh
fi

# 0 / unset / auto → all CPUs. Builds are serialized on Coolify (concurrent_builds=1),
# so use the host fully; leave live game + Coolify to contend only briefly.
JOBS="${IDLEOT_COMPILE_JOBS:-}"
if [[ -z "$JOBS" || "$JOBS" == "0" || "$JOBS" == "auto" ]]; then
	JOBS="$(nproc)"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" VCPKG_MAX_CONCURRENCY="$JOBS"
echo "[compile] jobs=$JOBS (nproc=$(nproc))"

cmake --preset linux-release \
	-DOPTIONS_ENABLE_CCACHE=ON \
	-DOPTIONS_ENABLE_SCCACHE=OFF \
	-DFEATURE_METRICS=ON \
	-DBUILD_TESTS=OFF
cmake --build --preset linux-release -j"$JOBS"
ccache -s || true

install -m 755 /src/build/linux-release/bin/crystalserver /src/out/crystalserver
echo "[compile] wrote /src/out/crystalserver"
