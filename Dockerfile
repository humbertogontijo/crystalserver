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
# Caching (critical — Coolify always passes --no-cache, so layer cache never hits):
#   BuildKit cache mounts with stable ids survive --no-cache and restore vcpkg packages
#   in minutes instead of ~45m. Do NOT enable Coolify "force docker cleanup" / builder
#   prune on this host or those mounts are wiped (see deploy/README.md).

FROM ubuntu:24.04 AS dependencies

ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,id=idleot-crystal-apt,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,id=idleot-crystal-apt-lists,target=/var/lib/apt/lists,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	cmake git unzip build-essential ca-certificates curl zip tar \
	pkg-config ninja-build autoconf automake libtool \
	python3 ccache

WORKDIR /opt
# Only vcpkg.json (baseline) busts this layer's *logic*; Coolify --no-cache still
# re-runs it, but binary/download mounts below make restore cheap.
COPY vcpkg.json /opt/vcpkg.json
RUN --mount=type=cache,id=idleot-vcpkg-git,target=/var/cache/vcpkg-git,sharing=locked \
	vcpkgCommitId=$(grep 'builtin-baseline' vcpkg.json | awk -F: '{print $2}' | tr -d '," \r\n') \
	&& echo "vcpkg commit: $vcpkgCommitId" \
	&& if [ ! -d /var/cache/vcpkg-git/vcpkg/.git ]; then \
		git clone --filter=blob:none https://github.com/microsoft/vcpkg.git /var/cache/vcpkg-git/vcpkg; \
	fi \
	&& git -C /var/cache/vcpkg-git/vcpkg fetch --depth 1 origin "$vcpkgCommitId" \
	&& git -C /var/cache/vcpkg-git/vcpkg checkout --force FETCH_HEAD \
	&& rm -rf /opt/vcpkg \
	&& cp -a /var/cache/vcpkg-git/vcpkg /opt/vcpkg \
	&& /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

ENV VCPKG_ROOT=/opt/vcpkg

WORKDIR /opt/vcpkg
COPY vcpkg.json /opt/vcpkg/

# Binary packages + downloads persist on the Coolify Docker host via BuildKit.
# VCPKG_BINARY_SOURCES=files is the durable form Coolify --no-cache still hits.
RUN --mount=type=cache,id=idleot-vcpkg-binaries,target=/var/cache/vcpkg-binaries,sharing=locked \
	--mount=type=cache,id=idleot-vcpkg-downloads,target=/var/cache/vcpkg-downloads,sharing=locked \
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

# Remount the same vcpkg caches so cmake's embedded `vcpkg install` restores
# packages instead of compiling again (and so the cache dir exists).
RUN --mount=type=cache,id=idleot-vcpkg-binaries,target=/var/cache/vcpkg-binaries,sharing=locked \
	--mount=type=cache,id=idleot-vcpkg-downloads,target=/var/cache/vcpkg-downloads,sharing=locked \
	--mount=type=cache,id=idleot-ccache,target=/var/cache/ccache,sharing=locked \
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

# Sparse-clone data/product from the umbrella at a pinned SHA.
# Product args live ONLY in this stage so product pin bumps never touch vcpkg.
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
RUN --mount=type=secret,id=github_token,required=false \
	set -euo pipefail \
	&& if [ -z "${IDLEOT_PRODUCT_SHA}" ]; then \
		echo "[product] IDLEOT_PRODUCT_SHA is required" >&2; exit 1; \
	fi \
	&& TOKEN="" \
	&& if [ -f /run/secrets/github_token ]; then TOKEN="$(cat /run/secrets/github_token)"; fi \
	&& if [ -z "$TOKEN" ] && [ -n "${GITHUB_TOKEN}" ]; then TOKEN="${GITHUB_TOKEN}"; fi \
	&& REPO="${IDLEOT_UMBRELLA_REPO}" \
	&& if [ -n "$TOKEN" ]; then \
		REPO="$(echo "$REPO" | sed -E "s#https://github.com/#https://x-access-token:${TOKEN}@github.com/#")"; \
	fi \
	&& git init umbrella \
	&& cd umbrella \
	&& git remote add origin "$REPO" \
	&& git config core.sparseCheckout true \
	&& printf 'data/product\n' > .git/info/sparse-checkout \
	&& git fetch --depth 1 origin "${IDLEOT_PRODUCT_SHA}" \
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
