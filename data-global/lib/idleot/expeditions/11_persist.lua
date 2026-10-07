ExpeditionPersist = ExpeditionPersist or {}

local pendingByKey = {}
local pendingByGuid = {}

local function huntsKv()
	if not kv or not kv.scoped then
		return nil
	end
	return kv.scoped("expeditions"):scoped("hunts")
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
	return Alts and Alts.isCompanion and Alts.isCompanion(player)
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
	local host = session.playerId and Player(session.playerId) or nil
	if hostGuid <= 0 and host then
		hostGuid = host:getGuid()
	end
	if hostGuid <= 0 then
		return nil
	end
	local accountId = 0
	if host and host:getGuid() == hostGuid then
		accountId = host:getAccountId()
	else
		local offline = Game.getOfflinePlayer and Game.getOfflinePlayer(hostGuid)
		accountId = offline and offline:getAccountId() or 0
	end

	local humanGuids = {}
	local seenHuman = {}
	local humanByAccount = {}
	local companionMembers = {}

	-- The host stays human even when a client detach re-marked its body as a companion.
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local member = Player(id)
		if member then
			local guid = member:getGuid()
			if guid == hostGuid or not isCompanion(session, member) then
				if not seenHuman[guid] then
					seenHuman[guid] = true
					humanGuids[#humanGuids + 1] = guid
					local account = member:getAccountId()
					if guid == hostGuid or not humanByAccount[account] then
						humanByAccount[account] = guid
					end
				end
			else
				companionMembers[#companionMembers + 1] = member
			end
		end
	end

	if #humanGuids == 0 then
		return nil
	end

	-- Restore redeploys each companion under a human of its own account.
	local companions = {}
	for _, companion in ipairs(companionMembers) do
		local controllerGuid = math.floor(tonumber(companion:getStorageValue(AltsConfig.STORAGE_COMPANION_CONTROLLER)) or 0)
		if not seenHuman[controllerGuid] then
			controllerGuid = humanByAccount[companion:getAccountId()] or hostGuid
		end
		companions[#companions + 1] = { name = companion:getName(), controllerGuid = controllerGuid }
	end

	return {
		-- session.key is fixed at creation; the host (session.guid) changes when the leader leaves.
		sessionKey = session.key or ExpeditionPersist.sessionKeyFromHostGuid(hostGuid),
		accountId = accountId,
		catalogId = catalog.id,
		catalogRole = catalog.role or "monster",
		lure = session.lure,
		lureMax = session.lureMax,
		forceFiendishCreatureId = session.forceFiendishCreatureId,
		skipOpenWorldForge = session.skipOpenWorldForge == true,
		stopOnInsufficientGold = session.stopOnInsufficientGold == true,
		stopOnInsufficientCap = session.stopOnInsufficientCap == true,
		hostGuid = hostGuid,
		humanGuids = humanGuids,
		companions = companions,
		-- Keeps the lobby "running" after a restart (no leave / kick mid-hunt).
		scope = session.scope,
		lobbyId = session.lobbyId,
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
	local online = Alts and Alts.findOnlinePlayerByGuid and Alts.findOnlinePlayerByGuid(guid)
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

local function snapshotGuidSet(snapshot)
	local set = {}
	local host = math.floor(tonumber(snapshot.hostGuid) or 0)
	if host > 0 then
		set[host] = true
	end
	for _, guid in ipairs(snapshot.humanGuids or {}) do
		local g = math.floor(tonumber(guid) or 0)
		if g > 0 then
			set[g] = true
		end
	end
	return set
end

local function snapshotAccountId(snapshot)
	local accountId = math.floor(tonumber(snapshot.accountId) or 0)
	if accountId > 0 then
		return accountId
	end
	local offline = Game.getOfflinePlayer and Game.getOfflinePlayer(math.floor(tonumber(snapshot.hostGuid) or 0))
	accountId = offline and offline:getAccountId() or 0
	snapshot.accountId = accountId
	return accountId
end

--- Restoring deploys the whole account team, so two snapshots for one account (or sharing
--- a member) would fight over the same characters on boot.
local function snapshotsConflict(a, b)
	local accountA = snapshotAccountId(a)
	if accountA > 0 and accountA == snapshotAccountId(b) then
		return true
	end
	local guidsA = snapshotGuidSet(a)
	for guid in pairs(snapshotGuidSet(b)) do
		if guidsA[guid] then
			return true
		end
	end
	return false
end

local function discardSnapshot(store, stale, keeper)
	if store and stale.sessionKey then
		store:remove(stale.sessionKey)
	end
	local keep = keeper and snapshotGuidSet(keeper) or {}
	for _, guid in ipairs(stale.humanGuids or {}) do
		if not keep[math.floor(tonumber(guid) or 0)] then
			setMemberPointer(guid, nil)
		end
	end
	unindexSnapshot(stale)
	if keeper then
		indexSnapshot(keeper)
	end
	logger.info(
		"[ExpeditionPersist] dropped stale hunt {} (superseded by {})",
		tostring(stale.sessionKey),
		tostring(keeper and keeper.sessionKey or "-")
	)
end

function ExpeditionPersist.writeSession(session)
	-- Shutdown logs members out one by one; the first snapshot holds the full roster.
	if session and session.persistedForRestart and ExpeditionPersist.isServerShuttingDown() then
		return true
	end
	local snapshot = ExpeditionPersist.snapshotFromSession(session)
	if not snapshot then
		return false
	end

	local store = huntsKv()
	if not store or not JsonParser then
		return false
	end

	local encoded = JsonParser.encode(snapshot)
	if not encoded then
		return false
	end

	for key, other in pairs(pendingByKey) do
		if key ~= snapshot.sessionKey and not ExpeditionManager.getSessionByKey(key) and snapshotsConflict(snapshot, other) then
			discardSnapshot(store, other, nil)
		end
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

	local store = huntsKv()
	if not store or not store.keys or not JsonParser then
		return 0
	end

	local ttl = ExpeditionConfig.HUNT_RESTORE_TTL_SEC or (7 * 24 * 3600)
	local now = os.time()
	local keys = store:keys("")
	if type(keys) ~= "table" then
		return 0
	end

	local candidates = {}
	for _, key in ipairs(keys) do
		local raw = store:get(key)
		if type(raw) == "string" and raw ~= "" then
			local snapshot = JsonParser.decode(raw)
			if type(snapshot) == "table" and snapshot.catalogId and snapshot.hostGuid then
				snapshot.sessionKey = snapshot.sessionKey or key
				local savedAt = tonumber(snapshot.savedAt) or 0
				if ttl > 0 and savedAt > 0 and now - savedAt > ttl then
					store:remove(key)
				else
					candidates[#candidates + 1] = snapshot
				end
			else
				store:remove(key)
			end
		end
	end

	-- Newest first so the hunt that was live at shutdown wins over stale duplicates.
	table.sort(candidates, function(a, b)
		local sa, sb = tonumber(a.savedAt) or 0, tonumber(b.savedAt) or 0
		if sa ~= sb then
			return sa > sb
		end
		local na, nb = #(a.humanGuids or {}), #(b.humanGuids or {})
		if na ~= nb then
			return na > nb
		end
		return tostring(a.sessionKey) < tostring(b.sessionKey)
	end)

	local kept = {}
	for _, snapshot in ipairs(candidates) do
		local keeper = nil
		for _, k in ipairs(kept) do
			if snapshotsConflict(k, snapshot) then
				keeper = k
				break
			end
		end
		if keeper then
			discardSnapshot(store, snapshot, keeper)
		else
			kept[#kept + 1] = snapshot
			indexSnapshot(snapshot)
		end
	end
	local loaded = #kept

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
end

--- Rebuild hunt instances/sessions on process start and begin hunting immediately.
function ExpeditionPersist.restoreAllOnStartup()
	local restored = 0
	for _, snapshot in pairs(pendingByKey) do
		if ExpeditionManager.restoreHuntOnStartup and ExpeditionManager.restoreHuntOnStartup(snapshot) then
			restored = restored + 1
		end
	end
	if restored > 0 then
		logger.info("[ExpeditionPersist] restored {} hunt(s) on startup", restored)
	end
	return restored
end
