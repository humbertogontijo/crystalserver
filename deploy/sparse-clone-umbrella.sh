#!/usr/bin/env bash
# Sparse-clone idleot/idleot at IDLEOT_PRODUCT_SHA into <dest>.
# Usage: sparse-clone-umbrella.sh <dest> <sparse-path> [sparse-path...]
# Env: IDLEOT_PRODUCT_SHA (required), IDLEOT_UMBRELLA_REPO, GITHUB_TOKEN
# Optional secret file: /run/secrets/github_token
set -euo pipefail

dest="${1:?usage: sparse-clone-umbrella.sh <dest> <sparse-path>...}"
shift
[ "$#" -ge 1 ] || { echo "at least one sparse-path required" >&2; exit 1; }

sha="${IDLEOT_PRODUCT_SHA:-}"
[ -n "$sha" ] || { echo "[product] IDLEOT_PRODUCT_SHA is required" >&2; exit 1; }
repo="${IDLEOT_UMBRELLA_REPO:-https://github.com/idleot/idleot.git}"

token=""
if [ -f /run/secrets/github_token ]; then
	token="$(cat /run/secrets/github_token)"
fi
if [ -z "$token" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
	token="${GITHUB_TOKEN}"
fi

retry() {
	local n=0
	until "$@"; do
		n=$((n + 1))
		[ "$n" -ge 5 ] && return 1
		echo "[product] attempt $n failed; retrying..." >&2
		sleep $((n * 5))
	done
}

rm -rf "$dest"
mkdir -p "$dest"
git -C "$dest" init -q
git -C "$dest" remote add origin "$repo"
if [ -n "$token" ]; then
	# Prefer header auth so the remote URL stays clean in logs.
	auth="$(printf 'x-access-token:%s' "$token" | base64 -w0 2>/dev/null || printf 'x-access-token:%s' "$token" | base64)"
	git -C "$dest" config --local "http.https://github.com/.extraheader" "AUTHORIZATION: basic $auth"
fi
git -C "$dest" config core.sparseCheckout true
printf '%s\n' "$@" >"$dest/.git/info/sparse-checkout"
retry git -C "$dest" -c http.version=HTTP/1.1 fetch --depth 1 origin "$sha"
git -C "$dest" checkout -q FETCH_HEAD
echo "[product] pinned $sha → $dest"
