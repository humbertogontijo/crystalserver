-- Auto-split from 07_manager.lua (shared EM_PRIV). Do not redefine ExpeditionManager.
ExpeditionManager = ExpeditionManager or {}
EM_PRIV = EM_PRIV or {}

EM_PRIV.sessionsByKey = EM_PRIV.sessionsByKey or {}
EM_PRIV.sessionsByPlayerId = EM_PRIV.sessionsByPlayerId or {}
-- Voluntary leave countdown (playerId → { event, sessionKey?, team? }).
EM_PRIV.leavePendingByPlayerId = EM_PRIV.leavePendingByPlayerId or {}
-- Team-wide stop countdown (sessionKey → { event, initiatorId }).
EM_PRIV.leavePendingBySessionKey = EM_PRIV.leavePendingBySessionKey or {}
-- Friend expedition invites: friendGuid → { hostGuid, sessionKey, expeditionId, expeditionName, expires }
EM_PRIV.teamInvitesByFriendGuid = EM_PRIV.teamInvitesByFriendGuid or {}
-- Real-client UI sync after headless→client takeover (player id → true).
EM_PRIV.expeditionClientSynced = EM_PRIV.expeditionClientSynced or {}

function EM_PRIV.playerKey(player)
	return "p" .. player:getGuid()
end

function EM_PRIV.syncClientMaps(session)
	if not session then
		return
	end
	for _, p in ipairs(ExpeditionManager.onlinePlayers(session)) do
		local pos = p:getPosition()
		if pos then
			p:sendMapDescription(pos)
		end
	end
end

function EM_PRIV.beginExpeditionHunt(session, contentRole)
	if not session or session.state == "ended" then
		return
	end
	EM_PRIV.syncClientMaps(session)
	if contentRole == "arena" then
		QuestArena.begin(session)
	elseif contentRole == "boss" then
		ExpeditionBoss.spawn(session)
	else
		ExpeditionPack.spawn(session)
	end
	ExpeditionAI.start(session)
	for _, p in ipairs(ExpeditionManager.onlinePlayers(session)) do
		IdleSafe.call("ActivityBoostLedger.applyOnExpeditionJoin", ActivityBoostLedger.applyOnExpeditionJoin, p)
	end
end

function ExpeditionManager.getSessionByKey(key)
	return EM_PRIV.sessionsByKey[key]
end

--- Counts of sessions that have not ended: { total, byRole = { [role] = n } }.
function ExpeditionManager.stats()
	local total, byRole = 0, {}
	for _, session in pairs(EM_PRIV.sessionsByKey) do
		if session.state ~= "ended" then
			local role = session.role or "monster"
			byRole[role] = (byRole[role] or 0) + 1
			total = total + 1
		end
	end
	return { total = total, byRole = byRole }
end

--- Live hunt/raid session bound to an engine instance id (e.g. GOD /goto spectator).
function ExpeditionManager.getSessionByInstanceId(instanceId)
	local id = Instance.normalize(instanceId)
	if Instance.isWorld(id) then
		return nil
	end
	local function owns(session)
		return session
			and session.state ~= "ended"
			and EM_PRIV.sessionsByKey[session.key] == session
			and session.instance
			and session.instance.instanceId == id
			and ExpeditionInstance.isLive(session.instance)
	end
	EM_PRIV.sessionByInstanceKey = EM_PRIV.sessionByInstanceKey or {}
	local cached = EM_PRIV.sessionByInstanceKey[id]
	if owns(cached) then
		return cached
	end
	EM_PRIV.sessionByInstanceKey[id] = nil
	for _, session in pairs(EM_PRIV.sessionsByKey) do
		if owns(session) then
			EM_PRIV.sessionByInstanceKey[id] = session
			return session
		end
	end
	return nil
end

function ExpeditionManager.getSessionByPlayer(player)
	if not player then
		return nil
	end
	return ExpeditionManager.resolveSession(player)
end

--- Session lookup for hosts, friends, and headless companions (may be absent from EM_PRIV.sessionsByPlayerId).
function ExpeditionManager.resolveSession(player)
	if not player then
		return nil
	end
	local session = EM_PRIV.sessionsByPlayerId[player:getId()]
	if session then
		return session
	end
	local guid = player:getGuid()
	for _, s in pairs(EM_PRIV.sessionsByKey) do
		if s.memberGuids and s.memberGuids[guid] then
			return s
		end
		if s.companionIds and s.companionIds[player:getId()] then
			return s
		end
		-- Headless companions may logout before removeHuntMember; humans must not
		-- re-bind via pending death after they have already left the session.
		if s.pendingHuntDeath and s.pendingHuntDeath.id == player:getId() then
			if Alts.isCompanion(player) then
				return s
			end
		end
	end
	if Alts.isCompanion(player) then
		local controller = Alts.getCompanionController(player)
		if controller then
			return EM_PRIV.sessionsByPlayerId[controller:getId()]
		end
	end
	return nil
end

--- True when the player has a live session and is physically in that instance.
--- Before the entry teleport completes (`session.entered` unset), returns true if a session exists.
function ExpeditionManager.isInExpedition(player)
	if not player then
		return false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or session.state == "ended" then
		return false
	end
	if session.deadPlayerIds and session.deadPlayerIds[player:getId()] then
		return false
	end
	if not session.entered then
		return true
	end
	return ExpeditionInstance.isLive(session.instance) and player:getInstanceId() == session.instance.instanceId
end

--- If the player has a session but is no longer in the instance, leave/rescue them.
--- Returns false when the player is not (or no longer) on a valid expedition.
function ExpeditionManager.reconcilePresence(player)
	if not player then
		return false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or session.state == "ended" or session.reconciling then
		return false
	end
	if not session.entered then
		return true
	end
	-- Membership is the bound key: shared hunt tiles exist on every instance id.
	if ExpeditionInstance.isLive(session.instance) and player:getInstanceId() == session.instance.instanceId then
		return true
	end

	local pos = player:getPosition()
	logger.warn(
		"[Expedition] {} outside session {} area (instance={} expected={} pos={},{},{} contains={}) - leaving",
		player:getName(),
		tostring(session.key),
		tostring(player:getInstanceId() or "-"),
		tostring(session.instance and session.instance.instanceId or "-"),
		pos and pos.x or "?",
		pos and pos.y or "?",
		pos and pos.z or "?",
		tostring(session.instance and ExpeditionInstance.contains(session.instance, pos) or false)
	)
	session.reconciling = true
	if session.kind == "raid" then
		RaidInstance.leave(player, { silent = true })
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You left the raid area.")
	else
		ExpeditionManager.leave(player, { silent = true })
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You left the expedition area.")
	end
	return false
end

-- A member bound to another instance left its session. Deferred: the engine reports the
-- change mid-move, and leaving teleports again.
IdleEvents.on("player.instanceChanged", function(player)
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or not session.entered or session.state == "ended" then
		return
	end
	addEvent(function(pid)
		local p = Player(pid)
		if p then
			ExpeditionManager.reconcilePresence(p)
		end
	end, 0, player:getId())
end, "ExpeditionPresence")

-- Solo sessions use session.playerId; party hunts/bosses use session.playerIds.
function ExpeditionManager.sessionMemberIds(session)
	if not session then
		return {}
	end
	if type(session.playerIds) == "table" and #session.playerIds > 0 then
		return session.playerIds
	end
	if session.playerId then
		return { session.playerId }
	end
	return {}
end

--- Online members, optionally kept only when `filter(player)` is true.
function ExpeditionManager.onlinePlayers(session, filter)
	local out = {}
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local player = Player(id)
		if player and (not filter or filter(player)) then
			out[#out + 1] = player
		end
	end
	return out
end

function ExpeditionManager.broadcastStatus(session)
	if not session then
		return
	end
	for _, player in ipairs(ExpeditionManager.onlinePlayers(session)) do
		ExpeditionProtocol.sendStatus(player, session)
	end
end

function ExpeditionManager.reselectAnchor(session)
	if not session or session.kind == "raid" then
		return nil
	end
	return ExpeditionConfig.pickAnchor(session)
end

function EM_PRIV.isOpenWorldReturnPos(pos)
	if not pos then
		return false
	end
	return InstanceWorld.isTownOnlyPos(pos)
end

function EM_PRIV.saveReturn(player, pos)
	pos = pos or (player and player:getPosition()) or nil
	if not player or not pos then
		return
	end
	-- Never persist a private-instance or hunt-footprint tile as the post-leave
	-- return point (switch leave→join with skipTeleport used to overwrite temple
	-- with the hunt XY; leave then teleportTo'd the same tile and no-oped).
	if Instance.isPrivate(Instance.of(player)) then
		return
	end
	if not EM_PRIV.isOpenWorldReturnPos(pos) then
		return
	end
	player:setStorageValue(ExpeditionConfig.STORAGE_RETURN_X, pos.x)
	player:setStorageValue(ExpeditionConfig.STORAGE_RETURN_Y, pos.y)
	player:setStorageValue(ExpeditionConfig.STORAGE_RETURN_Z, pos.z)
end

function EM_PRIV.loadReturn(player)
	local x = player:getStorageValue(ExpeditionConfig.STORAGE_RETURN_X)
	local y = player:getStorageValue(ExpeditionConfig.STORAGE_RETURN_Y)
	local z = player:getStorageValue(ExpeditionConfig.STORAGE_RETURN_Z)
	local function templeFallback()
		local town = player:getTown()
		if town then
			return town:getTemplePosition()
		end
		return Position(32369, 32241, 7)
	end
	if x < 0 or y < 0 or z < 0 then
		return templeFallback()
	end
	local pos = Position(x, y, z)
	if not EM_PRIV.isOpenWorldReturnPos(pos) then
		return templeFallback()
	end
	return pos
end

--- Expedition exit: humans go back to their lobby room; companions (and any failure)
--- fall back to the open-world return tile.
function EM_PRIV.returnToLobby(player, returnPos)
	if not player then
		return false
	end
	local companion = Alts.isCompanion(player) and not Alts.isRealUiClient(player)
	if not companion then
		local record = LobbyManager.ensureForPlayer(player)
		if record and LobbyInstance.enterNow(player, record, {}) then
			return true
		end
	end
	returnPos = returnPos or EM_PRIV.loadReturn(player)
	return InstanceWorld.exitToOpenWorld(player, returnPos)
end

--- After expedition cleanup: hometown temple (recall) or back to the lobby room.
--- Always immediate — the IT channel already completed before leave/abort.
function EM_PRIV.teleportAfterLeave(player, returnPos, opts)
	opts = opts or {}
	if opts.goHometown then
		local ok, err = InstanceTeleport.executeHometown(player, { fromExpedition = true })
		if ok then
			return true
		end
		logger.warn(
			"[Expedition] goHometown after leave failed for {}: {} — falling back to open world",
			player:getName(),
			tostring(err)
		)
	end
	return EM_PRIV.returnToLobby(player, returnPos)
end

--- Combat-lock gate for IT kinds (non-PZ is allowed; duration handles it).
function EM_PRIV.expeditionTeleportCombatOk(player)
	if not player then
		return false, "Invalid player."
	end
	if PzTeleport.isGod(player) then
		return true
	end
	if PzTeleport.isCombatLocked(player) then
		return false, PzTeleport.PZ_LOCKED_MESSAGE or "You cannot teleport while PZ-locked."
	end
	return true
end

function EM_PRIV.markActive(player, expeditionId)
	player:setStorageValue(ExpeditionConfig.STORAGE_ACTIVE, 1)
	player:setStorageValue(ExpeditionConfig.STORAGE_EXPEDITION_ID, expeditionId and 1 or -1)
	-- Store expedition id string via KV when available; storage holds flag only.
	local kv = player:kv()
	if kv then
		kv:set("expedition_id", expeditionId or "")
	end
end

function EM_PRIV.clearActive(player)
	player:setStorageValue(ExpeditionConfig.STORAGE_ACTIVE, -1)
	local kv = player:kv()
	if kv then
		kv:remove("expedition_id")
		-- Keep combat_automation KV so loadouts survive leave/rejoin.
	end
end

-- Rotten Blood / Darklight Core icons are applied by monster onThink and never
-- cleared on instance teleports (open-world zone leave does not fire). Also zero
-- Soul War–style hazard points in case zone afterLeave was skipped.
function ExpeditionManager.clearAreaEffects(player)
	if not player then
		return
	end
	onPlayerLeaveRottenArea(player)
	player:setHazardSystemPoints(0)
	-- Restore world hazard (e.g. Gnomprona) if still standing in a hazard zone.
	player:updateHazard()
	-- Agony fields (Darklight Core) use CONDITION_AGONY with ticks=-1 while standing
	-- on the tile; instance teleports skip step-out so strip it on expedition leave.
	player:removeCondition(CONDITION_AGONY, CONDITIONID_COMBAT)
	player:removeCondition(CONDITION_AGONY, CONDITIONID_DEFAULT)
end

function ExpeditionManager.sanitizeAutomation(loadout, player)
	local config = CombatAutomationStore.sanitize(loadout, player)
	return { slots = config.slots or {} }
end

function EM_PRIV.persistAutomation(player, automation)
	local state = CombatAutomation.getState(player)
	CombatAutomationStore.persist(player, {
		slots = automation and automation.slots or {},
		autoTarget = state and state.config and state.config.autoTarget or nil,
	})
	return
end

function EM_PRIV.loadPersistedAutomation(player)
	local config = CombatAutomationStore.getConfig(player)
	return { slots = config.slots or {} }
end

function ExpeditionManager.bindSession(session)
	if not session or not session.key then
		return
	end
	EM_PRIV.sessionsByKey[session.key] = session
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		EM_PRIV.sessionsByPlayerId[id] = session
	end
end

--- Root Scope of a session: its timers, subscriptions and child scopes (boss mechanics,
--- encounter copies, ...) run in the session's instance while it is the live session for
--- its key, and end in cleanupSession.
function ExpeditionManager.scope(session)
	local scope = session.scope
	if not scope then
		scope = Scope.new({
			name = "session:" .. tostring(session.key),
			instanceId = function()
				return session.instance and session.instance.instanceId or nil
			end,
			alive = function()
				return not session._cleaned and EM_PRIV.sessionsByKey[session.key] == session
			end,
		})
		session.scope = scope
	end
	return scope
end

--- Mark the party as inside the instance; emits "session.started" once.
function ExpeditionManager.markEntered(session)
	session.entered = true
	if not session.startedEmitted then
		session.startedEmitted = true
		IdleEvents.emit("session.started", session)
	end
end

function ExpeditionManager.unbindSession(session)
	if not session then
		return
	end
	if session.key then
		EM_PRIV.sessionsByKey[session.key] = nil
	end
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		EM_PRIV.sessionsByPlayerId[id] = nil
	end
	if session.playerId then
		EM_PRIV.sessionsByPlayerId[session.playerId] = nil
	end
end

function ExpeditionManager.saveReturnPos(player)
	EM_PRIV.saveReturn(player)
end

function ExpeditionManager.loadReturnPos(player)
	return EM_PRIV.loadReturn(player)
end

function ExpeditionManager.markActiveFlag(player, expeditionId)
	EM_PRIV.markActive(player, expeditionId)
end

function ExpeditionManager.clearActiveFlag(player)
	EM_PRIV.clearActive(player)
end

function ExpeditionManager.persistAutomation(player, automation)
	EM_PRIV.persistAutomation(player, automation)
end

function ExpeditionManager.loadPersistedAutomation(player)
	return EM_PRIV.loadPersistedAutomation(player)
end

function ExpeditionManager.setAutomation(player, loadout)
	if not player then
		return
	end
	local raw = loadout
	if type(loadout) == "table" and loadout.slots == nil and loadout.loadout == nil then
		-- Accept bare { slots } or array; preserve auto-target when omitted.
		raw = { slots = type(loadout.slots) == "table" and loadout.slots or loadout }
	end
	CombatAutomationStore.setConfig(player, raw)
	return
end

function EM_PRIV.meetsExpeditionLevel(player, levelMin)
	if PzTeleport.isGod(player) then
		return true
	end
	return player:getLevel() >= levelMin
end

--- Players below `levelMin` (GODs always pass).
function ExpeditionManager.underleveled(players, levelMin)
	local blocked = {}
	for _, p in ipairs(players or {}) do
		if p and not EM_PRIV.meetsExpeditionLevel(p, levelMin) then
			blocked[#blocked + 1] = p
		end
	end
	return blocked
end

function EM_PRIV.playerHasExpeditionStamina(player)
	return ExpeditionSafety.hasStamina(player)
end

--- nil when all have stamina; otherwise error naming the first blocked player.
function EM_PRIV.partyStaminaError(players)
	local blocked = ExpeditionSafety.firstWithoutStamina(players)
	if blocked then
		return string.format("%s needs stamina to enter an expedition.", blocked:getName())
	end
	return nil
end

--- Players whose stamina must be > 0 before the host can start (not every online friend).
function EM_PRIV.collectStaminaGatePlayers(host, options)
	options = options or {}
	local list = {}
	local seen = {}
	local function push(p)
		if not p then
			return
		end
		local id = p:getId()
		if seen[id] then
			return
		end
		seen[id] = true
		list[#list + 1] = p
	end
	push(host)
	if not options.skipPartyGate then
		for _, teammate in ipairs(EM_PRIV.collectExpectedHumanTeammates(host, options)) do
			push(teammate)
		end
	end
	if type(options.preAcceptedPlayers) == "table" then
		for _, teammate in ipairs(options.preAcceptedPlayers) do
			push(teammate)
		end
	end
	return list
end

--- Collect online party for a hunt/boss: only leader can start; members pulled in.
--- Returns eligible Players list, or nil + error when joiner cannot start.
--- `extraPlayers`: optional Players (e.g. account-team companions) to include even
--- when Party:addMember failed / getMembers is empty - otherwise they stay at the
--- host's world tile while the host teleports into the instance alone.
function EM_PRIV.isSessionCompanion(session, player)
	if not player then
		return false
	end
	-- Attached UI clients are human viewers for hunt UX (death modal, accept prompts).
	if EM_PRIV.hasUiClient(player) then
		return false
	end
	if session and session.companionIds and session.companionIds[player:getId()] then
		return true
	end
	return Alts.isCompanion(player)
end

--- True when the player has a live ProtocolGame UI (not headless).
function EM_PRIV.hasUiClient(player)
	if not player then
		return false
	end
	if player:isHeadless() then
		return false
	end
	if player:getProtocolVersion() == 0 then
		return false
	end
	return true
end

function EM_PRIV.collectSessionHumans(session)
	-- Headless (companions or disconnected alts) never need switch accept prompts.
	return ExpeditionManager.onlinePlayers(session, function(p)
		return not EM_PRIV.isSessionCompanion(session, p) and EM_PRIV.hasUiClient(p)
	end)
end

function EM_PRIV.countHumanMembers(session)
	return #ExpeditionManager.onlinePlayers(session, function(p)
		return not EM_PRIV.isSessionCompanion(session, p)
	end)
end

--- Online players among `memberIds` (every fighter: humans and headless companions alike).
local function onlineMembers(memberIds)
	local players = {}
	for _, id in ipairs(memberIds or {}) do
		local p = Player(id)
		if p then
			players[#players + 1] = p
		end
	end
	return players
end

--- Error when a team member of the boss session is still on that boss's cooldown (nil
--- when everyone may fight it).
function EM_PRIV.entryBossCooldownError(session)
	if not session or session.role ~= "boss" then
		return nil
	end
	local bossName = ExpeditionConfig.bossTypeName(session.catalog)
	if not bossName then
		return nil
	end
	local canFight, _, _, err = ExpeditionConfig.partyCanFightBoss(onlineMembers(ExpeditionManager.sessionMemberIds(session)), bossName)
	if canFight then
		return nil
	end
	return err or "A team member is on boss cooldown."
end

--- Boss cooldown for every fighter among `memberIds`, once they are actually inside: a
--- cancelled entry channel never costs a cooldown.
function EM_PRIV.applyEntryBossCooldown(session, memberIds)
	if not session or session.role ~= "boss" then
		return
	end
	local bossName = ExpeditionConfig.bossTypeName(session.catalog)
	if not bossName then
		return
	end
	ExpeditionConfig.applyBossCooldown(onlineMembers(memberIds), bossName)
end

function EM_PRIV.refundBossCooldownForSession(session)
	if not session or session.role ~= "boss" then
		return
	end
	local bossName = ExpeditionConfig.bossTypeName(session.catalog)
	if not bossName then
		return
	end
	ExpeditionConfig.clearBossCooldown(onlineMembers(ExpeditionManager.sessionMemberIds(session)), bossName)
end

function EM_PRIV.syncHuntPersist(session)
	if not session then
		return
	end
	if ExpeditionPersist.isPersistableHunt(session) then
		IdleSafe.call("ExpeditionPersist.writeSession", ExpeditionPersist.writeSession, session)
	elseif not ExpeditionPersist.isServerShuttingDown() then
		IdleSafe.call("ExpeditionPersist.clearSession", ExpeditionPersist.clearSession, session)
	end
end

function ExpeditionManager.hasPendingRestore(player)
	return ExpeditionPersist.hasPendingRestore(player)
end

--- Refresh the lobbies of these players (presence: in expedition / busy / back in lobby).
--- Deferred so the session bind/unbind has settled before presence is read.
function EM_PRIV.notifyLobbies(playerIds)
	local guids = {}
	for _, id in ipairs(playerIds or {}) do
		local p = Player(id)
		if p then
			guids[#guids + 1] = p:getGuid()
		end
	end
	if #guids == 0 then
		return
	end
	addEvent(function()
		local seen = {}
		for _, guid in ipairs(guids) do
			local record = LobbyStore.getByGuid(guid)
			if record and not seen[record.id] then
				seen[record.id] = true
				LobbyProtocol.broadcast(record)
			end
		end
	end, 100)
end

--- Lobby whose members join this start; nil for solo runs (scope ~= "lobby").
function EM_PRIV.startLobby(host, options)
	options = options or {}
	if not host or options.scope ~= "lobby" then
		return nil
	end
	local record = options.lobbyId and LobbyStore.get(options.lobbyId) or LobbyStore.getForPlayer(host)
	if record and record.hostGuid == host:getGuid() then
		return record
	end
	return nil
end

--- Human lobby members inside the lobby room (= ready) who join a lobby start.
function EM_PRIV.collectExpectedHumanTeammates(host, options)
	local record = EM_PRIV.startLobby(host, options)
	if not record then
		return {}
	end
	local list = {}
	for _, p in ipairs(LobbyManager.onlineHumans(record, host:getGuid())) do
		if EM_PRIV.hasUiClient(p) and not (Alts.isCompanion(p)) and LobbyInstance.isInRoom(p, record) then
			list[#list + 1] = p
		end
	end
	return list
end

--- Names for the boss-difficulty player boxes: the lobby roster (incl. companions).
function EM_PRIV.collectBossDifficultyBannerNames(host, options)
	local names = {}
	if host then
		names[1] = host:getName()
	end
	local record = EM_PRIV.startLobby(host, options)
	if record then
		for _, name in ipairs(LobbyStore.memberNames(record, host:getGuid())) do
			names[#names + 1] = name
		end
	end
	return names
end

function EM_PRIV.awaitingHumanCount(session)
	if type(session.awaitingHumanGuids) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(session.awaitingHumanGuids) do
		n = n + 1
	end
	return n
end

function EM_PRIV.clearAcceptTimeout(session)
	if not session then
		return
	end
	ExpeditionManager.scope(session):cancel("acceptTimeout")
	session.acceptDeadline = nil
end

function EM_PRIV.armAcceptTimeout(session)
	if not session then
		return
	end
	local sec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
	session.acceptDeadline = os.time() + sec
	ExpeditionManager.scope(session):timer("acceptTimeout", sec * 1000, function()
		if session.entered or session.starting or session.state ~= "pending" then
			return
		end
		ExpeditionManager.cancelWaitingSession(session, "Team expedition invite timed out.")
	end)
end

--- Gather players for a hunt/boss join.
--- `extraPlayers` are account-team companions (included when eligible; omit for solo bosses).
--- `opts.ignoreParty`: solo bosses - host only (no world party members).
--- `opts.skipPzCheck`: switch leave→join; host already left an expedition.
function EM_PRIV.collectHuntJoinParty(player, levelMin, extraPlayers, opts)
	opts = opts or {}
	local ignoreParty = opts.ignoreParty == true
	local skipPzCheck = opts.skipPzCheck == true
	local candidates = {}
	local seen = {}

	local function pushCandidate(p)
		if not p then
			return
		end
		local id = p:getId()
		if seen[id] then
			return
		end
		seen[id] = true
		candidates[#candidates + 1] = p
	end

	if ignoreParty then
		pushCandidate(player)
	else
		local party = player:getParty()
		if party then
			local leader = party:getLeader()
			if not leader or leader:getId() ~= player:getId() then
				return nil, "Only the party leader can start a hunt or boss expedition."
			end
			pushCandidate(leader)
			local members = party:getMembers()
			if type(members) == "table" then
				for _, member in ipairs(members) do
					if member and member:getId() ~= leader:getId() then
						pushCandidate(member)
					end
				end
			end
		else
			pushCandidate(player)
		end
	end

	if type(extraPlayers) == "table" then
		for _, extra in ipairs(extraPlayers) do
			pushCandidate(extra)
		end
	end

	local eligible = {}
	for _, member in ipairs(candidates) do
		if ExpeditionManager.getSessionByPlayer(member) then
			if member:getId() == player:getId() then
				return nil, "Already on an expedition."
			end
			member:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				"You were not pulled into the expedition (already on one)."
			)
		elseif not EM_PRIV.playerHasExpeditionStamina(member) then
			if member:getId() == player:getId() then
				return nil, "You need stamina to enter an expedition."
			end
			member:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				"You were not pulled into the expedition (need stamina)."
			)
		elseif not EM_PRIV.meetsExpeditionLevel(member, levelMin) then
			-- Account-team companions enter with the host; host already passed levelMin.
			local isTeamCompanion = Alts
				and Alts.isCompanion
				and Alts.isCompanion(member)
			if isTeamCompanion then
				eligible[#eligible + 1] = member
			else
				member:sendTextMessage(
					MESSAGE_EVENT_ADVANCE,
					string.format(
						"You were not pulled into the expedition (need level %d, you are %d).",
						levelMin,
						member:getLevel()
					)
				)
			end
		else
			local isTeamCompanion = Alts
				and Alts.isCompanion
				and Alts.isCompanion(member)
			local needCombat = not skipPzCheck
				and not isTeamCompanion
				and PzTeleport
			if needCombat then
				local allowed, combatErr = EM_PRIV.expeditionTeleportCombatOk(member)
				if not allowed then
					if member:getId() == player:getId() then
						return nil, combatErr or "You cannot teleport while PZ-locked."
					end
					member:sendTextMessage(
						MESSAGE_EVENT_ADVANCE,
						"You were not pulled into the expedition (PZ-locked)."
					)
				else
					eligible[#eligible + 1] = member
				end
			else
				eligible[#eligible + 1] = member
			end
		end
	end

	if #eligible == 0 then
		return nil, "No eligible party members for this expedition."
	end
	return eligible
end

function EM_PRIV.memberStanceFromConfig(member)
	return CombatAutomationConfig.configuredStanceForPlayer(member)
end

function EM_PRIV.prepareMemberAutomation(member, loadout, isHost)
	local automation
	if isHost then
		automation = ExpeditionManager.sanitizeAutomation(loadout, member)
		if #(automation.slots or {}) == 0 then
			automation = EM_PRIV.loadPersistedAutomation(member)
		else
			EM_PRIV.persistAutomation(member, automation)
			local state = CombatAutomation.getState(member)
			CombatAutomationStore.applyToRuntime(member, {
				slots = automation.slots,
				autoTarget = state and state.config and state.config.autoTarget or nil,
				_loaded = true,
			})
		end
	else
		automation = EM_PRIV.loadPersistedAutomation(member)
	end
	return automation
end

function EM_PRIV.registerSessionMember(session, member, host, opts)
	opts = opts or {}
	if not session or not member or not host then
		return
	end
	local hostId = host:getId()
	local memberId = member:getId()
	local catalog = session.catalog
	local loadout = opts.loadout
	local hostWorldPos = opts.hostWorldPos
	local companionById = opts.companionById or {}

	session.playerIds = session.playerIds or {}
	session.playerIds[#session.playerIds + 1] = memberId
	session.memberGuids = session.memberGuids or {}
	session.memberGuids[member:getGuid()] = memberId
	session.memberStance = session.memberStance or {}
	do
		local stance, rangedDist = EM_PRIV.memberStanceFromConfig(member)
		session.memberStance[memberId] = stance
		session.memberRangedDistance = session.memberRangedDistance or {}
		session.memberRangedDistance[memberId] = rangedDist
	end
	session.memberAutomation = session.memberAutomation or {}
	local isHost = memberId == hostId
	local automation = EM_PRIV.prepareMemberAutomation(member, loadout, isHost)
	session.memberAutomation[memberId] = automation
	if isHost then
		session.automation = automation
		session.stance = session.memberStance[memberId]
	end

	session.companionIds = session.companionIds or {}
	local fromDeploy = companionById[memberId] == true
	local isCompanion = fromDeploy
		or (Alts.isCompanion(member))
	if isCompanion then
		session.companionIds[memberId] = true
		IdleSafe.call("Alts.markCompanion", Alts.markCompanion, member, host)
		EM_PRIV.saveReturn(member, hostWorldPos)
	else
		EM_PRIV.saveReturn(member)
	end
	EM_PRIV.markActive(member, catalog and catalog.id or "")
	SampleSpells.ensure(member)
	member:registerEvent("ExpeditionPlayerDeath")
	ExpeditionAI.enablePersistence(member)
	EM_PRIV.sessionsByPlayerId[memberId] = session
	if session.entered then
		EM_PRIV.syncHuntPersist(session)
	end
end

