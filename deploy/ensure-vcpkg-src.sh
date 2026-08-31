#!/usr/bin/env bash
# Ensure blobless microsoft/vcpkg at <commit> under <cache_root> (default /var/cache/vcpkg-src).
# Shared by Crystal + OTC via BuildKit cache mounts; flock so concurrent builds don't race.
# Never use --depth 1 — vcpkg versioning needs full history.
#
# Optional host seed: set IDLEOT_VCPKG_HOST_SEED when a vcpkg tree is bind-mounted
# at that path (local tooling only — Coolify builds use BuildKit cache mounts).
set -euo pipefail

commit="${1:?usage: ensure-vcpkg-src.sh <commit> [cache_root]}"
root="${2:-/var/cache/vcpkg-src}"
dst="$root/vcpkg"
host_seed="${IDLEOT_VCPKG_HOST_SEED:-}"
vcpkg_git_url="${VCPKG_GIT_URL:-https://github.com/microsoft/vcpkg.git}"
git_retries="${VCPKG_GIT_RETRIES:-5}"

mkdir -p "$root"
exec 9>"$root/.lock"
flock 9

git_retry() {
	local attempt=1
	local delay=5
	while true; do
		if "$@"; then
			return 0
		fi
		if (( attempt >= git_retries )); then
			echo "[vcpkg-src] git failed after ${git_retries} attempts: $*" >&2
			return 1
		fi
		echo "[vcpkg-src] git retry ${attempt}/${git_retries} in ${delay}s: $*" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
		if (( delay > 60 )); then delay=60; fi
	done
}

if [[ -n "$host_seed" && -d "$host_seed/vcpkg/.git" && ! -d "$dst/.git" ]]; then
	echo "[vcpkg-src] seeding from host ${host_seed}/vcpkg"
	rm -rf "$dst"
	cp -a "$host_seed/vcpkg" "$dst"
fi

if [[ ! -d "$dst/.git" ]]; then
	rm -rf "$dst"
	git_retry git clone --filter=blob:none "$vcpkg_git_url" "$dst"
fi

if ! git -C "$dst" cat-file -e "${commit}^{commit}" 2>/dev/null; then
	git_retry git -C "$dst" fetch --filter=blob:none origin "$commit"
fi

git -C "$dst" checkout -q "$commit"
echo "[vcpkg-src] ready $commit → $dst"
