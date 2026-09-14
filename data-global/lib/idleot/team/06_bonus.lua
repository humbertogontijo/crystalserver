--- Team-exclusive XP boost + prey slots (roster membership, not party/range).
TeamBonus = TeamBonus or {}

local BONUS_DAMAGE = 0
local BONUS_DEFENSE = 1
local BONUS_EXPERIENCE = 2
local BONUS_LOOT = 3

local BONUS_NAMES = {
	[BONUS_DAMAGE] = "Damage",
	[BONUS_DEFENSE] = "Defense",
	[BONUS_EXPERIENCE] = "Experience",
	[BONUS_LOOT] = "Loot",
}

local STATE_LOCKED = "locked"
local STATE_INACTIVE = "inactive"
local STATE_SELECTION = "selection"
local STATE_ACTIVE = "active"

local function controllerKv(controller)
	return controller and controller.kv and controller:kv() or nil
end

local function decode(raw)
	if type(raw) == "table" then
		return raw
	end
	if type(raw) == "string" and raw ~= "" and JsonParser and JsonParser.decode then
		local ok, decoded = pcall(JsonParser.decode, raw)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return nil
end

local function encode(tbl)
	if JsonParser and JsonParser.encode then
		return JsonParser.encode(tbl)
	end
	return nil
end

local function emptyPreySlot(index, state)
	return {
		index = index,
		state = state or STATE_LOCKED,
		raceId = 0,
		raceName = "",
		bonusType = BONUS_EXPERIENCE,
		bonusPercent = 0,
		bonusRarity = 1,
		bonusTimeLeft = 0,
		raceIdList = {},
		raceNames = {},
	}
end

local function defaultBonuses()
	return {
		xpBoost = { timeLeft = 0, percent = TeamConfig.XP_BOOST_PERCENT or 50 },
		buyCount = 1,
		lastDrainAt = 0,
		prey = {
			emptyPreySlot(1, STATE_INACTIVE),
			emptyPreySlot(2, STATE_LOCKED),
			emptyPreySlot(3, STATE_LOCKED),
		},
	}
end

local function indexedValues(raw)
	if type(raw) ~= "table" then
		return {}
	end
	if #raw > 0 then
		local out = {}
		for i = 1, #raw do
			out[i] = raw[i]
		end
		return out
	end
	local keys = {}
	for k in pairs(raw) do
		local idx = tonumber(k)
		if idx then
			keys[#keys + 1] = idx
		end
	end
	table.sort(keys)
	local out = {}
	for _, idx in ipairs(keys) do
		out[#out + 1] = raw[idx] or raw[tostring(idx)]
	end
	return out
end

local function normalizePreySlot(raw, index)
	local slot = emptyPreySlot(index, STATE_LOCKED)
	if type(raw) ~= "table" then
		return slot
	end
	slot.state = tostring(raw.state or STATE_LOCKED)
	slot.raceId = tonumber(raw.raceId) or 0
	slot.raceName = tostring(raw.raceName or "")
	slot.bonusType = tonumber(raw.bonusType) or BONUS_EXPERIENCE
	slot.bonusPercent = tonumber(raw.bonusPercent) or 0
	slot.bonusRarity = tonumber(raw.bonusRarity) or 1
	slot.bonusTimeLeft = math.max(0, tonumber(raw.bonusTimeLeft) or 0)
	slot.raceIdList = {}
	slot.raceNames = {}
	for _, id in ipairs(indexedValues(raw.raceIdList)) do
		local raceId = tonumber(id) or 0
		if raceId > 0 then
			slot.raceIdList[#slot.raceIdList + 1] = raceId
		end
	end
	for _, name in ipairs(indexedValues(raw.raceNames)) do
		slot.raceNames[#slot.raceNames + 1] = tostring(name)
	end
	if slot.state == STATE_ACTIVE and (slot.raceId <= 0 or slot.bonusTimeLeft <= 0) then
		slot.state = STATE_INACTIVE
		slot.raceId = 0
		slot.raceName = ""
		slot.bonusTimeLeft = 0
		slot.raceIdList = {}
		slot.raceNames = {}
	end
	return slot
end

local function bonusesPayloadIsEmpty(stored)
	if type(stored) ~= "table" then
		return true
	end
	local xp = stored.xpBoost
	if type(xp) == "table" and (tonumber(xp.timeLeft) or 0) > 0 then
		return false
	end
	local prey = stored.prey
	if type(prey) ~= "table" then
		return true
	end
	for i = 1, TeamConfig.PREY_SLOT_COUNT or 3 do
		local slot = prey[i]
		if type(slot) == "table" then
			if tostring(slot.state) == STATE_ACTIVE and (tonumber(slot.raceId) or 0) > 0 then
				return false
			end
			if type(slot.raceIdList) == "table" then
				local n = 0
				for _ in pairs(slot.raceIdList) do
					n = n + 1
					if n > 0 then
						return false
					end
				end
			end
		end
	end
	return true
end

local function reclaimOrphanedBonuses(controller, kv, stored)
	if not controller or not kv or not TeamStore or not TeamStore.resolvePlayerByGuid then
		return stored
	end
	if not bonusesPayloadIsEmpty(stored) then
		return stored
	end
	local accountId = controller.getAccountId and controller:getAccountId() or 0
	local myGuid = controller:getGuid()
	if not accountId or accountId <= 0 then
		return stored
	end
	local resultId = db.storeQuery(
		"SELECT `id` FROM `players` WHERE `account_id` = "
			.. tonumber(accountId)
			.. " AND `deletion` = 0"
	)
	if not resultId then
		return stored
	end
	repeat
		local guid = Result.getNumber(resultId, "id")
		if guid and guid ~= myGuid then
			local other = TeamStore.resolvePlayerByGuid(guid)
			if other and other.kv then
				local otherKv = other:kv()
				local otherRaw = otherKv and otherKv:get(TeamConfig.KV_BONUSES)
				local otherBonuses = decode(otherRaw)
				local pointsHere = tonumber(TeamStore.getControllerPointer(other) or 0) == myGuid
				if type(otherBonuses) == "table" and pointsHere and not bonusesPayloadIsEmpty(otherBonuses) then
					kv:set(TeamConfig.KV_BONUSES, otherRaw)
					otherKv:remove(TeamConfig.KV_BONUSES)
					Result.free(resultId)
					return otherBonuses
				end
			end
		end
	until not Result.next(resultId)
	Result.free(resultId)
	return stored
end

local function loadBonuses(controller)
	local data = defaultBonuses()
	if not controller then
		return data
	end
	local kv = controllerKv(controller)
	if not kv then
		return data
	end
	local stored = decode(kv:get(TeamConfig.KV_BONUSES))
	stored = reclaimOrphanedBonuses(controller, kv, stored)
	if type(stored) ~= "table" then
		return data
	end
	if type(stored.xpBoost) == "table" then
		data.xpBoost.timeLeft = math.max(0, tonumber(stored.xpBoost.timeLeft) or 0)
		data.xpBoost.percent = tonumber(stored.xpBoost.percent) or (TeamConfig.XP_BOOST_PERCENT or 50)
	end
	data.buyCount = math.max(1, math.min(TeamConfig.XP_BOOST_MAX_BUYS or 5, tonumber(stored.buyCount) or 1))
	data.lastDrainAt = tonumber(stored.lastDrainAt) or 0
	if type(stored.prey) == "table" then
		for i = 1, TeamConfig.PREY_SLOT_COUNT or 3 do
			data.prey[i] = normalizePreySlot(stored.prey[i], i)
		end
	end
	return data
end

local function saveBonuses(controller, data)
	local kv = controllerKv(controller)
	if not kv then
		return false
	end
	local payload = encode(data)
	if not payload then
		return false
	end
	kv:set(TeamConfig.KV_BONUSES, payload)
	return true
end

local function resolveController(player)
	if not player or not TeamStore then
		return nil
	end
	return TeamStore.resolveTeamController(player) or player
end

function TeamBonus.isRosterMember(player)
	if not player or not TeamStore then
		return false
	end
	local controller = resolveController(player)
	if not controller then
		return false
	end
	local myName = player:getName():lower()
	for _, entry in ipairs(TeamStore.getMembers(player) or {}) do
		if entry.name and entry.name:lower() == myName then
			return true
		end
	end
	return false
end

local function foreachOnlineRoster(controller, fn)
	if not controller or not TeamStore or type(fn) ~= "function" then
		return
	end
	for _, entry in ipairs(TeamStore.getMembers(controller) or {}) do
		local name = entry.name
		if name then
			local member = Player(name)
			if member then
				fn(member, entry)
			end
		end
	end
end

local function raceName(raceId)
	raceId = tonumber(raceId) or 0
	if raceId <= 0 then
		return ""
	end
	local mtype = MonsterType and MonsterType(raceId)
	if mtype and mtype.getName then
		local ok, name = pcall(function()
			return mtype:getName()
		end)
		if ok and name and name ~= "" then
			return name
		end
	end
	-- Fallback: scan bestiary names
	if Game and Game.getBestiaryList then
		local ids = Game.getBestiaryList(false) or {}
		local names = Game.getBestiaryList(true) or {}
		for i, id in pairs(ids) do
			if tonumber(id) == raceId then
				return tostring(names[i] or "")
			end
		end
	end
	return ""
end

local function collectBestiaryRaceIds()
	local ids = {}
	local seen = {}
	local function push(raceId)
		raceId = tonumber(raceId) or 0
		if raceId > 0 and not seen[raceId] then
			seen[raceId] = true
			ids[#ids + 1] = raceId
		end
	end
	if Game and Game.getBestiaryList then
		local listed = Game.getBestiaryList(false)
		if type(listed) == "table" then
			for _, raceId in pairs(listed) do
				push(raceId)
			end
		end
		-- Some builds return ids keyed by raceId when called without bool.
		if #ids == 0 then
			listed = Game.getBestiaryList()
			if type(listed) == "table" then
				for k, v in pairs(listed) do
					if type(v) == "number" then
						push(v)
					elseif type(k) == "number" and type(v) == "string" then
						push(k)
					end
				end
			end
		end
	end
	return ids
end

local function rollBonusType(previous)
	local pick = math.random(BONUS_DAMAGE, BONUS_LOOT)
	if previous ~= nil and pick == previous then
		pick = (pick + 1) % 4
	end
	return pick
end

local function rollBonusValue(bonusType, previousRarity)
	local rarity = tonumber(previousRarity) or 1
	if rarity >= 9 then
		rarity = 10
	else
		rarity = math.random(rarity + 1, 10)
	end
	local percent
	if bonusType == BONUS_DAMAGE then
		percent = 2 * rarity + 5
	elseif bonusType == BONUS_DEFENSE then
		percent = 2 * rarity + 10
	else
		percent = 3 * rarity + 10
	end
	return rarity, percent
end

local function buildMonsterGrid(level, blacklist)
	local out = {}
	local names = {}
	blacklist = blacklist or {}
	local blocked = {}
	for _, id in pairs(blacklist) do
		blocked[tonumber(id) or 0] = true
	end
	local ids = collectBestiaryRaceIds()
	if #ids == 0 then
		return out, names
	end
	level = tonumber(level) or 1
	local stageOne, stageTwo, stageThree, stageFour
	local levelStage = math.floor(level / 100)
	if levelStage == 0 then
		stageOne, stageTwo, stageThree, stageFour = 3, 3, 2, 1
	elseif levelStage <= 2 then
		stageOne, stageTwo, stageThree, stageFour = 1, 3, 3, 2
	elseif levelStage <= 4 then
		stageOne, stageTwo, stageThree, stageFour = 1, 2, 3, 3
	else
		stageOne, stageTwo, stageThree, stageFour = 1, 1, 3, 4
	end
	local tries = 0
	while #out < 9 and tries < 400 do
		tries = tries + 1
		local raceId = tonumber(ids[math.random(1, #ids)]) or 0
		if raceId > 0 and not blocked[raceId] then
			blocked[raceId] = true
			local mtype = MonsterType(raceId)
			local ok = false
			local stars = 1
			local preyable = true
			local exclusive = false
			local exp = 1
			if mtype then
				if mtype.isPreyable then
					preyable = mtype:isPreyable() ~= false
				end
				if mtype.isPreyExclusive then
					exclusive = mtype:isPreyExclusive() == true
				end
				if mtype.experience then
					exp = tonumber(mtype:experience()) or 1
				end
				if mtype.BestiaryStars then
					stars = tonumber(mtype:BestiaryStars()) or 1
				end
			end
			if preyable and not exclusive and exp > 0 then
				if stageOne > 0 and stars <= 1 then
					ok = true
					stageOne = stageOne - 1
				elseif stageTwo > 0 and stars == 2 then
					ok = true
					stageTwo = stageTwo - 1
				elseif stageThree > 0 and stars == 3 then
					ok = true
					stageThree = stageThree - 1
				elseif stageFour > 0 and stars >= 4 then
					ok = true
					stageFour = stageFour - 1
				elseif tries >= 40 or (#out + (400 - tries) < 9) then
					-- Prefer stage match, but always fill the 9-slot grid eventually.
					ok = true
				end
			end
			if ok then
				out[#out + 1] = raceId
				names[#names + 1] = raceName(raceId)
			end
		end
	end
	return out, names
end

local function applySlotUnlockRules(controller, data)
	local hostPremium = false
	if controller and controller.isPremium then
		hostPremium = controller:isPremium() == true
	end
	local slot2 = data.prey[2]
	if slot2 then
		if hostPremium then
			if slot2.state == STATE_LOCKED then
				slot2.state = STATE_INACTIVE
			end
		elseif slot2.state ~= STATE_ACTIVE then
			slot2.state = STATE_LOCKED
			slot2.raceId = 0
			slot2.raceName = ""
			slot2.bonusTimeLeft = 0
			slot2.raceIdList = {}
			slot2.raceNames = {}
		end
	end
	-- Slot 3 stays locked for management unless a roster member has preyThirdSlot.
	-- Active bonuses keep running until expiry.
	local slot3 = data.prey[3]
	if slot3 and slot3.state == STATE_LOCKED then
		-- leave locked until someone with unlock opens/rerolls
	elseif slot3 and slot3.state ~= STATE_ACTIVE and slot3.state ~= STATE_SELECTION and slot3.state ~= STATE_INACTIVE then
		slot3.state = STATE_LOCKED
	end
end

local function syncCombatCacheForPlayer(player, data)
	if not player then
		return
	end
	if player.clearTeamPreyBonuses then
		player:clearTeamPreyBonuses()
	end
	if not data or not TeamBonus.isRosterMember(player) then
		return
	end
	if not player.setTeamPreyBonus then
		return
	end
	for _, slot in ipairs(data.prey or {}) do
		if slot.state == STATE_ACTIVE and slot.raceId and slot.raceId > 0 and slot.bonusTimeLeft > 0 then
			player:setTeamPreyBonus(slot.raceId, slot.bonusType, slot.bonusPercent)
		end
	end
end

function TeamBonus.syncCombatCache(controller)
	controller = controller or nil
	if not controller then
		return
	end
	local data = loadBonuses(controller)
	foreachOnlineRoster(controller, function(member)
		syncCombatCacheForPlayer(member, data)
	end)
end

local function drainTeamTimers(controller, data, now)
	now = now or os.time()
	local last = tonumber(data.lastDrainAt) or 0
	if last <= 0 then
		data.lastDrainAt = now
		return false
	end
	local elapsed = now - last
	if elapsed < 60 then
		return false
	end
	local minutes = math.floor(elapsed / 60)
	if minutes <= 0 then
		return false
	end
	data.lastDrainAt = last + minutes * 60
	local changed = false
	if data.xpBoost and (data.xpBoost.timeLeft or 0) > 0 then
		data.xpBoost.timeLeft = math.max(0, data.xpBoost.timeLeft - minutes * 60)
		changed = true
	end
	for _, slot in ipairs(data.prey or {}) do
		if slot.state == STATE_ACTIVE and (slot.bonusTimeLeft or 0) > 0 then
			slot.bonusTimeLeft = math.max(0, slot.bonusTimeLeft - minutes * 60)
			if slot.bonusTimeLeft <= 0 then
				slot.state = STATE_SELECTION
				slot.raceId = 0
				slot.raceName = ""
				slot.bonusPercent = 0
			end
			changed = true
		end
	end
	return changed
end

function TeamBonus.touchDrain(player)
	if not player or not TeamBonus.isRosterMember(player) then
		return
	end
	local controller = resolveController(player)
	if not controller then
		return
	end
	local data = loadBonuses(controller)
	if drainTeamTimers(controller, data, os.time()) then
		saveBonuses(controller, data)
		TeamBonus.syncCombatCache(controller)
	end
end

local function payCoins(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return true
	end
	if player.canRemoveCoins and player.removeTransferableCoinsBalance then
		if not player:canRemoveCoins(amount) then
			return false, "Not enough Tibia Coins."
		end
		if not player:removeTransferableCoinsBalance(amount) then
			return false, "Failed to charge Tibia Coins."
		end
		return true
	end
	if player.getTransferableCoins and player.removeTransferableCoins then
		if (player:getTransferableCoins() or 0) < amount then
			return false, "Not enough Tibia Coins."
		end
		player:removeTransferableCoins(amount)
		return true
	end
	return false, "Coin payment unavailable."
end

local function payGold(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return true
	end
	if player.removeMoneyBank then
		if not player:removeMoneyBank(amount) then
			return false, "Not enough gold."
		end
		return true
	end
	return false, "Gold payment unavailable."
end

local function payPreyCards(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return true
	end
	local have = player.getPreyCards and player:getPreyCards() or 0
	if have < amount then
		return false, "Not enough Prey Wildcard cards."
	end
	if player.usePreyCards then
		if not player:usePreyCards(amount) then
			return false, "Not enough Prey Wildcard cards."
		end
		return true
	end
	-- Fallback: not available — refuse rather than desync card balance.
	return false, "Prey card payment unavailable."
end

function TeamBonus.canManagePreySlot3(player)
	if not player then
		return false
	end
	if player.preyThirdSlot then
		return player:preyThirdSlot() == true
	end
	return false
end

function TeamBonus.nextXpBoostPrice(data)
	local prices = TeamConfig.XP_BOOST_PRICES or { 60, 90, 180, 360, 720 }
	local buyCount = math.max(1, math.min(#prices, tonumber(data and data.buyCount) or 1))
	return prices[buyCount] or prices[#prices], buyCount
end

function TeamBonus.getWire(player)
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	drainTeamTimers(controller, data, os.time())
	saveBonuses(controller, data)

	local slot3Manage = TeamBonus.canManagePreySlot3(player)
	local preyWire = {}
	for i, slot in ipairs(data.prey) do
		local locked = slot.state == STATE_LOCKED
		-- Slot 3: always show an active team prey to everyone. Without personal
		-- third-slot unlock, non-active states stay locked (store unlock CTA).
		if i == 3 and not slot3Manage and slot.state ~= STATE_ACTIVE then
			locked = true
		end
		-- Never ship an empty selection grid; regenerate once onto the team controller.
		if not locked and slot.state == STATE_SELECTION and #(slot.raceIdList or {}) == 0 then
			local blacklist = {}
			for _, other in ipairs(data.prey) do
				if other.raceId and other.raceId > 0 then
					blacklist[#blacklist + 1] = other.raceId
				end
			end
			local level = (controller and controller.getLevel and controller:getLevel()) or (player:getLevel() or 1)
			slot.raceIdList, slot.raceNames = buildMonsterGrid(level, blacklist)
			if #(slot.raceIdList or {}) == 0 then
				slot.state = STATE_INACTIVE
			end
			saveBonuses(controller, data)
		end
		preyWire[#preyWire + 1] = {
			index = i,
			state = locked and STATE_LOCKED or slot.state,
			raceId = slot.raceId,
			raceName = slot.raceName,
			bonusType = slot.bonusType,
			bonusName = BONUS_NAMES[slot.bonusType] or "Bonus",
			bonusPercent = slot.bonusPercent,
			bonusRarity = slot.bonusRarity,
			bonusTimeLeft = slot.bonusTimeLeft,
			raceIdList = (locked and {}) or slot.raceIdList,
			raceNames = (locked and {}) or slot.raceNames,
			canManage = (i ~= 3 and not locked) or (i == 3 and slot3Manage),
			-- Keep unlock CTA visible even while an active team prey is shown.
			needsPersonalThirdSlot = i == 3 and not slot3Manage,
		}
	end

	local price, buyCount = TeamBonus.nextXpBoostPrice(data)
	local xpActive = (data.xpBoost.timeLeft or 0) > 0
	local mult = TeamConfig.PREY_PRICE_MULT or 2
	local perLevel = configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_REROLL_PRICE_LEVEL) or 200
	local listPrice = configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_SELECTION_LIST_PRICE) or 5
	local bonusPrice = configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_BONUS_REROLL_PRICE) or 1
	local level = player:getLevel() or 1
	return {
		xpBoost = {
			active = xpActive,
			timeLeft = data.xpBoost.timeLeft or 0,
			percent = data.xpBoost.percent or (TeamConfig.XP_BOOST_PERCENT or 50),
			nextPrice = price,
			buyCount = buyCount,
			maxBuys = TeamConfig.XP_BOOST_MAX_BUYS or 5,
			canBuy = (not xpActive) and buyCount <= (TeamConfig.XP_BOOST_MAX_BUYS or 5),
		},
		prey = preyWire,
		preyPrices = {
			listRerollGold = mult * level * perLevel,
			selectCards = mult * listPrice,
			bonusRerollCards = mult * bonusPrice,
			priceMult = mult,
		},
		canEdit = TeamStore and TeamStore.canEditTeam and TeamStore.canEditTeam(player) or false,
	}
end

local function vocationBaseId(src)
	if not src or not src.getVocation then
		return nil
	end
	local voc = src:getVocation()
	if not voc then
		return nil
	end
	if voc.getBaseId then
		return tonumber(voc:getBaseId())
	end
	if voc.getId then
		return tonumber(voc:getId())
	end
	return nil
end

function TeamBonus.computePartyXpPreview(player)
	local members = (TeamStore and TeamStore.getMembers and TeamStore.getMembers(player)) or {}
	local realCount = 0
	local companionCount = 0
	local unique = {}
	local uniqueCount = 0

	for _, entry in ipairs(members) do
		local name = entry.name
		if name then
			local controller = resolveController(player)
			local isHost = controller and name:lower() == controller:getName():lower()
			local online = Player(name)
			local isCompanion = false
			if online and TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(online) then
				isCompanion = true
			elseif not isHost and entry.kind == TeamConfig.KIND_COMPANION then
				isCompanion = true
			end

			if isCompanion then
				companionCount = companionCount + 1
			else
				realCount = realCount + 1
			end

			local offline = (not online) and Game.getOfflinePlayer and Game.getOfflinePlayer(name) or nil
			local src = online or offline
			local baseId = vocationBaseId(src)
			if baseId and not unique[baseId] and uniqueCount < 4 then
				unique[baseId] = true
				uniqueCount = uniqueCount + 1
			end
		end
	end

	local n = realCount + companionCount
	if n <= 0 then
		n = 1
		realCount = 1
	end
	if uniqueCount < 1 then
		uniqueCount = 1
	end
	local vocBonusTable = TeamConfig.PARTY_VOCATION_BONUS or { [1] = 1.20, [2] = 1.35, [3] = 1.70, [4] = 2.00 }
	-- At 4 vocations the party bonus is +100%. Each share is:
	--   (weight / partySize) * ((vocBonus - 1) / (maxVocBonus - 1))
	-- so 1 real + 3 companions => 2.5/4 * 100% = 62.5%.
	local maxVocBonus = vocBonusTable[4] or 2.00
	if n <= 1 then
		return {
			realCount = realCount,
			companionCount = companionCount,
			partySize = 1,
			uniqueVocations = uniqueCount,
			vocBonus = 1,
			weight = 1,
			effectiveMult = 1,
			shareFraction = 1,
			sharePercent = 100,
			idealFourSharePercent = 100,
			allRealSharePercent = 100,
		}
	end
	local vocBonus = vocBonusTable[uniqueCount] or 1.20
	local weight = realCount + (TeamConfig.COMPANION_PARTY_WEIGHT or 0.5) * companionCount
	local bonusFactor = (vocBonus - 1) / math.max(0.0001, maxVocBonus - 1)
	local shareFraction = (weight / n) * bonusFactor

	return {
		realCount = realCount,
		companionCount = companionCount,
		partySize = n,
		uniqueVocations = uniqueCount,
		vocBonus = vocBonus,
		weight = weight,
		effectiveMult = vocBonus * (weight / n),
		shareFraction = shareFraction,
		sharePercent = math.floor(shareFraction * 1000 + 0.5) / 10,
		idealFourSharePercent = 100,
		allRealSharePercent = math.floor(bonusFactor * 1000 + 0.5) / 10,
	}
end

function TeamBonus.effectiveXpBoost(player)
	if not player or not TeamBonus.isRosterMember(player) then
		return 0, false
	end
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	drainTeamTimers(controller, data, os.time())
	if (data.xpBoost.timeLeft or 0) > 0 then
		return data.xpBoost.percent or (TeamConfig.XP_BOOST_PERCENT or 50), true
	end
	return 0, false
end

function TeamBonus.effectivePrey(player, raceId)
	raceId = tonumber(raceId) or 0
	if raceId <= 0 or not player or not TeamBonus.isRosterMember(player) then
		return nil
	end
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	drainTeamTimers(controller, data, os.time())
	for _, slot in ipairs(data.prey or {}) do
		if slot.state == STATE_ACTIVE and slot.raceId == raceId and (slot.bonusTimeLeft or 0) > 0 then
			return {
				bonusType = slot.bonusType,
				bonusPercent = slot.bonusPercent,
				raceId = raceId,
			}
		end
	end
	return nil
end

function TeamBonus.hasTeamPreyForRace(player, raceId)
	return TeamBonus.effectivePrey(player, raceId) ~= nil
end

function TeamBonus.buyXpBoost(player)
	if not player then
		return false, "Invalid player."
	end
	if not TeamStore.canEditTeam(player) then
		return false, "Only the team host can buy the team XP boost."
	end
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	if (data.xpBoost.timeLeft or 0) > 0 then
		return false, "Team XP boost is already active."
	end
	local maxBuys = TeamConfig.XP_BOOST_MAX_BUYS or 5
	if (data.buyCount or 1) > maxBuys then
		return false, "Daily team XP boost purchase limit reached."
	end
	local price = TeamBonus.nextXpBoostPrice(data)
	local ok, err = payCoins(player, price)
	if not ok then
		return false, err
	end
	data.xpBoost.timeLeft = TeamConfig.XP_BOOST_DURATION_SEC or 3600
	data.xpBoost.percent = TeamConfig.XP_BOOST_PERCENT or 50
	data.buyCount = (data.buyCount or 1) + 1
	data.lastDrainAt = os.time()
	saveBonuses(controller, data)
	TeamBonus.syncCombatCache(controller)
	return true
end

local function ensureSlotManageable(player, slotIndex, data)
	slotIndex = tonumber(slotIndex) or 0
	if slotIndex < 1 or slotIndex > (TeamConfig.PREY_SLOT_COUNT or 3) then
		return false, "Invalid prey slot."
	end
	if slotIndex == 3 and not TeamBonus.canManagePreySlot3(player) then
		return false, "Unlock Permanent Prey Slot in the store to manage team prey slot 3."
	end
	local slot = data.prey[slotIndex]
	if not slot then
		return false, "Invalid prey slot."
	end
	if slotIndex == 2 and slot.state == STATE_LOCKED then
		return false, "Team prey slot 2 requires a premium team host."
	end
	if slotIndex == 3 and slot.state == STATE_LOCKED then
		slot.state = STATE_INACTIVE
	end
	if slot.state == STATE_LOCKED then
		return false, "That team prey slot is locked."
	end
	if not TeamStore.canEditTeam(player) and slotIndex ~= 3 then
		return false, "Only the team host can manage that slot."
	end
	-- Slot 3: any roster member with personal third slot may manage.
	if slotIndex == 3 and not TeamBonus.isRosterMember(player) then
		return false, "You are not on this team."
	end
	return true, slot
end

function TeamBonus.preyRerollList(player, slotIndex)
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	local ok, slotOrErr = ensureSlotManageable(player, slotIndex, data)
	if not ok then
		return false, slotOrErr
	end
	local slot = slotOrErr
	local mult = TeamConfig.PREY_PRICE_MULT or 2
	local perLevel = configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_REROLL_PRICE_LEVEL) or 200
	local price = mult * (player:getLevel() or 1) * perLevel
	local paid, err = payGold(player, price)
	if not paid then
		return false, err
	end
	local blacklist = {}
	for _, other in ipairs(data.prey) do
		if other.raceId and other.raceId > 0 then
			blacklist[#blacklist + 1] = other.raceId
		end
	end
	slot.raceIdList, slot.raceNames = buildMonsterGrid(player:getLevel(), blacklist)
	slot.state = STATE_SELECTION
	slot.raceId = 0
	slot.raceName = ""
	slot.bonusTimeLeft = 0
	saveBonuses(controller, data)
	TeamBonus.syncCombatCache(controller)
	return true
end

function TeamBonus.preySelect(player, slotIndex, raceId)
	raceId = tonumber(raceId) or 0
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	local ok, slotOrErr = ensureSlotManageable(player, slotIndex, data)
	if not ok then
		return false, slotOrErr
	end
	local slot = slotOrErr
	if slot.state ~= STATE_SELECTION and slot.state ~= STATE_INACTIVE then
		return false, "Prey slot is not ready for selection."
	end
	local found = false
	for _, id in ipairs(slot.raceIdList or {}) do
		if tonumber(id) == raceId then
			found = true
			break
		end
	end
	if not found then
		-- Allow opening selection with a free first grid if empty.
		if #(slot.raceIdList or {}) == 0 then
			local blacklist = {}
			for _, other in ipairs(data.prey) do
				if other.raceId and other.raceId > 0 then
					blacklist[#blacklist + 1] = other.raceId
				end
			end
			slot.raceIdList, slot.raceNames = buildMonsterGrid(player:getLevel(), blacklist)
			slot.state = STATE_SELECTION
			saveBonuses(controller, data)
			return false, "Choose a monster from the new list."
		end
		return false, "That monster is not on the current list."
	end
	-- Confirming a creature from the current list is free (same as personal prey
	-- MONSTERSELECTION). Wildcard costs apply only to pick-specific / bonus reroll.
	local bonusType = rollBonusType(nil)
	local rarity, percent = rollBonusValue(bonusType, 1)
	slot.raceId = raceId
	slot.raceName = raceName(raceId)
	slot.bonusType = bonusType
	slot.bonusRarity = rarity
	slot.bonusPercent = percent
	slot.bonusTimeLeft = TeamConfig.PREY_BONUS_TIME_SEC
		or (configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_BONUS_TIME))
		or 7200
	slot.state = STATE_ACTIVE
	slot.raceIdList = {}
	slot.raceNames = {}
	if data.lastDrainAt == 0 then
		data.lastDrainAt = os.time()
	end
	saveBonuses(controller, data)
	TeamBonus.syncCombatCache(controller)
	return true
end

function TeamBonus.preyBonusReroll(player, slotIndex)
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	local ok, slotOrErr = ensureSlotManageable(player, slotIndex, data)
	if not ok then
		return false, slotOrErr
	end
	local slot = slotOrErr
	if slot.state ~= STATE_ACTIVE or slot.raceId <= 0 then
		return false, "No active team prey to reroll."
	end
	local mult = TeamConfig.PREY_PRICE_MULT or 2
	local bonusPrice = configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_BONUS_REROLL_PRICE) or 1
	local paid, err = payPreyCards(player, mult * bonusPrice)
	if not paid then
		return false, err
	end
	local bonusType = rollBonusType(slot.bonusType)
	local rarity, percent = rollBonusValue(bonusType, slot.bonusRarity)
	slot.bonusType = bonusType
	slot.bonusRarity = rarity
	slot.bonusPercent = percent
	slot.bonusTimeLeft = TeamConfig.PREY_BONUS_TIME_SEC
		or (configManager and configManager.getNumber and configManager.getNumber(configKeys.PREY_BONUS_TIME))
		or 7200
	saveBonuses(controller, data)
	TeamBonus.syncCombatCache(controller)
	return true
end

function TeamBonus.preyOpenSlot(player, slotIndex)
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	local ok, slotOrErr = ensureSlotManageable(player, slotIndex, data)
	if not ok then
		return false, slotOrErr
	end
	local slot = slotOrErr
	if slot.state == STATE_ACTIVE then
		return true
	end
	if #(slot.raceIdList or {}) == 0 then
		local blacklist = {}
		for _, other in ipairs(data.prey) do
			if other.raceId and other.raceId > 0 then
				blacklist[#blacklist + 1] = other.raceId
			end
		end
		slot.raceIdList, slot.raceNames = buildMonsterGrid(player:getLevel(), blacklist)
	end
	if #(slot.raceIdList or {}) == 0 then
		return false, "No preyable creatures available for team prey."
	end
	slot.state = STATE_SELECTION
	saveBonuses(controller, data)
	return true
end

function TeamBonus.onMemberLogin(player)
	if not player then
		return
	end
	-- Real UI clients must not keep the headless-companion mark (blocks UI opcodes).
	-- Controller pointer stays in TeamStore KV; TeamManager.onBecameHeadless restores the mark.
	local isUiClient = false
	if player.isHeadless and player:isHeadless() then
		isUiClient = false
	elseif player.getProtocolVersion and player:getProtocolVersion() > 0 then
		isUiClient = true
	else
		local client = player.getClient and player:getClient() or nil
		local version = type(client) == "table" and tonumber(client.version) or nil
		isUiClient = version and version > 0
	end
	if isUiClient and TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player) then
		player:setStorageValue(TeamConfig.STORAGE_COMPANION_CONTROLLER, -1)
	end
	if not TeamBonus.isRosterMember(player) then
		if player.clearTeamPreyBonuses then
			player:clearTeamPreyBonuses()
		end
		return
	end
	local controller = resolveController(player)
	local data = loadBonuses(controller)
	applySlotUnlockRules(controller, data)
	drainTeamTimers(controller, data, os.time())
	saveBonuses(controller, data)
	syncCombatCacheForPlayer(player, data)
end
