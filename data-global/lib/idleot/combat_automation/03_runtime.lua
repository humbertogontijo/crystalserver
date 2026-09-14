CombatAutomation = CombatAutomation or {}

local statesByPlayerId = {}

local function nowMs()
	-- Wall-clock ms (OTSYS_TIME). os.clock() is CPU-time and stalls exhaust under load.
	if type(systemTime) == "function" then
		return math.floor(systemTime())
	end
	return math.floor(os.time() * 1000)
end

local function percentOf(current, maximum)
	maximum = math.max(1, maximum or 1)
	current = math.max(0, current or 0)
	return math.floor((current / maximum) * 100)
end

local function spellGroup(slot)
	if not slot or slot.kind ~= "spell" then
		return nil
	end
	return CombatAutomationConfig.SpellGroupById and CombatAutomationConfig.SpellGroupById[slot.spellId]
end

local function isHasteSpell(slot)
	local words = tostring(slot and slot.words or ""):lower()
	-- Haste / Strong Haste / Charge (utani*), plus Swift Foot.
	return words:find("utani", 1, true) ~= nil or words == "utamo tempo san"
end

local function playerIsHasted(player)
	return player and type(CONDITION_HASTE) == "number" and player:hasCondition(CONDITION_HASTE)
end

local function playerHasManaShield(player)
	return player and type(CONDITION_MANASHIELD) == "number" and player:hasCondition(CONDITION_MANASHIELD)
end

local function playerInProtectionZone(player)
	if not player or not player.getZoneType then
		return false
	end
	local zoneProtection = ZONE_PROTECTION or 0
	return player:getZoneType() == zoneProtection
end

-- Party buff spells: cast only while the caster is not already under that buff.
local PARTY_BUFF_BY_WORDS = {
	["utito mas sio"] = { condition = "attributes", subId = 1 }, -- Train Party
	["utamo mas sio"] = { condition = "attributes", subId = 2 }, -- Protect Party
	["utori mas sio"] = { condition = "attributes", subId = 3 }, -- Enchant Party
	["utura mas sio"] = { condition = "regeneration", subId = 1 }, -- Heal Party
	["utevo mas sio"] = { condition = "regeneration", subId = 3 }, -- Enlighten Party
}

local FAMILIAR_WORDS = {
	["utevo gran res eq"] = true, -- Knight
	["utevo gran res sac"] = true, -- Paladin
	["utevo gran res dru"] = true, -- Druid
	["utevo gran res ven"] = true, -- Sorcerer
	["utevo gran res tio"] = true, -- Monk
}

local CHALLENGE_WORDS = {
	["exeta res"] = "challenge", -- Challenge (adjacent)
	["exeta amp res"] = "amp_challenge", -- Chivalrous: ranged or not adjacent
	["exana amp res"] = "ranged_chain", -- Divine Dazzle
	["exori mas res"] = "brawl", -- Balanced Brawl
}

-- Assigned after visibleMonsters / iterPartyPlayers (forward decl for slotShouldFire).
local supportSlotShouldFire

--- Attack/runes gate on monster count; stance/cripple/ammo/support ignore HP/mana triggers.
local function slotIgnoresTriggerStat(slot)
	if not slot then
		return false
	end
	if slot.kind == "rune" or slot.kind == "ammo" then
		return true
	end
	local group = spellGroup(slot)
	if group == "attack" or group == "stance" or group == "support" then
		return true
	end
	-- Crippling auras are catalogued as support but behave like stances.
	local words = tostring(slot.words or ""):lower()
	return words == "exori kor tempo" or words == "exori moe tempo"
end

--- HP % threshold for friend/area/self heals. Legacy "always"/mana → not full.
local function healHpThreshold(slot)
	local stat = slot and slot.triggerStat or "hp"
	if stat == "always" or stat == "mana" then
		return 99
	end
	return math.max(0, math.min(100, math.floor(tonumber(slot and slot.triggerPercent) or 0)))
end

--- Magic Shield (utamo vita): keep up when absent; respect Always / Mana % triggers.
local function shieldSlotShouldFire(player, slot, hpPercent, manaPercent)
	if not slot or slot.enabled == false then
		return false
	end
	local words = tostring(slot.words or ""):lower()
	if words ~= "utamo vita" then
		return false
	end
	if playerHasManaShield(player) then
		return false
	end
	local stat = slot.triggerStat or "always"
	local threshold = slot.triggerPercent or 0
	if stat == "always" then
		return true
	elseif stat == "mana" then
		return manaPercent <= threshold
	end
	return true
end

local function slotShouldFire(slot, hpPercent, manaPercent, player)
	if not slot or slot.enabled == false then
		return false
	end
	local group = spellGroup(slot)
	if group == "support" then
		return supportSlotShouldFire(player, slot)
	end
	if group == "shield" then
		return shieldSlotShouldFire(player, slot, hpPercent, manaPercent)
	end
	if slotIgnoresTriggerStat(slot) then
		return true
	end
	-- Healing spells are always HP-threshold gated.
	if group == "healing" then
		return hpPercent <= healHpThreshold(slot)
	end
	local stat = slot.triggerStat or "hp"
	local threshold = slot.triggerPercent or 0
	if stat == "always" then
		-- Legacy potion Always ≈ not full HP.
		if slot.kind == "potion" then
			return hpPercent <= 99
		end
		return true
	elseif stat == "mana" then
		return manaPercent <= threshold
	end
	return hpPercent <= threshold
end

local function isPartyHealSlot(slot)
	if not slot or slot.kind ~= "spell" then
		return false
	end
	local area = CombatAutomationConfig.SpellAreaById and CombatAutomationConfig.SpellAreaById[slot.spellId]
	if area and area.kind == "friend" then
		return true
	end
	local words = tostring(slot.words or ""):lower()
	return words == "exura sio" or words == "exura gran sio" or words == "exura tio sio"
end

--- Mass heals (self-centered AoE) - Mass Healing / Mass Spirit Mend today.
local function isAreaHealSlot(slot)
	if not slot or slot.kind ~= "spell" then
		return false
	end
	local group = CombatAutomationConfig.SpellGroupById and CombatAutomationConfig.SpellGroupById[slot.spellId]
	if group ~= "healing" then
		return false
	end
	local area = CombatAutomationConfig.SpellAreaById and CombatAutomationConfig.SpellAreaById[slot.spellId]
	if not area or area.kind ~= "self" then
		return false
	end
	if type(area.tiles) == "table" and #area.tiles > 1 then
		return true
	end
	if type(area.wodTiles) == "table" and #area.wodTiles > 1 then
		return true
	end
	local radius = math.max(0, tonumber(area.radius) or 0)
	local wodRadius = math.max(0, tonumber(area.wodRadius) or 0)
	return (radius > 0 or wodRadius > 0) and (area.shape == "circle" or area.shape == "square")
end

local function iterPartyPlayers(player)
	local out = {}
	if not player then
		return out
	end
	local party = player:getParty()
	if not party then
		return out
	end
	local seen = {}
	local function push(member)
		if not member or not member:isPlayer() then
			return
		end
		local mid = member:getId()
		if not mid or seen[mid] then
			return
		end
		seen[mid] = true
		out[#out + 1] = member
	end
	for _, member in ipairs(party:getMembers() or {}) do
		push(member)
	end
	push(party:getLeader())
	return out
end

--- Player who owns this creature for combat alliance (self, or summon master).
function CombatAutomation.controllingPlayer(creature)
	if not creature then
		return nil
	end
	if creature.isPlayer and creature:isPlayer() then
		return creature
	end
	local master = creature.getMaster and creature:getMaster() or nil
	if master and master.isPlayer and master:isPlayer() then
		return master
	end
	return nil
end

local function partyProtectionEnabled()
	if isRetroPVP() then
		return configManager.getBoolean(configKeys.ADVANCED_PARTY_PROTECTION)
	end
	return true
end

local function sameParty(a, b)
	if not a or not b or not partyProtectionEnabled() then
		return false
	end
	local pa = a.getParty and a:getParty() or nil
	local pb = b.getParty and b:getParty() or nil
	return pa ~= nil and pa == pb
end

local function sameExpedition(a, b)
	if not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return false
	end
	local sa = ExpeditionManager.getSessionByPlayer(a)
	local sb = ExpeditionManager.getSessionByPlayer(b)
	if not sa or not sb or sa ~= sb then
		return false
	end
	-- World-boss band fights are open PvP: sharing a session must not ally rivals.
	if sa.kind == "worldboss" then
		return false
	end
	return true
end

--- Rival players in the same world-boss band (manual target / sticky AUTO).
local function isWorldBossRival(player, creature)
	if not player or not creature or not creature.isPlayer or not creature:isPlayer() then
		return false
	end
	if creature:getId() == player:getId() then
		return false
	end
	if player.isOpenPvp and creature.isOpenPvp and player:isOpenPvp() and creature:isOpenPvp() then
		return true
	end
	if not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return false
	end
	local sa = ExpeditionManager.getSessionByPlayer(player)
	local sb = ExpeditionManager.getSessionByPlayer(creature)
	if not sa or not sb or sa.kind ~= "worldboss" or sb.kind ~= "worldboss" then
		return false
	end
	return sa.bandId ~= nil and sa.bandId == sb.bandId
end

local function sameTeamDeployment(a, b)
	if not TeamManager then
		return false
	end
	local aid, bid = a:getId(), b:getId()
	if TeamManager.getDeployment then
		local da = TeamManager.getDeployment(a)
		if da then
			for _, id in ipairs(da.companionIds or {}) do
				if id == bid then
					return true
				end
			end
		end
		local db = TeamManager.getDeployment(b)
		if db then
			for _, id in ipairs(db.companionIds or {}) do
				if id == aid then
					return true
				end
			end
		end
	end
	if not TeamConfig or not a.getStorageValue then
		return false
	end
	local key = TeamConfig.STORAGE_COMPANION_CONTROLLER
	local ga = a:getStorageValue(key)
	local gb = b:getStorageValue(key)
	if ga and ga > 0 and gb and gb > 0 and ga == gb then
		return true
	end
	if ga and ga > 0 and b.getGuid and ga == b:getGuid() then
		return true
	end
	if gb and gb > 0 and a.getGuid and gb == a:getGuid() then
		return true
	end
	return false
end

--- True when two players share a party, expedition, or account-team deployment.
function CombatAutomation.isAlliedPlayer(a, b)
	if not a or not b then
		return false
	end
	if a:getId() == b:getId() then
		return true
	end
	if not a.isPlayer or not a:isPlayer() or not b.isPlayer or not b:isPlayer() then
		return false
	end
	return sameParty(a, b) or sameExpedition(a, b) or sameTeamDeployment(a, b)
end

--- Lowest-HP party member (not self) at/under the slot HP threshold, same floor.
--- Returns the Player userdata or nil.
local function pickPartyHealTarget(player, slot)
	if not player or not slot then
		return nil
	end
	local threshold = healHpThreshold(slot)
	local casterId = player:getId()
	local origin = player:getPosition()
	local best, bestPct
	for _, member in ipairs(iterPartyPlayers(player)) do
		if member:getId() ~= casterId and member:getHealth() > 0 then
			local pos = member:getPosition()
			if pos and origin and pos.z == origin.z then
				local pct = percentOf(member:getHealth(), member:getMaxHealth())
				if pct <= threshold and (not bestPct or pct < bestPct) then
					best, bestPct = member, pct
				end
			end
		end
	end
	return best
end

--- Charge NPC buy price from inventory gold, then bank (same economics as NPC buy).
--- Uses Player:removeMoney (useBank=true) so Canary syncs resource-balance packets to the client.
--- Config price 0 = free (still succeeds). Missing price = refuse.
local function chargeNpcBuyPrice(player, typeId)
	local price = CombatAutomationConfig.NpcBuyPriceByTypeId and CombatAutomationConfig.NpcBuyPriceByTypeId[typeId]
	-- Prefer live NPC shop registry when available (clientId == typeId for these supplies),
	-- unless config explicitly marks the supply free (price 0).
	if price ~= 0 and NpcPriceChecker and NpcPriceChecker[typeId] and NpcPriceChecker[typeId].buy then
		price = NpcPriceChecker[typeId].buy
	end
	if price == nil then
		return false
	end
	price = math.floor(tonumber(price) or 0)
	if price <= 0 then
		return true
	end
	local inventoryMoney = player:getMoney() or 0
	local bankBalance = player:getBankBalance() or 0
	if price > (inventoryMoney + bankBalance) then
		return false
	end
	return player:removeMoney(price)
end

local function expeditionSession(player)
	if not player or not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return nil
	end
	return ExpeditionManager.getSessionByPlayer(player)
end

--- Prefer consuming an inventory stack; otherwise charge NPC buy price from this character.
local function consumeSupply(player, typeId)
	local item = player:getItemById(typeId, true)
	if item then
		-- OTC supply analyser is driven by 0xCE; notify before remove.
		player:updateSupplyTracker(item)
		if not item:remove(1) then
			return false
		end
		return true
	end
	if not chargeNpcBuyPrice(player, typeId) then
		local recovered = ExpeditionSafety
			and ExpeditionSafety.handleShortage
			and ExpeditionSafety.handleShortage(
				player,
				"gold",
				function()
					if not chargeNpcBuyPrice(player, typeId) then
						return false
					end
					local tmp = Game.createItem(typeId, 1)
					if tmp then
						player:updateSupplyTracker(tmp)
					end
					return true
				end,
				string.format("%s ran out of gold for supplies. Expedition stopped.", player:getName())
			)
		return recovered == true
	end
	local tmp = Game.createItem(typeId, 1)
	if tmp then
		player:updateSupplyTracker(tmp)
	end
	return true
end

local function getEquippedQuiver(player)
	local right = player:getSlotItem(CONST_SLOT_RIGHT)
	if not right then
		return nil
	end
	local it = ItemType(right:getId())
	if it and it.isQuiver and it:isQuiver() then
		return right
	end
	return nil
end

--- True when configured ammo is already usable by getQuiverAmmoOfType (ammo slot or quiver).
local function ammoIsReady(player, typeId)
	local slotAmmo = player:getSlotItem(CONST_SLOT_AMMO)
	if slotAmmo and slotAmmo:getId() == typeId and (slotAmmo:getCount() or 0) > 0 then
		return true
	end
	local quiver = getEquippedQuiver(player)
	if quiver and quiver.getItemCountById and (quiver:getItemCountById(typeId) or 0) > 0 then
		return true
	end
	return false
end

local function clearAmmoSlotIfWrong(player, typeId)
	local current = player:getSlotItem(CONST_SLOT_AMMO)
	if not current or current:getId() == typeId then
		return true
	end
	local bp = player:getSlotItem(CONST_SLOT_BACKPACK)
	if bp and current.moveTo then
		return current:moveTo(bp) == true
	end
	return false
end

local function addItemReturnOk(ret)
	return ret == RETURNVALUE_NOERROR or ret == 0
end

local function canCarryAmmo(player, typeId, count)
	if not player or not player.getFreeCapacity then
		return true
	end
	local it = ItemType(typeId)
	local weight = 0
	if it and it.getWeight then
		weight = tonumber(it:getWeight(count)) or 0
	end
	return weight <= (player:getFreeCapacity() or 0)
end

--- Spawn ammo into quiver/backpack. When ignoreCap, use FLAG_NOLIMIT (gold-gated restock).
--- Direct player-slot adds do not honor FLAG_NOLIMIT for cap, so park via a container first.
local function spawnAmmo(player, typeId, count, ignoreCap)
	local item = Game.createItem(typeId, count)
	if not item then
		return false
	end
	local flags = ignoreCap and FLAG_NOLIMIT or 0

	local quiver = getEquippedQuiver(player)
	if quiver and quiver.addItemEx and addItemReturnOk(quiver:addItemEx(item, -1, flags)) then
		return true
	end

	-- Classic ammo slot: FLAG_NOLIMIT only skips cap on container→player (FLAG_CHILDISOWNER).
	local bp = player:getSlotItem(CONST_SLOT_BACKPACK)
	if bp and bp.addItemEx and addItemReturnOk(bp:addItemEx(item, -1, flags)) then
		if clearAmmoSlotIfWrong(player, typeId) and item.moveToSlot and item:moveToSlot(player, CONST_SLOT_AMMO) then
			return true
		end
		-- Left in backpack; next tick can move it into the ammo slot.
		return player:getItemById(typeId, true) ~= nil
	end

	return false
end

--- Move existing configured ammo into quiver (preferred) or classic ammo slot.
--- When createMissing, spawn `count` units (caller already charged gold if needed).
local function placeConfiguredAmmo(player, typeId, createMissing, count, ignoreCap)
	count = math.max(1, math.floor(tonumber(count) or 1))
	if ammoIsReady(player, typeId) then
		return true
	end

	local quiver = getEquippedQuiver(player)
	local fromInv = player:getItemById(typeId, true)
	if fromInv then
		if quiver and fromInv.moveTo and fromInv:moveTo(quiver) then
			return ammoIsReady(player, typeId)
		end
		if clearAmmoSlotIfWrong(player, typeId) and fromInv.moveToSlot and fromInv:moveToSlot(player, CONST_SLOT_AMMO) then
			return ammoIsReady(player, typeId)
		end
	end

	if not createMissing then
		return false
	end

	if ignoreCap == false and not canCarryAmmo(player, typeId, count) then
		return false
	end
	return spawnAmmo(player, typeId, count, ignoreCap ~= false)
end

--- Configured ammo typeId from automation slots / legacy field.
local function preferredAmmoTypeId(config)
	if type(config) ~= "table" then
		return 0
	end
	for _, slot in ipairs(config.slots or {}) do
		if slot.kind == "ammo" and slot.enabled ~= false then
			local id = math.floor(tonumber(slot.ammoTypeId) or 0)
			if id > 0 then
				return id
			end
		end
	end
	return math.floor(tonumber(config.ammoTypeId) or 0)
end

--- Keep configured ammo ready for distance attacks.
--- Inventory first for that typeId only; if missing, charge NPC buy price then spawn one.
local function ensureAmmo(player, config)
	if not player or not CombatAutomationCatalog or not CombatAutomationCatalog.isPaladin(player) then
		return
	end
	local configured = preferredAmmoTypeId(config)
	local typeId = select(1, CombatAutomationCatalog.resolveAmmoTypeId(player, configured))
	typeId = math.floor(tonumber(typeId) or 0)
	if typeId <= 0 then
		return
	end

	if ammoIsReady(player, typeId) then
		return
	end

	local session = expeditionSession(player)
	local respectCap = session and session.stopOnInsufficientCap == true

	-- Only the configured type counts as "have ammo"; never substitute another arrow/bolt.
	if player:getItemById(typeId, true) then
		if placeConfiguredAmmo(player, typeId, false) then
			return
		end
	end

	-- No physical ammo of this type: charge this character's gold, then equip one.
	-- Do not use consumeSupply - that would double-count supply tracker when the weapon consumes it.
	if respectCap and not canCarryAmmo(player, typeId, 1) then
		if ExpeditionSafety and ExpeditionSafety.handleShortage then
			ExpeditionSafety.handleShortage(
				player,
				"cap",
				function()
					return canCarryAmmo(player, typeId, 1)
				end,
				string.format("%s has insufficient capacity for ammo. Expedition stopped.", player:getName())
			)
		end
		if not canCarryAmmo(player, typeId, 1) then
			return
		end
	end
	if not chargeNpcBuyPrice(player, typeId) then
		local charged = ExpeditionSafety
			and ExpeditionSafety.handleShortage
			and ExpeditionSafety.handleShortage(
				player,
				"gold",
				function()
					return chargeNpcBuyPrice(player, typeId)
				end,
				string.format("%s ran out of gold for ammo. Expedition stopped.", player:getName())
			)
		if charged ~= true then
			return
		end
	end
	-- Default: ignore cap (gold-gated). stopOnInsufficientCap → already verified weight above.
	if not placeConfiguredAmmo(player, typeId, true, 1, not respectCap) then
		if respectCap and ExpeditionSafety and ExpeditionSafety.handleShortage then
			ExpeditionSafety.handleShortage(
				player,
				"cap",
				function()
					return placeConfiguredAmmo(player, typeId, true, 1, false)
				end,
				string.format("%s has insufficient capacity for ammo. Expedition stopped.", player:getName())
			)
		end
	end
end

local function usePotion(player, typeId)
	local effect = CombatAutomationConfig.PotionEffects and CombatAutomationConfig.PotionEffects[typeId]
	if not effect then
		return false
	end
	if not consumeSupply(player, typeId) then
		return false
	end
	if effect.health then
		doTargetCombatHealth(player, player, COMBAT_HEALING, effect.health[1], effect.health[2], CONST_ME_MAGIC_BLUE)
	end
	if effect.mana then
		doTargetCombatMana(0, player, effect.mana[1], effect.mana[2], CONST_ME_MAGIC_BLUE)
	end
	local pos = player:getPosition()
	local instanceId = player.getInstanceId and player:getInstanceId() or nil
	if instanceId ~= nil and Game.getSpectators then
		local specs = Game.getSpectators(pos, true, true, 0, 0, 0, 0, instanceId)
		if type(specs) == "table" then
			for _, spec in ipairs(specs) do
				if spec then
					pos:sendMagicEffect(CONST_ME_MAGIC_BLUE, spec)
				end
			end
		end
	else
		pos:sendMagicEffect(CONST_ME_MAGIC_BLUE)
	end
	return true
end

-- Approximate AoE radius for monsterCount gating only.
-- Real damage/area/FX come from apps/crystalserver/data/scripts/runes/*.lua via player:castRune.
local RuneAreaRangeByTypeId = {
	[21351] = 1, -- light stone shower (CIRCLE1X1)
	[3161] = 3, -- avalanche (CIRCLE3X3)
	[3175] = 3, -- stone shower
	[3191] = 3, -- great fireball
	[3200] = 1, -- explosion (SQUARE1X1)
	[3202] = 3, -- thunderstorm
}

local function runeWords(typeId)
	local map = CombatAutomationConfig.RuneWordsByTypeId
	if map and map[typeId] then
		return map[typeId]
	end
	return ""
end

-- Soft backoff after a cast that still failed (mana/weapon/range/etc.) so we do not
-- spam CONST_ME_POFF every TICK_MS. Spell/group CDs are checked before cast instead.
-- Keep this short (one tick) so transient range/LOS misses recover quickly.
local CAST_FAIL_BACKOFF_MS = CombatAutomationConfig.TICK_MS or 250

local function getInstantSpell(words)
	if type(words) ~= "string" or words == "" then
		return nil
	end
	local ok, spell = pcall(Spell, words)
	if ok and spell then
		return spell
	end
	return nil
end

local function spellExhaustMs(words)
	local spell = getInstantSpell(words)
	if spell then
		local cd = spell:cooldown()
		if type(cd) == "number" and cd > 0 then
			return cd
		end
	end
	local mapped = CombatAutomationConfig.SpellCooldownMsByWords and CombatAutomationConfig.SpellCooldownMsByWords[words]
	if type(mapped) == "number" and mapped > 0 then
		return mapped
	end
	return CombatAutomationConfig.SPELL_EXHAUST_MS or 2000
end

local function getRuneSpell(typeId)
	local ok, spell = pcall(Spell, typeId)
	if ok and spell then
		return spell
	end
	return nil
end

local function runeExhaustMs(typeId)
	local spell = getRuneSpell(typeId)
	if spell then
		local cd = spell:cooldown()
		if type(cd) == "number" and cd > 0 then
			return cd
		end
	end
	return CombatAutomationConfig.RUNE_EXHAUST_MS or 2000
end

--- Returns: "cast" | "skip" | "fail"
--- skip = not ready / gated (no attempt). fail = engine/script rejected (silent).
--- param: optional player-name for friend/party heals (exura sio).
local function tryCastSpellWords(player, words, param)
	if type(words) ~= "string" or words == "" then
		return "skip"
	end
	if not CombatAutomationConfig.AllowedSpellWords[words] then
		return "skip"
	end
	-- Fail closed on vocation/level even if a stale slot slipped into KV.
	local catalogId = nil
	for id, mapped in pairs(CombatAutomationConfig.SpellWordsById or {}) do
		if mapped == words then
			catalogId = id
			break
		end
	end
	if catalogId and CombatAutomationCatalog and CombatAutomationCatalog.spellAllowedForPlayer then
		if not CombatAutomationCatalog.spellAllowedForPlayer(catalogId, player) then
			return "skip"
		end
	end

	if SampleSpells and SampleSpells.ensureWords then
		SampleSpells.ensureWords(player, words)
	end

	local castParam = (type(param) == "string" and param ~= "") and param or nil
	if player.canCastSpell then
		local ready
		if castParam then
			ready = player:canCastSpell(words, castParam)
		else
			ready = player:canCastSpell(words)
		end
		if not ready then
			return "skip"
		end
	end

	local result
	if castParam then
		result = player:castSpell(words, castParam, true)
	else
		result = player:castSpell(words, true)
	end
	if result == true then
		return "cast"
	end
	return "fail"
end

-- Canary `lua_enums.cpp` does not register TALKTYPE_SPELL_USE, so the global is nil and
-- `creature:say` falls back to TALKTYPE_MONSTER_SAY (looks like a regular/monster line).
-- Wire value matches SpeakClasses::TALKTYPE_SPELL_USE / OTC MessageSpell = 9.
local TALKTYPE_SPELL_USE_WIRE = 9

local function notifyAutomationCast(player, slot, words, label, exhaustMs)
	if words and words ~= "" then
		pcall(function()
			player:say(words, TALKTYPE_SPELL_USE_WIRE)
		end)
	end
	local payload = {
		slotId = slot and slot.id or "",
		kind = slot and slot.kind or "",
		words = words or "",
		label = label or words or "",
		exhaustMs = exhaustMs or 0,
		caster = player and player:getName() or "",
	}
	local function sendCast(target)
		if not target then
			return
		end
		if CombatAutomationProtocol and CombatAutomationProtocol.sendCast then
			CombatAutomationProtocol.sendCast(target, payload)
		elseif ExpeditionProtocol and ExpeditionProtocol.sendAutomationCast then
			ExpeditionProtocol.sendAutomationCast(target, payload)
		end
	end
	sendCast(player)
	-- Headless companions have no client; relay to expedition host so the cast flash is visible.
	if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player) then
		local session = ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
		if session and session.playerId and session.playerId ~= player:getId() then
			sendCast(Player(session.playerId))
		end
	end
end

local function useRune(player, typeId)
	if not CombatAutomationConfig.AllowedRunes or not CombatAutomationConfig.AllowedRunes[typeId] then
		return false
	end
	if CombatAutomationCatalog and CombatAutomationCatalog.runeAllowedForPlayer then
		if not CombatAutomationCatalog.runeAllowedForPlayer(typeId, player) then
			return false
		end
	end
	local target = player:getTarget()
	if not target then
		return false
	end
	if not player.castRune then
		return false
	end
	if not consumeSupply(player, typeId) then
		return false
	end
	-- Real rune script on the current target (correct area / distance / impact FX).
	local ok, result = pcall(function()
		return player:castRune(typeId, target)
	end)
	return ok and result == true
end

--- Returns: "cast" | "skip" | "fail"
--- skip = not ready / gated (no attempt). fail = engine/script rejected (silent).
local function tryUseRune(player, typeId)
	if not CombatAutomationConfig.AllowedRunes or not CombatAutomationConfig.AllowedRunes[typeId] then
		return "skip"
	end
	if CombatAutomationCatalog and CombatAutomationCatalog.runeAllowedForPlayer then
		if not CombatAutomationCatalog.runeAllowedForPlayer(typeId, player) then
			return "skip"
		end
	end
	if not player:getTarget() then
		return "skip"
	end
	if not player.castRune then
		return "skip"
	end
	if useRune(player, typeId) then
		return "cast"
	end
	return "fail"
end

local function spellRank(slot)
	local group = CombatAutomationConfig.SpellGroupById and CombatAutomationConfig.SpellGroupById[slot.spellId]
	if group == "healing" then
		return 0
	end
	if group == "support" or group == "shield" or group == "stance" then
		return 1
	end
	if group == "attack" then
		return 2
	end
	-- Legacy fallback for configs generated before SpellGroupById.
	local words = slot.words or ""
	if words:find("exura", 1, true) then
		return 0
	end
	if words == "utamo vita" then
		return 1
	end
	if words:find("utani", 1, true) then
		return 1
	end
	return 2
end

-- Crystal stance spells toggle off when re-cast. Map words → channel + Stance_t value
-- (see creatures_definitions.hpp Stance_t). Primary: getStance(); elemental: getElementalStance().
-- Monk virtues use VirtueMonk_t via getVirtue() (not Stance_t); they do not toggle off on re-cast.
local STANCE_BY_WORDS = {
	["utamo tempo"] = { id = 1, elemental = false }, -- STANCE_PROTECTOR
	["utito tempo"] = { id = 2, elemental = false }, -- STANCE_BLOOD_RAGE
	["utori hur"] = { id = 3, elemental = false }, -- STANCE_DIVINE_DEFIANCE
	["utori con"] = { id = 4, elemental = false }, -- STANCE_SHARPSHOOTER
	["exori kor tempo"] = { id = 5, elemental = false }, -- STANCE_EXPOSE_WEAKNESS
	["exori moe tempo"] = { id = 6, elemental = false }, -- STANCE_SAP_STRENGTH
	["uteta flam"] = { id = 7, elemental = true }, -- STANCE_MASTER_OF_FLAMES
	["uteta vis"] = { id = 8, elemental = true }, -- STANCE_MASTER_OF_THUNDER
	["uteta mort"] = { id = 9, elemental = true }, -- STANCE_MASTER_OF_DECAY
	["utura sio"] = { id = 10, elemental = false }, -- STANCE_SHARED_CONSERVATION
	["utito dru"] = { id = 11, elemental = false }, -- STANCE_ELEMENTAL_SYNTHESIS
	["utori virtu"] = { id = 1, elemental = false, virtue = true }, -- VIRTUE_HARMONY
	["utito virtu"] = { id = 2, elemental = false, virtue = true }, -- VIRTUE_JUSTICE
	["utura tio"] = { id = 3, elemental = false, virtue = true }, -- VIRTUE_SUSTAIN
}

local function stanceInfoForWords(words)
	return STANCE_BY_WORDS[tostring(words or ""):lower()]
end

local function currentStanceValue(player, info)
	if not player or not info then
		return nil
	end
	if info.virtue then
		if player.getVirtue then
			return player:getVirtue()
		end
		return nil
	end
	if info.elemental then
		if player.getElementalStance then
			return player:getElementalStance()
		end
		return nil
	end
	if player.getStance then
		return player:getStance()
	end
	return nil
end

--- Skip stance casts that would toggle off or thrash exclusive channels.
--- Only the highest-priority configured stance per channel may cast; once active, leave it.
local function shouldSkipStanceCast(player, words, preferredByChannel)
	local info = stanceInfoForWords(words)
	if not info then
		return false
	end
	local channel = info.elemental and "elemental" or "primary"
	local preferred = preferredByChannel and preferredByChannel[channel]
	if preferred and preferred ~= words then
		return true
	end
	local current = currentStanceValue(player, info)
	if current == nil then
		return false
	end
	local none = 0
	if info.virtue then
		none = (VIRTUE_NONE ~= nil and VIRTUE_NONE) or 0
	else
		none = (STANCE_NONE ~= nil and STANCE_NONE) or 0
	end
	if current == none then
		return false
	end
	-- Already this stance/virtue - do not re-cast (stances toggle off; virtues waste mana).
	return current == info.id
end

local function preferredStanceWordsByChannel(slots)
	local preferred = {}
	for _, slot in ipairs(slots) do
		if slot and slot.enabled ~= false and slot.kind == "spell" then
			local words = slot.words or ""
			local info = stanceInfoForWords(words)
			if info then
				local channel = info.elemental and "elemental" or "primary"
				if not preferred[channel] then
					preferred[channel] = words
				end
			end
		end
	end
	return preferred
end

local function tileDistance(a, b)
	if not a or not b or a.z ~= b.z then
		return math.huge
	end
	return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

-- Squared Euclidean tile distance for auto-target sorting.
-- Ordering: 1 orthogonal (1) < 1 diagonal (2) < 2 orthogonal (4).
local function sortDistanceSquared(a, b)
	if not a or not b or a.z ~= b.z then
		return math.huge
	end
	local dx = math.abs(a.x - b.x)
	local dy = math.abs(a.y - b.y)
	return dx * dx + dy * dy
end

--- Open-PvP arenas (world boss): never auto-pick players — sticky manual target only.
--- Skulled rivals are hit by AOE via Creature:onTargetCombat, not by retargeting AUTO.
function CombatAutomation.isValidAttackTarget(player, creature)
	if not player or not creature then
		return false
	end
	if creature:isRemoved() or creature:getHealth() <= 0 then
		return false
	end

	local zoneProtection = ZONE_PROTECTION or 0
	if player:getZoneType() == zoneProtection then
		return false
	end
	if creature:getZoneType() == zoneProtection then
		return false
	end

	if player.getInstanceId and creature.getInstanceId and player:getInstanceId() ~= creature:getInstanceId() then
		return false
	end

	local fromPos = player:getPosition()
	local toPos = creature:getPosition()
	if not fromPos or not toPos or fromPos.z ~= toPos.z then
		return false
	end
	local instanceId = player.getInstanceId and player:getInstanceId() or 0
	if fromPos.isSightClear and not fromPos:isSightClear(toPos, true, instanceId) then
		return false
	end

	local tile = creature:getTile()
	if tile and tile.hasProperty and CONST_PROP_BLOCKPROJECTILE and tile:hasProperty(CONST_PROP_BLOCKPROJECTILE, instanceId) then
		return false
	end

	if creature:isPlayer() then
		if creature:getId() == player:getId() then
			return false
		end
		if SoftDeath and SoftDeath.isDowned and SoftDeath.isDowned(creature) then
			return false
		end
		if not isWorldBossRival(player, creature) then
			return false
		end
		-- Party / account-team allies stay protected even in open-PvP arenas.
		if sameParty(player, creature) or sameTeamDeployment(player, creature) then
			return false
		end
		-- Sticky manual target only — AOE splash on skulls is handled in onTargetCombat.
		local current = player:getTarget()
		if current and current:getId() == creature:getId() then
			return true
		end
		return false
	end

	if not creature:isMonster() then
		return false
	end

	local master = creature.getMaster and creature:getMaster() or nil
	if master and master.isPlayer and master:isPlayer() then
		return false
	end

	local mType = creature.getType and creature:getType()
	if mType and mType.isAttackable and not mType:isAttackable() then
		return false
	end

	return true
end

-- Per-tick cache: monster-count + challenge checks used to rescan spectators per slot.
local tickVisibleMonsters = nil

local function computeVisibleMonsters(player)
	local result = {}
	local playerPos = player:getPosition()
	local spectators = Game.getSpectators(playerPos, false, false, 8, 8, 6, 6, player.getInstanceId and player:getInstanceId() or nil)
	for _, creature in ipairs(spectators) do
		-- Pick pool is monsters only; rival players are sticky via getTarget(), never auto-picked.
		if creature and creature:isMonster() and CombatAutomation.isValidAttackTarget(player, creature) then
			result[#result + 1] = creature
		end
	end
	return result
end

local function visibleMonsters(player)
	if tickVisibleMonsters ~= nil then
		return tickVisibleMonsters
	end
	return computeVisibleMonsters(player)
end

local function partyBuffConditionType(kind)
	if kind == "attributes" and type(CONDITION_ATTRIBUTES) == "number" then
		return CONDITION_ATTRIBUTES
	end
	if kind == "regeneration" and type(CONDITION_REGENERATION) == "number" then
		return CONDITION_REGENERATION
	end
	return nil
end

local function playerHasPartyBuff(player, words)
	local info = PARTY_BUFF_BY_WORDS[words]
	if not info or not player then
		return false
	end
	local conditionType = partyBuffConditionType(info.condition)
	if not conditionType then
		return false
	end
	return player:hasCondition(conditionType, info.subId)
end

local function partyMembersInRange(player, maxDistance)
	local out = {}
	local origin = player and player:getPosition()
	if not origin then
		return out
	end
	maxDistance = math.max(1, math.floor(tonumber(maxDistance) or 36))
	for _, member in ipairs(iterPartyPlayers(player)) do
		local pos = member:getPosition()
		if pos and pos:getDistance(origin) <= maxDistance then
			out[#out + 1] = member
		end
	end
	return out
end

local function playerHasFamiliarSummon(player)
	if not player or not player.getSummons then
		return false
	end
	local summons = player:getSummons()
	if type(summons) ~= "table" then
		return false
	end
	for i = 1, #summons do
		local summon = summons[i]
		local summonType = summon and summon.getType and summon:getType() or nil
		if summonType and summonType.familiar and summonType:familiar() then
			return true
		end
		-- Fallback: any summon blocks CreateFamiliarSpell.
		if summon then
			return true
		end
	end
	return false
end

local function monsterIsRanged(monster)
	local mType = monster and monster.getType and monster:getType() or nil
	if not mType or not mType.getTargetDistance then
		return false
	end
	return (mType:getTargetDistance() or 1) > 1
end

local function monsterHasMaster(monster)
	if not monster or not monster.getMaster then
		return false
	end
	return monster:getMaster() ~= nil
end

local function monsterIsRewardBoss(monster)
	local mType = monster and monster.getType and monster:getType() or nil
	return mType and mType.isRewardBoss and mType:isRewardBoss()
end

--- Prefer reward bosses and the active expedition/world-boss target over trash.
local function monsterIsFocusBoss(player, monster)
	if not monster then
		return false
	end
	if monsterIsRewardBoss(monster) then
		return true
	end
	if not player or not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		return false
	end
	if session.bossCreatureId and monster:getId() == session.bossCreatureId then
		return true
	end
	if session.kind == "worldboss" then
		local wb = ActivityBoostWorldBoss and ActivityBoostWorldBoss.active and ActivityBoostWorldBoss.active[session.bandId]
		if wb and wb.bossCreatureId and monster:getId() == wb.bossCreatureId then
			return true
		end
		local bossName = (wb and wb.bossName) or (session.catalog and session.catalog.name)
		if bossName and monster:getName() == bossName then
			return true
		end
	elseif session.role == "boss" then
		local bossName = session.catalog and session.catalog.name
		if bossName and monster:getName() == bossName then
			return true
		end
	end
	return false
end

local function hasRewardBossNearby(player)
	if not player then
		return false
	end
	local playerPos = player:getPosition()
	local spectators = Game.getSpectators(playerPos, false, false, 8, 8, 6, 6, player.getInstanceId and player:getInstanceId() or nil)
	for _, creature in ipairs(spectators) do
		if creature and creature:isMonster() and monsterIsRewardBoss(creature) then
			return true
		end
	end
	return false
end

--- Soft-despawned (knocked out): pause AUTO until softSpawn.
local function isSoftDespawnedPlayer(player)
	return SoftDeath and SoftDeath.isDowned and SoftDeath.isDowned(player)
end

--- Balanced Brawl directional footprint (matches support/balanced_brawl.lua matrix).
local function isInBalancedBrawlArea(player, monster)
	local origin = player:getPosition()
	local monsterPos = monster:getPosition()
	if not origin or not monsterPos or origin.z ~= monsterPos.z then
		return false
	end
	local dx = monsterPos.x - origin.x
	local dy = monsterPos.y - origin.y
	local forward, lateral
	local direction = player:getDirection()
	if direction == DIRECTION_NORTH then
		forward, lateral = -dy, math.abs(dx)
	elseif direction == DIRECTION_EAST then
		forward, lateral = dx, math.abs(dy)
	elseif direction == DIRECTION_SOUTH then
		forward, lateral = dy, math.abs(dx)
	elseif direction == DIRECTION_WEST then
		forward, lateral = -dx, math.abs(dy)
	else
		return false
	end
	local maxLateralByForward = {
		[0] = 6,
		[1] = 5,
		[2] = 5,
		[3] = 4,
		[4] = 3,
		[5] = 2,
		[6] = 0,
	}
	local maxLat = maxLateralByForward[forward]
	if maxLat == nil then
		return false
	end
	if forward == 0 and lateral == 0 then
		return false
	end
	if forward == 1 and lateral == 0 then
		return false
	end
	return lateral <= maxLat
end

local function challengeCanAffectCreature(player, words)
	local mode = CHALLENGE_WORDS[words]
	if not mode or not player then
		return false
	end
	if mode ~= "challenge" and hasRewardBossNearby(player) then
		return false
	end
	local origin = player:getPosition()
	if not origin then
		return false
	end
	for _, monster in ipairs(visibleMonsters(player)) do
		if mode == "challenge" then
			local mp = monster:getPosition()
			if mp and mp.z == origin.z and math.max(math.abs(mp.x - origin.x), math.abs(mp.y - origin.y)) <= 1 then
				return true
			end
		elseif mode == "amp_challenge" then
			-- Mirrors product chivalrous_challenge.lua: ranged types or not adjacent.
			if not monsterHasMaster(monster) then
				local mp = monster:getPosition()
				if mp and mp.z == origin.z then
					local cheb = tileDistance(origin, mp)
					if cheb <= 7 and (monsterIsRanged(monster) or cheb > 1) then
						return true
					end
				end
			end
		elseif mode == "ranged_chain" then
			if monsterIsRanged(monster) and not monsterHasMaster(monster) then
				local mp = monster:getPosition()
				if mp and tileDistance(origin, mp) <= 7 then
					return true
				end
			end
		elseif mode == "brawl" then
			if monsterIsRanged(monster) and isInBalancedBrawlArea(player, monster) then
				return true
			end
		end
	end
	return false
end

--- Support spells ignore HP/mana "when" and use spell-specific keep-up rules.
supportSlotShouldFire = function(player, slot)
	if not slot or slot.enabled == false then
		return false
	end
	local words = tostring(slot.words or ""):lower()
	if isHasteSpell(slot) then
		if slot.pzCast ~= true and playerInProtectionZone(player) then
			return false
		end
		return not playerIsHasted(player)
	end
	if CHALLENGE_WORDS[words] then
		return challengeCanAffectCreature(player, words)
	end
	if PARTY_BUFF_BY_WORDS[words] then
		if playerHasPartyBuff(player, words) then
			return false
		end
		-- Party spells require at least one other member in range.
		return #partyMembersInRange(player, 36) > 1
	end
	if FAMILIAR_WORDS[words] then
		-- Engine spell:cooldown is 0; CreateFamiliarSpell owns CONDITION_SPELLCOOLDOWN.
		if playerHasFamiliarSummon(player) then
			return false
		end
		if player.canCastSpell and not player:canCastSpell(words) then
			return false
		end
		return true
	end
	return true
end

--- Equipped weapon shootRange (Monster::canUseAttack analog for players). Fist / none → 1.
function CombatAutomation.weaponShootRange(player)
	if not player then
		return 1
	end
	local weapon = nil
	if player.getSlotItem and CONST_SLOT_LEFT then
		weapon = player:getSlotItem(CONST_SLOT_LEFT)
		if not weapon and CONST_SLOT_RIGHT then
			weapon = player:getSlotItem(CONST_SLOT_RIGHT)
		end
	end
	if not weapon then
		return 1
	end
	local it = ItemType(weapon:getId())
	if not it then
		return 1
	end
	local weaponType = it.getWeaponType and it:getWeaponType() or nil
	if weaponType == WEAPON_NONE or weaponType == WEAPON_SHIELD or weaponType == WEAPON_AMMO then
		return 1
	end
	local range = it.getShootRange and it:getShootRange() or nil
	if type(range) == "number" and range > 0 then
		return math.floor(range)
	end
	return 1
end

--- True when creature is within Chebyshev weapon range (and existing LOS/validity).
function CombatAutomation.isInWeaponRange(player, creature)
	if not player or not creature then
		return false
	end
	if CombatAutomation.isValidAttackTarget and not CombatAutomation.isValidAttackTarget(player, creature) then
		return false
	end
	local fromPos = player:getPosition()
	local toPos = creature:getPosition()
	if not fromPos or not toPos or fromPos.z ~= toPos.z then
		return false
	end
	local dist = math.max(math.abs(fromPos.x - toPos.x), math.abs(fromPos.y - toPos.y))
	return dist <= CombatAutomation.weaponShootRange(player)
end

--- Count living monsters within Chebyshev radius of `center` (Mode E scoring).
local function countMonstersNear(monsters, center, radius)
	if not center then
		return 0
	end
	radius = math.max(0, math.floor(tonumber(radius) or 1))
	local n = 0
	for i = 1, #monsters do
		local m = monsters[i]
		local mp = m and m.getPosition and m:getPosition()
		if mp and mp.z == center.z and tileDistance(center, mp) <= radius then
			n = n + 1
		end
	end
	return n
end

local function monsterHpPercent(monster)
	if not monster then
		return 100
	end
	local hp = monster.getHealth and monster:getHealth() or 0
	local maxHp = monster.getMaxHealth and monster:getMaxHealth() or 1
	if maxHp <= 0 then
		return 100
	end
	return (hp / maxHp) * 100
end

--- Pick monster by auto-target mode A–I.
function CombatAutomation.pickMonsterBySort(player, monsters, sortMode)
	if type(monsters) ~= "table" or #monsters == 0 then
		return nil
	end
	local mode = CombatAutomationConfig.normalizeAutoTargetMode(sortMode)
	local playerPos = player and player:getPosition() or nil
	local pool = {}
	for i = 1, #monsters do
		local monster = monsters[i]
		if CombatAutomation.isValidAttackTarget(player, monster) then
			pool[#pool + 1] = monster
		end
	end
	if #pool == 0 then
		return nil
	end

	local aoeRadius = CombatAutomationConfig.AOE_BEST_RADIUS or 1
	local function distSq(m)
		if not playerPos then
			return 0
		end
		return sortDistanceSquared(playerPos, m:getPosition())
	end

	table.sort(pool, function(a, b)
		-- Always prefer bosses over trash, regardless of auto-target mode.
		local ba, bb = monsterIsFocusBoss(player, a), monsterIsFocusBoss(player, b)
		if ba ~= bb then
			return ba
		end

		local da, db = distSq(a), distSq(b)
		local ha, hb = monsterHpPercent(a), monsterHpPercent(b)
		local ida, idb = a:getId(), b:getId()

		if mode == "B" then
			if da ~= db then
				return da > db
			end
		elseif mode == "C" then
			if ha ~= hb then
				return ha < hb
			end
			if da ~= db then
				return da < db
			end
		elseif mode == "D" then
			if ha ~= hb then
				return ha > hb
			end
			if da ~= db then
				return da < db
			end
		elseif mode == "E" then
			local ca = countMonstersNear(pool, a:getPosition(), aoeRadius)
			local cb = countMonstersNear(pool, b:getPosition(), aoeRadius)
			if ca ~= cb then
				return ca > cb
			end
			if da ~= db then
				return da < db
			end
		elseif mode == "F" then
			if da ~= db then
				return da < db
			end
			if ha ~= hb then
				return ha < hb
			end
		elseif mode == "G" then
			if da ~= db then
				return da < db
			end
			if ha ~= hb then
				return ha > hb
			end
		elseif mode == "H" then
			if da ~= db then
				return da > db
			end
			if ha ~= hb then
				return ha < hb
			end
		elseif mode == "I" then
			if da ~= db then
				return da > db
			end
			if ha ~= hb then
				return ha > hb
			end
		else
			-- A closest (prefer already in weapon range)
			local ara = CombatAutomation.isInWeaponRange(player, a)
			local arb = CombatAutomation.isInWeaponRange(player, b)
			if ara ~= arb then
				return ara
			end
			if da ~= db then
				return da < db
			end
		end
		return ida < idb
	end)
	return pool[1]
end

local function isOnScreen(player, creature)
	if not CombatAutomationMovement or not CombatAutomationMovement.isInViewport then
		local playerPos = player:getPosition()
		local creaturePos = creature:getPosition()
		return playerPos.z == creaturePos.z
			and math.abs(playerPos.x - creaturePos.x) <= 8
			and math.abs(playerPos.y - creaturePos.y) <= 6
	end
	return CombatAutomationMovement.isInViewport(player:getPosition(), creature:getPosition())
end

local function syncAutoAttackTarget(player, state, target, force)
	if not player or not state then
		return
	end
	local creatureId = 0
	if target then
		creatureId = target:getId() or 0
	end
	if not force and state.lastSyncedAttackCreatureId == creatureId then
		return
	end
	state.lastSyncedAttackCreatureId = creatureId
	if CombatAutomationProtocol and CombatAutomationProtocol.sendAttackTarget then
		CombatAutomationProtocol.sendAttackTarget(player, creatureId)
	end
end

--- Re-send the current attack target to the client (login / getAutomation).
function CombatAutomation.resyncAttackTarget(player)
	if not player then
		return
	end
	local state = CombatAutomation.getState(player)
	local target = player:getTarget()
	if target and CombatAutomation.isValidAttackTarget(player, target) and isOnScreen(player, target) then
		syncAutoAttackTarget(player, state, target, true)
		return
	end
	syncAutoAttackTarget(player, state, nil, true)
end

local function autoTarget(player, config, state)
	local options = config and config.autoTarget
	if type(options) ~= "table" or options.enabled ~= true then
		return player:getTarget()
	end
	if isSoftDespawnedPlayer(player) then
		if player:getTarget() then
			player:setTarget(nil)
		end
		syncAutoAttackTarget(player, state, nil)
		return nil
	end
	local mode = CombatAutomationConfig.normalizeAutoTargetMode(options.mode or options.sortMode)
	local aggressive = mode == "E" or mode == "C" or mode == "D"

	local current = player:getTarget()
	if current and CombatAutomation.isValidAttackTarget(player, current) and isOnScreen(player, current) then
		if not aggressive then
			-- Sticky trash yields when a boss is in range — but never steal a live PvP player target.
			if not current:isPlayer() and not monsterIsFocusBoss(player, current) then
				local preferred = CombatAutomation.pickMonsterBySort(player, visibleMonsters(player), mode)
				if preferred and monsterIsFocusBoss(player, preferred) and preferred:getId() ~= current:getId() then
					player:setTarget(preferred)
					syncAutoAttackTarget(player, state, preferred)
					return preferred
				end
			end
			syncAutoAttackTarget(player, state, current)
			return current
		end
		-- Aggressive modes: keep sticky target unless a clearly better pick exists.
		-- Live player targets stay sticky (pickMonsterBySort is monsters-only).
		if current:isPlayer() then
			syncAutoAttackTarget(player, state, current)
			return current
		end
	elseif current then
		player:setTarget(nil)
		current = nil
	end

	local monsters = visibleMonsters(player)
	local target = CombatAutomation.pickMonsterBySort(player, monsters, mode)
	if aggressive and current and target and current:getId() == target:getId() then
		syncAutoAttackTarget(player, state, current)
		return current
	end
	if aggressive and current and target and current:getId() ~= target:getId() then
		-- Mode E/C/D: retarget when a better focus is found.
		player:setTarget(target)
	elseif target and not current then
		player:setTarget(target)
	elseif target and current and not aggressive then
		-- sticky already returned
	elseif target then
		player:setTarget(target)
	end

	local resolved = player:getTarget() or target
	if resolved and CombatAutomation.isValidAttackTarget(player, resolved) and isOnScreen(player, resolved) then
		syncAutoAttackTarget(player, state, resolved)
		return resolved
	end
	if resolved then
		player:setTarget(nil)
	end
	syncAutoAttackTarget(player, state, nil)
	return nil
end

local function tileListContains(tiles, dx, dy)
	if type(tiles) ~= "table" then
		return false
	end
	local set = tiles._set
	if not set then
		set = {}
		for i = 1, #tiles do
			local t = tiles[i]
			if type(t) == "table" then
				set[(t[1] * 131) + t[2]] = true
			end
		end
		tiles._set = set
	end
	return set[(dx * 131) + dy] == true
end

local function playerHasWodArea(player, wod)
	if not player or type(wod) ~= "table" or type(wod.name) ~= "string" then
		return false
	end
	local check = wod.check
	if check == "additionalArea" then
		return player.getWheelSpellAdditionalArea and player:getWheelSpellAdditionalArea(wod.name) == true
	end
	if check == "instantSkill" then
		return player.instantSkillWOD and player:instantSkillWOD(wod.name) == true
	end
	return false
end

local function directionTilesForArea(player, area)
	if type(area) ~= "table" then
		return nil
	end
	local direction = player:getDirection()
	if type(area.gradeByDir) == "table" and type(area.wod) == "table" and area.wod.check == "upgradeGrade" then
		local grade = 0
		if player.upgradeSpellsWOD then
			grade = tonumber(player:upgradeSpellsWOD(area.wod.name)) or 0
		end
		local none = (type(WHEEL_GRADE_NONE) == "number" and WHEEL_GRADE_NONE) or 0
		local index = (grade == none) and 1 or grade
		local byDir = area.gradeByDir[index] or area.gradeByDir[1] or area.byDir
		return byDir and byDir[direction] or nil
	end
	if type(area.wodByDir) == "table" and playerHasWodArea(player, area.wod) then
		return area.wodByDir[direction]
	end
	if type(area.byDir) == "table" then
		return area.byDir[direction]
	end
	return nil
end

local function selfTilesForArea(player, area)
	if type(area) ~= "table" then
		return nil
	end
	if type(area.wodTiles) == "table" and playerHasWodArea(player, area.wod) then
		return area.wodTiles
	end
	return area.tiles
end

local function isInsideSpellArea(player, target, monster, area)
	if type(area) ~= "table" then
		return monster == target
	end
	local origin = player:getPosition()
	local monsterPos = monster:getPosition()
	if origin.z ~= monsterPos.z then
		return false
	end

	-- Directional AREA_* matrices (base / WoD / upgrade-grade variants).
	local dirTiles = directionTilesForArea(player, area)
	if dirTiles ~= nil then
		return tileListContains(dirTiles, monsterPos.x - origin.x, monsterPos.y - origin.y)
	end

	-- Target-centered matrices (runes / target AoE).
	if area.kind == "target" and type(area.tiles) == "table" then
		if not target then
			return false
		end
		local center = target:getPosition()
		if not center or center.z ~= monsterPos.z then
			return false
		end
		return tileListContains(area.tiles, monsterPos.x - center.x, monsterPos.y - center.y)
	end

	-- Self-centered matrices (Mass Healing, Sap Strength, …) with optional WoD size.
	if area.kind == "self" then
		local tiles = selfTilesForArea(player, area)
		if type(tiles) == "table" then
			return tileListContains(tiles, monsterPos.x - origin.x, monsterPos.y - origin.y)
		end
	elseif type(area.tiles) == "table" and not area.byDir then
		return tileListContains(area.tiles, monsterPos.x - origin.x, monsterPos.y - origin.y)
	end

	if area.kind == "target" then
		if not target then
			return false
		end
		local center = target:getPosition()
		local radius = math.max(0, tonumber(area.radius) or 0)
		if area.shape == "circle" then
			local dx = monsterPos.x - center.x
			local dy = monsterPos.y - center.y
			return center.z == monsterPos.z and ((dx * dx) + (dy * dy)) <= (radius * radius)
		end
		return tileDistance(center, monsterPos) <= radius
	end
	if area.kind == "direction" then
		-- Fallback for spells without a named AREA_* matrix.
		local dx = monsterPos.x - origin.x
		local dy = monsterPos.y - origin.y
		local forward
		local lateral
		local direction = player:getDirection()
		if direction == DIRECTION_NORTH then
			forward, lateral = -dy, math.abs(dx)
		elseif direction == DIRECTION_EAST then
			forward, lateral = dx, math.abs(dy)
		elseif direction == DIRECTION_SOUTH then
			forward, lateral = dy, math.abs(dx)
		elseif direction == DIRECTION_WEST then
			forward, lateral = -dx, math.abs(dy)
		elseif direction == DIRECTION_NORTHEAST then
			forward, lateral = math.max(dx, -dy), math.abs(dx + dy)
			if dx < 0 or dy > 0 then
				forward = -1
			end
		elseif direction == DIRECTION_SOUTHEAST then
			forward, lateral = math.max(dx, dy), math.abs(dx - dy)
			if dx < 0 or dy < 0 then
				forward = -1
			end
		elseif direction == DIRECTION_SOUTHWEST then
			forward, lateral = math.max(-dx, dy), math.abs(dx + dy)
			if dx > 0 or dy < 0 then
				forward = -1
			end
		else
			forward, lateral = math.max(-dx, -dy), math.abs(dx - dy)
			if dx > 0 or dy > 0 then
				forward = -1
			end
		end
		local length = math.max(1, tonumber(area.length) or 1)
		local spread = math.max(0, tonumber(area.spread) or 0)
		local allowedLateral = spread == 0 and 0 or math.min(spread, math.max(1, math.floor((forward + 1) / 2)))
		return forward >= 1 and forward <= length and lateral <= allowedLateral
	end
	local radius = math.max(0, tonumber(area.radius) or 0)
	if area.kind == "self" and type(area.wod) == "table" and playerHasWodArea(player, area.wod) then
		radius = math.max(radius, tonumber(area.wodRadius) or radius)
	end
	if area.shape == "circle" then
		local dx = monsterPos.x - origin.x
		local dy = monsterPos.y - origin.y
		return ((dx * dx) + (dy * dy)) <= (radius * radius)
	end
	return tileDistance(origin, monsterPos) <= radius
end

--- True if caster or any party member inside the AoE is at/under the HP threshold.
local function areaHealShouldFire(player, slot, casterHpPercent, casterManaPercent)
	if not slot or slot.enabled == false then
		return false
	end
	-- Healing spells are HP-gated only (mana trigger is potions/support).
	local threshold = healHpThreshold(slot)
	if casterHpPercent <= threshold then
		return true
	end
	local area = CombatAutomationConfig.SpellAreaById and CombatAutomationConfig.SpellAreaById[slot.spellId]
	if type(area) ~= "table" then
		return false
	end
	local casterId = player:getId()
	for _, member in ipairs(iterPartyPlayers(player)) do
		if member:getId() ~= casterId and member:getHealth() > 0 then
			if isInsideSpellArea(player, nil, member, area) then
				local pct = percentOf(member:getHealth(), member:getMaxHealth())
				if pct <= threshold then
					return true
				end
			end
		end
	end
	return false
end

local function countMonstersForSlot(player, slot)
	local target = player:getTarget()
	local area
	if slot.kind == "rune" then
		local range = RuneAreaRangeByTypeId[slot.runeTypeId]
		area = {
			kind = "target",
			shape = range and "circle" or "single",
			radius = range or 0,
		}
	else
		area = CombatAutomationConfig.SpellAreaById and CombatAutomationConfig.SpellAreaById[slot.spellId]
	end
	local count = 0
	for _, monster in ipairs(visibleMonsters(player)) do
		if isInsideSpellArea(player, target, monster, area) then
			count = count + 1
		end
	end
	return count
end

local function slotHasEnoughMonsters(player, slot)
	if slot.kind ~= "spell" and slot.kind ~= "rune" then
		return true
	end
	local required = math.max(1, math.min(9, math.floor(tonumber(slot.monsterCount) or 1)))
	local count = countMonstersForSlot(player, slot)
	if slot.monsterCountMode == "exact" then
		return count == required
	end
	return count >= required
end

local function playerIsTrapped(player)
	if not player then
		return false
	end
	local pos = player:getPosition()
	if not pos then
		return false
	end
	local dirs = {
		{ 0, -1 },
		{ 1, 0 },
		{ 0, 1 },
		{ -1, 0 },
	}
	for _, d in ipairs(dirs) do
		local npos = Position(pos.x + d[1], pos.y + d[2], pos.z)
		local tile = Tile(npos)
		if tile and tile.queryAdd then
			local q = tile:queryAdd(player, FLAG_PATHFINDING or 0)
			if q == RETURNVALUE_NOERROR or q == 0 then
				return false
			end
		elseif tile and tile:getGround() then
			return false
		end
	end
	return true
end

local function slotPassesSituationalGates(player, slot)
	if slot.castIfTrapped == true and not playerIsTrapped(player) then
		return false
	end
	local needHarmony = math.floor(tonumber(slot.harmonyThreshold) or 0)
	if needHarmony > 0 and player.getHarmony then
		if (player:getHarmony() or 0) < needHarmony then
			return false
		end
	end
	return true
end

local function slotExhaustUntil(state, slotId, t, exhaustMs)
	local untilMs = state.exhaustUntil and state.exhaustUntil[slotId]
	if type(untilMs) == "number" then
		return untilMs
	end
	local last = state.exhaust[slotId] or 0
	return last + math.max(0, math.floor(exhaustMs or 0))
end

local function slotReady(state, slotId, t, exhaustMs)
	return t >= slotExhaustUntil(state, slotId, t, exhaustMs)
end

local function markExhaust(state, slotId, t, durationMs)
	state.exhaust = state.exhaust or {}
	state.exhaustUntil = state.exhaustUntil or {}
	local untilMs = t + math.max(0, math.floor(durationMs or 0))
	if (state.exhaustUntil[slotId] or 0) < untilMs then
		state.exhaustUntil[slotId] = untilMs
	end
	state.exhaust[slotId] = t
end

local function markFired(state, player, slot, words, label, exhaustMs, t, gateWithLuaExhaust)
	-- Spells/runes rely on engine CDs; only potions (and fail backoff) need Lua exhaust.
	if gateWithLuaExhaust then
		markExhaust(state, slot.id, t, exhaustMs)
	end
	notifyAutomationCast(player, slot, words, label, exhaustMs)
end

local function markCastFailed(state, slotId, t)
	markExhaust(state, slotId, t, CAST_FAIL_BACKOFF_MS)
end

function CombatAutomation.getState(player)
	if not player then
		return nil
	end
	local id = player:getId()
	local state = statesByPlayerId[id]
	if not state then
		state = {
			playerId = id,
			config = {
				slots = {},
				autoTarget = { enabled = false, stance = "melee", rangedDistance = 3, mode = "A" },
				forceSkillOrder = true,
			},
			exhaust = {},
			exhaustUntil = {},
			event = nil,
			lastSyncedAttackCreatureId = nil,
			directive = nil,
		}
		statesByPlayerId[id] = state
	end
	return state
end

function CombatAutomation.clearState(player)
	if not player then
		return
	end
	local id = player:getId()
	statesByPlayerId[id] = nil
end

--- Run one automation tick for the player.
--- AUTO off: clear target and skip attack/rune slots; heals/support/potions still run.
function CombatAutomation.tick(player)
	if not player then
		return
	end
	local state = CombatAutomation.getState(player)
	local config = state.config
		or {
			slots = {},
			autoTarget = { enabled = false, stance = "melee", rangedDistance = 3, mode = "A" },
			forceSkillOrder = true,
		}

	tickVisibleMonsters = computeVisibleMonsters(player)

	-- Soft-despawned: no target, move, or combat casts until respawn.
	if isSoftDespawnedPlayer(player) then
		if player:getTarget() then
			player:setTarget(nil)
		end
		if player.setFollowCreature then
			player:setFollowCreature(nil)
		end
		syncAutoAttackTarget(player, state, nil)
		tickVisibleMonsters = nil
		return
	end

	local autoEnabled = type(config.autoTarget) == "table" and config.autoTarget.enabled == true
	if not autoEnabled then
		local current = player:getTarget()
		if current then
			player:setTarget(nil)
		end
		syncAutoAttackTarget(player, state, nil)
	else
		autoTarget(player, config, state)
	end

	-- Positioning after target pick (hold / follow / stance).
	if CombatAutomationMovement and CombatAutomationMovement.tick then
		CombatAutomationMovement.tick(player, config)
	end

	-- Paladin distance ammo: equip preferred type; charge gold when inventory is empty.
	local ammoSlots = config.slots
	ensureAmmo(player, {
		slots = ammoSlots,
		ammoTypeId = config.ammoTypeId or 0,
	})

	local slots = config.slots
	if type(slots) ~= "table" or #slots == 0 then
		tickVisibleMonsters = nil
		return
	end

	local hpPercent = percentOf(player:getHealth(), player:getMaxHealth())
	local manaPercent = percentOf(player:getMana(), player:getMaxMana())
	local t = nowMs()
	state.exhaust = state.exhaust or {}
	state.exhaustUntil = state.exhaustUntil or {}

	-- Potions: do not stop after the first success — HP and mana pots can both be
	-- eligible in the same tick. Cap one success per restored resource so stacked
	-- HP potions do not all fire together.
	local usedPotionHealth, usedPotionMana = false, false
	for _, slot in ipairs(slots) do
		if slot.kind == "potion" and slotShouldFire(slot, hpPercent, manaPercent, player) then
			local effect = CombatAutomationConfig.PotionEffects and CombatAutomationConfig.PotionEffects[slot.potionTypeId]
			local givesHealth = effect and effect.health ~= nil
			local givesMana = effect and effect.mana ~= nil
			if effect and not ((givesHealth and usedPotionHealth) or (givesMana and usedPotionMana)) then
				local exhaust = CombatAutomationConfig.POTION_EXHAUST_MS or 1000
				if slotReady(state, slot.id, t, exhaust) then
					if usePotion(player, slot.potionTypeId) then
						if givesHealth then
							usedPotionHealth = true
						end
						if givesMana then
							usedPotionMana = true
						end
						markFired(state, player, slot, "", "potion", exhaust, t, true)
						hpPercent = percentOf(player:getHealth(), player:getMaxHealth())
						manaPercent = percentOf(player:getMana(), player:getMaxMana())
					end
				end
			end
		end
	end

	local supportSlots, combatSlots = {}, {}
	for _, slot in ipairs(slots) do
		if slot.kind == "rune" then
			combatSlots[#combatSlots + 1] = slot
		elseif slot.kind == "spell" then
			if spellRank(slot) < 2 then
				supportSlots[#supportSlots + 1] = slot
			else
				combatSlots[#combatSlots + 1] = slot
			end
		end
	end
	local function byPriority(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return tostring(a.id) < tostring(b.id)
	end
	table.sort(supportSlots, byPriority)
	table.sort(combatSlots, byPriority)

	local attackTarget = player:getTarget()
	if attackTarget and attackTarget.getPosition then
		local fromPos = player:getPosition()
		local toPos = attackTarget:getPosition()
		if fromPos and toPos and fromPos.z == toPos.z then
			local dx = toPos.x - fromPos.x
			local dy = toPos.y - fromPos.y
			if dx ~= 0 or dy ~= 0 then
				local dir
				if math.abs(dx) > math.abs(dy) then
					dir = dx > 0 and DIRECTION_EAST or DIRECTION_WEST
				else
					dir = dy > 0 and DIRECTION_SOUTH or DIRECTION_NORTH
				end
				if dir and player:getDirection() ~= dir then
					player:setDirection(dir)
				end
			end
		end
	end

	local preferredStances = preferredStanceWordsByChannel(supportSlots)

	-- Healing / support / shield always run (mana-only).
	for _, slot in ipairs(supportSlots) do
		local partyTarget = nil
		local shouldFire = false
		if isPartyHealSlot(slot) then
			if slot.enabled ~= false then
				partyTarget = pickPartyHealTarget(player, slot)
				shouldFire = partyTarget ~= nil
			end
		elseif isAreaHealSlot(slot) then
			shouldFire = areaHealShouldFire(player, slot, hpPercent, manaPercent)
		else
			shouldFire = slotShouldFire(slot, hpPercent, manaPercent, player)
		end
		if shouldFire and slotPassesSituationalGates(player, slot) then
			local words = slot.words or ""
			if not shouldSkipStanceCast(player, words, preferredStances) then
				local exhaust = spellExhaustMs(words)
				if slotReady(state, slot.id, t, 0) then
					local param = partyTarget and partyTarget:getName() or nil
					local result = tryCastSpellWords(player, words, param)
					if result == "cast" then
						markFired(state, player, slot, words, words, exhaust, t, false)
						hpPercent = percentOf(player:getHealth(), player:getMaxHealth())
						manaPercent = percentOf(player:getMana(), player:getMaxMana())
						-- Keep checking other support/heals; engine CD returns "skip".
					elseif result == "fail" then
						markCastFailed(state, slot.id, t)
					end
				end
			end
		end
	end

	local forceSkillOrder = config.forceSkillOrder ~= false
	if autoEnabled then
		for _, slot in ipairs(combatSlots) do
			if
				slotShouldFire(slot, hpPercent, manaPercent, player)
				and slotHasEnoughMonsters(player, slot)
				and slotPassesSituationalGates(player, slot)
			then
				local castOk = false
				if slot.kind == "spell" then
					local words = slot.words or ""
					local exhaust = spellExhaustMs(words)
					if slotReady(state, slot.id, t, 0) then
						local result = tryCastSpellWords(player, words)
						if result == "cast" then
							markFired(state, player, slot, words, words, exhaust, t, false)
							castOk = true
						elseif result == "fail" then
							markCastFailed(state, slot.id, t)
						end
					end
				elseif slot.kind == "rune" then
					local exhaust = runeExhaustMs(slot.runeTypeId)
					if slotReady(state, slot.id, t, 0) then
						local result = tryUseRune(player, slot.runeTypeId)
						if result == "cast" then
							local words = runeWords(slot.runeTypeId)
							markFired(state, player, slot, words, words, exhaust, t, false)
							castOk = true
						elseif result == "fail" then
							markCastFailed(state, slot.id, t)
						end
					end
				end
				-- forceSkillOrder: only one successful combat cast per tick; otherwise keep trying.
				if castOk and forceSkillOrder then
					break
				end
			end
		end
	end

	tickVisibleMonsters = nil
end

local function isHuntFrozen(session)
	return session and session.state == "ended"
end

local function expeditionSession(player)
	if not player or not ExpeditionManager then
		return nil, false
	end
	local session = ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	if session and isHuntFrozen(session) then
		return session, true
	end
	if ExpeditionManager.reconcilePresence and not ExpeditionManager.reconcilePresence(player) then
		return nil, false
	end
	if ExpeditionManager.isInExpedition and not ExpeditionManager.isInExpedition(player) then
		return nil, false
	end
	return session, false
end

local function shouldRunLoop(player, state, session, frozen)
	if frozen then
		return false
	end
	if not player or not state then
		return false
	end
	if session then
		return true
	end
	if not state.config then
		return false
	end
	local hasSlots = type(state.config.slots) == "table" and #state.config.slots > 0
	local hasAutoTarget = type(state.config.autoTarget) == "table" and state.config.autoTarget.enabled == true
	return hasSlots or hasAutoTarget
end

--- Driven by Player::onThink / idle-combat 250ms cycle (EventCallback playerOnThink).
--- Do not schedule addEvent here — engine think owns cadence.
function CombatAutomation.onThink(player, _interval)
	if not player then
		return
	end
	local state = CombatAutomation.getState(player)
	local session, frozen = expeditionSession(player)
	if not shouldRunLoop(player, state, session, frozen) then
		return
	end
	if state.config then
		CombatAutomation.tick(player)
	end
end

--- Ensure loadout is in runtime state so onThink can tick (think pipeline owns the loop).
function CombatAutomation.ensureLoop(player)
	if player and CombatAutomationStore and CombatAutomationStore.getConfig then
		CombatAutomationStore.getConfig(player)
	end
end

function CombatAutomation.stopLoop(player)
	-- Think pipeline stops naturally when shouldRunLoop is false / idleCombat clears.
	if player then
		CombatAutomation.clearState(player)
	end
end
