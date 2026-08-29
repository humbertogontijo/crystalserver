#!/usr/bin/env bash
# Compile CrystalServer inside a toolchain container with *real* host binds:
#   /var/cache/vcpkg-{src,binaries,downloads}  /var/cache/ccache
# Writes binary to /src/out/crystalserver (repo workdir mounted at /src).
set -euo pipefail

cd /src

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

cmake --preset linux-release \
	-DOPTIONS_ENABLE_CCACHE=ON \
	-DOPTIONS_ENABLE_SCCACHE=OFF
cmake --build --preset linux-release -j"$(nproc)"
ccache -s || true

install -m 755 /src/build/linux-release/bin/crystalserver /src/out/crystalserver
echo "[compile] wrote /src/out/crystalserver"
