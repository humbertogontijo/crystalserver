#!/usr/bin/env bash
# Compile CrystalServer (Dockerfile builder stage or local toolchain container).
# Expects WORKDIR /src and BuildKit/host caches at:
#   /var/cache/vcpkg-{src,binaries,downloads}  /var/cache/ccache
# Writes binary to /src/out/crystalserver.
set -euo pipefail

cd /src

if [[ -f /src/deploy/apply-engine-idleot.sh ]]; then
	bash /src/deploy/apply-engine-idleot.sh
fi

mkdir -p /var/cache/vcpkg-binaries /var/cache/vcpkg-downloads /var/cache/vcpkg-src /var/cache/ccache /src/out

commit="$(grep 'builtin-baseline' /src/vcpkg.json | awk -F: '{print $2}' | tr -d '," \r\n')"
bash /src/deploy/ensure-vcpkg-src.sh "$commit" /var/cache/vcpkg-src

rm -rf /opt/vcpkg
cp -a /var/cache/vcpkg-src/vcpkg /opt/vcpkg
if [[ ! -x /opt/vcpkg/vcpkg ]]; then
	/opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics
fi

export VCPKG_ROOT=/opt/vcpkg \
	VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg-binaries \
	VCPKG_DOWNLOADS=/var/cache/vcpkg-downloads \
	VCPKG_BINARY_SOURCES="clear;files,/var/cache/vcpkg-binaries,readwrite" \
	CCACHE_DIR=/var/cache/ccache \
	CCACHE_MAXSIZE=20G

cp -f /src/vcpkg.json /opt/vcpkg/vcpkg.json
(
	cd /opt/vcpkg
	./vcpkg --feature-flags=manifests,versions install
)

JOBS="${IDLEOT_COMPILE_JOBS:-}"
if [[ -z "$JOBS" ]]; then
	JOBS="$(nproc)"
	# Coolify often builds client + server concurrently on one host — cap to reduce OOM kills.
	if (( JOBS > 4 )); then
		JOBS=4
	fi
fi

cmake --preset linux-release \
	-DOPTIONS_ENABLE_CCACHE=ON \
	-DOPTIONS_ENABLE_SCCACHE=OFF \
	-DBUILD_TESTS=OFF \
	-DIDLEOT_CUSTOM_DIR=/src/idleot/engine-custom
cmake --build --preset linux-release -j"$JOBS"
ccache -s || true

install -m 755 /src/build/linux-release/bin/crystalserver /src/out/crystalserver
echo "[compile] wrote /src/out/crystalserver"
