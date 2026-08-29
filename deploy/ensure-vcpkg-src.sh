#!/usr/bin/env bash
# Ensure blobless microsoft/vcpkg at <commit> under <cache_root> (default /var/cache/vcpkg-src).
# Shared by Crystal + OTC via host bind; flock so concurrent builds don't race.
# Never use --depth 1 — vcpkg versioning needs full history.
set -euo pipefail

commit="${1:?usage: ensure-vcpkg-src.sh <commit> [cache_root]}"
root="${2:-/var/cache/vcpkg-src}"
dst="$root/vcpkg"

mkdir -p "$root"
exec 9>"$root/.lock"
flock 9

if [ ! -d "$dst/.git" ]; then
	rm -rf "$dst"
	git clone --filter=blob:none https://github.com/microsoft/vcpkg.git "$dst"
fi

if ! git -C "$dst" cat-file -e "${commit}^{commit}" 2>/dev/null; then
	git -C "$dst" fetch --filter=blob:none origin "$commit"
fi

git -C "$dst" checkout -q "$commit"
echo "[vcpkg-src] ready $commit → $dst"
