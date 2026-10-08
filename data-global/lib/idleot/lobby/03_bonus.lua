--- Lobby-exclusive XP boost + prey slots (lobby membership, not party/range).
--- Stored on the lobby record so they move with leadership.
LobbyBonus = LobbyBonus or {}

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
		xpBoost = { timeLeft = 0, percent = LobbyConfig.XP_BOOST_PERCENT },
		buyCount = 1,
		buyDay = IdleUtil.dayKey(),
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

--- Normalize any stored payload (lobby record or parked KV).
function LobbyBonus.normalize(stored)
	local data = defaultBonuses()
	if type(stored) ~= "table" then
		return data
	end
	if type(stored.xpBoost) == "table" then
		data.xpBoost.timeLeft = math.max(0, tonumber(stored.xpBoost.timeLeft) or 0)
		data.xpBoost.percent = tonumber(stored.xpBoost.percent) or LobbyConfig.XP_BOOST_PERCENT
	end
	-- buyCount is the next purchase number; MAX_BUYS + 1 means today's cap is reached.
	if stored.buyDay == data.buyDay then
		data.buyCount = math.max(1, math.min(LobbyConfig.XP_BOOST_MAX_BUYS + 1, tonumber(stored.buyCount) or 1))
	end
	data.lastDrainAt = tonumber(stored.lastDrainAt) or 0
	local prey = indexedValues(stored.prey)
	for i = 1, LobbyConfig.PREY_SLOT_COUNT do
		data.prey[i] = normalizePreySlot(prey[i], i)
	end
	return data
end

--- True when paid timers are still running (worth keeping when a lobby dissolves).
function LobbyBonus.hasActive(recordOrData)
	if type(recordOrData) ~= "table" then
		return false
	end
	local data = recordOrData
	if recordOrData.members ~= nil then
		data = recordOrData.bonuses
	end
	if type(data) ~= "table" then
		return false
	end
	if type(data.xpBoost) == "table" and (tonumber(data.xpBoost.timeLeft) or 0) > 0 then
		return true
	end
	for _, slot in ipairs(indexedValues(data.prey)) do
		if type(slot) == "table" and tostring(slot.state) == STATE_ACTIVE and (tonumber(slot.raceId) or 0) > 0 then
			return true
		end
	end
	return false
end

local function loadBonuses(record)
	return LobbyBonus.normalize(record and record.bonuses)
end

local function saveBonuses(record, data)
	if not record then
		return
	end
	record.bonuses = data
	LobbyStore.save(record)
end

local function hostOf(record)
	return record and Player(record.hostGuid) or nil
end

local function lobbyOf(player)
	return LobbyStore.getForPlayer(player)
end

local function raceName(raceId)
	raceId = tonumber(raceId) or 0
	if raceId <= 0 then
		return ""
	end
	local mtype = MonsterType(raceId)
	if mtype and mtype.getName then
		local ok, name = pcall(function()
			return mtype:getName()
		end)
		if ok and name and name ~= "" then
			return name
		end
	end
	local ids = Game.getBestiaryList(false)
	local names = Game.getBestiaryList(true)
	for i, id in pairs(ids) do
		if tonumber(id) == raceId then
			return tostring(names[i] or "")
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
	for _, raceId in pairs(Game.getBestiaryList(false)) do
		push(raceId)
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
	local blocked = {}
	for _, id in pairs(blacklist or {}) do
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
				preyable = mtype:isPreyable() ~= false
				exclusive = mtype:isPreyExclusive() == true
				exp = tonumber(mtype:experience()) or 1
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

local function activeRaceBlacklist(data)
	local blacklist = {}
	for _, other in ipairs(data.prey) do
		if other.raceId and other.raceId > 0 then
			blacklist[#blacklist + 1] = other.raceId
		end
	end
	return blacklist
end

local function applySlotUnlockRules(record, data)
	local host = hostOf(record)
	local hostPremium = host and host:isPremium() == true or false
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
	-- Slot 3 stays locked until a member with preyThirdSlot opens it; active bonuses run out.
end

local function syncCombatCacheForPlayer(player, data)
	if not player then
		return
	end
	player:clearTeamPreyBonuses()
	if not data then
		return
	end
	for _, slot in ipairs(data.prey or {}) do
		if slot.state == STATE_ACTIVE and slot.raceId and slot.raceId > 0 and slot.bonusTimeLeft > 0 then
			player:setTeamPreyBonus(slot.raceId, slot.bonusType, slot.bonusPercent)
		end
	end
end

--- Push the lobby's team prey into every online member's combat cache.
function LobbyBonus.syncCombatCache(record)
	if not record then
		return
	end
	local data = loadBonuses(record)
	for _, m in ipairs(record.members) do
		local member = Player(m.guid)
		if member then
			syncCombatCacheForPlayer(member, data)
		end
	end
end

--- A player left a lobby: drop that lobby's prey from their combat cache.
function LobbyBonus.clearCombatCache(player)
	if player then
		player:clearTeamPreyBonuses()
	end
end

local function drainTimers(data, now)
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

function LobbyBonus.touchDrain(player)
	local record = lobbyOf(player)
	if not record or not record.bonuses then
		return
	end
	local data = loadBonuses(record)
	if drainTimers(data, os.time()) then
		saveBonuses(record, data)
		LobbyBonus.syncCombatCache(record)
	end
end

local function payGold(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return true
	end
	if not player:removeMoneyBank(amount) then
		return false, "Not enough gold."
	end
	return true
end

local function payPreyCards(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return true
	end
	local have = player:getPreyCards() or 0
	if have < amount then
		return false, "Not enough Prey Wildcard cards."
	end
	if player:usePreyCards(amount) then
		return true
	end
	-- Refuse rather than desync the card balance.
	return false, "Prey card payment unavailable."
end

function LobbyBonus.canManagePreySlot3(player)
	return player ~= nil and player:preyThirdSlot() == true
end

function LobbyBonus.nextXpBoostPrice(data)
	local prices = LobbyConfig.XP_BOOST_PRICES
	local buyCount = math.max(1, math.min(#prices, tonumber(data and data.buyCount) or 1))
	return prices[buyCount] or prices[#prices], buyCount
end

local function configNumber(key, fallback)
	return configManager.getNumber(key) or fallback
end

function LobbyBonus.getWire(player, record)
	record = record or lobbyOf(player)
	if not record then
		return nil
	end
	local data = loadBonuses(record)
	applySlotUnlockRules(record, data)
	local dirty = drainTimers(data, os.time()) and record.bonuses ~= nil

	local slot3Manage = LobbyBonus.canManagePreySlot3(player)
	local isHost = LobbyStore.isHost(record, player)
	local preyWire = {}
	for i, slot in ipairs(data.prey) do
		local locked = slot.state == STATE_LOCKED
		-- Slot 3: an active lobby prey is visible to everyone; otherwise locked without the unlock.
		if i == 3 and not slot3Manage and slot.state ~= STATE_ACTIVE then
			locked = true
		end
		if not locked and slot.state == STATE_SELECTION and #(slot.raceIdList or {}) == 0 then
			local host = hostOf(record)
			local level = (host and host:getLevel()) or player:getLevel() or 1
			slot.raceIdList, slot.raceNames = buildMonsterGrid(level, activeRaceBlacklist(data))
			if #slot.raceIdList == 0 then
				slot.state = STATE_INACTIVE
			end
			dirty = true
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
			raceIdList = locked and {} or slot.raceIdList,
			raceNames = locked and {} or slot.raceNames,
			canManage = (i ~= 3 and not locked and isHost) or (i == 3 and slot3Manage),
			needsPersonalThirdSlot = i == 3 and not slot3Manage,
		}
	end
	if dirty then
		saveBonuses(record, data)
	end

	local price, buyCount = LobbyBonus.nextXpBoostPrice(data)
	local xpActive = (data.xpBoost.timeLeft or 0) > 0
	local mult = LobbyConfig.PREY_PRICE_MULT
	local level = player:getLevel() or 1
	return {
		xpBoost = {
			active = xpActive,
			timeLeft = data.xpBoost.timeLeft or 0,
			percent = data.xpBoost.percent or LobbyConfig.XP_BOOST_PERCENT,
			nextPrice = price,
			buyCount = buyCount,
			maxBuys = LobbyConfig.XP_BOOST_MAX_BUYS,
			canBuy = isHost and not xpActive and (data.buyCount or 1) <= LobbyConfig.XP_BOOST_MAX_BUYS,
		},
		prey = preyWire,
		preyPrices = {
			listRerollGold = mult * level * configNumber(configKeys.PREY_REROLL_PRICE_LEVEL, 200),
			selectCards = mult * configNumber(configKeys.PREY_SELECTION_LIST_PRICE, 5),
			bonusRerollCards = mult * configNumber(configKeys.PREY_BONUS_REROLL_PRICE, 1),
			priceMult = mult,
		},
		canEdit = isHost,
	}
end

local function vocationBaseId(src)
	local voc = src and src:getVocation()
	if not voc then
		return nil
	end
	return tonumber(voc:getBaseId())
end

--- Expected party XP share for the lobby line-up (alts weigh half).
--- Nil when solo: no party forms, so there is no shared experience.
function LobbyBonus.computePartyXpPreview(record)
	local realCount = 0
	local altCount = 0
	local unique = {}
	local uniqueCount = 0
	for _, m in ipairs((record and record.members) or {}) do
		if LobbyStore.isAltEntry(record, m) then
			altCount = altCount + 1
		else
			realCount = realCount + 1
		end
		local src = Player(m.guid) or Game.getOfflinePlayer(m.guid)
		local baseId = vocationBaseId(src)
		if baseId and not unique[baseId] and uniqueCount < 4 then
			unique[baseId] = true
			uniqueCount = uniqueCount + 1
		end
	end

	local n = realCount + altCount
	if n <= 1 then
		return nil
	end
	uniqueCount = math.max(1, uniqueCount)
	local vocBonusTable = LobbyConfig.PARTY_VOCATION_BONUS
	-- At 4 vocations the party bonus is +100%. Each share is
	-- (weight / partySize) * ((vocBonus - 1) / (maxVocBonus - 1)).
	local maxVocBonus = vocBonusTable[4] or 2.00
	local vocBonus = vocBonusTable[uniqueCount] or 1.20
	local weight = realCount + LobbyConfig.ALT_PARTY_WEIGHT * altCount
	local bonusFactor = (vocBonus - 1) / math.max(0.0001, maxVocBonus - 1)
	local shareFraction = (weight / n) * bonusFactor
	return {
		realCount = realCount,
		altCount = altCount,
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

function LobbyBonus.effectiveXpBoost(player)
	local record = lobbyOf(player)
	if not record or not record.bonuses then
		return 0, false
	end
	local data = loadBonuses(record)
	drainTimers(data, os.time())
	if (data.xpBoost.timeLeft or 0) > 0 then
		return data.xpBoost.percent or LobbyConfig.XP_BOOST_PERCENT, true
	end
	return 0, false
end

function LobbyBonus.effectivePrey(player, raceId)
	raceId = tonumber(raceId) or 0
	local record = raceId > 0 and lobbyOf(player) or nil
	if not record or not record.bonuses then
		return nil
	end
	local data = loadBonuses(record)
	drainTimers(data, os.time())
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

--- Stock onGainExperience hook: an active team XP boost replaces the personal one (whose
--- timer pauses). Returns its percent, or nil when the personal boost applies.
function LobbyBonus.teamXpBoostPercent(player)
	local percent, active = LobbyBonus.effectiveXpBoost(player)
	if not active then
		return nil
	end
	LobbyBonus.touchDrain(player)
	return percent
end

local PREY_BONUS_EXPERIENCE = 2
local PREY_BONUS_LOOT = 3

--- Team prey on raceId replaces the personal slot (including a personal bonus of another type).
local function teamPreyPercent(player, raceId, bonusType, personal)
	local teamPrey = LobbyBonus.effectivePrey(player, raceId)
	if not teamPrey then
		return personal(player, raceId)
	end
	LobbyBonus.touchDrain(player)
	return teamPrey.bonusType == bonusType and (teamPrey.bonusPercent or 0) or 0
end

--- Stock onGainExperience hook: experience multiplier percent (100 = no bonus).
function LobbyBonus.preyExperiencePercent(player, raceId)
	return 100 + teamPreyPercent(player, raceId, PREY_BONUS_EXPERIENCE, function(p, race)
		return p:getPreyExperiencePercentage(race) - 100
	end)
end

--- Stock ondroploot_prey hook: prey loot chance percent.
function LobbyBonus.preyLootPercent(player, raceId)
	return teamPreyPercent(player, raceId, PREY_BONUS_LOOT, function(p, race)
		return p:getPreyLootPercentage(race)
	end)
end

--- Store gate for the Lobby XP Boost offer: disabled reason (nil when buyable) and the next price.
function LobbyBonus.canBuyXpBoost(player)
	local record = lobbyOf(player)
	if not record then
		return "You are not in a lobby.", LobbyConfig.XP_BOOST_PRICES[1]
	end
	local data = loadBonuses(record)
	drainTimers(data, os.time())
	local price = LobbyBonus.nextXpBoostPrice(data)
	if not LobbyStore.isHost(record, player) then
		return "Only the lobby host can buy the lobby XP boost.", price
	end
	if (data.xpBoost.timeLeft or 0) > 0 then
		return "Lobby XP boost is already active.", price
	end
	if (data.buyCount or 1) > LobbyConfig.XP_BOOST_MAX_BUYS then
		return "Daily lobby XP boost purchase limit reached.", price
	end
	return nil, price
end

--- Activates the boost (coins are charged by the store after this succeeds).
function LobbyBonus.applyXpBoost(player)
	local reason = LobbyBonus.canBuyXpBoost(player)
	if reason then
		return false, reason
	end
	local record = lobbyOf(player)
	local data = loadBonuses(record)
	applySlotUnlockRules(record, data)
	data.xpBoost.timeLeft = LobbyConfig.XP_BOOST_DURATION_SEC
	data.xpBoost.percent = LobbyConfig.XP_BOOST_PERCENT
	data.buyCount = (data.buyCount or 1) + 1
	data.lastDrainAt = os.time()
	saveBonuses(record, data)
	LobbyBonus.syncCombatCache(record)
	return true
end

local function ensureSlotManageable(player, record, slotIndex, data)
	slotIndex = tonumber(slotIndex) or 0
	if slotIndex < 1 or slotIndex > LobbyConfig.PREY_SLOT_COUNT then
		return false, "Invalid prey slot."
	end
	if slotIndex == 3 and not LobbyBonus.canManagePreySlot3(player) then
		return false, "Unlock Permanent Prey Slot in the store to manage lobby prey slot 3."
	end
	local slot = data.prey[slotIndex]
	if not slot then
		return false, "Invalid prey slot."
	end
	if slotIndex == 2 and slot.state == STATE_LOCKED then
		return false, "Lobby prey slot 2 requires a premium lobby host."
	end
	if slotIndex == 3 and slot.state == STATE_LOCKED then
		slot.state = STATE_INACTIVE
	end
	if slot.state == STATE_LOCKED then
		return false, "That lobby prey slot is locked."
	end
	-- Slot 3: any member with the personal third slot may manage it.
	if slotIndex ~= 3 and not LobbyStore.isHost(record, player) then
		return false, "Only the lobby host can manage that slot."
	end
	return true, slot
end

local function withSlot(player, slotIndex, fn)
	local record = lobbyOf(player)
	if not record then
		return false, "You are not in a lobby."
	end
	local data = loadBonuses(record)
	applySlotUnlockRules(record, data)
	local ok, slotOrErr = ensureSlotManageable(player, record, slotIndex, data)
	if not ok then
		return false, slotOrErr
	end
	local done, err, keepChanges = fn(record, data, slotOrErr)
	if done then
		saveBonuses(record, data)
		LobbyBonus.syncCombatCache(record)
		return true
	end
	if keepChanges then
		saveBonuses(record, data)
	end
	return false, err
end

function LobbyBonus.preyRerollList(player, slotIndex)
	return withSlot(player, slotIndex, function(_, data, slot)
		local price = LobbyConfig.PREY_PRICE_MULT * (player:getLevel() or 1) * configNumber(configKeys.PREY_REROLL_PRICE_LEVEL, 200)
		local paid, err = payGold(player, price)
		if not paid then
			return nil, err
		end
		slot.raceIdList, slot.raceNames = buildMonsterGrid(player:getLevel(), activeRaceBlacklist(data))
		slot.state = STATE_SELECTION
		slot.raceId = 0
		slot.raceName = ""
		slot.bonusTimeLeft = 0
		return true
	end)
end

function LobbyBonus.preySelect(player, slotIndex, raceId)
	raceId = tonumber(raceId) or 0
	return withSlot(player, slotIndex, function(_, data, slot)
		if slot.state ~= STATE_SELECTION and slot.state ~= STATE_INACTIVE then
			return nil, "Prey slot is not ready for selection."
		end
		local found = false
		for _, id in ipairs(slot.raceIdList or {}) do
			if tonumber(id) == raceId then
				found = true
				break
			end
		end
		if not found then
			if #(slot.raceIdList or {}) == 0 then
				slot.raceIdList, slot.raceNames = buildMonsterGrid(player:getLevel(), activeRaceBlacklist(data))
				slot.state = STATE_SELECTION
				return false, "Choose a monster from the new list.", true
			end
			return nil, "That monster is not on the current list."
		end
		-- Confirming a creature from the current list is free (same as personal prey).
		local bonusType = rollBonusType(nil)
		local rarity, percent = rollBonusValue(bonusType, 1)
		slot.raceId = raceId
		slot.raceName = raceName(raceId)
		slot.bonusType = bonusType
		slot.bonusRarity = rarity
		slot.bonusPercent = percent
		slot.bonusTimeLeft = LobbyConfig.PREY_BONUS_TIME_SEC
		slot.state = STATE_ACTIVE
		slot.raceIdList = {}
		slot.raceNames = {}
		if (tonumber(data.lastDrainAt) or 0) == 0 then
			data.lastDrainAt = os.time()
		end
		return true
	end)
end

function LobbyBonus.preyBonusReroll(player, slotIndex)
	return withSlot(player, slotIndex, function(_, _, slot)
		if slot.state ~= STATE_ACTIVE or slot.raceId <= 0 then
			return nil, "No active lobby prey to reroll."
		end
		local cards = LobbyConfig.PREY_PRICE_MULT * configNumber(configKeys.PREY_BONUS_REROLL_PRICE, 1)
		local paid, err = payPreyCards(player, cards)
		if not paid then
			return nil, err
		end
		local bonusType = rollBonusType(slot.bonusType)
		local rarity, percent = rollBonusValue(bonusType, slot.bonusRarity)
		slot.bonusType = bonusType
		slot.bonusRarity = rarity
		slot.bonusPercent = percent
		slot.bonusTimeLeft = LobbyConfig.PREY_BONUS_TIME_SEC
		return true
	end)
end

function LobbyBonus.preyOpenSlot(player, slotIndex)
	return withSlot(player, slotIndex, function(_, data, slot)
		if slot.state == STATE_ACTIVE then
			return true
		end
		if #(slot.raceIdList or {}) == 0 then
			slot.raceIdList, slot.raceNames = buildMonsterGrid(player:getLevel(), activeRaceBlacklist(data))
		end
		if #slot.raceIdList == 0 then
			return nil, "No preyable creatures available for lobby prey."
		end
		slot.state = STATE_SELECTION
		return true
	end)
end

--- Login: drain timers and load the lobby's prey into this member's combat cache.
function LobbyBonus.onMemberLogin(player)
	local record = lobbyOf(player)
	if not record or not record.bonuses then
		LobbyBonus.clearCombatCache(player)
		return
	end
	local data = loadBonuses(record)
	applySlotUnlockRules(record, data)
	drainTimers(data, os.time())
	saveBonuses(record, data)
	syncCombatCacheForPlayer(player, data)
end

--- Park active bonuses on the player when their lobby dissolves.
function LobbyBonus.park(player, record)
	if not player or not record or not LobbyBonus.hasActive(record) then
		return
	end
	local data = loadBonuses(record)
	drainTimers(data, os.time())
	player:kv():set(LobbyConfig.KV_PARKED_BONUSES, JsonParser.encode(data))
end

--- Restore parked bonuses into a lobby this player now hosts (no-op when the lobby has its own).
function LobbyBonus.restoreParked(player, record)
	if not player or not record or LobbyBonus.hasActive(record) then
		return
	end
	local raw = player:kv():get(LobbyConfig.KV_PARKED_BONUSES)
	if type(raw) ~= "string" or raw == "" then
		return
	end
	player:kv():remove(LobbyConfig.KV_PARKED_BONUSES)
	local ok, decoded = pcall(JsonParser.decode, raw)
	if ok and type(decoded) == "table" and LobbyBonus.hasActive(decoded) then
		local data = LobbyBonus.normalize(decoded)
		-- Paused while parked: restart the drain clock now.
		data.lastDrainAt = os.time()
		saveBonuses(record, data)
		LobbyBonus.syncCombatCache(record)
	end
end
