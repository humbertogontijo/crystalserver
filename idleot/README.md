# idleot/

IdleOT overlay for this CrystalServer fork. Path under `idleot/` maps to
`apps/crystalserver/…`. **Extension chooses behavior** (MOVE vs PATCH).

## Two kinds of product (never mix)

| Kind | Author under `idleot/` | Apply step | Commit where |
|------|------------------------|------------|--------------|
| **Overlay** | `lib/custom/`, `scripts/custom/`, `npc/custom/`, `scripts/custom_migrations/` | `make product-apply` (runtime link/copy) | Engine repo only |
| **Engine** | `src/**/*.patch`, MOVE TUs, `engine-custom/`, Docker/CMake | `make fork-export` then `FORCE=1 make fork-apply` | Applied `src/` **and** `idleot/` in engine repo |

Overlay never touches numbered core `data/migrations/` — use `scripts/custom_migrations/`
(timestamp + KV via stock `Migration()` API).

## Layout

```text
idleot/<relpath>
→ <relpath>   # strip .patch / .append
```

| Authoring path | Op | Destination |
|----------------|-----|-------------|
| `src/io/io_wheel.cpp.patch` | PATCH | `src/io/io_wheel.cpp` |
| `lib/custom/hireling/load.lua` | MOVE | datapack `lib/custom/hireling/load.lua` (runtime overlay) |
| `scripts/custom_migrations/…lua` | MOVE | datapack `scripts/custom_migrations/` (not numbered core) |
| `lib/lib.lua.append` | APPEND | datapack `lib/lib.lua` |
| `engine-custom/` | CMake | `-DIDLEOT_CUSTOM_DIR` (not a dest file) |

## Extension registry

| Suffix | Behavior | Upstream conflict |
|--------|----------|-------------------|
| *(any other)* | **MOVE** — install whole file | Dest **exists** on `upstream/main` → conflict |
| `.patch` | **PATCH** — `git apply` onto dest | Dest **missing** → conflict (file moved) |
| `.append` | Append onto existing dest | Dest missing → same as PATCH |

## Developer loops

**Overlay (Lua / migrations)**

1. Edit `idleot/lib/custom/…`, `scripts/custom/…`, `npc/custom/…`, or `scripts/custom_migrations/…`.
2. `make product-apply` (from umbrella) links into `run/crystalserver/data-global`.
3. Commit in **this engine repo**. Umbrella only bumps the submodule SHA.

**Engine C++ / stock datapack patch**

1. Edit the applied file under `apps/crystalserver/src` (or stock `data/` paths in the fork).
2. `make fork-export` → refreshes `idleot/<relpath>.patch` (or MOVE).
3. Commit **both** applied tree and `idleot/` here. Never one without the other.

**Upstream bump**

1. Rebase/cherry-pick manually ([`docs/engine-forks.md`](../../../docs/engine-forks.md)).
2. `bun run ci:idleot` + `ci:fork-apply` — PATCH/MOVE conflicts list what broke.
3. Fix `idleot/`, then `FORCE=1 make fork-apply`.
4. Smoke: `make opentibia-server-config` from umbrella.

Coolify builds **this repo** (applied HEAD + in-tree `idleot/`). Runtime entrypoint
materializes overlay into the mounted datapack — no umbrella product clone.

## Commands (umbrella)

```bash
make product-apply              # idleot overlay → run/crystalserver
make fork-export                # diffs → idleot/**/*.patch or MOVE
FORCE=1 make fork-apply         # upstream + idleot engine files → this repo
bun run ci:idleot
bun run ci:fork-apply
```

[`index.yml`](index.yml) holds series order and dest→label map for export.
