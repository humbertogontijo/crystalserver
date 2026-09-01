ExpeditionPersist = ExpeditionPersist or {}

local pendingByKey = {}
local pendingByGuid = {}
local restoringByKey = {}

local function huntsKv()
	if not kv or not kv.scoped then
		return nil
	end
	return kv.scoped("expeditions"):scoped("hunts")
end

local function playerKv(player)
	if not player or not player.kv then
		return nil
	end
	return player:kv()
end

function ExpeditionPersist.sessionKeyFromHostGuid(hostGuid)
	hostGuid = math.floor(tonumber(hostGuid) or 0)
	if hostGuid <= 0 then
		return nil
	end
	return "p" .. tostring(hostGuid)
end

function ExpeditionPersist.isServerShuttingDown()
	if not Game or not Game.getGameState then
		return false
	end
	local state = Game.getGameState()
	return state == GAME_STATE_SHUTDOWN or state == GAME_STATE_CLOSED
end

function ExpeditionPersist.isPersistableHunt(session)
	if not session or session.state == "ended" or not session.entered then
		return false
	end
	if session.kind == "raid" or session.kind == "soulpit" or session.kind == "worldboss" then
		return false
	end
	local role = session.role
	if role ~= "monster" then
		if session.catalog and session.catalog.role == "monster" then
			role = "monster"
		else
			return false
		end
	end
	return role == "monster"
end

local function isCompanion(session, player)
	if not player then
		return false
	end
	if session and session.companionIds and session.companionIds[player:getId()] then
		return true
	end
	return TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player)
end

function ExpeditionPersist.snapshotFromSession(session)
	if not ExpeditionPersist.isPersistableHunt(session) then
		return nil
	end
	local catalog = session.catalog
	if not catalog or not catalog.id then
		return nil
	end

	local hostGuid = session.guid or 0
	if hostGuid <= 0 and session.playerId then
		local host = Player(session.playerId)
		if host then
			hostGuid = host:getGuid()
		end
	end
	if hostGuid <= 0 then
		return nil
	end

	local humanGuids = {}
	local companionGuids = {}
	local seenHuman = {}
	local seenCompanion = {}

	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local member = Player(id)
		if member then
			local guid = member:getGuid()
			if isCompanion(session, member) then
				if not seenCompanion[guid] then
					seenCompanion[guid] = true
					companionGuids[#companionGuids + 1] = guid
				end
			else
				if not seenHuman[guid] then
					seenHuman[guid] = true
					humanGuids[#humanGuids + 1] = guid
				end
			end
		end
	end

	if #humanGuids == 0 then
		return nil
	end

	return {
		sessionKey = ExpeditionPersist.sessionKeyFromHostGuid(hostGuid),
		catalogId = catalog.id,
		catalogRole = catalog.role or "monster",
		lure = session.lure,
		lureMax = session.lureMax,
		stopOnInsufficientGold = session.stopOnInsufficientGold == true,
		stopOnInsufficientCap = session.stopOnInsufficientCap == true,
		hostGuid = hostGuid,
		humanGuids = humanGuids,
		companionGuids = companionGuids,
		savedAt = os.time(),
	}
end

local function setMemberPointer(guid, sessionKey)
	guid = math.floor(tonumber(guid) or 0)
	if guid <= 0 then
		return
	end
	local offline = Game.getOfflinePlayer and Game.getOfflinePlayer(guid)
	if offline and offline.kv then
		local kvStore = offline:kv()
		if kvStore then
			if sessionKey then
				kvStore:set(ExpeditionConfig.KV_HUNT_KEY, sessionKey)
			else
				kvStore:remove(ExpeditionConfig.KV_HUNT_KEY)
			end
		end
	end
	local online = TeamStore and TeamStore.findOnlinePlayerByGuid and TeamStore.findOnlinePlayerByGuid(guid)
	if online and online.kv then
		local kvStore = online:kv()
		if kvStore then
			if sessionKey then
				kvStore:set(ExpeditionConfig.KV_HUNT_KEY, sessionKey)
			else
				kvStore:remove(ExpeditionConfig.KV_HUNT_KEY)
			end
		end
	end
end

local function indexSnapshot(snapshot)
	if not snapshot or not snapshot.sessionKey then
		return
	end
	pendingByKey[snapshot.sessionKey] = snapshot
	for _, guid in ipairs(snapshot.humanGuids or {}) do
		pendingByGuid[math.floor(tonumber(guid) or 0)] = snapshot.sessionKey
	end
end

local function unindexSnapshot(snapshot)
	if not snapshot or not snapshot.sessionKey then
		return
	end
	pendingByKey[snapshot.sessionKey] = nil
	for _, guid in ipairs(snapshot.humanGuids or {}) do
		local g = math.floor(tonumber(guid) or 0)
		if pendingByGuid[g] == snapshot.sessionKey then
			pendingByGuid[g] = nil
		end
	end
end

function ExpeditionPersist.writeSession(session)
	local snapshot = ExpeditionPersist.snapshotFromSession(session)
	if not snapshot then
		return false
	end

	local store = huntsKv()
	if not store or not ExpeditionJson then
		return false
	end

	local encoded = ExpeditionJson.encode(snapshot)
	if not encoded then
		return false
	end

	store:set(snapshot.sessionKey, encoded)
	indexSnapshot(snapshot)

	for _, guid in ipairs(snapshot.humanGuids or {}) do
		setMemberPointer(guid, snapshot.sessionKey)
	end
	return true
end

function ExpeditionPersist.clearSession(session)
	if not session then
		return
	end
	local snapshot = ExpeditionPersist.snapshotFromSession(session)
		or pendingByKey[session.key]
		or (session.key and pendingByKey[session.key])

	local sessionKey = (snapshot and snapshot.sessionKey) or session.key
	if not sessionKey then
		return
	end

	local store = huntsKv()
	if store then
		store:remove(sessionKey)
	end

	if snapshot then
		for _, guid in ipairs(snapshot.humanGuids or {}) do
			setMemberPointer(guid, nil)
		end
		unindexSnapshot(snapshot)
	else
		unindexSnapshot({ sessionKey = sessionKey, humanGuids = {} })
	end
	restoringByKey[sessionKey] = nil
end

function ExpeditionPersist.saveAllLive(sessionsByKey)
	if type(sessionsByKey) ~= "table" then
		return
	end
	for _, session in pairs(sessionsByKey) do
		if ExpeditionPersist.isPersistableHunt(session) then
			ExpeditionPersist.writeSession(session)
		end
	end
end

function ExpeditionPersist.loadAll()
	pendingByKey = {}
	pendingByGuid = {}
	restoringByKey = {}

	local store = huntsKv()
	if not store or not store.keys or not ExpeditionJson then
		return 0
	end

	local ttl = ExpeditionConfig.HUNT_RESTORE_TTL_SEC or (7 * 24 * 3600)
	local now = os.time()
	local loaded = 0
	local keys = store:keys("")
	if type(keys) ~= "table" then
		return 0
	end

	for _, key in ipairs(keys) do
		local raw = store:get(key)
		if type(raw) == "string" and raw ~= "" then
			local snapshot = ExpeditionJson.decode(raw)
			if type(snapshot) == "table" and snapshot.catalogId and snapshot.hostGuid then
				snapshot.sessionKey = snapshot.sessionKey or key
				local savedAt = tonumber(snapshot.savedAt) or 0
				if ttl > 0 and savedAt > 0 and now - savedAt > ttl then
					store:remove(key)
				else
					indexSnapshot(snapshot)
					loaded = loaded + 1
				end
			else
				store:remove(key)
			end
		end
	end

	logger.info("[ExpeditionPersist] loaded {} pending hunt(s)", loaded)
	return loaded
end

function ExpeditionPersist.hasPendingRestore(player)
	if not player then
		return false
	end
	local guid = player:getGuid()
	return pendingByGuid[guid] ~= nil
end

function ExpeditionPersist.getPendingSnapshot(player)
	if not player then
		return nil
	end
	local key = pendingByGuid[player:getGuid()]
	if not key then
		return nil
	end
	return pendingByKey[key]
end

local function collectOnlineHumans(snapshot, excludeGuid)
	local out = {}
	local seen = {}
	excludeGuid = math.floor(tonumber(excludeGuid) or 0)
	for _, rawGuid in ipairs(snapshot.humanGuids or {}) do
		local guid = math.floor(tonumber(rawGuid) or 0)
		if guid > 0 and guid ~= excludeGuid and not seen[guid] then
			seen[guid] = true
			local online = TeamStore and TeamStore.findOnlinePlayerByGuid and TeamStore.findOnlinePlayerByGuid(guid)
			if online and not (TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(online)) then
				out[#out + 1] = online
			end
		end
	end
	return out
end

function ExpeditionPersist.tryRestoreOnLogin(player)
	if not player or not ExpeditionManager or not ExpeditionManager.join then
		return false
	end

	ExpeditionConfig.refundBossAttemptIfMarked(player)

	local snapshot = ExpeditionPersist.getPendingSnapshot(player)
	if not snapshot then
		return false
	end

	local sessionKey = snapshot.sessionKey
	if not sessionKey then
		return false
	end

	local live = ExpeditionManager.getSessionByKey and ExpeditionManager.getSessionByKey(sessionKey)
	if live and live.state ~= "ended" then
		if ExpeditionManager.getSessionByPlayer(player) then
			return true
		end
		local host = Player(live.playerId)
		if host and ExpeditionManager.attachFriendToSession then
			ExpeditionManager.attachFriendToSession(player, live, host, { skipMaybeStart = true })
			return true
		end
		return false
	end

	if restoringByKey[sessionKey] then
		local playerId = player:getId()
		addEvent(function()
			local p = Player(playerId)
			if p and ExpeditionPersist.tryRestoreOnLogin then
				pcall(ExpeditionPersist.tryRestoreOnLogin, p)
			end
		end, 1500)
		return true
	end

	local playerGuid = player:getGuid()
	local hostGuid = math.floor(tonumber(snapshot.hostGuid) or 0)
	local joiner = player
	if hostGuid > 0 and hostGuid ~= playerGuid then
		local hostOnline = TeamStore and TeamStore.findOnlinePlayerByGuid and TeamStore.findOnlinePlayerByGuid(hostGuid)
		if hostOnline and not ExpeditionManager.getSessionByPlayer(hostOnline) then
			joiner = hostOnline
		end
	end

	if not joiner then
		return false
	end

	local preAccepted = collectOnlineHumans(snapshot, joiner:getGuid())
	restoringByKey[sessionKey] = true

	local ok, err = pcall(function()
		ExpeditionManager.join(
			joiner,
			snapshot.catalogId,
			snapshot.catalogRole or "monster",
			nil,
			snapshot.lure,
			{
				skipPzCheck = true,
				restoreSkipTeamAccept = true,
				restoreHostGuid = hostGuid,
				preAcceptedPlayers = preAccepted,
				stopOnInsufficientGold = snapshot.stopOnInsufficientGold,
				stopOnInsufficientCap = snapshot.stopOnInsufficientCap,
			}
		)
	end)

	restoringByKey[sessionKey] = nil

	if not ok then
		logger.error("[ExpeditionPersist] restore join failed for {}: {}", player:getName(), tostring(err))
		ExpeditionPersist.clearSnapshot(snapshot)
		return false
	end

	local restored = ExpeditionManager.getSessionByKey and ExpeditionManager.getSessionByKey(sessionKey)
	if not restored then
		ExpeditionPersist.clearSnapshot(snapshot)
		return false
	end

	if joiner:getGuid() ~= playerGuid and playerGuid ~= hostGuid then
		local host = Player(restored.playerId)
		if host and ExpeditionManager.attachFriendToSession then
			if not ExpeditionManager.getSessionByPlayer(player) then
				ExpeditionManager.attachFriendToSession(player, restored, host, { skipMaybeStart = true })
			end
		end
	end

	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		"Your expedition was interrupted. Starting the hunt again..."
	)
	return true
end

function ExpeditionPersist.clearSnapshot(snapshot)
	if not snapshot then
		return
	end
	local store = huntsKv()
	if store and snapshot.sessionKey then
		store:remove(snapshot.sessionKey)
	end
	for _, guid in ipairs(snapshot.humanGuids or {}) do
		setMemberPointer(guid, nil)
	end
	unindexSnapshot(snapshot)
	restoringByKey[snapshot.sessionKey] = nil
end
