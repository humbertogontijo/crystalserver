QuestsManager = QuestsManager or {}

local JOIN_STOR = JOIN_STOR or 100157
local QUESTSTORAGE_BASE = QUESTSTORAGE_BASE or 1500
local KILLSSTORAGE_BASE = KILLSSTORAGE_BASE or 65000
local REPEATSTORAGE_BASE = REPEATSTORAGE_BASE or 48950
local POINTSSTORAGE = POINTSSTORAGE or 2500

-- Non-Grizzly board → active storage key (stage 0 = hunting).
local KITNO_BOARD_STORAGE = {
	Budrik = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.BudrikMinos
	end,
	Lugri = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.LugriNecromancers
	end,
	Gabel = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.GreenDjinnTask
	end,
	Malor = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.BlueDjinnTask
	end,
	RaymondStriker = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.PirateTask
	end,
	DanielSteelsoul = function(taskId)
		local map = {
			[1] = Storage.Quest.U8_5.KillingInTheNameOf.TrollTask,
			[2] = Storage.Quest.U8_5.KillingInTheNameOf.GoblinTask,
			[3] = Storage.Quest.U8_5.KillingInTheNameOf.RotwormTask,
			[4] = Storage.Quest.U8_5.KillingInTheNameOf.CyclopsTask,
		}
		return map[taskId]
	end,
}

local KITNO_BOARD_KILL_COUNT = {
	Budrik = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.MinotaurCount
	end,
	Lugri = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.NecromancerCount
	end,
	Gabel = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.GreenDjinnCount
	end,
	Malor = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.BlueDjinnCount
	end,
	RaymondStriker = function()
		return Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.PirateCount
	end,
	DanielSteelsoul = function(taskId)
		local map = {
			[1] = Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.TrollCount,
			[2] = Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.GoblinCount,
			[3] = Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.RotwormCount,
			[4] = Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.CyclopsCount,
		}
		return map[taskId]
	end,
}

local function killCounterBase()
	if Storage and Storage.Quest and Storage.Quest.U8_5 and Storage.Quest.U8_5.KillingInTheNameOf then
		return Storage.Quest.U8_5.KillingInTheNameOf.MonsterKillCount.KillCount
	end
	return 42179
end

local function ensureKitnoJoined(player)
	if player:getStorageValue(JOIN_STOR) < 1 then
		player:setStorageValue(JOIN_STOR, 1)
	end
end

local function payKitnoRewards(player, task)
	if not task or type(task.rewards) ~= "table" then
		return
	end
	local skipAchievement = type(task.bossName) == "string" and task.bossName ~= ""
	local pointsRate = configManager.getNumber(configKeys.RATE_KILLING_IN_THE_NAME_OF_POINTS) or 1
	for _, reward in ipairs(task.rewards) do
		local rtype = reward.type
		local value = reward.value
		if rtype == "exp" and value and value[1] then
			player:addExperience(value[1], true)
		elseif rtype == "money" and value and value[1] then
			player:addMoney(value[1])
		elseif rtype == "points" and value and value[1] then
			local cur = math.max(0, player:getStorageValue(POINTSSTORAGE))
			player:setStorageValue(POINTSSTORAGE, cur + math.floor(value[1] * pointsRate))
		elseif rtype == "item" and value and value[1] then
			player:addItem(value[1], value[2] or 1)
		elseif rtype == "storage" and value and value[1] then
			player:setStorageValue(value[1], value[3] or 1)
			if value[2] then
				player:setStorageValue(value[2], value[4] or 0)
			end
		elseif rtype == "achievement" and value and value[1] then
			-- Paw & Fur boss tasks unlock an exclusive solo expedition instead.
			if not skipAchievement then
				player:addAchievement(value[1])
			end
		end
	end
end

local function kitnoTaskTable(entry)
	if not tasks or not entry then
		return nil
	end
	local board = tasks[entry.board]
	return board and board[entry.taskId] or nil
end

local function kitnoProgress(player, entry)
	local task = kitnoTaskTable(entry)
	if not task then
		return 0, entry.killsRequired or 0, QuestsConfig.STATUS_LOCKED
	end

	if entry.board == "GrizzlyAdams" then
		local state = player:getStorageValue(QUESTSTORAGE_BASE + entry.taskId)
		local kills = math.max(0, player:getStorageValue(killCounterBase() + entry.taskId))
		if state >= 2 or (task.norepeatable and player:getStorageValue(REPEATSTORAGE_BASE + entry.taskId) > 0 and state <= 0) then
			if state >= 2 or (task.norepeatable and player:getStorageValue(REPEATSTORAGE_BASE + entry.taskId) > 0) then
				return kills, task.killsRequired, QuestsConfig.STATUS_DONE
			end
		end
		if state > 0 and state < 2 then
			if kills >= task.killsRequired then
				return kills, task.killsRequired, QuestsConfig.STATUS_READY
			end
			return kills, task.killsRequired, QuestsConfig.STATUS_ACTIVE
		end
		local level = player:getLevel()
		if task.level and (level < task.level[1] or level > task.level[2]) then
			return 0, task.killsRequired, QuestsConfig.STATUS_LOCKED
		end
		return 0, task.killsRequired, QuestsConfig.STATUS_AVAILABLE
	end

	-- Other boards use dedicated storages (0 = active, 1+ = done stages for some).
	local getter = KITNO_BOARD_STORAGE[entry.board]
	local killGetter = KITNO_BOARD_KILL_COUNT[entry.board]
	if not getter or not killGetter then
		return 0, task.killsRequired, QuestsConfig.STATUS_LOCKED
	end
	local stor = getter(entry.taskId)
	local killStor = killGetter(entry.taskId)
	if not stor or not killStor then
		return 0, task.killsRequired, QuestsConfig.STATUS_LOCKED
	end
	local state = player:getStorageValue(stor)
	local kills = math.max(0, player:getStorageValue(killStor))
	if state == -1 or state == nil then
		state = -1
	end
	-- Lugri uses 0 and 3 as active stages; most boards use 0 = hunting, >=1 done.
	if entry.board == "Lugri" then
		if state == 0 or state == 3 then
			if kills >= task.killsRequired then
				return kills, task.killsRequired, QuestsConfig.STATUS_READY
			end
			return kills, task.killsRequired, QuestsConfig.STATUS_ACTIVE
		end
		if state > 0 and state ~= 3 then
			return kills, task.killsRequired, QuestsConfig.STATUS_DONE
		end
		return 0, task.killsRequired, QuestsConfig.STATUS_AVAILABLE
	end
	if state == 0 then
		if kills >= task.killsRequired then
			return kills, task.killsRequired, QuestsConfig.STATUS_READY
		end
		return kills, task.killsRequired, QuestsConfig.STATUS_ACTIVE
	end
	if state > 0 then
		return kills, task.killsRequired, QuestsConfig.STATUS_DONE
	end
	local level = player:getLevel()
	if task.level and (level < task.level[1] or level > task.level[2]) then
		return 0, task.killsRequired, QuestsConfig.STATUS_LOCKED
	end
	return 0, task.killsRequired, QuestsConfig.STATUS_AVAILABLE
end

local function spikeProgress(player, entry)
	local main = entry.storageMain
	local daily = entry.storageDaily
	local required = entry.killsRequired or 7
	local now = os.time()
	if daily and player:getStorageValue(daily) > now then
		local kills = math.max(0, player:getStorageValue(main))
		return kills, required, QuestsConfig.STATUS_DONE
	end
	local state = player:getStorageValue(main)
	if state == -1 or state < 0 then
		return 0, required, QuestsConfig.STATUS_AVAILABLE
	end
	local kills = math.max(0, state)
	if kills >= required then
		return kills, required, QuestsConfig.STATUS_READY
	end
	return kills, required, QuestsConfig.STATUS_ACTIVE
end

local function afbProgress(player, entry)
	local stor = entry.storage
	local state = player:getStorageValue(stor)
	if state >= 2 then
		return 1, 1, QuestsConfig.STATUS_DONE
	end
	local count = player:getItemCount(entry.itemId) or 0
	if state == 1 then
		if count >= (entry.itemCount or 1) then
			return count, entry.itemCount or 1, QuestsConfig.STATUS_READY
		end
		return count, entry.itemCount or 1, QuestsConfig.STATUS_ACTIVE
	end
	-- Auto-start AFB if not started.
	return count, entry.itemCount or 1, QuestsConfig.STATUS_AVAILABLE
end

local function outfitProgress(player, entry)
	if entry.requiresOutfit then
		local male = player:hasOutfit(entry.lookTypeMale or 0)
		local female = player:hasOutfit(entry.lookTypeFemale or 0)
		if not male and not female then
			return 0, 1, QuestsConfig.STATUS_LOCKED
		end
		if player:hasOutfit(entry.lookTypeMale or 0, entry.addon or 0)
			or player:hasOutfit(entry.lookTypeFemale or 0, entry.addon or 0) then
			return 1, 1, QuestsConfig.STATUS_DONE
		end
	elseif entry.storageMission and player:getStorageValue(entry.storageMission) >= 2 then
		if player:hasOutfit(entry.lookTypeMale or 0, entry.addon or 0)
			or player:hasOutfit(entry.lookTypeFemale or 0, entry.addon or 0) then
			return 1, 1, QuestsConfig.STATUS_DONE
		end
	end

	local haveAll = true
	local haveAny = false
	local totalNeed = 0
	local totalHave = 0
	for _, it in ipairs(entry.items or {}) do
		local have = player:getItemCount(it.itemId) or 0
		totalNeed = totalNeed + it.count
		totalHave = totalHave + math.min(have, it.count)
		if have < it.count then
			haveAll = false
		else
			haveAny = true
		end
	end
	if haveAll then
		return totalHave, totalNeed, QuestsConfig.STATUS_READY
	end
	if haveAny or totalHave > 0 then
		return totalHave, totalNeed, QuestsConfig.STATUS_ACTIVE
	end
	return 0, totalNeed, QuestsConfig.STATUS_AVAILABLE
end

local function dragonProgress(player, entry)
	local counter = entry.storageCounter
	local kills = math.max(0, player:getStorageValue(counter))
	local required = entry.killsRequired or 50
	if kills >= required then
		return kills, required, QuestsConfig.STATUS_READY
	end
	if kills > 0 then
		return kills, required, QuestsConfig.STATUS_ACTIVE
	end
	return 0, required, QuestsConfig.STATUS_AVAILABLE
end

local function arenaSpecForEntry(entry)
	if not entry or not QuestArena or not QuestArena.buildSvargrondSpec then
		return nil
	end
	return QuestArena.buildSvargrondSpec(entry.arenaId)
end

local function arenaProgress(player, entry)
	local spec = arenaSpecForEntry(entry)
	local required = entry.killsRequired or 10
	if not spec or not spec.storages then
		return 0, required, QuestsConfig.STATUS_LOCKED
	end
	local stor = spec.storages
	local arenaId = stor.arenaId or entry.arenaId or 1
	local curArena = player:getStorageValue(stor.arena)
	if curArena < 1 then
		curArena = 1
	end

	local rewardsDone = ChestGrant
		and ChestGrant.allClaimed
		and ChestGrant.allClaimed(player, entry.rewardUids or spec.rewardUids)
	local completed = (stor.questLog and player:getStorageValue(stor.questLog) >= 2)
		or (stor.doorAccess and player:getStorageValue(stor.doorAccess) >= 1)
		or (curArena > arenaId)

	if completed then
		if rewardsDone then
			return required, required, QuestsConfig.STATUS_DONE
		end
		return required, required, QuestsConfig.STATUS_READY
	end

	if curArena < arenaId then
		return 0, required, QuestsConfig.STATUS_LOCKED
	end
	if curArena > arenaId then
		return required, required, rewardsDone and QuestsConfig.STATUS_DONE or QuestsConfig.STATUS_READY
	end

	local pit = player:getStorageValue(stor.pitDoor)
	if pit >= 1 and pit <= 10 then
		-- PitDoor N means N-1 victories so far (stock: starts at 1).
		local kills = math.max(0, pit - 1)
		return kills, required, QuestsConfig.STATUS_ACTIVE
	end
	if pit > 10 then
		return required, required, QuestsConfig.STATUS_READY
	end
	return 0, required, QuestsConfig.STATUS_AVAILABLE
end

function QuestsManager.getProgress(player, entry)
	if not player or not entry then
		return 0, 0, QuestsConfig.STATUS_LOCKED
	end
	if entry.handler == "kitno" then
		return kitnoProgress(player, entry)
	elseif entry.handler == "spike" then
		return spikeProgress(player, entry)
	elseif entry.handler == "afb" then
		return afbProgress(player, entry)
	elseif entry.handler == "outfit" then
		return outfitProgress(player, entry)
	elseif entry.handler == "dragon_hunt" then
		return dragonProgress(player, entry)
	elseif entry.handler == "arena" then
		return arenaProgress(player, entry)
	end
	return 0, 0, QuestsConfig.STATUS_LOCKED
end

local function findHuntIdForHint(hint)
	if not hint or not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return nil
	end
	local needle = tostring(hint):lower()
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if not entry.exclusiveKitno and not entry.exclusiveArena then
			local name = tostring(entry.name or ""):lower()
			if name == needle or name:find(needle, 1, true) then
				return entry.id
			end
			if type(entry.creatures) == "table" then
				for _, c in ipairs(entry.creatures) do
					local cname = tostring(c.name or c):lower()
					if cname == needle or cname:find(needle, 1, true) then
						return entry.id
					end
				end
			end
		end
	end
	return nil
end

local function creatureIdForHint(hint)
	if not hint or not CreatureInfo or not CreatureInfo.get then
		return nil
	end
	local info = CreatureInfo.get(hint)
	if info then
		local id = tonumber(info.creatureId)
		if id and id > 0 then
			return id
		end
	end
	return nil
end

local function creatureIdForEntry(entry)
	if not entry then
		return nil
	end
	if entry.huntHint then
		local id = creatureIdForHint(entry.huntHint)
		if id then
			return id
		end
	end
	if entry.bossName then
		local info = CreatureInfo and CreatureInfo.get and CreatureInfo.get(entry.bossName)
		if info then
			local id = tonumber(info.creatureId)
			if id and id > 0 then
				return id
			end
		end
	end
	if type(entry.creatures) == "table" then
		for _, name in ipairs(entry.creatures) do
			local id = creatureIdForHint(name)
			if id then
				return id
			end
		end
	end
	return nil
end

local function normalizeRequirementItems(entry)
	local out = {}
	if not entry then
		return out
	end
	if entry.itemId then
		out[#out + 1] = {
			itemId = tonumber(entry.itemId) or 0,
			count = tonumber(entry.itemCount) or 1,
		}
	end
	if type(entry.items) == "table" then
		for _, it in ipairs(entry.items) do
			local itemId = tonumber(it.itemId or it[1]) or 0
			local count = tonumber(it.count or it[2]) or 1
			if itemId > 0 then
				out[#out + 1] = { itemId = itemId, count = count }
			end
		end
	end
	return out
end

local function pushReward(out, kind, value, itemId, count)
	out[#out + 1] = {
		kind = kind,
		value = value,
		itemId = itemId,
		count = count,
	}
end

local function normalizeRewards(entry)
	local out = {}
	if not entry then
		return out
	end

	if entry.handler == "kitno" then
		local task = kitnoTaskTable(entry)
		if task and type(task.rewards) == "table" then
			local bossName = task.bossName or entry.bossName
			for _, reward in ipairs(task.rewards) do
				local rtype = reward.type
				local value = reward.value
				if rtype == "exp" and value and value[1] then
					pushReward(out, "exp", tonumber(value[1]) or 0)
				elseif rtype == "money" and value and value[1] then
					pushReward(out, "money", tonumber(value[1]) or 0)
				elseif rtype == "points" and value and value[1] then
					pushReward(out, "points", tonumber(value[1]) or 0)
				elseif rtype == "item" and value and value[1] then
					pushReward(out, "item", nil, tonumber(value[1]) or 0, tonumber(value[2]) or 1)
				elseif rtype == "achievement" and value and value[1] then
					if bossName and bossName ~= "" then
						-- Replaced by exclusive solo boss unlock.
						pushReward(out, "solo_boss", tostring(bossName))
					else
						pushReward(out, "achievement", tostring(value[1]))
					end
				end
			end
			if bossName and bossName ~= "" then
				local hasSolo = false
				for _, r in ipairs(out) do
					if r.kind == "solo_boss" then
						hasSolo = true
						break
					end
				end
				if not hasSolo then
					pushReward(out, "solo_boss", tostring(bossName))
				end
			end
		end
		return out
	end

	if entry.handler == "spike" or entry.handler == "afb" then
		if entry.reportExp then
			pushReward(out, "exp", tonumber(entry.reportExp) or 0)
		end
		return out
	end

	if entry.handler == "outfit" then
		pushReward(out, "addon", entry.addon or 0)
		return out
	end

	if entry.handler == "dragon_hunt" then
		pushReward(out, "exp", 5000)
		pushReward(out, "loot", "random armor")
		return out
	end

	if entry.handler == "arena" then
		local uids = entry.rewardUids
		if ChestGrant and ChestGrant.listRewards and uids then
			for _, r in ipairs(ChestGrant.listRewards(uids)) do
				out[#out + 1] = r
			end
		end
		local spec = arenaSpecForEntry(entry)
		if spec and spec.trophy and spec.trophy.itemId then
			pushReward(out, "item", nil, tonumber(spec.trophy.itemId) or 0, 1)
		end
		return out
	end

	if entry.reportExp then
		pushReward(out, "exp", tonumber(entry.reportExp) or 0)
	end
	return out
end

function QuestsManager.listForPlayer(player, filterKind)
	QuestsKitnoBoss.registerExpeditions()
	QuestArena.registerExpeditions()
	local out = {}
	for _, entry in ipairs(QuestsCatalog.all()) do
		if not filterKind or entry.kind == filterKind then
			local progress, required, status = QuestsManager.getProgress(player, entry)
			local bossHuntId = nil
			if entry.handler == "kitno" and entry.bossName and QuestsKitnoBoss then
				local id = QuestsKitnoBoss.expeditionIdForTaskId(entry.taskId)
				if id and QuestsKitnoBoss.isUnlocked(player, id) then
					bossHuntId = id
				end
			end
			local huntId = findHuntIdForHint(entry.huntHint)
			if entry.handler == "arena" and QuestArena and QuestArena.expeditionIdForArena then
				huntId = QuestArena.expeditionIdForArena(entry.arenaId) or huntId
			end
			local row = {
				id = entry.id,
				kind = entry.kind,
				pack = entry.pack,
				name = entry.name,
				description = entry.description,
				progress = progress,
				required = required,
				status = status,
				huntId = huntId,
				huntHint = entry.huntHint,
				bossName = entry.bossName,
				bossHuntId = bossHuntId,
				creatureId = creatureIdForEntry(entry),
				items = normalizeRequirementItems(entry),
				rewards = normalizeRewards(entry),
			}
			if entry.handler == "arena" and ChestGrant and ChestGrant.pendingChoices then
				local uids = entry.rewardUids
				local spec = arenaSpecForEntry(entry)
				uids = uids or (spec and spec.rewardUids)
				local pending = ChestGrant.pendingChoices(player, uids)
				if #pending > 0 then
					row.rewardChoices = pending
				end
			end
			if entry.lookTypeMale or entry.lookTypeFemale then
				row.lookType = entry.lookTypeMale or entry.lookTypeFemale
				row.lookTypeFemale = entry.lookTypeFemale
				row.addon = entry.addon
			end
			out[#out + 1] = row
		end
	end
	return out
end

function QuestsManager.accept(player, entryId)
	local entry = QuestsCatalog.get(entryId)
	if not entry then
		return false, "Unknown quest."
	end
	local _, _, status = QuestsManager.getProgress(player, entry)
	if status == QuestsConfig.STATUS_LOCKED then
		return false, "This quest is locked."
	end
	if status == QuestsConfig.STATUS_DONE then
		return false, "Already completed."
	end
	if status == QuestsConfig.STATUS_ACTIVE or status == QuestsConfig.STATUS_READY then
		return false, "Already in progress."
	end

	if entry.handler == "kitno" then
		ensureKitnoJoined(player)
		local task = kitnoTaskTable(entry)
		if not task then
			return false, "Task data missing."
		end
		if entry.board == "GrizzlyAdams" then
			if player.canStartTask and not player:canStartTask(task.raceName, tasks.GrizzlyAdams) then
				return false, "You cannot start this task."
			end
			player:setStorageValue(QUESTSTORAGE_BASE + entry.taskId, 1)
			player:setStorageValue(killCounterBase() + entry.taskId, 0)
			return true, "Task accepted."
		end
		local getter = KITNO_BOARD_STORAGE[entry.board]
		local killGetter = KITNO_BOARD_KILL_COUNT[entry.board]
		local stor = getter and getter(entry.taskId)
		local killStor = killGetter and killGetter(entry.taskId)
		if not stor or not killStor then
			return false, "Task storage missing."
		end
		player:setStorageValue(stor, 0)
		player:setStorageValue(killStor, 0)
		return true, "Task accepted."
	end

	if entry.handler == "spike" then
		local daily = entry.storageDaily
		if daily and player:getStorageValue(daily) > os.time() then
			return false, "This Spike task is on cooldown."
		end
		player:setStorageValue(entry.storageMain, 0)
		return true, "Spike task accepted."
	end

	if entry.handler == "afb" then
		local AFB = Storage.Quest.U8_6.AFathersBurden
		if player:getStorageValue(AFB.Status) < 1 then
			player:setStorageValue(AFB.Status, 1)
			player:setStorageValue(AFB.Progress, 0)
			player:setStorageValue(AFB.Sinew, 1)
			player:setStorageValue(AFB.Wood, 1)
			player:setStorageValue(AFB.Cloth, 1)
			player:setStorageValue(AFB.Silk, 1)
			player:setStorageValue(AFB.Crystal, 1)
			player:setStorageValue(AFB.Root, 1)
			player:setStorageValue(AFB.Iron, 1)
			player:setStorageValue(AFB.Scale, 1)
			if AFB.QuestLog then
				player:setStorageValue(AFB.QuestLog, 1)
			end
		elseif player:getStorageValue(entry.storage) < 1 then
			player:setStorageValue(entry.storage, 1)
		end
		return true, "Quest accepted."
	end

	if entry.handler == "outfit" then
		if entry.storageMission and player:getStorageValue(entry.storageMission) < 1 then
			player:setStorageValue(entry.storageMission, 1)
		end
		return true, "Collect the required items."
	end

	if entry.handler == "dragon_hunt" then
		-- Counter starts at first kill; accept is a no-op join.
		local skel = Storage.Quest.U10_80.TheGreatDragonHunt.WarriorSkeleton
		if skel and player:getStorageValue(skel) < 1 then
			player:setStorageValue(skel, 1)
		end
		return true, "Hunt dragons and dragon lords."
	end

	if entry.handler == "arena" then
		local spec = arenaSpecForEntry(entry)
		if not spec or not spec.storages then
			return false, "Arena data missing."
		end
		local stor = spec.storages
		local arenaId = stor.arenaId or entry.arenaId
		local fee = tonumber(entry.fee or spec.fee) or 0
		local curArena = player:getStorageValue(stor.arena)
		if curArena < 1 then
			player:setStorageValue(stor.arena, arenaId)
			curArena = arenaId
		end
		if curArena ~= arenaId then
			return false, "This arena difficulty is not available."
		end
		if player:getStorageValue(stor.pitDoor) >= 1 then
			return false, "You already paid the fee — use Hunt to enter the arena."
		end
		if fee > 0 and not player:removeMoneyBank(fee) then
			return false, "You do not have enough money."
		end
		player:setStorageValue(stor.pitDoor, 1)
		if stor.questLog and player:getStorageValue(stor.questLog) ~= 1 then
			player:setStorageValue(stor.questLog, 1)
		end
		-- Unlock exclusive expedition row for Hunt.
		ExpeditionProtocol.sendCatalog(player)
		return true, string.format("Fee paid. Use Hunt to start the %s arena.", spec.name or "arena")
	end

	return false, "Cannot accept."
end

function QuestsManager.report(player, entryId, opts)
	local entry = QuestsCatalog.get(entryId)
	if not entry then
		return false, "Unknown quest."
	end
	local progress, required, status = QuestsManager.getProgress(player, entry)
	if status ~= QuestsConfig.STATUS_READY and not (entry.handler == "outfit" and status == QuestsConfig.STATUS_READY) then
		if status == QuestsConfig.STATUS_ACTIVE then
			return false, string.format("Progress %d/%d.", progress, required)
		end
		return false, "Nothing to report."
	end

	if entry.handler == "kitno" then
		local task = kitnoTaskTable(entry)
		if not task then
			return false, "Task data missing."
		end
		if entry.board == "GrizzlyAdams" then
			payKitnoRewards(player, task)
			local repeats = math.max(0, player:getStorageValue(REPEATSTORAGE_BASE + entry.taskId))
			player:setStorageValue(REPEATSTORAGE_BASE + entry.taskId, repeats + 1)
			player:setStorageValue(QUESTSTORAGE_BASE + entry.taskId, task.norepeatable and 2 or 0)
			player:setStorageValue(killCounterBase() + entry.taskId, 0)
			local bossHuntId = nil
			if task.bossName and QuestsKitnoBoss and QuestsKitnoBoss.unlock then
				bossHuntId = QuestsKitnoBoss.unlock(player, entry.taskId)
				if bossHuntId then
					return true, string.format(
						"Task reported. Exclusive solo expedition unlocked: %s.",
						QuestsKitnoBoss.resolveMonsterName(task.bossName) or task.bossName
					), bossHuntId
				end
			end
			return true, "Task reported."
		end
		local getter = KITNO_BOARD_STORAGE[entry.board]
		local stor = getter and getter(entry.taskId)
		payKitnoRewards(player, task)
		if stor then
			player:setStorageValue(stor, 1)
		end
		return true, "Task reported."
	end

	if entry.handler == "spike" then
		-- Fame storage lives under SpikeTaskQuest.Constants after quests/load.lua
		-- remaps the datapack's flat Spike_Fame_Points key.
		local spike = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest
		local fame = (spike and ((spike.Constants and spike.Constants.Spike_Fame_Points) or spike.Spike_Fame_Points)) or 44313
		player:setStorageValue(fame, math.max(0, player:getStorageValue(fame)) + 1)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You have received a fame point.")
		player:addExperience(entry.reportExp or 1000, true)
		player:setStorageValue(entry.storageMain, -1)
		if entry.storageDaily then
			player:setStorageValue(entry.storageDaily, os.time() + 72000)
		end
		return true, "Spike task reported."
	end

	if entry.handler == "afb" then
		local need = entry.itemCount or 1
		if not player:removeItem(entry.itemId, need) then
			return false, "Missing required item."
		end
		player:setStorageValue(entry.storage, 2)
		local AFB = Storage.Quest.U8_6.AFathersBurden
		local progressVal = math.max(0, player:getStorageValue(AFB.Progress)) + 1
		player:setStorageValue(AFB.Progress, progressVal)
		player:addExperience(entry.reportExp or 2500, true)
		if progressVal >= 8 then
			player:setStorageValue(AFB.Status, 2)
			player:addItem(11701, 1)
			player:addExperience(8000, true)
			return true, "All presents delivered!"
		end
		return true, "Item delivered."
	end

	if entry.handler == "outfit" then
		for _, it in ipairs(entry.items or {}) do
			if (player:getItemCount(it.itemId) or 0) < it.count then
				return false, "Missing required items."
			end
		end
		for _, it in ipairs(entry.items or {}) do
			if not player:removeItem(it.itemId, it.count) then
				return false, "Could not remove items."
			end
		end
		if entry.lookTypeMale then
			player:addOutfitAddon(entry.lookTypeMale, entry.addon or 0)
		end
		if entry.lookTypeFemale then
			player:addOutfitAddon(entry.lookTypeFemale, entry.addon or 0)
		end
		if entry.storageMission then
			player:setStorageValue(entry.storageMission, 2)
		end
		return true, "Addon granted."
	end

	if entry.handler == "dragon_hunt" then
		local lootOptions = { 3386, 2493, 2494, 2495, 2496, 2497 }
		local itemId = lootOptions[math.random(1, #lootOptions)]
		player:addItem(itemId, 1)
		player:setStorageValue(entry.storageCounter, 0)
		local ach = entry.storageAchievement
		if ach then
			player:setStorageValue(ach, math.max(0, player:getStorageValue(ach)) + 1)
		end
		player:addExperience(5000, true)
		return true, "Dragon hoard claimed."
	end

	if entry.handler == "arena" then
		local spec = arenaSpecForEntry(entry)
		if not spec then
			return false, "Arena data missing."
		end
		local uids = entry.rewardUids or spec.rewardUids
		if not ChestGrant or not ChestGrant.grantUids then
			return false, "Reward system unavailable."
		end
		local pending = ChestGrant.pendingChoices and ChestGrant.pendingChoices(player, uids) or {}
		local rewardUid = opts and tonumber(opts.rewardUid) or nil
		if #pending > 0 and not rewardUid then
			return false, "Choose a reward."
		end
		local granted, errors = ChestGrant.grantUids(player, uids, { rewardUid = rewardUid })
		if #errors > 0 then
			local msg = errors[1] or "Could not grant rewards."
			if granted > 0 then
				msg = string.format("%s (%d reward(s) were granted.)", msg, granted)
			end
			return false, msg
		end
		-- Trophy (stock tile reward).
		local trophy = spec.trophy
		if trophy and trophy.itemId and trophy.storage and player:getStorageValue(trophy.storage) < 1 then
			local item = player:addItem(trophy.itemId, 1)
			if item and trophy.desc then
				item:setAttribute(ITEM_ATTRIBUTE_DESCRIPTION, string.format(trophy.desc, player:getName()))
			end
			player:setStorageValue(trophy.storage, 1)
			granted = granted + 1
		end
		if granted == 0 and ChestGrant.allClaimed(player, uids) then
			return true, "Rewards already claimed."
		end
		return true, string.format("Arena rewards claimed (%d).", granted)
	end

	return false, "Cannot report."
end

--- Credit expedition kills for Spike / Dragon Hunt (stock scripts are map-gated).
function QuestsManager.onMonsterKill(player, monsterName)
	if not player or not monsterName then
		return
	end
	local name = monsterName:lower()

	for _, entry in ipairs(QuestsCatalog.all()) do
		if entry.handler == "spike" then
			local _, _, status = spikeProgress(player, entry)
			if status == QuestsConfig.STATUS_ACTIVE and entry.creatures then
				for _, c in ipairs(entry.creatures) do
					if name == c:lower() then
						local cur = math.max(0, player:getStorageValue(entry.storageMain))
						if cur < (entry.killsRequired or 7) then
							player:setStorageValue(entry.storageMain, cur + 1)
						end
						break
					end
				end
			end
		elseif entry.handler == "dragon_hunt" and entry.creatures then
			for _, c in ipairs(entry.creatures) do
				if name == c:lower() then
					local cur = math.max(0, player:getStorageValue(entry.storageCounter))
					player:setStorageValue(entry.storageCounter, cur + 1)
					break
				end
			end
		end
	end
end

IdleEvents.on("monster.died", function(monster, _corpse, _killer, mostDamageKiller)
	if not Instance.isPrivate(monster:getInstanceId()) then
		return
	end
	local name = monster:getName()
	onDeathForParty(monster, mostDamageKiller, function(_, player)
		QuestsManager.onMonsterKill(player, name)
	end)
end, "QuestsManager")
