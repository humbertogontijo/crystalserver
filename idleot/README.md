# idleot/

IdleOT overlay for this CrystalServer fork. Path under `idleot/` maps to
datapack / prepare destinations. **This tree is product overlay only** — engine
C++ and Docker live as normal commits in the fork (rebase onto upstream).

## Layout

| Authoring path | Op | Destination |
|----------------|-----|-------------|
| `lib/custom/…` | MOVE | datapack `lib/custom/…` |
| `scripts/custom/…` | MOVE | datapack `scripts/custom/…` |
| `npc/custom/…` | MOVE | datapack `npc/custom/…` |
| `scripts/custom_migrations/…` | MOVE | datapack `scripts/custom_migrations/` |
| `data/**/*.patch` / `data-global/**/*.patch` | PATCH | stock datapack file |
| `lib/lib.lua.append` | APPEND | datapack `lib/lib.lua` |
| `engine-custom/` | CMake | `-DIDLEOT_CUSTOM_DIR` |

Overlay never touches numbered core `data/migrations/` — use `scripts/custom_migrations/`
(timestamp + KV via stock `Migration()` API).

## Developer loops

**Overlay (Lua / migrations)**

1. Edit under `idleot/lib/custom/…`, `scripts/custom/…`, `npc/custom/…`, or `scripts/custom_migrations/…`.
2. From the umbrella: `make product-apply` (links into `run/crystalserver/data-global`).
3. Commit in **this engine repo**. Coolify builds `idleot/crystalserver` from `main`.

**Engine C++ / Docker**

1. Edit files under `src/`, `Dockerfile`, etc. in this repo (not under `idleot/`).
2. Commit and push. No patch export step.

**Upstream**

```bash
git fetch upstream
git rebase upstream/main   # or merge if rebase is painful
# fix conflicts in the real files, build, push
```

## Commands (umbrella)

```bash
make product-apply              # idleot overlay → run/crystalserver
bun run ci:idleot               # MOVE/PATCH uniqueness vs upstream
```
