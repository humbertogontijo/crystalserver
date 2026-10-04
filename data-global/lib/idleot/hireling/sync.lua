-- Hireling runtime sync: load DB rows into PLAYER_HIRELINGS and recover lamps.
-- Repairs per-player state when login grant fails.

ProductHirelingSync = ProductHirelingSync or {}

local function hirelingFromResult(resultId, playerId)
	if not Hireling or not resultId then
		return nil
	end
	local hireling = Hireling:new()
	hireling.id = Result.getNumber(resultId, "id")
	hireling.player_id = playerId or Result.getNumber(resultId, "player_id")
	hireling.name = Result.getString(resultId, "name")
	hireling.active = Result.getNumber(resultId, "active")
	hireling.sex = Result.getNumber(resultId, "sex")
	hireling.posx = Result.getNumber(resultId, "posx")
	hireling.posy = Result.getNumber(resultId, "posy")
	hireling.posz = Result.getNumber(resultId, "posz")
	hireling.lookbody = Result.getNumber(resultId, "lookbody")
	hireling.lookfeet = Result.getNumber(resultId, "lookfeet")
	hireling.lookhead = Result.getNumber(resultId, "lookhead")
	hireling.looklegs = Result.getNumber(resultId, "looklegs")
	hireling.looktype = Result.getNumber(resultId, "looktype")
	return hireling
end

function ProductHirelingSync.registerHireling(hireling)
	if not hireling or not hireling.player_id or not hireling.id then
		return false
	end
	if not PLAYER_HIRELINGS then
		return false
	end

	local bucket = PLAYER_HIRELINGS[hireling.player_id]
	if not bucket then
		bucket = {}
		PLAYER_HIRELINGS[hireling.player_id] = bucket
	end

	for _, existing in ipairs(bucket) do
		if existing.id == hireling.id then
			return false
		end
	end

	table.insert(bucket, hireling)
	if HIRELINGS then
		table.insert(HIRELINGS, hireling)
	end
	return true
end

function ProductHirelingSync.loadAllFromDatabase()
	if ProductHirelingSync._loadedAll then
		return
	end
	if not Hireling or not PLAYER_HIRELINGS or not db or not db.storeQuery then
		return
	end

	-- Stock HirelingsInit may have populated memory already.
	if HIRELINGS and #HIRELINGS > 0 then
		ProductHirelingSync._loadedAll = true
		return
	end

	local worldId = configManager.getNumber(configKeys.WORLD_ID)
	local query = string.format(
		"SELECT `ph`.* FROM `player_hirelings` AS `ph` INNER JOIN `players` AS `p` ON `p`.`id` = `ph`.`player_id` WHERE `p`.`world_id` = %d",
		worldId
	)
	local resultId = db.storeQuery(query)
	if not resultId then
		ProductHirelingSync._loadedAll = true
		return
	end

	repeat
		local playerId = Result.getNumber(resultId, "player_id")
		local hireling = hirelingFromResult(resultId, playerId)
		if hireling then
			ProductHirelingSync.registerHireling(hireling)
		end
	until not Result.next(resultId)
	Result.free(resultId)

	ProductHirelingSync._loadedAll = true
	if spawnNPCs and HIRELINGS and #HIRELINGS > 0 then
		spawnNPCs()
	end
end

function ProductHirelingSync.ensurePlayerHirelingsLoaded(player)
	if not player or not player.isPlayer or not player:isPlayer() then
		return false
	end
	if not player.hasHirelings then
		return false
	end
	if player:hasHirelings() then
		return true
	end
	if not db or not db.storeQuery then
		return false
	end

	local guid = player:getGuid()
	local resultId = db.storeQuery(string.format("SELECT * FROM `player_hirelings` WHERE `player_id` = %d", guid))
	if not resultId then
		return false
	end

	repeat
		local hireling = hirelingFromResult(resultId, guid)
		if hireling then
			ProductHirelingSync.registerHireling(hireling)
		end
	until not Result.next(resultId)
	Result.free(resultId)

	return player:hasHirelings()
end

local function playerOwnsHirelingLamp(player, hirelingId)
	if not player or not hirelingId then
		return false
	end
	if player.findHirelingLamp then
		return player:findHirelingLamp(hirelingId) ~= nil
	end
	return false
end

function ProductHirelingSync.tryGrantHirelingLamp(player, hireling)
	if not player or not hireling or not hireling.id then
		return false
	end
	-- Deployed hirelings do not need a lamp item.
	if hireling.active == 1 then
		return true
	end
	if playerOwnsHirelingLamp(player, hireling.id) then
		return true
	end
	if not player.getStoreInbox or not HIRELING_LAMP then
		return false
	end

	local inbox = player:getStoreInbox()
	if not inbox then
		return false
	end
	local inboxItems = inbox:getItems()
	if inboxItems and #inboxItems >= inbox:getMaxCapacity() then
		return false
	end

	local lamp = inbox:addItem(HIRELING_LAMP, 1, INDEX_WHEREEVER, FLAG_NOLIMIT)
	if not lamp then
		return false
	end

	lamp:setAttribute(
		ITEM_ATTRIBUTE_DESCRIPTION,
		"This mysterious lamp summons your very own personal hireling.\nThis item cannot be traded.\nThis magic lamp is the home of "
			.. hireling:getName()
			.. "."
	)
	lamp:setCustomAttribute("Hireling", hireling.id)
	return true
end
