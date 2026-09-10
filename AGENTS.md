# CrystalServer agent guide

Lua-first for product gameplay, but **do not avoid C++ by default**. Long Lua
workarounds that dodge a small engine change deliver worse quality. Monorepo
index: [`../../AGENTS.md`](../../AGENTS.md). Fork layout:
[`../../docs/engine-forks.md`](../../docs/engine-forks.md).

## Lua vs C++

1. **Prefer Lua** in product islands when the existing Lua/C++ API already
   supports the behavior cleanly:
   - `data-global/lib/idleot/`
   - `data-global/scripts/idleot/`
   - `data-global/npc/idleot/`
   - Product DB: `data-global/scripts/custom_migrations/` (not core `data/migrations/`)
2. **Before Lua-only**, weigh:
   - **Hot-path cost** — combat ticks, pathfinding, spawn loops, per-creature
     or per-tile work → lean C++ (or a thin C++ binding + thin Lua).
   - **Code volume** — large workarounds, duplicated hooks, or fragile stock
     monkey patches → prefer a small C++ interface that enables short Lua.
   - **API gap** — capability many scripts need → one focused C++/Lua binding;
     do not re-implement around the gap in every script.
3. **C++ scope** — smallest interface that unlocks clean Lua; not a wholesale
   port of product content into `src/`. Commit in this submodule, rebase
   `upstream/main`, no `*.patch` twins of engine diffs.
