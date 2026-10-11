# CrystalServer — IdleOT engine Makefile
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: help server-build server-test server-start build test start

help:
	@echo "CrystalServer (IdleOT)"
	@echo "  make server-build       cmake + build (vcpkg)"
	@echo "                          METRICS=1 compiles OpenTelemetry metrics (sticky; METRICS=0 drops it)"
	@echo "  make server-test        build tests in build/<os>-test and run unit tests"
	@echo "  make server-start       run ./crystalserver (cwd = this repo)"

server-build:
	@VCPKG_ROOT="$${VCPKG_ROOT:-$(HOME)/vcpkg}"; \
	test -f "$$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" || (echo "[server] install vcpkg first" && exit 1); \
	export VCPKG_ROOT; \
	case "$$(uname -s)" in Darwin) PRESET=macos-release; case "$$(uname -m)" in arm64|aarch64) export VCPKG_FORCE_SYSTEM_BINARIES=1 ;; esac ;; \
		Linux) PRESET=linux-release ;; *) PRESET=linux-release ;; esac; \
	JOBS="$$(sysctl -n hw.ncpu 2>/dev/null || nproc)"; \
	MAP_TOOLS=""; \
	if [ -d "$(HERE)/../../packages/map-tools" ]; then MAP_TOOLS="$(HERE)/../../packages/map-tools"; fi; \
	METRICS_FLAG=""; \
	case "$(METRICS)" in 1|on|ON|yes|true) METRICS_FLAG="-DFEATURE_METRICS=ON" ;; \
		0|off|OFF|no|false) METRICS_FLAG="-DFEATURE_METRICS=OFF" ;; esac; \
	cd "$(HERE)" && \
		if [ -n "$$MAP_TOOLS" ]; then \
			cmake --preset "$$PRESET" -DIDLEOT_MAP_TOOLS_DIR="$$MAP_TOOLS" $$METRICS_FLAG; \
		else \
			cmake --preset "$$PRESET" $$METRICS_FLAG; \
		fi && \
		cmake --build --preset "$$PRESET" -j"$$JOBS" || exit 1; \
	ABS_BIN=""; \
	for cand in \
		"$(HERE)/build/$$PRESET/bin/crystalserver" \
		"$(HERE)/build/macos-release/bin/crystalserver" \
		"$(HERE)/build/linux-release/bin/crystalserver"; do \
		if [ -x "$$cand" ] && [ ! -L "$$cand" ]; then ABS_BIN="$$cand"; break; fi; \
	done; \
	if [ -z "$$ABS_BIN" ]; then \
		ABS_BIN="$$(find "$(HERE)/build" -type f ! -type l -name crystalserver -perm -111 2>/dev/null | head -1)"; \
	fi; \
	test -n "$$ABS_BIN" && test -x "$$ABS_BIN" || (echo "[server] binary missing" && exit 1); \
	ABS_BIN="$$(cd "$$(dirname "$$ABS_BIN")" && pwd)/$$(basename "$$ABS_BIN")"; \
	ln -sfn "$$ABS_BIN" "$(HERE)/crystalserver"; \
	echo "[server] binary → $(HERE)/crystalserver"; \
	if [ -n "$$MAP_TOOLS" ]; then \
		MAP_TOOLS_BIN="$$MAP_TOOLS/build/$$PRESET/bin"; \
		mkdir -p "$$MAP_TOOLS_BIN"; \
		for tool in cip-occupancy map-query; do \
			ABS_TOOL="$$(find "$(HERE)/build/$$PRESET/bin" -type f -name "$$tool" -perm -111 2>/dev/null | head -1)"; \
			[ -n "$$ABS_TOOL" ] && ln -sfn "$$ABS_TOOL" "$$MAP_TOOLS_BIN/$$tool" && echo "[map-tools] $$tool → $$ABS_TOOL"; \
		done; \
		ABS_MQFFI=""; \
		for cand in \
			"$(HERE)/build/$$PRESET/bin/libmap_query_ffi.dylib" \
			"$(HERE)/build/$$PRESET/bin/libmap_query_ffi.so"; do \
			if [ -f "$$cand" ]; then ABS_MQFFI="$$cand"; break; fi; \
		done; \
		if [ -z "$$ABS_MQFFI" ]; then \
			ABS_MQFFI="$$(find "$(HERE)/build/$$PRESET/bin" -type f \( -name 'libmap_query_ffi.dylib' -o -name 'libmap_query_ffi.so' \) 2>/dev/null | head -1)"; \
		fi; \
		if [ -n "$$ABS_MQFFI" ]; then \
			case "$$ABS_MQFFI" in *.dylib) ln -sfn "$$ABS_MQFFI" "$$MAP_TOOLS_BIN/libmap_query_ffi.dylib" ;; \
				*.so) ln -sfn "$$ABS_MQFFI" "$$MAP_TOOLS_BIN/libmap_query_ffi.so" ;; esac; \
			echo "[map-tools] map_query_ffi → $$ABS_MQFFI"; \
		fi; \
	fi

server-test:
	@VCPKG_ROOT="$${VCPKG_ROOT:-$(HOME)/vcpkg}"; \
	test -f "$$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" || (echo "[server] install vcpkg first" && exit 1); \
	export VCPKG_ROOT; \
	case "$$(uname -s)" in Darwin) PRESET=macos-test; case "$$(uname -m)" in arm64|aarch64) export VCPKG_FORCE_SYSTEM_BINARIES=1 ;; esac ;; \
		*) PRESET=linux-test ;; esac; \
	JOBS="$$(sysctl -n hw.ncpu 2>/dev/null || nproc)"; \
	cd "$(HERE)" && \
		cmake --preset "$$PRESET" && \
		cmake --build --preset "$$PRESET" -j"$$JOBS" && \
		cd "$(HERE)/build/$$PRESET/tests/unit" && ctest --output-on-failure

server-start:
	@test -f "$(HERE)/config.lua" || cat "$(HERE)/config.lua.dist" "$(HERE)/deploy/config.idleot.lua" > "$(HERE)/config.lua"
	@test -x "$(HERE)/crystalserver" || (echo "[server] missing ./crystalserver — make server-build" && exit 1)
	@cd "$(HERE)" && exec ./crystalserver

# Short aliases (same as umbrella naming preferred)
build: server-build
test: server-test
start: server-start
