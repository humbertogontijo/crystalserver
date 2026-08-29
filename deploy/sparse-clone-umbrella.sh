#!/usr/bin/env bash
# Sparse-clone idleot/idleot at IDLEOT_PRODUCT_SHA into <dest>.
# Usage: sparse-clone-umbrella.sh <dest> <sparse-path> [sparse-path...]
# Env: IDLEOT_PRODUCT_SHA (required), IDLEOT_UMBRELLA_REPO, GITHUB_TOKEN
# Optional: /run/secrets/github_token
set -euo pipefail

dest="${1:?usage: sparse-clone-umbrella.sh <dest> <sparse-path>...}"
shift
[ "$#" -ge 1 ] || { echo "at least one sparse-path required" >&2; exit 1; }

sha="${IDLEOT_PRODUCT_SHA:?IDLEOT_PRODUCT_SHA is required}"
repo="${IDLEOT_UMBRELLA_REPO:-https://github.com/idleot/idleot.git}"

token=""
if [ -f /run/secrets/github_token ]; then
	token="$(cat /run/secrets/github_token)"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
	token="${GITHUB_TOKEN}"
fi

rm -rf "$dest"
mkdir -p "$dest"
git -C "$dest" init -q
git -C "$dest" remote add origin "$repo"
if [ -n "$token" ]; then
	auth="$(printf 'x-access-token:%s' "$token" | base64 -w0 2>/dev/null || printf 'x-access-token:%s' "$token" | base64)"
	git -C "$dest" config --local "http.https://github.com/.extraheader" "AUTHORIZATION: basic $auth"
fi
git -C "$dest" config core.sparseCheckout true
printf '%s\n' "$@" >"$dest/.git/info/sparse-checkout"
git -C "$dest" fetch --depth 1 origin "$sha"
git -C "$dest" checkout -q FETCH_HEAD
echo "[product] pinned $sha → $dest"
