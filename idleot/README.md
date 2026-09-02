# idleot/

IdleOT overlay for this CrystalServer fork. Path under `idleot/` maps to
datapack / prepare destinations. **Product-only Lua lives here.** Engine C++
and **forked stock datapack files** are normal commits in this repo (rebase
onto upstream). Do not dual-write `idleot/**/*.patch` twins of `data/` /
`data-global/` / `src/`.

## Layout

| Authoring path | Op | Destination |
|----------------|-----|-------------|
| `lib/idleot/…` | MOVE | datapack `lib/idleot/…` |
| `scripts/idleot/…` | MOVE | datapack `scripts/idleot/…` |
| `npc/idleot/…` | MOVE | datapack `npc/idleot/…` |
| `scripts/custom_migrations/…` | MOVE | datapack `scripts/custom_migrations/` |
| `lib/lib.lua.append` | APPEND | datapack `lib/lib.lua` |
| `engine-custom/` | CMake | `-DIDLEOT_CUSTOM_DIR` |
| `index.yml` `series.paths` | inventory | forked stock `data/` / `data-global/` files |

Overlay never touches numbered core `data/migrations/` — use `scripts/custom_migrations/`
(timestamp + KV via stock `Migration()` API).

## How to know custom vs not

- **Ours, overlay:** path contains `/idleot/` (or `scripts/custom_migrations/`).
- **Ours, fork:** listed in `index.yml` / `git diff --name-only upstream/main -- data data-global`.
- **Not ours:** everything else from upstream.

Prefer a `scripts/idleot/` hook (server save, hireling lamp) over editing stock
files. If there is no extension point, edit the real file and add it to
`index.yml`. `make opentibia-server-config` keeps the `data-global/` paths from
that list in the submodule worktree (maps stay sparse-excluded).

## Developer loops

**Overlay (Lua / migrations)**

1. Edit under `idleot/lib/idleot/…`, `scripts/idleot/…`, `npc/idleot/…`, or `scripts/custom_migrations/…`.
2. From the umbrella: `make product-apply` (links into `run/crystalserver/data-global`).
3. Commit in **this engine repo**. Coolify builds `idleot/crystalserver` from `main`.

**Forked stock Lua / engine C++ / Docker**

1. Edit files under `data/`, `data-global/`, `src/`, `Dockerfile` in this repo.
2. If it is a new stock-file tweak, add the path to `index.yml` `series.paths`.
3. Commit and push. No patch export step.

**Upstream**

```bash
git fetch upstream
git rebase upstream/main   # or merge if rebase is painful
# fix conflicts in the real files, build, push
```

## Commands (umbrella)

```bash
make product-apply              # idleot overlay → run/crystalserver
bun run ci:idleot               # MOVE dests vs upstream
# incoming-branch dry-run:
# IDLEOT_UPSTREAM_REF=upstream/<branch> bun run ci:idleot
```
