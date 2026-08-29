# syntax=docker/dockerfile:1.7
# IdleOT CrystalServer — Coolify build from idleot/crystalserver (repo root context).
# Datapack/world come from host bind mounts (/data/idleot/crystalserver/).
# Product overlay is sparse-cloned from idleot/idleot at IDLEOT_PRODUCT_SHA.
#
# Volumes (Coolify → Storage → Bind mount):
#   /data/idleot/crystalserver/data        → /crystalserver/data
#   /data/idleot/crystalserver/data-global → /crystalserver/data-global
#
# Build args:
#   IDLEOT_PRODUCT_SHA — umbrella commit that owns data/product (required for product)
#   IDLEOT_UMBRELLA_REPO — default https://github.com/idleot/idleot.git
#   GITHUB_TOKEN — build-time env for private umbrella clone (Coolify injects ARGs)
#
# Vcpkg / ccache durability (Coolify always passes --no-cache):
#   Named stages below are overridden by Compose `additional_contexts` pointing at
#   host dirs under /data/idleot/cache/*. Those binds survive `docker builder prune`.
#   Local builds: pass the same --build-context flags, or leave defaults (empty).

# Overridden on Coolify via docker-compose.yaml additional_contexts → /data/idleot/cache/...
FROM scratch AS idleot_vcpkg_binaries
FROM scratch AS idleot_vcpkg_downloads
FROM scratch AS idleot_ccache
FROM scratch AS idleot_vcpkg_src

FROM ubuntu:24.04 AS dependencies

ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,id=idleot-crystal-apt,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,id=idleot-crystal-apt-lists,target=/var/lib/apt/lists,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	cmake git unzip build-essential ca-certificates curl zip tar \
	pkg-config ninja-build autoconf automake libtool \
	python3 ccache rsync util-linux

SHELL ["/bin/bash", "-lc"]

WORKDIR /opt
COPY vcpkg.json /opt/vcpkg.json
# Shared host tree (/data/idleot/cache/vcpkg-src) with Crystal + OTC. flock around
# checkout — blobless clone (not --depth 1); versioning needs full history.
RUN --mount=type=bind,from=idleot_vcpkg_src,source=.,target=/var/cache/vcpkg-src,rw \
	<<'EOS'
set -euo pipefail
vcpkgCommitId=$(grep 'builtin-baseline' vcpkg.json | awk -F: '{print $2}' | tr -d '," \r\n')
echo "vcpkg commit: $vcpkgCommitId"
mkdir -p /var/cache/vcpkg-src
flock /var/cache/vcpkg-src/.lock bash -c '
	set -euo pipefail
	commit="$1"
	if [ ! -d /var/cache/vcpkg-src/vcpkg/.git ]; then
		ok=0
		for i in 1 2 3 4 5; do
			if git -c http.version=HTTP/1.1 clone --filter=blob:none \
				https://github.com/microsoft/vcpkg.git /var/cache/vcpkg-src/vcpkg; then ok=1; break; fi
			echo "[vcpkg] clone attempt $i failed; retrying..." >&2
			rm -rf /var/cache/vcpkg-src/vcpkg
			sleep $((i * 5))
		done
		[ "$ok" = 1 ]
	fi
	if ! git -C /var/cache/vcpkg-src/vcpkg cat-file -e "${commit}^{commit}" 2>/dev/null; then
		ok=0
		for i in 1 2 3 4 5; do
			if git -C /var/cache/vcpkg-src/vcpkg -c http.version=HTTP/1.1 fetch --filter=blob:none origin "$commit"; then ok=1; break; fi
			echo "[vcpkg] fetch attempt $i failed; retrying..." >&2
			sleep $((i * 5))
		done
		[ "$ok" = 1 ]
	fi
	git -C /var/cache/vcpkg-src/vcpkg checkout -q "$commit"
	touch "/var/cache/vcpkg-src/${commit}.ok"
' bash "$vcpkgCommitId"
rm -rf /opt/vcpkg
cp -a /var/cache/vcpkg-src/vcpkg /opt/vcpkg
/opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics
EOS

ENV VCPKG_ROOT=/opt/vcpkg

WORKDIR /opt/vcpkg
COPY vcpkg.json /opt/vcpkg/

# Host-dir binds (Compose additional_contexts). Writes persist on the Coolify disk.
RUN --mount=type=bind,from=idleot_vcpkg_binaries,source=.,target=/var/cache/vcpkg-binaries,rw \
	--mount=type=bind,from=idleot_vcpkg_downloads,source=.,target=/var/cache/vcpkg-downloads,rw \
	mkdir -p /var/cache/vcpkg-binaries /var/cache/vcpkg-downloads \
	&& export VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg-binaries \
		VCPKG_DOWNLOADS=/var/cache/vcpkg-downloads \
		VCPKG_BINARY_SOURCES="clear;files,/var/cache/vcpkg-binaries,readwrite" \
	&& ./vcpkg --feature-flags=manifests,versions install \
	&& echo "[vcpkg] binary cache entries: $(find /var/cache/vcpkg-binaries -type f 2>/dev/null | wc -l)"

FROM dependencies AS build

WORKDIR /srv
COPY src ./src
COPY cmake ./cmake
COPY CMakeLists.txt \
	CMakePresets.json \
	vcpkg.json \
	recompile.sh \
	./

RUN --mount=type=bind,from=idleot_vcpkg_binaries,source=.,target=/var/cache/vcpkg-binaries,rw \
	--mount=type=bind,from=idleot_vcpkg_downloads,source=.,target=/var/cache/vcpkg-downloads,rw \
	--mount=type=bind,from=idleot_ccache,source=.,target=/var/cache/ccache,rw \
	mkdir -p /var/cache/vcpkg-binaries /var/cache/vcpkg-downloads /var/cache/ccache \
	&& export VCPKG_ROOT=/opt/vcpkg \
		VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg-binaries \
		VCPKG_DOWNLOADS=/var/cache/vcpkg-downloads \
		VCPKG_BINARY_SOURCES="clear;files,/var/cache/vcpkg-binaries,readwrite" \
		CCACHE_DIR=/var/cache/ccache \
		CCACHE_MAXSIZE=20G \
	&& cmake --preset linux-release \
		-DOPTIONS_ENABLE_CCACHE=ON \
		-DOPTIONS_ENABLE_SCCACHE=OFF \
	&& cmake --build --preset linux-release -j"$(nproc)" \
	&& (ccache -s || true)

# Product args live ONLY here so product pin bumps never touch vcpkg.
FROM ubuntu:24.04 AS product

ARG DEBIAN_FRONTEND=noninteractive
ARG IDLEOT_PRODUCT_SHA=
ARG IDLEOT_UMBRELLA_REPO=https://github.com/idleot/idleot.git
ARG GITHUB_TOKEN=

RUN --mount=type=cache,id=idleot-crystal-apt,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,id=idleot-crystal-apt-lists,target=/var/lib/apt/lists,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	git ca-certificates

SHELL ["/bin/bash", "-lc"]

WORKDIR /opt/idleot
# Product pin: retries + compose build.network=host (RUN --network=host needs BuildKit entitlement).
RUN --mount=type=secret,id=github_token,required=false \
	set -euo pipefail \
	&& if [ -z "${IDLEOT_PRODUCT_SHA}" ]; then \
		echo "[product] IDLEOT_PRODUCT_SHA is required" >&2; exit 1; \
	fi \
	&& TOKEN="" \
	&& if [ -f /run/secrets/github_token ]; then TOKEN="$(cat /run/secrets/github_token)"; fi \
	&& if [ -z "$TOKEN" ] && [ -n "${GITHUB_TOKEN}" ]; then TOKEN="${GITHUB_TOKEN}"; fi \
	&& git init umbrella \
	&& cd umbrella \
	&& git remote add origin "${IDLEOT_UMBRELLA_REPO}" \
	&& if [ -n "$TOKEN" ]; then \
		git config --local "http.https://github.com/.extraheader" "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0 2>/dev/null || printf 'x-access-token:%s' "$TOKEN" | base64)"; \
	fi \
	&& git config core.sparseCheckout true \
	&& printf 'data/product\n' > .git/info/sparse-checkout \
	&& ok=0 \
	&& for i in 1 2 3 4 5; do \
		if git -c http.version=HTTP/1.1 fetch --depth 1 origin "${IDLEOT_PRODUCT_SHA}"; then ok=1; break; fi; \
		echo "[product] fetch attempt $i failed; retrying..." >&2; \
		sleep $((i * 5)); \
	done \
	&& [ "$ok" = 1 ] \
	&& git checkout FETCH_HEAD \
	&& test -d data/product \
	&& echo "[product] pinned ${IDLEOT_PRODUCT_SHA}"

FROM ubuntu:24.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,id=idleot-crystal-apt,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,id=idleot-crystal-apt-lists,target=/var/lib/apt/lists,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	mariadb-client curl ca-certificates

WORKDIR /crystalserver

COPY --from=build /srv/build/linux-release/bin/crystalserver /crystalserver/crystalserver
COPY schema.sql /crystalserver/schema.sql
COPY key.pem /crystalserver/key.pem
COPY config.lua.dist /crystalserver/config.lua

COPY --from=product /opt/idleot/umbrella/data/product /opt/idleot/product
COPY deploy/materialize-product.sh /opt/idleot/materialize-product.sh
COPY deploy/server-entrypoint.sh /crystalserver/server-entrypoint.sh

RUN mkdir -p /crystalserver/data /crystalserver/data-global \
	&& chmod +x /crystalserver/crystalserver /crystalserver/server-entrypoint.sh \
		/opt/idleot/materialize-product.sh

EXPOSE 7171 7172 7173 7174

ENV MYSQL_HOST=127.0.0.1 \
	MYSQL_PORT=3306 \
	MYSQL_USER=crystal \
	MYSQL_PASSWORD=crystal \
	MYSQL_DATABASE=crystalserver \
	SERVER_IP=auto \
	STATUS_PORT=7171 \
	GAME_PORT=7172 \
	WEBSOCKET_GAME_PORT=7174 \
	IDLEOT_PRODUCT_DIR=/opt/idleot/product \
	IDLEOT_MATERIALIZE=/opt/idleot/materialize-product.sh

ENTRYPOINT ["/crystalserver/server-entrypoint.sh"]
