# Instances

Every creature and item lives in exactly one **instance**: a parallel layer of
the map. Two things interact (see each other, collide, fight, share a tile
stack) only when their instances match.

## Identity

`InstanceId` (`src/game/instance_id.hpp`) is `{kind, subareaId, channel}`
packed into 64 bits. Its canonical text form is the **key**
`kind:subareaId:channel` (e.g. `hunt:2104284:3`); Lua, logs and the KV store
only ever see keys.

| Kind | Meaning |
|------|---------|
| `world` | `world:0:0`, the shared map template (map file items, houses, map save). |
| `city`, `settlement`, `wild`, `hunt`, `connector` | Open-world layers from the subarea partition. Channel 0 always exists; overflow channels open when the main one is full. |
| `hub` | Adventurers' hub; also the login fallback. |
| `lobby`, `raid`, `arena`, `worldboss`, `soulpit` | Private-only kinds: every channel is a reserved session. |

`InstanceId::Any` is a spectator wildcard and is never stored on a thing.

## Registry

`InstanceRegistry` (`g_instanceRegistry()`) is the single source of truth:

- `allocate(kind, subareaId, {owner, tag})` opens a reserved channel or
  returns `nullopt` (logged, counted in `instance_allocate_failed_total{kind}`).
  Reserved channel numbers only move forward per `{kind, subarea}`, so a key
  captured by a script never silently points at a newer session.
- `pickChannel(kind, subareaId, preferred, player)` returns the public channel
  a player should join (explicit `preferred` → current channel of that
  subarea → party's channel → lowest with room → new). Channel numbers belong
  to their subarea and never carry over when crossing into another one.
- `isLive`, `isPrivate`, `find` (owner, tag, state), `members`, `release`.
  World and implicit main channels (channel 0 of open-world kinds and hub) are
  always live.

## Rules

1. **Things are born in their instance.** `Game.createMonster`,
   `Game.createNpc`, `Game.createItem`, `Tile:addItem`, ... take an explicit
   instance; without one they use the actor scope (below). Only players move
   between instances (`Player::moveToInstance` / `player:setInstanceId` inside
   `InstanceWorld`); the umbrella `scripts/ci/check-instance-setters.sh`
   enforces it.
2. **No position fallback.** Code must pass the instance explicitly or run
   under an actor scope. Guessing from a tile position is reported as an
   inference (see strict mode) and refused when `instanceStrict = true`.
3. **Capture the key up front.** Callbacks that run later (`addEvent`, death
   events, phased boss timers) capture the key when they are scheduled and
   check `Instance.isLive(key[, owner])` before acting. Never re-read a
   session table that may have been reassigned in between.
4. **Membership is the bound key.** A player belongs to a session when
   `player:getInstanceId() == session key`, not when they stand inside its
   footprint (hunt tiles are shared by every channel).
5. **World is the template.** Map save, house items and other persistent
   shared state are World-only. Use `Instance.WORLD` explicitly for off-map
   singletons shared by every instance.

## Actor scope

`InstanceActorScope` (thread-local, `src/game/game.hpp`) tells instance-less
engine calls which layer they run in:

| Mode | Opened by | Instance |
|------|-----------|----------|
| Creature | packet dispatch, NPC/creature events, conditions, move events | the actor's current instance |
| Instance | `Game.runInInstance(key, fn)`, item decay, `addEvent` restore | the captured key |
| Positional | startup, global events, raids | open-world layer at each position (by design, not reported) |
| None | — | inference: reported, refused in strict mode |

`addEvent` and engine tasks capture the scope when scheduled
(`Game::bindInstanceScope`) and restore it when they run, capturing the id
rather than the creature.

## Login and persistence

Every player rebind writes the KV record `instance = {key, kind, owner,
private}`. On login, before placement, `Game::bindPlayerInstance`:

1. snapshots the record to `instance_login` (used by the stranded-expedition
   check);
2. restores the recorded key when it is still live, its owner matches (private
   sessions) and the login position fits it;
3. lets `InstanceWorld.bindLogin` refine it (live hunt session, lobby, open
   world);
4. otherwise picks the open-world channel at the position, and finally falls
   back to the hub (temple when inside the hub, else the hub center).

Reconnects keep the attached player's current instance.

## Strict mode

`instanceStrict` (`config.lua`) gates every place that used to guess. Each
call to `reportInstanceInference(site)` increments
`instance_inferred_total{site}` and logs a rate-limited warning with the Lua
traceback. With `instanceStrict = false` the inference proceeds; with `true`
the operation is refused.

Sites: `Game.createMonster`, `Game.createNpc`, `Game.generateNpc`,
`Game.createItem`, `Game.createContainer`, `Game.createSoulPitMonster`,
`Tile.addItem`, `Tile.getTopCreature`, `Tile.getFieldItem`, `combat`,
`effect`, `cylinder`, `reconnect`.

## Lua

`data/libs/functions/instance.lua` is a thin wrapper over the engine:

- `Instance.WORLD`, `Instance.HUB` — keys from the engine.
- `Instance.key(kind, subareaId, channel)`, `Instance.parse(id)`,
  `Instance.normalize(id)`, `Instance.of(thing)`.
- `Instance.kind/subareaId/channel/withChannel`, `Instance.isWorld`,
  `Instance.isPrivate`, `Instance.isOpenWorld`, `Instance.sameSubarea`.
- `Instance.isLive(key[, owner])` — `Game.isInstanceLive`.

Expedition sessions use `ExpeditionInstance.isLive(instance)` (not torn down
and still live in the engine); torn-down instances keep their key so late
callbacks can compare against it.
