# syntax=docker/dockerfile:1.7
# IdleOT CrystalServer — Coolify compose build (idleot/crystalserver).
#
# Host binds (compose additional_contexts → /data/idleot/cache/*):
#   vcpkg-src, vcpkg-binaries, vcpkg-downloads, ccache
# Datapack: /data/idleot/crystalserver/{data,data-global}
# Product: sparse-clone umbrella at IDLEOT_PRODUCT_SHA (isolated stage).

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
COPY vcpkg.json deploy/ensure-vcpkg-src.sh /opt/
RUN --mount=type=bind,from=idleot_vcpkg_src,source=.,target=/var/cache/vcpkg-src,rw \
	commit="$(grep 'builtin-baseline' /opt/vcpkg.json | awk -F: '{print $2}' | tr -d '," \r\n')" \
	&& /opt/ensure-vcpkg-src.sh "$commit" \
	&& rm -rf /opt/vcpkg \
	&& cp -a /var/cache/vcpkg-src/vcpkg /opt/vcpkg \
	&& /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

ENV VCPKG_ROOT=/opt/vcpkg

WORKDIR /opt/vcpkg
COPY vcpkg.json /opt/vcpkg/

RUN --mount=type=bind,from=idleot_vcpkg_binaries,source=.,target=/var/cache/vcpkg-binaries,rw \
	--mount=type=bind,from=idleot_vcpkg_downloads,source=.,target=/var/cache/vcpkg-downloads,rw \
	mkdir -p /var/cache/vcpkg-binaries /var/cache/vcpkg-downloads \
	&& export VCPKG_DEFAULT_BINARY_CACHE=/var/cache/vcpkg-binaries \
		VCPKG_DOWNLOADS=/var/cache/vcpkg-downloads \
		VCPKG_BINARY_SOURCES="clear;files,/var/cache/vcpkg-binaries,readwrite" \
	&& ./vcpkg --feature-flags=manifests,versions install

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

# Product pin isolated so SHA bumps never invalidate vcpkg layers.
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
COPY deploy/sparse-clone-umbrella.sh /tmp/sparse-clone-umbrella.sh
WORKDIR /opt/idleot
RUN --mount=type=secret,id=github_token,required=false \
	/tmp/sparse-clone-umbrella.sh /opt/idleot/umbrella data/product \
	&& test -d /opt/idleot/umbrella/data/product

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
