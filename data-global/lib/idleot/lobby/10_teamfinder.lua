-- Bridge public idle lobbies ↔ CIP Team Finder (0x2C/0x2D).
-- Channel open/close for Assemble/Unlist lives in C++; this module upserts listings
-- from lobby state and joins players into LobbyManager on Team Finder accept.
LobbyTeamFinder = LobbyTeamFinder or {}

local VOCATIONS_ALL = 31 -- druid|knight|paladin|sorcerer|monk

local function online(guid)
	return Alts.findOnlinePlayerByGuid(guid)
end

local function cipHuntIds(catalog)
	local regionId = tonumber(catalog and catalog.id) or 0
	local info = regionId > 0 and Game.getSubareaInfo(regionId) or nil
	local cip = info and tonumber(info.cipId) or 0
	if (cip <= 0 or cip > 65535) and type(catalog.center) == "table" then
		local c = catalog.center
		info = Game.getSubareaAt(Position(c.x, c.y, c.z))
		cip = info and tonumber(info.cipId) or 0
	end
	if cip <= 0 or cip > 65535 then
		return nil, nil
	end
	-- Parent area is optional on the wire; Join Team resolves the name from huntArea.
	return 0, cip
end

--- Build Team Finder activity fields from a lobby expedition, or nil when not advertisable.
function LobbyTeamFinder.activityOpts(record)
	if not record or (record.expeditionId or "") == "" then
		return nil
	end
	local catalog = ExpeditionConfig.getById(record.expeditionId, record.role)
	if not catalog then
		return nil
	end
	local opts = {
		minLevel = record.levelMin,
		maxLevel = record.levelMax,
		vocationIDs = VOCATIONS_ALL,
		teamSlots = record.size,
		freeSlots = math.max(1, record.size - #record.members),
		timestamp = os.time(),
	}
	local kind = catalog.kind
	if kind == "boss" or record.role == "boss" then
		local bossId = tonumber(record.creatureId) or tonumber(catalog.creatureId) or 0
		if bossId <= 0 or bossId > 65535 then
			return nil
		end
		opts.teamType = 1
		opts.bossID = bossId
	elseif kind == "quest" or record.role == "quest" then
		local questId = tonumber(catalog.cipQuestId) or 0
		if questId <= 0 or questId > 65535 then
			return nil
		end
		opts.teamType = 3
		opts.questID = questId
	else
		local huntType, huntArea = cipHuntIds(catalog)
		if not huntArea then
			return nil
		end
		opts.teamType = 2
		opts.huntType = huntType
		opts.huntArea = huntArea
	end
	return opts
end

local function catalogFromActivity(opts)
	opts = opts or {}
	local teamType = tonumber(opts.teamType) or 0
	if teamType == 1 then
		local bossId = tonumber(opts.bossID) or 0
		if bossId <= 0 then
			return nil
		end
		for _, entry in ipairs(ExpeditionConfig.Catalog or {}) do
			if (entry.kind == "boss" or entry.role == "boss") and tonumber(entry.creatureId) == bossId then
				return entry
			end
		end
		return ExpeditionConfig.getById(bossId, "boss")
	elseif teamType == 2 then
		local huntArea = tonumber(opts.huntArea) or 0
		if huntArea <= 0 then
			return nil
		end
		local byId = ExpeditionConfig.getById(huntArea, "monster")
		if byId then
			return byId
		end
		for _, entry in ipairs(ExpeditionConfig.Catalog or {}) do
			if entry.kind == "hunt" or entry.role == "monster" then
				if tonumber(entry.id) == huntArea then
					return entry
				end
				local info = Game.getSubareaInfo(tonumber(entry.id) or 0)
				if info and tonumber(info.cipId) == huntArea then
					return entry
				end
			end
		end
	elseif teamType == 3 then
		local questId = tonumber(opts.questID) or 0
		if questId <= 0 then
			return nil
		end
		for _, entry in ipairs(ExpeditionConfig.Catalog or {}) do
			if tonumber(entry.cipQuestId) == questId then
				return entry
			end
		end
	end
	return nil
end

function LobbyTeamFinder.shouldList(record)
	return record
		and record.public
		and LobbyManager.isIdle(record)
		and (record.expeditionId or "") ~= ""
		and LobbyStore.freeSlots(record) > 0
end

--- Upsert or remove the host's Team Finder row from lobby state.
function LobbyTeamFinder.sync(record)
	local host = record and online(record.hostGuid) or nil
	if not host then
		return
	end
	if not LobbyTeamFinder.shouldList(record) then
		if record.teamFinder then
			Game.removeTeamFinder(host, false)
			record.teamFinder = false
			LobbyStore.save(record)
		end
		return
	end
	local opts = LobbyTeamFinder.activityOpts(record)
	if not opts then
		if record.teamFinder then
			Game.removeTeamFinder(host, false)
			record.teamFinder = false
			LobbyStore.save(record)
		end
		return
	end
	Game.upsertTeamFinder(host, opts)
	if not record.teamFinder then
		record.teamFinder = true
		LobbyStore.save(record)
	end
end

function LobbyTeamFinder.unlist(record, closeChannel)
	local host = record and online(record.hostGuid) or nil
	if host then
		Game.removeTeamFinder(host, closeChannel ~= false)
	elseif record then
		Game.removeTeamFinder(record.hostGuid, false)
	end
	if record and record.teamFinder then
		record.teamFinder = false
		LobbyStore.save(record)
	end
end

-- C++ Team Finder hooks ----------------------------------------------------------

--- Assemble Team: list the host's personal lobby publicly for the chosen activity.
function LobbyTeamFinder.onAssemble(leader, opts)
	if not leader then
		return
	end
	local record = LobbyManager.ensureForPlayer(leader)
	if not record then
		return
	end
	opts = opts or {}
	local catalog = catalogFromActivity(opts)
	if not catalog then
		-- Unknown activity: drop the C++ listing rather than mark a TF-backed lobby
		-- with a missing expedition.
		record.public = false
		LobbyTeamFinder.unlist(record, false)
		LobbyStore.save(record)
		LobbyProtocol.broadcast(record)
		return
	end
	local role = catalog.role
	if role ~= "boss" and role ~= "monster" and role ~= "quest" then
		role = catalog.kind == "boss" and "boss" or (catalog.kind == "quest" and "quest" or "monster")
	end
	record.expeditionId = tostring(catalog.id)
	record.role = role
	record.expeditionName = tostring(catalog.name or catalog.id)
	local cid = tonumber(catalog.creatureId)
	if (not cid or cid <= 0) and type(catalog.creatureIds) == "table" then
		cid = tonumber(catalog.creatureIds[1])
	end
	record.creatureId = cid
	if opts.minLevel and opts.minLevel > 0 then
		record.levelMin = math.max(1, math.floor(opts.minLevel))
	end
	if opts.maxLevel and opts.maxLevel > 0 then
		record.levelMax = math.max(record.levelMin, math.floor(opts.maxLevel))
	end
	if opts.teamSlots and opts.teamSlots > 0 then
		record.size = math.max(#record.members, math.min(LobbyConfig.MAX_MEMBERS, math.floor(opts.teamSlots)))
	end
	record.public = true
	record.teamFinder = true
	LobbyStore.save(record)
	LobbyInstance.applyVariant(record)
	-- Reconcile freeSlots / membersMap with lobby membership and re-invite
	-- existing lobby members into the Team Finder channel C++ just opened.
	LobbyTeamFinder.sync(record)
	if #record.members >= 2 then
		LobbyManager.openChannel(record)
	end
	LobbyProtocol.broadcast(record)
end

--- Leader accepted a Join Team request: land the member in the host lobby.
--- Returns false when join fails so C++ can revert membersMap / skip the toast.
function LobbyTeamFinder.onAccept(leader, member)
	if not leader or not member then
		return false
	end
	local record = LobbyStore.getForPlayer(leader)
	if not record then
		return false
	end
	-- Enforce listing level range (and public) — Team Finder accept is not a
	-- private invite that should bypass checkJoinable.
	local ok, err = LobbyManager.join(member, record.id, false)
	if not ok then
		if err then
			member:sendTextMessage(MESSAGE_STATUS, err)
		end
		return false
	end
	record.teamFinder = true
	LobbyStore.save(record)
	return true
end

--- Unlist Team: stop advertising; keep the personal lobby private.
function LobbyTeamFinder.onUnlist(leader)
	if not leader then
		return
	end
	local record = LobbyStore.getForPlayer(leader)
	if not record then
		return
	end
	record.public = false
	record.teamFinder = false
	LobbyStore.save(record)
	LobbyProtocol.broadcast(record)
end
