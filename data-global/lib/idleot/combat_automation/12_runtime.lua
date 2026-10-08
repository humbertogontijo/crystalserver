CombatAutomation = CombatAutomation or {}

local statesByPlayerId = {}

local nowMs = CombatGeo.nowMs
local tileDistance = CombatGeo.chebyshev

local function percentOf(current, maximum)
	maximum = math.max(1, maximum or 1)
	current = math.max(0, current or 0)
	return math.floor((current / maximum) * 100)
end

local function spellGroup(slot)
	if not slot or slot.kind ~= "spell" then
		return nil
	end
	return CombatAutomationConfig.SpellGroupById[slot.spellId]
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
	if not player then
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
	["exeta res"] = "challenge", -- Challenge: adjacent area + chain to distant monsters
	["exeta amp res"] = "amp_challenge", -- Chivalrous: chain to monsters still keeping range
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

--- HP % threshold for friend/area/self heals (healing slots always trigger on HP).
local function healHpThreshold(slot)
	return slot.triggerPercent
end

local function isManaShieldPotion(slot)
	if not slot or slot.kind ~= "potion" then
		return false
	end
	local effect = CombatAutomationConfig.PotionEffects[slot.potionTypeId]
	return effect ~= nil and effect.manashield == true
end

--- Magic Shield (utamo vita or magic shield potion): keep up when absent; respect Always / Mana % triggers.
local function shieldSlotShouldFire(player, slot, hpPercent, manaPercent)
	if not slot or slot.enabled == false then
		return false
	end
	local words = tostring(slot.words or ""):lower()
	if words ~= "utamo vita" and not isManaShieldPotion(slot) then
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
	if group == "shield" or isManaShieldPotion(slot) then
		return shieldSlotShouldFire(player, slot, hpPercent, manaPercent)
	end
	if slotIgnoresTriggerStat(slot) then
		return true
	end
	-- Cures (exana pox/flam/vis/kor/mort) are condition-gated, not HP-gated.
	local cure = slot.kind == "spell" and CombatAutomationConfig.cureConditionForWords(slot.words)
	if cure then
		return player ~= nil and player:hasCondition(cure)
	end
	-- Healing spells are always HP-threshold gated.
	if group == "healing" then
		return hpPercent <= healHpThreshold(slot)
	end
	local stat = slot.triggerStat or "hp"
	local threshold = slot.triggerPercent or 0
	if stat == "always" then
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
	local area = CombatAutomationConfig.SpellAreaById[slot.spellId]
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
	local group = CombatAutomationConfig.SpellGroupById[slot.spellId]
	if group ~= "healing" then
		return false
	end
	local area = CombatAutomationConfig.SpellAreaById[slot.spellId]
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
	if creature:isPlayer() then
		return creature
	end
	local master = creature:getMaster()
	if master and master:isPlayer() then
		return master
	end
	return nil
end

local function sameParty(a, b)
	if not a or not b or isRetroPVP(a) then
		return false
	end
	local pa = a:getParty()
	local pb = b:getParty()
	return pa ~= nil and pa == pb
end

local function sameExpedition(a, b)
	local sa = ExpeditionManager.getSessionByPlayer(a)
	local sb = ExpeditionManager.getSessionByPlayer(b)
	if not sa or not sb or sa ~= sb then
		return false
	end
	-- Sharing a session on a PvP-enabled instance does not make players allies.
	return Game.getWorldType(a:getInstanceId()) == WORLDTYPE_OPTIONAL
end

--- Another player on a PvP-enabled instance (non-optional world type).
local function isPvpRival(player, creature)
	if not player or not creature or not creature:isPlayer() then
		return false
	end
	if creature:getId() == player:getId() then
		return false
	end
	return Game.getWorldType(player:getInstanceId()) ~= WORLDTYPE_OPTIONAL
end

local function sameTeamDeployment(a, b)
	local aid, bid = a:getId(), b:getId()
	local da = Alts.getDeployment(a)
	if da then
		for _, id in ipairs(da.companionIds or {}) do
			if id == bid then
				return true
			end
		end
	end
	local db = Alts.getDeployment(b)
	if db then
		for _, id in ipairs(db.companionIds or {}) do
			if id == aid then
				return true
			end
		end
	end
	local key = AltsConfig.STORAGE_COMPANION_CONTROLLER
	local ga = a:getStorageValue(key)
	local gb = b:getStorageValue(key)
	if ga and ga > 0 and gb and gb > 0 and ga == gb then
		return true
	end
	if ga and ga > 0 and ga == b:getGuid() then
		return true
	end
	if gb and gb > 0 and gb == a:getGuid() then
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
	if not a:isPlayer() or not b:isPlayer() then
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
--- Supplies priced in tokens rather than NPC gold (e.g. Cledwyn's magic shield potion).
local function supplyTokenPrice(typeId)
	local effect = CombatAutomationConfig.PotionEffects[typeId]
	return effect and effect.tokenPrice or nil
end

local function chargeNpcBuyPrice(player, typeId)
	local tokenPrice = supplyTokenPrice(typeId)
	if tokenPrice then
		return TokenMarket ~= nil and TokenMarket.acquire(player, tokenPrice.id, tokenPrice.count) == true
	end
	local price = CombatAutomationConfig.NpcBuyPriceByTypeId[typeId]
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
	if not player then
		return nil
	end
	return ExpeditionManager.getSessionByPlayer(player)
end

--- True when consumeSupply would succeed without the shortage handler.
local function supplyAvailable(player, typeId)
	if player:getItemById(typeId, true) then
		return true
	end
	local tokenPrice = supplyTokenPrice(typeId)
	if tokenPrice then
		local quote = TokenMarket.quote(player, tokenPrice.id, tokenPrice.count)
		return quote.gold <= (player:getMoney() or 0) + (player:getBankBalance() or 0)
	end
	local price = CombatAutomationConfig.NpcBuyPriceByTypeId[typeId]
	if price ~= 0 and NpcPriceChecker and NpcPriceChecker[typeId] and NpcPriceChecker[typeId].buy then
		price = NpcPriceChecker[typeId].buy
	end
	if price == nil then
		return false
	end
	price = math.floor(tonumber(price) or 0)
	return price <= 0 or price <= (player:getMoney() or 0) + (player:getBankBalance() or 0)
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
	if it and it:isQuiver() then
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
	if quiver and (quiver:getItemCountById(typeId) or 0) > 0 then
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
	if bp then
		return current:moveTo(bp) == true
	end
	return false
end

local function addItemReturnOk(ret)
	return ret == RETURNVALUE_NOERROR or ret == 0
end

local function canCarryAmmo(player, typeId, count)
	if not player then
		return true
	end
	local it = ItemType(typeId)
	local weight = tonumber(it:getWeight(count)) or 0
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
	if quiver and addItemReturnOk(quiver:addItemEx(item, -1, flags)) then
		return true
	end

	-- Classic ammo slot: FLAG_NOLIMIT only skips cap on container→player (FLAG_CHILDISOWNER).
	local bp = player:getSlotItem(CONST_SLOT_BACKPACK)
	if bp and addItemReturnOk(bp:addItemEx(item, -1, flags)) then
		if clearAmmoSlotIfWrong(player, typeId) and item:moveToSlot(player, CONST_SLOT_AMMO) then
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
		if quiver and fromInv:moveTo(quiver) then
			return ammoIsReady(player, typeId)
		end
		if clearAmmoSlotIfWrong(player, typeId) and fromInv:moveToSlot(player, CONST_SLOT_AMMO) then
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

--- Configured ammo typeId: the first enabled ammo slot, else config.ammoTypeId.
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
	if not player or not CombatAutomationCatalog.isPaladin(player) then
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
		ExpeditionSafety.handleShortage(
			player,
			"cap",
			function()
				return canCarryAmmo(player, typeId, 1)
			end,
			string.format("%s has insufficient capacity for ammo. Expedition stopped.", player:getName())
		)
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
		if respectCap then
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
	local effect = CombatAutomationConfig.PotionEffects[typeId]
	if not effect then
		return false
	end
	if not consumeSupply(player, typeId) then
		return false
	end
	local fx = CONST_ME_MAGIC_BLUE
	if effect.manashield then
		-- Mirrors the stock magic shield potion (data/scripts/actions/items/potions.lua).
		local condition = Condition(CONDITION_MANASHIELD)
		condition:setParameter(CONDITION_PARAM_TICKS, 60000)
		condition:setParameter(CONDITION_PARAM_MANASHIELD, math.min(player:getMaxMana(), 300 + 7.6 * player:getLevel() + 7 * player:getMagicLevel()))
		player:addCondition(condition)
		fx = CONST_ME_ENERGYAREA
	end
	if effect.health then
		doTargetCombatHealth(player, player, COMBAT_HEALING, effect.health[1], effect.health[2], CONST_ME_MAGIC_BLUE)
	end
	if effect.mana then
		doTargetCombatMana(0, player, effect.mana[1], effect.mana[2], CONST_ME_MAGIC_BLUE)
	end
	local pos = player:getPosition()
	local instanceId = player:getInstanceId()
	if instanceId ~= nil then
		local specs = Game.getSpectators(pos, true, true, 0, 0, 0, 0, instanceId)
		if type(specs) == "table" then
			for _, spec in ipairs(specs) do
				if spec then
					pos:sendMagicEffect(fx, spec)
				end
			end
		end
	else
		pos:sendMagicEffect(fx)
	end
	player:say("Aaaah...", MESSAGE_POTION)
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
local CAST_FAIL_BACKOFF_MS = CombatAutomationConfig.TICK_MS

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
	local mapped = CombatAutomationConfig.SpellCooldownMsByWords[words]
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

-- words -> catalog spell id, rebuilt when CombatAutomationConfig.SpellWordsById is replaced.
local spellIdByWords, spellIdByWordsSource = {}, nil

local function catalogSpellIdForWords(words)
	local source = CombatAutomationConfig.SpellWordsById
	if source ~= spellIdByWordsSource then
		spellIdByWords, spellIdByWordsSource = {}, source
		for id, mapped in pairs(source or {}) do
			if spellIdByWords[mapped] == nil then
				spellIdByWords[mapped] = id
			end
		end
	end
	return spellIdByWords[words]
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
	local catalogId = catalogSpellIdForWords(words)
	if catalogId then
		if not CombatAutomationCatalog.spellAllowedForPlayer(catalogId, player) then
			return "skip"
		end
	end

	SampleSpells.ensureWords(player, words)

	local castParam = (type(param) == "string" and param ~= "") and param or nil
	local ready
	if castParam then
		ready = player:canCastSpell(words, castParam)
	else
		ready = player:canCastSpell(words)
	end
	if not ready then
		return "skip"
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

--- Spell words talk type, same as a typed cast (Player::saySpell): emoteSpells → orange
--- monster say, otherwise a regular yellow say.
local function spellTalkType()
	if configManager.getBoolean(configKeys.EMOTE_SPELLS) then
		return TALKTYPE_MONSTER_SAY
	end
	return TALKTYPE_SAY
end

local function notifyAutomationCast(player, slot, words, label, exhaustMs)
	-- Runes are thrown silently; their words only label the client cast flash.
	if words and words ~= "" and not (slot and slot.kind == "rune") then
		player:say(words, spellTalkType())
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
		if target then
			CombatAutomationProtocol.sendCast(target, payload)
		end
	end
	sendCast(player)
	-- Headless companions have no client; relay to expedition host so the cast flash is visible.
	if Alts.isCompanion(player) then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session and session.playerId and session.playerId ~= player:getId() then
			sendCast(Player(session.playerId))
		end
	end
end

--- aim: optional Position for area runes (best tile); defaults to the current target.
local function useRune(player, typeId, aim)
	if not CombatAutomationConfig.AllowedRunes[typeId] then
		return false
	end
	if not CombatAutomationCatalog.runeAllowedForPlayer(typeId, player) then
		return false
	end
	local target = player:getTarget()
	if not target then
		return false
	end
	-- Charge after a successful cast; only a shortage (handler may stop the hunt) pays up front.
	local prepaid = false
	if not supplyAvailable(player, typeId) then
		if not consumeSupply(player, typeId) then
			return false
		end
		prepaid = true
	end
	-- Real rune script (correct area / distance / impact FX).
	local ok, result = pcall(function()
		return player:castRune(typeId, aim or target)
	end)
	local cast = ok and result == true
	if cast and not prepaid then
		consumeSupply(player, typeId)
	end
	return cast
end

--- Returns: "cast" | "skip" | "fail"
--- skip = not ready / gated (no attempt). fail = engine/script rejected (silent).
local function tryUseRune(player, typeId, aim)
	if not CombatAutomationConfig.AllowedRunes[typeId] then
		return "skip"
	end
	if not CombatAutomationCatalog.runeAllowedForPlayer(typeId, player) then
		return "skip"
	end
	if not player:getTarget() then
		return "skip"
	end
	if useRune(player, typeId, aim) then
		return "cast"
	end
	return "fail"
end

local function spellRank(slot)
	local group = CombatAutomationConfig.SpellGroupById[slot.spellId]
	if group == "healing" then
		return 0
	end
	if group == "support" or group == "shield" or group == "stance" then
		return 1
	end
	return 2
end

--- AUTO off only stops attacking: heals, potions and support keep running, except the
--- support spells that pull monsters (AttackOnlySupportWords).
local function runsWithAutoOff(slot)
	if slot.kind == "potion" then
		return true
	end
	local words = tostring(slot.words or ""):lower()
	local attackOnly = CombatAutomationConfig.AttackOnlySupportWords or {}
	return spellRank(slot) < 2 and not attackOnly[words]
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

-- Master of Flames / Thunder / Decay: a native stance-element cast arms the next-spell
-- conversion (Player::resolveElementCast), so stance-element attack slots lead the rotation.
local ELEMENT_BY_WORD = { flam = "fire", vis = "energy", mort = "death" }
local ELEMENT_BY_STANCE = {
	[STANCE_MASTER_OF_FLAMES or 7] = "fire",
	[STANCE_MASTER_OF_THUNDER or 8] = "energy",
	[STANCE_MASTER_OF_DECAY or 9] = "death",
}

local function slotElement(slot)
	local words = slot.kind == "rune" and runeWords(slot.runeTypeId) or slot.words
	for token in tostring(words or ""):lower():gmatch("%a+") do
		local element = ELEMENT_BY_WORD[token]
		if element then
			return element
		end
	end
	return nil
end

--- Priority-ordered combat slots split into tiers: the elemental stance's element first,
--- then everything else. One tier when no elemental stance is active.
local function stanceElementTiers(player, slots)
	local element = player and ELEMENT_BY_STANCE[player:getElementalStance()]
	if not element then
		return { slots }
	end
	local stanceTier, rest = {}, {}
	for _, slot in ipairs(slots) do
		if slotElement(slot) == element then
			stanceTier[#stanceTier + 1] = slot
		else
			rest[#rest + 1] = slot
		end
	end
	return { stanceTier, rest }
end

local function stanceElementOrder(player, slots)
	local tiers = stanceElementTiers(player, slots)
	if #tiers == 1 then
		return slots
	end
	local ordered = {}
	for _, tier in ipairs(tiers) do
		for _, slot in ipairs(tier) do
			ordered[#ordered + 1] = slot
		end
	end
	return ordered
end

local function currentStanceValue(player, info)
	if not player or not info then
		return nil
	end
	if info.virtue then
		return player:getVirtue()
	end
	if info.elemental then
		return player:getElementalStance()
	end
	return player:getStance()
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

--- Players are never auto-picked: on PvP-enabled instances only the sticky manual target stays valid.
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

	if player:getInstanceId() ~= creature:getInstanceId() then
		return false
	end

	local fromPos = player:getPosition()
	local toPos = creature:getPosition()
	if not fromPos or not toPos or fromPos.z ~= toPos.z then
		return false
	end
	local instanceId = Instance.of(player)
	if not fromPos:isSightClear(toPos, true, instanceId) then
		return false
	end

	local tile = creature:getTile()
	if tile and tile:hasProperty(CONST_PROP_BLOCKPROJECTILE, instanceId) then
		return false
	end

	if creature:isPlayer() then
		if creature:getId() == player:getId() then
			return false
		end
		if SoftDeath.isDowned(creature) then
			return false
		end
		if not isPvpRival(player, creature) then
			return false
		end
		if sameParty(player, creature) or sameTeamDeployment(player, creature) then
			return false
		end
		local current = player:getTarget()
		if current and current:getId() == creature:getId() then
			return true
		end
		return false
	end

	if not creature:isMonster() then
		return false
	end

	local master = creature:getMaster()
	if master and master:isPlayer() then
		return false
	end

	local mType = creature:getType()
	if mType and not mType:isAttackable() then
		return false
	end

	return true
end

-- Spectator scan shared by every check in the running tick.
local tickVisibleMonsters = nil

-- Pick pool is monsters only (the monster rules of isValidAttackTarget, in the engine);
-- rival players are sticky via getTarget(), never auto-picked.
local function computeVisibleMonsters(player)
	return player:combatScan()
end

local function visibleMonsters(player)
	if tickVisibleMonsters ~= nil then
		return tickVisibleMonsters
	end
	return computeVisibleMonsters(player)
end
CombatAutomation.visibleMonsters = visibleMonsters

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
	if not player then
		return false
	end
	local summons = player:getSummons()
	if type(summons) ~= "table" then
		return false
	end
	for i = 1, #summons do
		local summon = summons[i]
		local summonType = summon and summon:getType()
		if summonType and summonType:familiar() then
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
	local mType = monster and monster:getType()
	if not mType or not mType.getTargetDistance then
		return false
	end
	return (mType:getTargetDistance() or 1) > 1
end

local function monsterHasMaster(monster)
	if not monster then
		return false
	end
	return monster:getMaster() ~= nil
end

local function monsterIsRewardBoss(monster)
	local mType = monster and monster:getType()
	return mType and mType:isRewardBoss()
end

--- Prefer reward bosses and the active expedition/world-boss target over trash.
--- `session` (optional): the player's expedition session, when the caller already has it.
local function monsterIsFocusBoss(player, monster, session)
	if not monster then
		return false
	end
	if monsterIsRewardBoss(monster) then
		return true
	end
	if not session and player then
		session = ExpeditionManager.getSessionByPlayer(player)
	end
	if not session then
		return false
	end
	if session.bossCreatureId and monster:getId() == session.bossCreatureId then
		return true
	end
	if session.kind == "worldboss" then
		local wb = ActivityBoostWorldBoss.active[session.bandId]
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
	for _, monster in ipairs(visibleMonsters(player)) do
		if monsterIsRewardBoss(monster) then
			return true
		end
	end
	return false
end

--- Soft-despawned (knocked out): pause AUTO until softSpawn.
local function isSoftDespawnedPlayer(player)
	return SoftDeath.isDowned(player)
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

--- First chain hop from the caster: same picker rules as the spell, in jump range and in sight.
local function knightChainCanStart(player, origin, monster, opts)
	if KnightChallenge.chainPriority(player, monster, opts) <= 0 then
		return false
	end
	local mp = monster:getPosition()
	if not mp or mp.z ~= origin.z or tileDistance(origin, mp) > KnightChallenge.CHAIN_DISTANCE then
		return false
	end
	local instanceId = Instance.of(player)
	return origin:isSightClear(mp, true, instanceId)
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
	-- Exeta res chain (challenge.lua) only runs with a free tile around the knight.
	local challengeChain = mode == "challenge" and KnightChallenge.hasRoomAround(player)
	for _, monster in ipairs(visibleMonsters(player)) do
		if mode == "challenge" then
			local mp = monster:getPosition()
			if tileDistance(mp, origin) <= 1 then
				return true
			end
			if challengeChain and knightChainCanStart(player, origin, monster, { skipAdjacent = true }) then
				return true
			end
		elseif mode == "amp_challenge" then
			-- Only turns ranged monsters melee; exeta res owns keeping the pack challenged.
			if
				KnightChallenge.isCurrentlyRanged(monster)
				and knightChainCanStart(player, origin, monster, { rangedOnly = true })
			then
				return true
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
		if not player:canCastSpell(words) then
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
	local weapon = player:getSlotItem(CONST_SLOT_LEFT) or player:getSlotItem(CONST_SLOT_RIGHT)
	if not weapon then
		return 1
	end
	local it = ItemType(weapon:getId())
	local weaponType = it:getWeaponType()
	if weaponType == WEAPON_NONE or weaponType == WEAPON_SHIELD or weaponType == WEAPON_AMMO then
		return 1
	end
	local range = it:getShootRange()
	if type(range) == "number" and range > 0 then
		return math.floor(range)
	end
	return 1
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
		return player:getWheelSpellAdditionalArea(wod.name) == true
	end
	if check == "instantSkill" then
		return player:instantSkillWOD(wod.name) == true
	end
	return false
end

local function directionTilesForArea(player, area, face)
	if type(area) ~= "table" then
		return nil
	end
	local direction = face or (player and player:getDirection())
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

local function isInsideSpellArea(player, target, monster, area, origin, face)
	if type(area) ~= "table" then
		return monster == target
	end
	origin = origin or player:getPosition()
	local monsterPos = monster:getPosition()
	if origin.z ~= monsterPos.z then
		return false
	end

	-- Directional AREA_* matrices (base / WoD / upgrade-grade variants).
	local dirTiles = directionTilesForArea(player, area, face)
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
		return false
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
	local area = CombatAutomationConfig.SpellAreaById[slot.spellId]
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

local CARDINAL_DIRS = { DIRECTION_NORTH, DIRECTION_EAST, DIRECTION_SOUTH, DIRECTION_WEST }

local function playerIsTrapped(player)
	if not player then
		return false
	end
	local pos = player:getPosition()
	if not pos then
		return false
	end
	for _, d in ipairs(CombatGeo.CARDINAL_OFFSETS) do
		local npos = Position(pos.x + d[1], pos.y + d[2], pos.z)
		local tile = Tile(npos)
		if tile then
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
	if needHarmony > 0 then
		if (player:getHarmony() or 0) < needHarmony then
			return false
		end
	end
	return true
end

local function slotExhaustUntil(state, slotId, exhaustMs)
	local untilMs = state.exhaustUntil and state.exhaustUntil[slotId]
	if type(untilMs) == "number" then
		return untilMs
	end
	local last = state.exhaust[slotId] or 0
	return last + math.max(0, math.floor(exhaustMs or 0))
end

local function slotReady(state, slotId, t, exhaustMs)
	return t >= slotExhaustUntil(state, slotId, exhaustMs)
end

local AREA_STEP_MS = 1000

--- Multi-tile attack area, or nil for single-target / non-attacks.
local function areaAttackOf(slot)
	if not slot or slot.enabled == false then
		return nil
	end
	if slot.kind == "rune" then
		local range = RuneAreaRangeByTypeId[slot.runeTypeId]
		if not range or range <= 0 then
			return nil
		end
		return { kind = "target", shape = "circle", radius = range }
	end
	if slot.kind ~= "spell" then
		return nil
	end
	local area = CombatAutomationConfig.SpellAreaById[slot.spellId]
	if type(area) ~= "table" then
		return nil
	end
	if type(area.tiles) == "table" and #area.tiles > 1 then
		return area
	end
	if type(area.wodTiles) == "table" and #area.wodTiles > 1 then
		return area
	end
	if type(area.byDir) == "table" or type(area.wodByDir) == "table" then
		return area
	end
	local radius = math.max(tonumber(area.radius) or 0, tonumber(area.wodRadius) or 0)
	if radius > 0 and area.shape ~= "single" then
		return area
	end
	return nil
end

local RUNE_AIM_RADIUS = 3
local RUNE_AIM_RANGE = 7

--- Best area-rune centre: a visible monster tile within RUNE_AIM_RADIUS of the target,
--- in range and shootable, that hits strictly more than centring on the target.
--- Nil = cast on the target.
local function runeAimPosition(player, typeId)
	local radius = RuneAreaRangeByTypeId[typeId]
	local target = player:getTarget()
	if not radius or radius <= 0 or not target then
		return nil
	end
	local ppos = player:getPosition()
	local tpos = target:getPosition()
	if not ppos or not tpos or ppos.z ~= tpos.z then
		return nil
	end
	local monsters = visibleMonsters(player)
	local r2 = radius * radius
	local function hitsAt(center)
		local n = 0
		for _, monster in ipairs(monsters) do
			local mpos = monster:getPosition()
			local dx, dy = mpos.x - center.x, mpos.y - center.y
			if mpos.z == center.z and dx * dx + dy * dy <= r2 then
				n = n + 1
			end
		end
		return n
	end
	local best, bestCount = nil, hitsAt(tpos)
	local instanceId = Instance.of(player)
	for _, monster in ipairs(monsters) do
		local mpos = monster:getPosition()
		if mpos.z == tpos.z and tileDistance(mpos, tpos) <= RUNE_AIM_RADIUS and tileDistance(ppos, mpos) <= RUNE_AIM_RANGE then
			local n = hitsAt(mpos)
			if n > bestCount and ppos:isSightClear(mpos, true, instanceId) then
				best, bestCount = mpos, n
			end
		end
	end
	return best
end

local function isDirectionalArea(area)
	return type(area) == "table"
		and (type(area.byDir) == "table" or type(area.wodByDir) == "table")
end

--- Any enabled attack spell slot with a directional area (waves, beams, front sweeps).
function CombatAutomation.hasDirectionalAttackSlot(config)
	for _, slot in ipairs(config and config.slots or {}) do
		if slot.enabled ~= false and slot.kind == "spell" and spellRank(slot) >= 2 and isDirectionalArea(areaAttackOf(slot)) then
			return true
		end
	end
	return false
end

local function countAreaHits(player, area, origin, face)
	local target = player:getTarget()
	local count = 0
	local monsters = visibleMonsters(player)
	for i = 1, #monsters do
		if isInsideSpellArea(player, target, monsters[i], area, origin, face) then
			count = count + 1
		end
	end
	return count
end

--- Monsters the slot hits from here (single-target slots: just the target).
local function countMonstersForSlot(player, slot, face)
	local area = areaAttackOf(slot) or (slot.kind == "spell" and CombatAutomationConfig.SpellAreaById[slot.spellId]) or nil
	return countAreaHits(player, area, nil, face)
end

local function monsterCountPasses(slot, count)
	local required = math.max(1, math.min(9, math.floor(tonumber(slot.monsterCount) or 1)))
	if slot.monsterCountMode == "exact" then
		return count == required
	end
	return count >= required
end

local function slotHasEnoughMonsters(player, slot, face)
	if slot.kind ~= "spell" and slot.kind ~= "rune" then
		return true
	end
	return monsterCountPasses(slot, countMonstersForSlot(player, slot, face))
end

local function byPriority(a, b)
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	return tostring(a.id) < tostring(b.id)
end

--- Attack execution order: "exact" monster counts first, then "at least", each from the
--- highest count down, then bar slot / step. A broad "at least 1" never runs ahead of a
--- narrower gate and takes the cooldown it needs.
local function byMonsterGate(a, b)
	local modeA = a.monsterCountMode == "exact" and 0 or 1
	local modeB = b.monsterCountMode == "exact" and 0 or 1
	if modeA ~= modeB then
		return modeA < modeB
	end
	local countA = math.floor(tonumber(a.monsterCount) or 1)
	local countB = math.floor(tonumber(b.monsterCount) or 1)
	if countA ~= countB then
		return countA > countB
	end
	return byPriority(a, b)
end

--- { config, slots } built once at the start of a tick (targeting, area steps and casts share it).
local tickCombatSlots = nil

--- Runes and attack spells (rank >= 2), in attack execution order (byMonsterGate).
local function combatSlotsOf(config)
	if tickCombatSlots and tickCombatSlots.config == config then
		return tickCombatSlots.slots
	end
	local slots = config and config.slots
	local combatSlots = {}
	if type(slots) ~= "table" then
		return combatSlots
	end
	for _, slot in ipairs(slots) do
		if slot.kind == "rune" or (slot.kind == "spell" and spellRank(slot) >= 2) then
			combatSlots[#combatSlots + 1] = slot
		end
	end
	table.sort(combatSlots, byMonsterGate)
	return combatSlots
end

local function walkTaskActive(player)
	return player and player:hasWalkTask()
end

--- The step walk must be finished before the cast tick. The first idle tick
--- only records that; the next tick faces and casts.
local function resolveAreaStep(player, state, t)
	state.skipStanceForAreaCast = nil
	state.areaCastSlotId = nil
	state.areaFace = nil
	local pending = state.pendingAreaCast
	if not pending then
		return
	end
	local ppos = player:getPosition()
	local onTile = ppos and ppos.x == pending.x and ppos.y == pending.y and ppos.z == pending.z
	local timedOut = t >= (pending.untilMs or 0)
	if walkTaskActive(player) or not (onTile or timedOut) then
		return
	end
	if not pending.idle then
		pending.idle = true
		state.skipStanceForAreaCast = true
		return
	end
	state.pendingAreaCast = nil
	state.skipStanceForAreaCast = true
	state.areaCastSlotId = pending.slotId
	if onTile then
		state.areaFace = pending.dir
	end
end

--- True when this combat slot is the one the rotation would cast next.
--- Lua exhaust of 0 is not enough: spells wait on the engine cooldown.
local function combatSlotWillCast(player, state, slot, t)
	if not slot or not slotReady(state, slot.id, t, 0) then
		return false
	end
	if slot.kind == "spell" then
		local words = slot.words or ""
		if words == "" or not (CombatAutomationConfig.AllowedSpellWords[words]) then
			return false
		end
		if not player:canCastSpell(words) then
			return false
		end
		return true
	end
	if slot.kind == "rune" then
		if not player:getTarget() then
			return false
		end
		local spell = getRuneSpell(slot.runeTypeId)
		if spell then
			local spellId = spell:id()
			if type(spellId) == "number" and spellId > 0 and player:hasCondition(CONDITION_SPELLCOOLDOWN, spellId) then
				return false
			end
			local group, secondary = spell:group()
			if type(group) == "number" and group > 0 and player:hasCondition(CONDITION_SPELLGROUPCOOLDOWN, group) then
				return false
			end
			if type(secondary) == "number" and secondary > 0 and player:hasCondition(CONDITION_SPELLGROUPCOOLDOWN, secondary) then
				return false
			end
		end
		return true
	end
	return false
end

--- Hits from `origin`; directional areas try all 4 facings. Ties keep
--- the current facing. Returns hits, facing.
local function bestAreaHits(player, area, origin)
	local face = player:getDirection()
	local best = countAreaHits(player, area, origin, face)
	if not isDirectionalArea(area) then
		return best, face
	end
	local bestDir = face
	for _, dir in ipairs(CARDINAL_DIRS) do
		if dir ~= face then
			local n = countAreaHits(player, area, origin, dir)
			if n > best then
				best, bestDir = n, dir
			end
		end
	end
	return best, bestDir
end

--- Combat slot could go out this tick: condition, gates, cooldown/mana, and its monster
--- count from here (directional areas: best facing).
local function combatSlotCastableNow(player, state, slot, hpPercent, manaPercent, t)
	if not (slotShouldFire(slot, hpPercent, manaPercent, player) and slotPassesSituationalGates(player, slot) and combatSlotWillCast(player, state, slot, t)) then
		return false
	end
	local area = areaAttackOf(slot)
	if area and isDirectionalArea(area) then
		return monsterCountPasses(slot, (bestAreaHits(player, area, player:getPosition())))
	end
	return slotHasEnoughMonsters(player, slot)
end

--- Steps of one multi-action slot share this key (one goes out per tick); every step of
--- a side slot (stance, equipment) is its own.
local function groupKeyOf(slot)
	if slot.group and not CombatAutomationConfig.SIDE_GROUPS[slot.group] then
		return slot.group
	end
	return slot.id
end

--- Multi-action slots: each group (bar slot) offers only its lowest castable step.
--- Returns those slots in `slots` order, plus group key -> chosen step.
local function firstCastableByGroup(player, state, slots, hpPercent, manaPercent, t)
	local chosen = {}
	for _, slot in ipairs(slots) do
		local key = groupKeyOf(slot)
		local current = chosen[key]
		if (not current or (slot.step or 1) < (current.step or 1)) and combatSlotCastableNow(player, state, slot, hpPercent, manaPercent, t) then
			chosen[key] = slot
		end
	end
	local out = {}
	for _, slot in ipairs(slots) do
		if chosen[groupKeyOf(slot)] == slot then
			out[#out + 1] = slot
		end
	end
	return out, chosen
end

--- Lead slot among `slots` (ready, gated). Strict order: the first by priority. Smart
--- (default): the area slot with the most hits (rotation-aware) when it hits 2+, else
--- the first by priority. Returns slot, area, hits, facing.
local function pickLeadSlotIn(player, state, slots, strict, hpPercent, manaPercent, t)
	local first = nil
	local lead, leadArea, leadHits, leadDir = nil, nil, 1, nil
	local ppos = player:getPosition()
	for _, slot in ipairs(slots) do
		if slotShouldFire(slot, hpPercent, manaPercent, player) and slotPassesSituationalGates(player, slot) and combatSlotWillCast(player, state, slot, t) then
			local area = areaAttackOf(slot)
			local hits, dir = 1, nil
			local gated
			if area and isDirectionalArea(area) then
				hits, dir = bestAreaHits(player, area, ppos)
				gated = monsterCountPasses(slot, hits)
			else
				gated = slotHasEnoughMonsters(player, slot)
				if area then
					hits = countAreaHits(player, area, ppos, player:getDirection())
				end
			end
			if gated then
				if not first then
					first = { slot, area, hits, dir }
					if strict then
						break
					end
				end
				if area and hits >= 2 and hits > leadHits then
					lead, leadArea, leadHits, leadDir = slot, area, hits, dir
				end
			end
		end
	end
	if not strict and lead then
		return lead, leadArea, leadHits, leadDir
	end
	if first then
		return first[1], first[2], first[3], first[4]
	end
	return nil
end

--- Combat slot the rotation leads with this tick. A sorcerer's elemental-stance tier is
--- searched first; other elements only lead when no stance-element slot can cast.
local function pickLeadSlot(player, state, config, hpPercent, manaPercent, t)
	local strict = config and config.strictSkillOrder == true
	local castable = firstCastableByGroup(player, state, combatSlotsOf(config), hpPercent, manaPercent, t)
	for _, tier in ipairs(stanceElementTiers(player, castable)) do
		local slot, area, hits, dir = pickLeadSlotIn(player, state, tier, strict, hpPercent, manaPercent, t)
		if slot then
			return slot, area, hits, dir
		end
	end
	return nil
end

--- Highest-priority ready area spell whose monster-count gate fails from `pos` with
--- every facing: it waits on the caster's position, not on cooldown or mana.
--- Target-centred areas do not depend on the caster tile.
local function positionBlockedAreaSlot(player, state, config, hpPercent, manaPercent, t, pos)
	local slots = combatSlotsOf(config)
	local _, chosen = firstCastableByGroup(player, state, slots, hpPercent, manaPercent, t)
	for _, slot in ipairs(stanceElementOrder(player, slots)) do
		-- A lower step of the same group goes out from here first.
		local lower = chosen[groupKeyOf(slot)]
		if slot.kind == "spell" and not (lower and (lower.step or 1) < (slot.step or 1)) then
			local area = areaAttackOf(slot)
			if
				area
				and area.kind ~= "target"
				and slotShouldFire(slot, hpPercent, manaPercent, player)
				and slotPassesSituationalGates(player, slot)
				and combatSlotWillCast(player, state, slot, t)
				and not monsterCountPasses(slot, (bestAreaHits(player, area, pos)))
			then
				return slot
			end
		end
	end
	return nil
end

--- Best-facing hits for `slot` cast from `pos`, and whether its monster-count gate passes.
function CombatAutomation.areaSlotHitsAt(player, slot, pos)
	local area = areaAttackOf(slot)
	if not area then
		return 0, false
	end
	local hits = bestAreaHits(player, area, pos)
	return hits, monsterCountPasses(slot, hits)
end

--- Position of the expedition anchor this companion forms on (nil for the anchor itself).
local function anchorPosOf(state)
	local anchor = CombatAutomationMovement.directiveAnchor(state)
	return anchor and anchor:getPosition() or nil
end

--- Cave-walk targeting context for a cave run member (expedition or open world), nil
--- outside a cave walk: `{ walking, range, ahead = tile one step along the route, blockerId }`.
local function luringContext(player)
	local run = Cavebot.runOfPlayer(player)
	if not run or not run.cave then
		return nil
	end
	local walking = Cavebot.isWalking(run)
	local blockerId = Cavebot.blockerId(run)
	if not walking and not blockerId then
		return nil
	end
	local ctx = { walking = walking, blockerId = blockerId }
	if walking then
		local ppos = player:getPosition()
		local front = Cavebot.travelFront(run, ppos)
		ctx.range = CombatAutomation.weaponShootRange(player)
		ctx.ahead = front and Position(ppos.x + front[1], ppos.y + front[2], ppos.z) or nil
	end
	return ctx
end

--- Target-centred (runes, diamond arrows, target AoE spells) and directional (waves,
--- beams) attacks the member can aim by picking its target. Caster-centred areas do
--- not depend on the target and are left out.
local function targetAreaAttacks(config)
	local out = {}
	for _, slot in ipairs(combatSlotsOf(config)) do
		local area = slot.enabled ~= false and areaAttackOf(slot) or nil
		if area and (area.kind == "target" or isDirectionalArea(area)) then
			out[#out + 1] = area
		end
	end
	local ammoArea = CombatAutomationConfig.AmmoAreaByTypeId[preferredAmmoTypeId(config)]
	if ammoArea then
		out[#out + 1] = ammoArea
	end
	return out
end

local function countHitsAimedAt(ctx, candidate, area, face)
	local n = 0
	for _, monster in ipairs(ctx.pool) do
		if isInsideSpellArea(ctx.player, candidate, monster, area, ctx.ppos, face) then
			n = n + 1
		end
	end
	return n
end

--- Most monsters any of the member's aimable area attacks hits with `candidate` as
--- the target (directional: facing it; on a diagonal, the better of both facings).
local function bestHitsAimedAt(ctx, candidate, mpos)
	local best = 0
	for _, area in ipairs(ctx.areas) do
		local hits
		if isDirectionalArea(area) then
			local dx, dy = mpos.x - ctx.ppos.x, mpos.y - ctx.ppos.y
			local horizontal = dx > 0 and DIRECTION_EAST or DIRECTION_WEST
			local vertical = dy > 0 and DIRECTION_SOUTH or DIRECTION_NORTH
			if math.abs(dx) > math.abs(dy) then
				hits = countHitsAimedAt(ctx, candidate, area, horizontal)
			elseif math.abs(dy) > math.abs(dx) then
				hits = countHitsAimedAt(ctx, candidate, area, vertical)
			else
				hits = math.max(countHitsAimedAt(ctx, candidate, area, horizontal), countHitsAimedAt(ctx, candidate, area, vertical))
			end
		else
			hits = countHitsAimedAt(ctx, candidate, area)
		end
		best = math.max(best, hits)
	end
	return best
end

--- Auto-target score (TARGET_* in 01_config): focus boss, lure blocker / beside the
--- route ahead, the anchor's 3x3 (the box the party kills in), extra monsters the
--- member's area attacks hit when aimed at it, reach for the stance, attacking me,
--- wounded, and the current target's stickiness. Chebyshev stands in for path length
--- so the per-tick pick needs no A*.
local function targetScore(monster, ctx)
	local cfg = CombatAutomationConfig
	local score = 0
	if ctx.current and ctx.current:getId() == monster:getId() then
		score = score + cfg.TARGET_STICKY_BONUS
	end
	local ppos = ctx.ppos
	local mpos = monster:getPosition()
	if not mpos or mpos.z ~= ppos.z then
		return score
	end
	local dist = tileDistance(ppos, mpos)
	if monsterIsFocusBoss(ctx.player, monster, ctx.session) then
		score = score + cfg.TARGET_BOSS_BONUS
	end
	local lure = ctx.lure
	if lure then
		if lure.blockerId == monster:getId() then
			score = score + cfg.TARGET_BLOCKER_BONUS
		elseif lure.ahead and tileDistance(mpos, lure.ahead) <= 1 then
			score = score + cfg.TARGET_ROUTE_AHEAD_BONUS
		end
	end
	local boxDist = tileDistance(ctx.anchorPos, mpos)
	if boxDist <= 1 then
		score = score + cfg.TARGET_BOX_BONUS
	elseif boxDist == 2 then
		score = score + cfg.TARGET_BOX_NEAR_BONUS
	end
	if #ctx.areas > 0 then
		local hits = bestHitsAimedAt(ctx, monster, mpos)
		if hits > 1 then
			score = score + math.min((hits - 1) * cfg.TARGET_AREA_PER_HIT, cfg.TARGET_AREA_CAP)
		end
	end
	if ctx.melee then
		if dist <= 1 then
			score = score + cfg.TARGET_MELEE_ADJACENT_BONUS
		elseif dist <= 3 then
			score = score + cfg.TARGET_MELEE_NEAR_BONUS
		end
	elseif dist <= ctx.shootRange then
		score = score + cfg.TARGET_RANGED_IN_RANGE_BONUS
	end
	local itsTarget = monster:getTarget()
	if itsTarget and itsTarget:getId() == ctx.player:getId() then
		score = score + cfg.TARGET_ATTACKING_ME_BONUS
	end
	local hp = percentOf(monster:getHealth(), monster:getMaxHealth())
	if hp < cfg.TARGET_FINISH_HP_PERCENT then
		score = score + cfg.TARGET_FINISH_BONUS
	elseif hp < cfg.TARGET_WOUNDED_HP_PERCENT then
		score = score + cfg.TARGET_WOUNDED_BONUS
	end
	return score
end

--- Best monster by targetScore (ties: nearest, then lowest id). While walking the
--- route only what is in weapon range counts, so stragglers behind do not pull the
--- target. Returns best, its score, and the scoring context (to score the current).
local function pickTarget(player, monsters, config, state)
	local ppos = player:getPosition()
	if type(monsters) ~= "table" or #monsters == 0 or not ppos then
		return nil
	end
	local lure = luringContext(player)
	local maxDist = lure and lure.walking and lure.range or nil
	local pool = {}
	for _, monster in ipairs(monsters) do
		if CombatAutomation.isValidAttackTarget(player, monster) and (not maxDist or tileDistance(ppos, monster:getPosition()) <= maxDist) then
			pool[#pool + 1] = monster
		end
	end
	if #pool == 0 then
		return nil
	end
	local ctx = {
		player = player,
		ppos = ppos,
		pool = pool,
		current = player:getTarget(),
		lure = lure,
		anchorPos = anchorPosOf(state) or ppos,
		melee = CombatAutomationConfig.stanceDistanceOf(config) <= 1,
		shootRange = CombatAutomation.weaponShootRange(player),
		areas = targetAreaAttacks(config),
		session = ExpeditionManager.getSessionByPlayer(player) or nil,
		scores = {},
	}
	local best, bestScore, bestDist = nil, nil, nil
	for _, monster in ipairs(pool) do
		local score = targetScore(monster, ctx)
		ctx.scores[monster:getId()] = score
		local d = sortDistanceSquared(ppos, monster:getPosition())
		if not best or score > bestScore or (score == bestScore and (d < bestDist or (d == bestDist and monster:getId() < best:getId()))) then
			best, bestScore, bestDist = monster, score, d
		end
	end
	return best, bestScore, ctx
end

--- True when `candidate` (scored `candidateScore`) should replace `current`: the
--- current carries the sticky bonus, so a switch must beat it by more than that.
local function isBetterTarget(ctx, candidate, candidateScore, current)
	if not candidate then
		return false
	end
	if not current then
		return true
	end
	if candidate:getId() == current:getId() then
		return false
	end
	return candidateScore > (ctx.scores[current:getId()] or targetScore(current, ctx))
end

local function isOnScreen(player, creature)
	return CombatGeo.isInViewport(player:getPosition(), creature:getPosition())
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
	CombatAutomationProtocol.sendAttackTarget(player, creatureId)
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

--- Live on-screen monster that only lost line of sight, for at most TARGET_SIGHT_GRACE_MS.
local function keepThroughSightLoss(player, current, state)
	if not state or not current:isMonster() or current:isRemoved() or current:getHealth() <= 0 or not isOnScreen(player, current) then
		return false
	end
	if player:getInstanceId() ~= current:getInstanceId() then
		return false
	end
	local now = nowMs()
	local lost = state.targetSightLost
	if not lost or lost.id ~= current:getId() then
		state.targetSightLost = { id = current:getId(), at = now }
		return true
	end
	return now - lost.at < (CombatAutomationConfig.TARGET_SIGHT_GRACE_MS or 1000)
end

--- `replacing`: a previous target is dropped (counted as a switch in the metrics).
local function switchTarget(player, state, pick, replacing)
	if replacing then
		ExpeditionMetrics.onTargetSwitch(player)
	end
	player:setTarget(pick)
	syncAutoAttackTarget(player, state, pick)
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
	local current = player:getTarget()
	if current and CombatAutomation.isValidAttackTarget(player, current) and isOnScreen(player, current) then
		if state then
			state.targetSightLost = nil
		end
		-- Live player targets stay sticky (pickTarget is monsters-only).
		if current:isPlayer() then
			syncAutoAttackTarget(player, state, current)
			return current
		end
	elseif current and keepThroughSightLoss(player, current, state) then
		-- Brief line-of-sight break (pillar, corner): keep the target unless a
		-- visible monster is strictly better.
		local pick, pickScore, ctx = pickTarget(player, visibleMonsters(player), config, state)
		if pick and isBetterTarget(ctx, pick, pickScore, current) then
			state.targetSightLost = nil
			switchTarget(player, state, pick, true)
			return pick
		end
		return current
	elseif current then
		if state then
			state.targetSightLost = nil
		end
		player:setTarget(nil)
		current = nil
	end

	-- Retarget only when the pick is strictly better. Equal scores stay sticky so
	-- stance does not thrash between same-distance monsters every tick.
	local pick, pickScore, ctx = pickTarget(player, visibleMonsters(player), config, state)
	if pick and isBetterTarget(ctx, pick, pickScore, current) then
		switchTarget(player, state, pick, current ~= nil)
		return pick
	end
	syncAutoAttackTarget(player, state, current)
	return current
end

--- Before the lead area attack: step one adjacent tile (diagonals included) when that
--- hits strictly more with its best facing, or as many with a directional area when it
--- puts a companion onto an anchor lane (and it is not on one yet); else turn here
--- when another facing hits more.
local function considerAreaStep(player, state, config, hpPercent, manaPercent, t)
	if state.pendingAreaCast or state.skipStanceForAreaCast then
		return
	end
	local ppos = player:getPosition()
	if not ppos then
		return
	end
	local slot, area = pickLeadSlot(player, state, config, hpPercent, manaPercent, t)
	if not slot or not area then
		-- No AoE goes out from here this tick: flag one that would from elsewhere
		-- (CombatAutomationMovement scores its hits when placing ranged casters).
		local blocked = positionBlockedAreaSlot(player, state, config, hpPercent, manaPercent, t, ppos)
		if blocked then
			state.areaBlockedSlotId = blocked.id
			state.areaBlockedAt = t
		end
		return
	end
	local face = player:getDirection()
	local hereFacing = countAreaHits(player, area, ppos, face)
	local hereBest, hereDir = bestAreaHits(player, area, ppos)
	local bestPos, bestCount, bestDir = nil, hereBest, hereDir
	local walking = walkTaskActive(player)
	-- Low HP: retreat positioning owns movement; never step into the pack for a hit.
	local critical = CombatAutomationConfig.isPositionCritical(player)
	-- Expedition anchor walking its route or holding its halt tile: a side step
	-- stalls the walk (step, settle, cast, repath) or leaves the halt tile.
	local luring = state.directive and state.directive.kind == "hold" and state.directive.luring
	-- The player walks themselves (manual control): cast from where they stand.
	local manual = CombatAutomationMovement.isManual(player)
	if not walking and not critical and not luring and not manual then
		local apos = isDirectionalArea(area) and anchorPosOf(state) or nil
		local seekLane = apos ~= nil and not CombatGeo.onAnchorLane(ppos, apos)
		local bestOnLane = false
		for _, off in ipairs(CombatGeo.NEIGHBOUR_OFFSETS) do
			local dest = Position(ppos.x + off[1], ppos.y + off[2], ppos.z)
			if CombatGeo.tileFree(dest, player) and not CombatGeo.fartherFromLeash(player, ppos, dest) then
				local n, dir = bestAreaHits(player, area, dest)
				local onLane = seekLane and CombatGeo.onAnchorLane(dest, apos)
				if n > bestCount or (n > 0 and n == bestCount and onLane and not bestOnLane) then
					bestPos, bestCount, bestDir, bestOnLane = dest, n, dir, onLane
				end
			end
		end
	end
	if bestPos then
		state.pendingAreaCast = {
			x = bestPos.x,
			y = bestPos.y,
			z = bestPos.z,
			dir = bestDir,
			slotId = slot.id,
			untilMs = t + AREA_STEP_MS,
		}
	elseif (hereDir ~= face and hereBest > hereFacing) or (config.strictSkillOrder ~= true and hereBest >= 2) then
		if isDirectionalArea(area) then
			state.areaFace = hereDir
		end
		state.areaCastSlotId = slot.id
	end
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
				autoTarget = { enabled = false, stance = "melee", rangedDistance = 3 },
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

-- ---------------------------------------------------------------------------
-- Equip slots: wear a ring / amulet the player owns at or below triggerPercent HP /
-- mana, until the stat is back at releasePercent; then put back what it replaced.
-- Per body slot the active rule first in bar order wins. Run with AUTO off too.
-- ---------------------------------------------------------------------------

local EQUIP_BODY_SLOTS = { ring = CONST_SLOT_RING, necklace = CONST_SLOT_NECKLACE }

--- `item` is `typeId` or its equipped form (transformEquipTo).
local function isEquipForm(item, typeId)
	if not item then
		return false
	end
	local id = item:getId()
	if id == typeId then
		return true
	end
	local it = ItemType(typeId)
	return it ~= nil and it.getTransformEquipId ~= nil and it:getTransformEquipId() == id
end

--- Unequipped id of a worn item (the id it turns back into in the backpack).
local function unequippedId(item)
	local id = item:getId()
	local it = ItemType(id)
	local back = it and it:getTransformDeEquipId() or 0
	return back > 0 and back or id
end

local function moveToBackpack(player, item)
	local bp = player:getSlotItem(CONST_SLOT_BACKPACK)
	return bp ~= nil and item:moveTo(bp) == true
end

local function setEquipStatus(player, state, slot, owned)
	state.equipStatus = state.equipStatus or {}
	local status = owned and "ok" or "missing"
	if state.equipStatus[slot.id] ~= status then
		state.equipStatus[slot.id] = status
		CombatAutomationProtocol.sendSlotStatus(player, slot.id, status)
	end
end

--- Wear `rule`'s item on `body` (nil rule: release what a rule put there).
--- `state.equipHeld[body]` = { slotId, typeId, restoreId } while a rule owns the slot.
local function applyEquip(player, state, body, rule, t)
	local held = state.equipHeld[body]
	local current = player:getSlotItem(body)
	if held and current and not isEquipForm(current, held.typeId) then
		-- The player changed the slot by hand: it is theirs again.
		state.equipHeld[body] = nil
		held = nil
	end
	if rule and current and isEquipForm(current, rule.equipTypeId) then
		-- Already worn: by hand (left alone) or for another rule (handed over).
		if held and held.slotId ~= rule.id then
			state.equipHeld[body] = { slotId = rule.id, typeId = rule.equipTypeId, restoreId = held.restoreId }
		end
		return
	end
	if not rule and not held then
		return
	end
	local swapMs = CombatAutomationConfig.EQUIP_SWAP_MS or 1000
	if t - (state.equipSwapAt[body] or 0) < swapMs then
		return
	end
	state.equipSwapAt[body] = t

	if rule then
		local item = player:getItemById(rule.equipTypeId, true)
		if not item then
			return
		end
		local restoreId = held and held.restoreId or (current and unequippedId(current)) or nil
		if current and not moveToBackpack(player, current) then
			return
		end
		if item:moveToSlot(player, body) ~= true then
			-- Refused (level / vocation / cap): put the old item back.
			local old = restoreId and player:getItemById(restoreId, true)
			if old then
				old:moveToSlot(player, body)
			end
			return
		end
		state.equipHeld[body] = { slotId = rule.id, typeId = rule.equipTypeId, restoreId = restoreId }
		local name = ItemType(rule.equipTypeId):getName()
		markFired(state, player, rule, "", name, 0, t, false)
		return
	end

	-- Release: the rule item comes off (or already expired) and the replaced item goes back.
	if current and not moveToBackpack(player, current) then
		return
	end
	state.equipHeld[body] = nil
	local restore = held.restoreId and player:getItemById(held.restoreId, true)
	if restore then
		restore:moveToSlot(player, body)
	end
end

local function runEquipRules(player, state, config, hpPercent, manaPercent, t)
	state.equipHeld = state.equipHeld or {}
	state.equipActive = state.equipActive or {}
	state.equipSwapAt = state.equipSwapAt or {}
	local want, any = {}, next(state.equipHeld) ~= nil
	for _, slot in ipairs(config.slots or {}) do
		local entry = slot.kind == "equip" and CombatAutomationConfig.EquipItems[slot.equipTypeId]
		local body = entry and EQUIP_BODY_SLOTS[entry.slot]
		if body then
			any = true
			local pct = slot.triggerStat == "mana" and manaPercent or hpPercent
			local active = false
			if slot.enabled ~= false then
				if state.equipActive[slot.id] then
					active = pct < (slot.releasePercent or 100)
				else
					active = pct <= (slot.triggerPercent or 0)
				end
			end
			state.equipActive[slot.id] = active or nil
			local owned = isEquipForm(player:getSlotItem(body), slot.equipTypeId) or player:getItemById(slot.equipTypeId, true) ~= nil
			setEquipStatus(player, state, slot, owned)
			if active and owned and not want[body] then
				want[body] = slot
			end
		end
	end
	if not any then
		return
	end
	for _, body in pairs(EQUIP_BODY_SLOTS) do
		applyEquip(player, state, body, want[body], t)
	end
end

--- Forget the equip statuses sent so far (the client asked for a full resync).
function CombatAutomation.resetEquipStatus(player)
	local state = player and CombatAutomation.getState(player)
	if state then
		state.equipStatus = nil
	end
end

--- Run one automation tick for the player.
--- AUTO off: clear target and skip attack/rune/support/stance slots; only the healing page still runs.
function CombatAutomation.tick(player)
	if not player then
		return
	end
	local state = CombatAutomation.getState(player)
	local config = state.config

	tickVisibleMonsters = computeVisibleMonsters(player)
	tickCombatSlots = nil
	tickCombatSlots = { config = config, slots = combatSlotsOf(config) }
	local function endTick()
		tickVisibleMonsters = nil
		tickCombatSlots = nil
	end

	-- Soft-despawned: no target, move, or combat casts until respawn.
	if isSoftDespawnedPlayer(player) then
		if player:getTarget() then
			player:setTarget(nil)
		end
		player:setFollowCreature(nil)
		syncAutoAttackTarget(player, state, nil)
		endTick()
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

	local hpPercent = percentOf(player:getHealth(), player:getMaxHealth())
	local manaPercent = percentOf(player:getMana(), player:getMaxMana())
	local t = nowMs()
	resolveAreaStep(player, state, t)
	if autoEnabled then
		considerAreaStep(player, state, config, hpPercent, manaPercent, t)
	end

	-- Positioning after target pick (hold / follow / stance).
	CombatAutomationMovement.tick(player, config)

	-- Paladin distance ammo: equip preferred type; charge gold when inventory is empty.
	ensureAmmo(player, config)

	runEquipRules(player, state, config, hpPercent, manaPercent, t)

	local slots = config.slots
	if type(slots) ~= "table" or #slots == 0 then
		endTick()
		return
	end

	-- Potions: do not stop after the first success — HP and mana pots can both be
	-- eligible in the same tick. Cap one success per restored resource so stacked
	-- HP potions do not all fire together.
	local usedPotionHealth, usedPotionMana = false, false
	local function tryPotionSlot(slot)
		if slotShouldFire(slot, hpPercent, manaPercent, player) then
			local effect = CombatAutomationConfig.PotionEffects[slot.potionTypeId]
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
						return true
					end
				end
			end
		end
		return false
	end

	local supportSlots, sustainSlots = {}, {}
	for _, slot in ipairs(slots) do
		if slot.kind == "potion" then
			sustainSlots[#sustainSlots + 1] = slot
		elseif slot.kind == "spell" and spellRank(slot) < 2 then
			supportSlots[#supportSlots + 1] = slot
			if autoEnabled or runsWithAutoOff(slot) then
				sustainSlots[#sustainSlots + 1] = slot
			end
		end
	end
	table.sort(supportSlots, byPriority)
	table.sort(sustainSlots, byPriority)
	local combatSlots = stanceElementOrder(player, combatSlotsOf(config))

	local attackTarget = player:getTarget()
	if attackTarget then
		CombatGeo.faceToward(player, attackTarget:getPosition())
	end
	if state.areaFace ~= nil and player:getDirection() ~= state.areaFace then
		player:setDirection(state.areaFace)
	end

	local preferredStances = preferredStanceWordsByChannel(supportSlots)

	-- Potions + healing / support / shield in slot priority: a higher-priority heal that
	-- lifts HP above a potion threshold saves that potion this tick.
	-- Multi-action slots: the first step that goes out consumes its group for this tick.
	local groupFired = {}
	for _, slot in ipairs(sustainSlots) do
		local groupKey = groupKeyOf(slot)
		local partyTarget = nil
		local shouldFire = false
		if groupFired[groupKey] then
			-- A lower step of this group already went out.
		elseif slot.kind == "potion" then
			groupFired[groupKey] = tryPotionSlot(slot)
		elseif isPartyHealSlot(slot) then
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
						groupFired[groupKey] = true
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

	if autoEnabled and not state.pendingAreaCast then
		local onlySlot = state.areaCastSlotId
		for _, slot in ipairs((firstCastableByGroup(player, state, combatSlots, hpPercent, manaPercent, t))) do
			if onlySlot and slot.id ~= onlySlot then
				-- Stepped for a specific area attack; do not fire a different one.
			elseif
				slotShouldFire(slot, hpPercent, manaPercent, player)
				and slotHasEnoughMonsters(player, slot)
				and slotPassesSituationalGates(player, slot)
			then
				local castOk = false
				local castArea = areaAttackOf(slot)
				local castHits = castArea and countAreaHits(player, castArea, player:getPosition(), player:getDirection())
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
						local result = tryUseRune(player, slot.runeTypeId, runeAimPosition(player, slot.runeTypeId))
						if result == "cast" then
							local words = runeWords(slot.runeTypeId)
							markFired(state, player, slot, words, words, exhaust, t, false)
							castOk = true
						elseif result == "fail" then
							markCastFailed(state, slot.id, t)
						end
					end
				end
				if castOk and castHits then
					ExpeditionMetrics.onAreaCast(player, castHits)
				end
				-- One successful combat cast per tick, so the slot order decides what goes out.
				if onlySlot or castOk then
					break
				end
			elseif onlySlot then
				break
			end
		end
	end
	state.skipStanceForAreaCast = nil
	state.areaCastSlotId = nil
	state.areaFace = nil

	endTick()
end

local function isHuntFrozen(session)
	return session and session.state == "ended"
end

--- (session, frozen) for the think loop: nil once the player left the expedition area.
local function activeExpeditionSession(player)
	if not player then
		return nil, false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session and isHuntFrozen(session) then
		return session, true
	end
	if not ExpeditionManager.reconcilePresence(player) then
		return nil, false
	end
	if not ExpeditionManager.isInExpedition(player) then
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

--- Driven by playerOnIdleCombatThink (250ms) / playerOnThink (scripts/idleot/expeditions/events.lua).
--- Do not schedule addEvent here — engine think owns cadence.
function CombatAutomation.onThink(player, _interval)
	if not player then
		return
	end
	local state = CombatAutomation.getState(player)
	local session, frozen = activeExpeditionSession(player)
	if not shouldRunLoop(player, state, session, frozen) then
		return
	end
	if state.config then
		CombatAutomation.tick(player)
	end
end
