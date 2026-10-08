# Combat automation & cavebot: ideas from donor helpers

Reviewed 2026-10-07 against the client-side bots in the OTClient donors
(CrystalOTC / NextGen `modules/game_helper`, koliseu `modules/game_helper` with its
`diagram/*.md` specs, and PlayTC, which is a CrystalOTC rebrand). Those bots run in the
client against a normal Tibia inventory. Ours runs on the server
(`data-global/lib/idleot/combat_automation`, `expeditions/04a_cavebot.lua`) with
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
| Presets / profiles | loadouts + presets (`04_store.lua`, `05_protocol.lua`) |
| Cavebot waypoints, luring, stop/walk by pack size, stuck recovery | catalog routes + holds, `lureMax`, `06_movement.lua`, `04a_cavebot.lua` |
| Low-supply alarm / refill | not applicable: supplies are bought per use; `ExpeditionSafety.handleShortage` stops the run when gold runs out |

## Done in this pass

- **Condition-gated cures.** `exana pox/flam/vis/kor/mort` are in the healing group, so
  they used to fire on the healing HP threshold. They now fire only while the caster
  has the condition they dispel (`CombatAutomationConfig.CureConditionByWords`, gate in
  `slotShouldFire`). The client shows a `CURE` badge and hides the HP trigger
  (`isCureSlot` in `mods/custom/game_combat_automation`).

## Worth building next

1. **Equipment rules (koliseu `equipment.md`).** Swap a ring or amulet by HP/MP
   condition with unequip priority and decay mapping (for example equip Might Ring at
   or below 40% HP and unequip at or above 80%; Energy Ring with hysteresis). Uses real
   inventory items, so it needs a new slot kind `equip` with `{ itemId, slot, onBelow,
   offAbove }` and a per-tick check next to the healer. Keep hysteresis to avoid
   flapping.
2. **Away alerts (koliseu `classes/alarms/*`).** These are client-only and fit idle
   play well. Alert on HP below N% while automation runs, a private message, a
   death or soft death, and the expedition stopping (gold shortage or kicked). They can
   reuse `mods/custom/game_attention` and the notify banner. Server signals already
   exist for the stop reasons.
3. **Enable guards (koliseu `auto_haste.md`).** A slot that is enabled but has no
   valid spell, rune or item should refuse to enable and say why, instead of sitting
   silently idle.
4. **Cavebot "avoid" lines (NextGen `cavebot_settings`).** Step out of known wave and
   beam lines of the current target before attacking. `00_anchor_spot.lua` already
   models area shapes, so this is a scoring term rather than a new system.
