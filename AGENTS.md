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

## Instances

- **Hazard is stock-only.** Zones live on map tiles shared by every instance,
  so a stock `Hazard.new({ name = "hazard.<area>", from, to, maxLevel, crit,
  dodge, damageBoost, defenseBoost }):register()` (see
  `data-global/scripts/systems/hazard_primal.lua`) also applies inside private
  expedition instances: zone `afterEnter`/`afterLeave` set player points and
  `onSpawn` flags monsters. Players pick their level through a stock NPC/lever
  (e.g. Gnomadness). Do not add expedition-side hazard logic.
Semantics, lifecycle and strict mode: [`docs/instances.md`](docs/instances.md).

- **Pass the instance explicitly or rely on the actor scope — there is no
  position fallback.** Packet, creature, NPC, condition, move and decay
  handlers run under an actor scope, and `addEvent` restores the scope it was
  scheduled in. Anywhere else (death callbacks of a gone creature, session
  timers, off-map singletons) pass the key:
  `Game.createMonster(name, pos, ext, force, nil, instanceId)`,
  `Game.createItem(id, count, pos, instanceId)`, `Game.runInInstance(key, fn)`.
  Inferring from a position is counted in `instance_inferred_total{site}` and
  refused when `instanceStrict = true`.
- **Capture the key up front; check liveness when the callback runs.**
  `Instance.isLive(key[, owner])` (or `ExpeditionInstance.isLive(instance)`)
  before spawning into a session. Membership is
  `player:getInstanceId() == key`, never "inside the footprint".
- **Only players change instance** (`InstanceWorld` / `Player::moveToInstance`);
  everything else is born in its instance (umbrella [`scripts/ci/check-instance-setters.sh`](../../scripts/ci/check-instance-setters.sh)).
- **World is the map template.** Use `Instance.WORLD` only for map-template or
  off-map singletons; open-world gameplay lives in city/subarea channels.
