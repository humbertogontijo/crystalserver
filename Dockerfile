# syntax=docker/dockerfile:1.7
# IdleOT CrystalServer — Coolify compose build (idleot/crystalserver).
#
# Compile in the builder stage with BuildKit cache mounts (vcpkg + ccache).
# Coolify custom build command must NOT pass --no-cache (resets those mounts
# on this host): DOCKER_BUILDKIT=1 docker compose build

FROM ubuntu:24.04 AS toolchain

ARG DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	cmake git unzip build-essential ca-certificates curl zip tar \
	pkg-config ninja-build autoconf automake libtool \
	python3 ccache rsync util-linux \
	&& rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-lc"]

FROM toolchain AS builder

WORKDIR /src
COPY . .

# Compile holds these mounts for the whole RUN. Client + server used to share
# idleot-vcpkg-* with sharing=locked, so a long WASM build blocked Crystal.
# sharing=shared: concurrent builds OK (ensure-vcpkg-src.sh flocks the git tree;
# vcpkg binary/download caches are content-addressed).
RUN --mount=type=cache,id=idleot-vcpkg-src,target=/var/cache/vcpkg-src,sharing=shared \
	--mount=type=cache,id=idleot-vcpkg-binaries,target=/var/cache/vcpkg-binaries,sharing=shared \
	--mount=type=cache,id=idleot-vcpkg-downloads,target=/var/cache/vcpkg-downloads,sharing=shared \
	--mount=type=cache,id=idleot-ccache,target=/var/cache/ccache,sharing=locked \
	bash deploy/compile.sh \
	&& test -x /src/out/crystalserver

# Product pin isolated from the binary build.
FROM ubuntu:24.04 AS product

ARG DEBIAN_FRONTEND=noninteractive
ARG IDLEOT_PRODUCT_SHA=
ARG IDLEOT_UMBRELLA_REPO=https://github.com/idleot/idleot.git
ARG GITHUB_TOKEN=

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	git ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-lc"]
COPY deploy/sparse-clone-umbrella.sh /tmp/sparse-clone-umbrella.sh
WORKDIR /opt/idleot
RUN --mount=type=secret,id=github_token,required=false \
	/tmp/sparse-clone-umbrella.sh /opt/idleot/umbrella data/product \
	&& test -d /opt/idleot/umbrella/data/product

FROM ubuntu:24.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	mariadb-client curl ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /crystalserver

COPY --from=builder /src/out/crystalserver /crystalserver/crystalserver
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
