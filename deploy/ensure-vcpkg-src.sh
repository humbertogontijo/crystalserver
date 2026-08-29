#!/usr/bin/env bash
# Ensure blobless microsoft/vcpkg at <commit> under <cache_root> (default /var/cache/vcpkg-src).
# Shared by Crystal + OTC via host bind; flock so concurrent builds don't race.
# Never use --depth 1 — vcpkg versioning needs full history.
set -euo pipefail

commit="${1:?usage: ensure-vcpkg-src.sh <commit> [cache_root]}"
root="${2:-/var/cache/vcpkg-src}"
dst="$root/vcpkg"
repo="https://github.com/microsoft/vcpkg.git"

mkdir -p "$root"
exec 9>"$root/.lock"
flock 9

retry() {
	local n=0
	until "$@"; do
		n=$((n + 1))
		[ "$n" -ge 5 ] && return 1
		echo "[vcpkg-src] attempt $n failed; retrying..." >&2
		sleep $((n * 5))
	done
}

if [ ! -d "$dst/.git" ]; then
	rm -rf "$dst"
	retry git -c http.version=HTTP/1.1 clone --filter=blob:none "$repo" "$dst"
fi

if ! git -C "$dst" cat-file -e "${commit}^{commit}" 2>/dev/null; then
	retry git -C "$dst" -c http.version=HTTP/1.1 fetch --filter=blob:none origin "$commit"
fi

git -C "$dst" checkout -q "$commit"
echo "[vcpkg-src] ready $commit → $dst"
