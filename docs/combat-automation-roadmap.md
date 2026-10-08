# Combat automation & cavebot: ideas from donor helpers

Reviewed 2026-10-07 against the client-side bots in the OTClient donors
(CrystalOTC / NextGen `modules/game_helper`, koliseu `modules/game_helper` with its
`diagram/*.md` specs, and PlayTC, which is a CrystalOTC rebrand). Those bots run in the
client against a normal Tibia inventory. Ours runs on the server
(`data-global/lib/idleot/combat_automation`, `data-global/lib/idleot/cavebot`) with
virtual supplies charged in gold per use, so most of their features either already
exist here or do not apply. This file records what is worth taking.

## Already covered (no action)

| Donor feature | Ours |
|---|---|
| Healer (HP/MP thresholds), mana shield, potions | `slotShouldFire`, `shieldSlotShouldFire`, `usePotion` |
| Heal friend / party heal / area heal | `pickPartyHealTarget`, `areaHealShouldFire` |
| Magic shooter (rules list, monster count, area hits) | rune/attack slots, `countMonstersForSlot`, area/direction tiles |
| Monk harmony thresholds | `harmonyThreshold` slot field |
| Auto haste (+ PZ), utito, party buffs, familiar | support group, `isHasteSpell`, `PARTY_BUFF_BY_WORDS`, `FAMILIAR_WORDS` |
| Targeting priority / ignore | target scoring (`TARGET_*` bonuses), store ignore lists |
| Presets / profiles | loadouts + presets (`13_store.lua`, `14_protocol.lua`) |
| Cavebot waypoints, luring, stop/walk by pack size, stuck recovery | catalog routes + holds, `lureMax`, `06_movement.lua`, `cavebot/03_core.lua` |
| Low-supply alarm / refill | not applicable: supplies are bought per use; `ExpeditionSafety.handleShortage` stops the run when gold runs out |

## Done in this pass

- **Condition-gated cures.** `exana pox/flam/vis/kor/mort` are in the healing group, so
  they used to fire on the healing HP threshold. They now fire only while the caster
  has the condition they dispel (`CombatAutomationConfig.CureConditionByWords`, gate in
  `slotShouldFire`). The client shows a `CURE` badge and hides the HP trigger
  (`isCureSlot` in `mods/custom/game_combat_automation`).
- **Equipment rules (koliseu `equipment.md`).** New slot kind `equip`
  (`equipTypeId`, `triggerStat` hp/mana, `triggerPercent`, `releasePercent`), set on
  the equipment side slot of the bar (group 2: step 1 ammo for paladins, step 2
  amulet, step 3 ring; `SIDE_GROUPS` / `EQUIP_STEP_BY_SLOT`). Side-slot steps are
  independent actions with their own condition; the stance side slot (group 1) works
  the same way (step 2 is the sorcerer crippling aura). A rule puts on the player's
  own ring or amulet at or below the trigger and swaps the previous item back at or
  above the release (hysteresis, default trigger + 30, `EQUIP_RELEASE_MARGIN`).
  Decay forms map back through `ItemType:getTransformEquipId()`, a ring the
  player put on by hand is never touched, and swaps of one body slot are at least
  `EQUIP_SWAP_MS` apart. Only real inventory items are used: when the player owns
  none the rule sits idle and the server sends `automationSlotStatus = missing`, which
  dims the bar slot and says so in its tooltip. Rules run every tick next to the ammo
  refill, also with AUTO off (`runEquipRules` in `12_runtime.lua`). Allowed items are
  `CombatAutomationConfig.EquipItems` (keep in sync with `Equip.CATALOG` in the
  client).
- **Cavebot "avoid" lines (NextGen `cavebot_settings`).** Party members (players
  following an anchor) score tiles lower when a wave or beam of a monster on screen
  covers them (`LINE_PENALTY` per line, at most `LINE_MAX_CASTERS`, in
  `memberTileScore`). Melee members also re-check their spot when their own target
  casts directional attacks. Shapes are the real spell areas: the engine now exposes,
  per entry of `MonsterType:getAttackList()`, `needDirection` (also for scripted
  `InstantSpell` attacks, which were missed before) and `area`, the tiles hit facing
  north as `{ x, y }` offsets from the caster (`AreaCombat::getOffsets`). Scripted
  attacks keep their combat in Lua, so their shape is unknown and they count as a
  5-tile cone. Casters fighting someone else are drawn as they face now; casters
  targeting the member are turned toward each candidate tile.

  **Why not the boss cone for every monster.** The boss front rule (7-tile cone,
  penalty above every other term) was evaluated for all monsters and rejected:
  - Cost: it would test every candidate tile against every visible monster, about
    20-40x the current positioning work, and ranged members would be "unsafe" almost
    all the time, so they would re-plan on every 250 ms tick instead of every 500 ms.
  - Accuracy: only about a third of monster types cast directional attacks, and real
    waves are narrow (a length 8 / spread 3 wave is 1, 1, 3, 3, 3, 5, 5, 5 tiles wide),
    so a 7-tile cone would push members out of many tiles that are safe.
  - Balance: a penalty that large on every monster swamps the anchor ring term, so
    members would drift away from the anchor.

  The line term instead uses each caster's real shape, cached per monster type and
  rotated once, rasterized once per evaluation (members only, every 500 ms). One
  line weighs as much as the anchor-lane slot bonus and less than ranged safety (100),
  so members leave a line when a nearby tile is as good, but never give up the
  formation for it. Bosses keep their stronger cone rule.

## Worth building next

1. **Away alerts (koliseu `classes/alarms/*`).** These are client-only and fit idle
   play well. Alert on HP below N% while automation runs, a private message, a
   death or soft death, and the expedition stopping (gold shortage or kicked). They can
   reuse `mods/custom/game_attention` and the notify banner. Server signals already
   exist for the stop reasons.
2. **Enable guards (koliseu `auto_haste.md`).** A slot that is enabled but has no
   valid spell, rune or item should refuse to enable and say why, instead of sitting
   silently idle. `automationSlotStatus` (used by equip rules) is the channel to
   reuse for this.
