# syntax=docker/dockerfile:1.7
# IdleOT CrystalServer runtime image (idleot/crystalserver).
#
# Built by .github/workflows/build-image.yml → ghcr.io/idleot/crystalserver:<sha>;
# Coolify only pulls it. Compile uses BuildKit cache mounts (vcpkg + ccache)
# that the workflow persists via buildkit-cache-dance.
#
# data + data-global are baked into the runtime stage; datapack-only pushes
# still rebuild it.

FROM ubuntu:24.04 AS toolchain

ARG DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
	&& apt-get update && apt-get install -y --no-install-recommends \
	cmake git unzip build-essential ca-certificates curl zip tar \
	pkg-config ninja-build autoconf automake libtool \
	python3 ccache util-linux \
	&& rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-lc"]

FROM toolchain AS builder

# 0 = auto (nproc).
ARG IDLEOT_COMPILE_JOBS=0
# GitHub Actions round-trips the ccache mount through actions/cache (10 GB repo cap).
ARG CCACHE_MAXSIZE=20G
ENV IDLEOT_COMPILE_JOBS=${IDLEOT_COMPILE_JOBS} \
	CCACHE_MAXSIZE=${CCACHE_MAXSIZE}

WORKDIR /src

COPY vcpkg.json ./
COPY deploy/ensure-vcpkg-src.sh deploy/vcpkg-install.sh ./deploy/

# Compile holds these mounts for the whole RUN. Client + server used to share
# idleot-vcpkg-* with sharing=locked, so a long WASM build blocked Crystal.
# sharing=shared: concurrent builds OK (ensure-vcpkg-src.sh flocks the git tree;
# vcpkg binary/download caches are content-addressed).
RUN --mount=type=cache,id=idleot-vcpkg-src,target=/var/cache/vcpkg-src,sharing=shared \
	--mount=type=cache,id=idleot-vcpkg-binaries,target=/var/cache/vcpkg-binaries,sharing=shared \
	--mount=type=cache,id=idleot-vcpkg-downloads,target=/var/cache/vcpkg-downloads,sharing=shared \
	bash deploy/vcpkg-install.sh

ENV IDLEOT_SKIP_VCPKG_INSTALL=1

COPY CMakeLists.txt CMakePresets.json ./
COPY cmake ./cmake
COPY src ./src
COPY deploy ./deploy

RUN --mount=type=cache,id=idleot-vcpkg-src,target=/var/cache/vcpkg-src,sharing=shared \
	--mount=type=cache,id=idleot-vcpkg-binaries,target=/var/cache/vcpkg-binaries,sharing=shared \
	--mount=type=cache,id=idleot-vcpkg-downloads,target=/var/cache/vcpkg-downloads,sharing=shared \
	--mount=type=cache,id=idleot-ccache,target=/var/cache/ccache,sharing=locked \
	bash deploy/compile.sh \
	&& test -x /src/out/crystalserver

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
COPY config.lua.dist deploy/config.idleot.lua /tmp/config/
COPY data /crystalserver/data
COPY data-global /crystalserver/data-global
COPY deploy/server-entrypoint.sh /crystalserver/server-entrypoint.sh

RUN cat /tmp/config/config.lua.dist /tmp/config/config.idleot.lua > /crystalserver/config.lua \
	&& rm -rf /tmp/config \
	&& chmod +x /crystalserver/crystalserver /crystalserver/server-entrypoint.sh

EXPOSE 7171 7172 7173 7174

ENV MYSQL_HOST=127.0.0.1 \
	MYSQL_PORT=3306 \
	MYSQL_USER=crystal \
	MYSQL_PASSWORD=crystal \
	MYSQL_DATABASE=crystalserver \
	SERVER_IP=auto \
	STATUS_PORT=7171 \
	GAME_PORT=7172 \
	WEBSOCKET_GAME_PORT=7174

ENTRYPOINT ["/crystalserver/server-entrypoint.sh"]
