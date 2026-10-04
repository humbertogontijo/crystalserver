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
-- Hunt place → channel → sessionKey. Channel is the team's shard on that subarea.
EM_PRIV.huntChannelsByPlace = EM_PRIV.huntChannelsByPlace or {}
-- Real-client UI sync after headless→client takeover (player id → true).
EM_PRIV.expeditionClientSynced = EM_PRIV.expeditionClientSynced or {}

function EM_PRIV.allocateHuntChannel(placeId, sessionKey)
	local place = tostring(placeId or "")
	local used = EM_PRIV.huntChannelsByPlace[place]
	if not used then
		used = {}
		EM_PRIV.huntChannelsByPlace[place] = used
	end
	local channel = 0
	while used[channel] do
		channel = channel + 1
	end
	used[channel] = sessionKey
	return channel
end

function EM_PRIV.releaseHuntChannel(placeId, channel)
	local place = tostring(placeId or "")
	local used = EM_PRIV.huntChannelsByPlace[place]
	if not used or channel == nil then
		return
	end
	used[math.floor(tonumber(channel) or -1)] = nil
end

function EM_PRIV.playerKey(player)
	return "p" .. player:getGuid()
end

function EM_PRIV.syncClientMaps(session)
	if not session then
		return
	end
	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(mid)
		if p and p.sendMapDescription then
			local pos = p:getPosition()
			if pos then
				p:sendMapDescription(pos)
			end
		end
	end
end

function EM_PRIV.beginExpeditionHunt(session, contentRole)
	if not session or session.state == "ended" then
		return
	end
	EM_PRIV.syncClientMaps(session)
	if contentRole == "arena" then
		if QuestArena and QuestArena.begin then
			QuestArena.begin(session)
		end
	elseif contentRole == "boss" then
		ExpeditionBoss.spawn(session)
	else
		ExpeditionPack.spawn(session)
	end
	ExpeditionAI.start(session)
	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(mid)
		if p and ActivityBoostLedger and ActivityBoostLedger.applyOnExpeditionJoin then
			pcall(ActivityBoostLedger.applyOnExpeditionJoin, p)
		end
	end
end

function ExpeditionManager.getSessionByKey(key)
	return EM_PRIV.sessionsByKey[key]
end

--- Live hunt/raid session bound to an engine instance id (e.g. GOD /goto spectator).
function ExpeditionManager.getSessionByInstanceId(instanceId)
	local id = math.floor(tonumber(instanceId) or 0)
	if id <= 0 then
		return nil
	end
	for _, session in pairs(EM_PRIV.sessionsByKey) do
		if session.state ~= "ended" and session.instance and session.instance.instanceId == id then
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
			if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player) then
				return s
			end
		end
	end
	if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player) then
		local controller = TeamManager.getCompanionController and TeamManager.getCompanionController(player)
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
	if session.instance and session.instance.instanceId and player.getInstanceId then
		return player:getInstanceId() == session.instance.instanceId
	end
	return ExpeditionInstance.contains(session.instance, player:getPosition())
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
	-- Occupancy alone is not enough: shared hunt tiles exist on every instance id.
	-- Match isInExpedition — wrong private id means the player is not in this hunt.
	if session.instance and session.instance.instanceId and player.getInstanceId then
		if player:getInstanceId() == session.instance.instanceId
			and ExpeditionInstance.contains(session.instance, player:getPosition())
		then
			return true
		end
	elseif ExpeditionInstance.contains(session.instance, player:getPosition()) then
		return true
	end

	session.reconciling = true
	if session.kind == "raid" and RaidInstance and RaidInstance.leave then
		RaidInstance.leave(player, { silent = true })
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You left the raid area.")
	else
		ExpeditionManager.leave(player, { silent = true })
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You left the expedition area.")
	end
	return false
end

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

function ExpeditionManager.broadcastStatus(session)
	if not session then
		return
	end
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local player = Player(id)
		if player then
			ExpeditionProtocol.sendStatus(player, session)
		end
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
	if InstanceWorld and InstanceWorld.isTownOnlyPos then
		return InstanceWorld.isTownOnlyPos(pos)
	end
	if not InstanceWorld or not InstanceWorld.classify then
		return true
	end
	local kind = InstanceWorld.classify(pos).kind
	if kind ~= "city" and kind ~= "settlement" and kind ~= "hub" then
		return false
	end
	-- City occupancy can win over hunt masks on shared XY (graves, etc.). Reject
	-- any tile that is also a hunt footprint so leave never parks on the hold.
	if kind ~= "hub" and InstanceWorld.occupancyByHuntId then
		for _, occ in pairs(InstanceWorld.occupancyByHuntId) do
			if occ and occ.contains and occ:contains(pos.x, pos.y) then
				return false
			end
		end
	end
	return true
end

function EM_PRIV.saveReturn(player, pos)
	pos = pos or (player and player:getPosition()) or nil
	if not player or not pos then
		return
	end
	-- Never persist a private-instance or hunt-footprint tile as the post-leave
	-- return point (switch leave→join with skipTeleport used to overwrite temple
	-- with the hunt XY; leave then teleportTo'd the same tile and no-oped).
	local privateBase = (InstanceWorld and InstanceWorld.PRIVATE_BASE) or 3000000
	if player.getInstanceId and (player:getInstanceId() or 0) >= privateBase then
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

function EM_PRIV.teleportPlayerHome(player, returnPos)
	if not player then
		return false
	end
	returnPos = returnPos or EM_PRIV.loadReturn(player)
	if InstanceWorld and InstanceWorld.exitToOpenWorld then
		return InstanceWorld.exitToOpenWorld(player, returnPos)
	end
	if InstanceWorld and InstanceWorld.travel then
		return InstanceWorld.travel(player, returnPos)
	end
	return player:teleportTo(returnPos) and true or false
end

--- After expedition cleanup: hometown temple (recall) or open-world return.
--- Always immediate — the IT channel already completed before leave/abort.
function EM_PRIV.teleportAfterLeave(player, returnPos, opts)
	opts = opts or {}
	if opts.goHometown and InstanceTeleport and InstanceTeleport.executeHometown then
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
	return EM_PRIV.teleportPlayerHome(player, returnPos)
end

--- Combat-lock gate for IT kinds (non-PZ is allowed; duration handles it).
function EM_PRIV.expeditionTeleportCombatOk(player)
	if not player then
		return false, "Invalid player."
	end
	if PzTeleport.isGod(player) then
		return true
	end
	if PzTeleport and PzTeleport.isCombatLocked and PzTeleport.isCombatLocked(player) then
		return false, PzTeleport.PZ_LOCKED_MESSAGE or "You cannot teleport while PZ-locked."
	end
	return true
end

function EM_PRIV.markActive(player, expeditionId, slot)
	player:setStorageValue(ExpeditionConfig.STORAGE_ACTIVE, 1)
	player:setStorageValue(ExpeditionConfig.STORAGE_EXPEDITION_ID, expeditionId and 1 or -1)
	player:setStorageValue(ExpeditionConfig.STORAGE_SLOT, slot or -1)
	-- Store expedition id string via KV when available; storage holds flag only.
	local kv = player:kv()
	if kv then
		kv:set("expedition_id", expeditionId or "")
	end
end

function EM_PRIV.clearActive(player)
	player:setStorageValue(ExpeditionConfig.STORAGE_ACTIVE, -1)
	player:setStorageValue(ExpeditionConfig.STORAGE_SLOT, -1)
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
	if type(onPlayerLeaveRottenArea) == "function" then
		pcall(onPlayerLeaveRottenArea, player)
	elseif player.removeIcon then
		pcall(function()
			player:removeIcon("rotten-hazard")
			player:removeIcon("rotten-area")
			player:removeIcon("white-cross")
		end)
	end
	if player.setHazardSystemPoints then
		pcall(function()
			player:setHazardSystemPoints(0)
		end)
	end
	-- Restore world hazard (e.g. Gnomprona) if still standing in a hazard zone.
	if player.updateHazard then
		pcall(function()
			player:updateHazard()
		end)
	end
	-- Agony fields (Darklight Core) use CONDITION_AGONY with ticks=-1 while standing
	-- on the tile; instance teleports skip step-out so strip it on expedition leave.
	if player.removeCondition then
		pcall(function()
			player:removeCondition(CONDITION_AGONY, CONDITIONID_COMBAT)
			player:removeCondition(CONDITION_AGONY, CONDITIONID_DEFAULT)
		end)
	end
end

function ExpeditionManager.sanitizeAutomation(loadout, player)
	if CombatAutomationStore and CombatAutomationStore.sanitize then
		local config = CombatAutomationStore.sanitize(loadout, player)
		return { slots = config.slots or {} }
	end
	return { slots = {} }
end

function EM_PRIV.persistAutomation(player, automation)
	if CombatAutomationStore and CombatAutomationStore.persist then
		local state = CombatAutomation and CombatAutomation.getState and CombatAutomation.getState(player)
		CombatAutomationStore.persist(player, {
			slots = automation and automation.slots or {},
			autoTarget = state and state.config and state.config.autoTarget or nil,
		})
		return
	end
end

function EM_PRIV.loadPersistedAutomation(player)
	if CombatAutomationStore and CombatAutomationStore.getConfig then
		local config = CombatAutomationStore.getConfig(player)
		return { slots = config.slots or {} }
	end
	return { slots = {} }
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

function ExpeditionManager.markActiveFlag(player, expeditionId, slot)
	EM_PRIV.markActive(player, expeditionId, slot)
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
	if CombatAutomationStore and CombatAutomationStore.setConfig then
		local raw = loadout
		if type(loadout) == "table" and loadout.slots == nil and loadout.loadout == nil then
			-- Accept bare { slots } or array; preserve auto-target when omitted.
			raw = { slots = type(loadout.slots) == "table" and loadout.slots or loadout }
		end
		CombatAutomationStore.setConfig(player, raw)
		return
	end
end

function EM_PRIV.meetsExpeditionLevel(player, levelMin)
	if PzTeleport.isGod(player) then
		return true
	end
	return player:getLevel() >= levelMin
end

function EM_PRIV.playerHasExpeditionStamina(player)
	if ExpeditionSafety and ExpeditionSafety.hasStamina then
		return ExpeditionSafety.hasStamina(player)
	end
	if not configManager.getBoolean(configKeys.STAMINA_SYSTEM) then
		return true
	end
	return player and player.getStamina and player:getStamina() > 0
end

--- nil when all have stamina; otherwise error naming the first blocked player.
function EM_PRIV.partyStaminaError(players)
	if ExpeditionSafety and ExpeditionSafety.firstWithoutStamina then
		local blocked = ExpeditionSafety.firstWithoutStamina(players)
		if blocked then
			return string.format("%s needs stamina to enter an expedition.", blocked:getName())
		end
		return nil
	end
	for _, p in ipairs(players or {}) do
		if p and not EM_PRIV.playerHasExpeditionStamina(p) then
			return string.format("%s needs stamina to enter an expedition.", p:getName())
		end
	end
	return nil
end

--- Players whose stamina must be > 0 before the host can start (not every online friend).
function EM_PRIV.collectStaminaGatePlayers(host, options)
	options = options or {}
	local list = {}
	local seen = {}
	local function push(p)
		if not p or not p.getId then
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
	if options.skipPartyGate then
		-- Solo boss / arena / switch: only host (+ explicit pre-accepted below).
	else
		local party = host:getParty()
		if party then
			local leader = party:getLeader()
			if leader and leader:getId() == host:getId() then
				for _, member in ipairs(party:getMembers() or {}) do
					push(member)
				end
			end
		end
		if ListingsStore and ListingsStore.getAcceptedMemberNames then
			for _, name in ipairs(ListingsStore.getAcceptedMemberNames(host:getGuid()) or {}) do
				push(Player(name))
			end
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
	return TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player)
end

--- True when the player has a live ProtocolGame UI (not headless).
function EM_PRIV.hasUiClient(player)
	if not player then
		return false
	end
	if player.isHeadless and player:isHeadless() then
		return false
	end
	if player.getProtocolVersion and player:getProtocolVersion() == 0 then
		return false
	end
	return true
end

function EM_PRIV.collectSessionHumans(session)
	local humans = {}
	if not session then
		return humans
	end
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		-- Headless (companions or disconnected alts) never need switch accept prompts.
		if p and not EM_PRIV.isSessionCompanion(session, p) and EM_PRIV.hasUiClient(p) then
			humans[#humans + 1] = p
		end
	end
	return humans
end

function EM_PRIV.countHumanMembers(session)
	if not session then
		return 0
	end
	local n = 0
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		if p and not EM_PRIV.isSessionCompanion(session, p) then
			n = n + 1
		end
	end
	return n
end

function EM_PRIV.clearBossAttemptsForSession(session)
	if not session or session.role ~= "boss" then
		return
	end
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		if p and not EM_PRIV.isSessionCompanion(session, p) and ExpeditionConfig.clearBossAttempt then
			ExpeditionConfig.clearBossAttempt(p)
		end
	end
end

function EM_PRIV.refundBossCooldownForSession(session)
	if not session or session.role ~= "boss" or not ExpeditionConfig.bossTypeName or not ExpeditionConfig.clearBossCooldown then
		return
	end
	local bossName = ExpeditionConfig.bossTypeName(session.catalog)
	if not bossName then
		return
	end
	local humans = {}
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		if p and not EM_PRIV.isSessionCompanion(session, p) then
			humans[#humans + 1] = p
		end
	end
	ExpeditionConfig.clearBossCooldown(humans, bossName)
end

function EM_PRIV.syncHuntPersist(session)
	if not session or not ExpeditionPersist then
		return
	end
	if ExpeditionPersist.isPersistableHunt(session) then
		pcall(ExpeditionPersist.writeSession, session)
	elseif ExpeditionPersist.clearSession and not ExpeditionPersist.isServerShuttingDown() then
		pcall(ExpeditionPersist.clearSession, session)
	end
end

function ExpeditionManager.hasPendingRestore(player)
	return ExpeditionPersist and ExpeditionPersist.hasPendingRestore and ExpeditionPersist.hasPendingRestore(player)
end

--- Online human teammates expected to accept before a team expedition starts.
function EM_PRIV.collectExpectedHumanTeammates(host)
	if not host then
		return {}
	end
	local seen = {}
	local list = {}
	local function push(p)
		if not p or p:getId() == host:getId() then
			return
		end
		if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(p) then
			return
		end
		if not EM_PRIV.hasUiClient(p) then
			return
		end
		local id = p:getId()
		if seen[id] then
			return
		end
		seen[id] = true
		list[#list + 1] = p
	end

	local party = host:getParty()
	if party then
		local leader = party:getLeader()
		if leader and leader:getId() == host:getId() then
			for _, member in ipairs(party:getMembers() or {}) do
				push(member)
			end
		end
	end

	local function pushName(name)
		local friend = Player(name)
		if friend then
			push(friend)
		end
	end
	if TeamStore and TeamStore.getFriendNames then
		for _, name in ipairs(TeamStore.getFriendNames(host)) do
			pushName(name)
		end
	end
	if ListingsStore and ListingsStore.getAcceptedMemberNames then
		for _, name in ipairs(ListingsStore.getAcceptedMemberNames(host:getGuid())) do
			pushName(name)
		end
	end
	return list
end

--- Names for the boss-difficulty player boxes: listing/team roster (incl. companions),
--- not only online UI clients used for combat gating.
function EM_PRIV.collectBossDifficultyBannerNames(host)
	local names = {}
	local seen = {}
	local function pushName(name)
		if type(name) ~= "string" or name == "" then
			return
		end
		local key = name:lower()
		if seen[key] then
			return
		end
		seen[key] = true
		names[#names + 1] = name
	end
	if host and host.getName then
		pushName(host:getName())
	end
	if ListingsStore and ListingsStore.getByHost and host then
		local listing = ListingsStore.getByHost(host)
		for _, m in ipairs((listing and listing.members) or {}) do
			local status = m and m.status
			if status == nil or status == (SocialConfig and SocialConfig.MEMBER_STATUS_ACCEPTED) or status == "accepted" then
				pushName(m and m.name)
			end
		end
	end
	if ListingsStore and ListingsStore.getAcceptedMemberNames and host and host.getGuid then
		for _, name in ipairs(ListingsStore.getAcceptedMemberNames(host:getGuid()) or {}) do
			pushName(name)
		end
	end
	if TeamStore and TeamStore.getMembers and host then
		for _, m in ipairs(TeamStore.getMembers(host) or {}) do
			pushName(m and m.name)
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
	if session.acceptTimeoutEvent then
		stopEvent(session.acceptTimeoutEvent)
		session.acceptTimeoutEvent = nil
	end
	session.acceptDeadline = nil
end

function EM_PRIV.armAcceptTimeout(session)
	if not session then
		return
	end
	EM_PRIV.clearAcceptTimeout(session)
	local sec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
	session.acceptDeadline = os.time() + sec
	local key = session.key
	session.acceptTimeoutEvent = addEvent(function()
		local live = ExpeditionManager.getSessionByKey(key)
		if not live or live.entered or live.starting then
			return
		end
		if live.state ~= "pending" then
			return
		end
		live.acceptTimeoutEvent = nil
		ExpeditionManager.cancelWaitingSession(
			live,
			"Team expedition invite timed out."
		)
	end, sec * 1000)
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
			local isTeamCompanion = TeamManager
				and TeamManager.isCompanion
				and TeamManager.isCompanion(member)
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
			local isTeamCompanion = TeamManager
				and TeamManager.isCompanion
				and TeamManager.isCompanion(member)
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
			if CombatAutomationStore and CombatAutomationStore.applyToRuntime then
				local state = CombatAutomation.getState(member)
				CombatAutomationStore.applyToRuntime(member, {
					slots = automation.slots,
					autoTarget = state and state.config and state.config.autoTarget or nil,
					_loaded = true,
				})
			end
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
	local channel = session.channel
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
		or (TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(member))
	if isCompanion then
		session.companionIds[memberId] = true
		if TeamManager and TeamManager.markCompanion then
			pcall(TeamManager.markCompanion, member, host)
		end
		EM_PRIV.saveReturn(member, hostWorldPos)
	else
		EM_PRIV.saveReturn(member)
	end
	EM_PRIV.markActive(member, catalog and catalog.id or "", channel)
	if SampleSpells and SampleSpells.ensure then
		SampleSpells.ensure(member)
	end
	member:registerEvent("ExpeditionPlayerDeath")
	ExpeditionAI.enablePersistence(member)
	EM_PRIV.sessionsByPlayerId[memberId] = session
	if session.entered then
		EM_PRIV.syncHuntPersist(session)
	end
end

