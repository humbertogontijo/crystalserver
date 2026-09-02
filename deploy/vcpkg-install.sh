#!/usr/bin/env bash
# Bootstrap vcpkg and install manifest packages (Dockerfile deps layer).
# Expects WORKDIR /src and caches at /var/cache/vcpkg-{src,binaries,downloads}.
set -euo pipefail

cd /src

mkdir -p /var/cache/vcpkg-binaries /var/cache/vcpkg-downloads /var/cache/vcpkg-src

commit="$(grep 'builtin-baseline' /src/vcpkg.json | awk -F: '{print $2}' | tr -d '," \r\n')"
bash /src/deploy/ensure-vcpkg-src.sh "$commit" /var/cache/vcpkg-src

if [[ ! -x /opt/vcpkg/vcpkg ]]; then
	rm -rf /opt/vcpkg
	cp -a /var/cache/vcpkg-src/vcpkg /opt/vcpkg
	/opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics
fi

export VCPKG_ROOT=/opt/vcpkg \
	VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg-binaries \
	VCPKG_DOWNLOADS=/var/cache/vcpkg-downloads \
	VCPKG_BINARY_SOURCES="clear;files,/var/cache/vcpkg-binaries,readwrite"

cp -f /src/vcpkg.json /opt/vcpkg/vcpkg.json
(
	cd /opt/vcpkg
	./vcpkg --feature-flags=manifests,versions install
)
echo "[vcpkg-install] crystal packages ready"
