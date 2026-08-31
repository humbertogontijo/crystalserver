ExpeditionManager = ExpeditionManager or {}

local sessionsByKey = {}
local sessionsByPlayerId = {}
-- Voluntary leave countdown (playerId → { event, sessionKey?, team? }).
local leavePendingByPlayerId = {}
-- Team-wide stop countdown (sessionKey → { event, initiatorId }).
local leavePendingBySessionKey = {}
-- Friend expedition invites: friendGuid → { hostGuid, sessionKey, expeditionId, expeditionName, expires }
local teamInvitesByFriendGuid = {}
-- Hunt place → channel → sessionKey. Channel is the team's shard on that subarea.
local huntChannelsByPlace = {}

local function allocateHuntChannel(placeId, sessionKey)
	local place = tostring(placeId or "")
	local used = huntChannelsByPlace[place]
	if not used then
		used = {}
		huntChannelsByPlace[place] = used
	end
	local channel = 0
	while used[channel] do
		channel = channel + 1
	end
	used[channel] = sessionKey
	return channel
end

local function releaseHuntChannel(placeId, channel)
	local place = tostring(placeId or "")
	local used = huntChannelsByPlace[place]
	if not used or channel == nil then
		return
	end
	used[math.floor(tonumber(channel) or -1)] = nil
end

local function isGodPlayer(player)
	return PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)
end

local function playerKey(player)
	return "p" .. player:getGuid()
end

local function syncClientMaps(session)
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

local function beginExpeditionHunt(session, contentRole)
	if not session or session.state == "ended" then
		return
	end
	syncClientMaps(session)
	if contentRole == "boss" then
		ExpeditionBoss.spawn(session)
	else
		ExpeditionWaves.spawn(session)
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
	return sessionsByKey[key]
end

--- Live hunt/raid session bound to an engine instance id (e.g. GOD /goto spectator).
function ExpeditionManager.getSessionByInstanceId(instanceId)
	local id = math.floor(tonumber(instanceId) or 0)
	if id <= 0 then
		return nil
	end
	for _, session in pairs(sessionsByKey) do
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

--- Session lookup for hosts, friends, and headless companions (may be absent from sessionsByPlayerId).
function ExpeditionManager.resolveSession(player)
	if not player then
		return nil
	end
	local session = sessionsByPlayerId[player:getId()]
	if session then
		return session
	end
	local guid = player:getGuid()
	for _, s in pairs(sessionsByKey) do
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
			return sessionsByPlayerId[controller:getId()]
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
	if ExpeditionInstance.contains(session.instance, player:getPosition()) then
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
			if ActivityBoostActivities and ActivityBoostActivities.noteHuntProgress then
				pcall(ActivityBoostActivities.noteHuntProgress, player, session)
			end
		end
	end
end

function ExpeditionManager.reselectAnchor(session)
	if not session or session.kind == "raid" then
		return nil
	end
	return ExpeditionConfig.pickAnchor(session)
end

local function saveReturn(player, pos)
	pos = pos or player:getPosition()
	player:setStorageValue(ExpeditionConfig.STORAGE_RETURN_X, pos.x)
	player:setStorageValue(ExpeditionConfig.STORAGE_RETURN_Y, pos.y)
	player:setStorageValue(ExpeditionConfig.STORAGE_RETURN_Z, pos.z)
end

local function loadReturn(player)
	local x = player:getStorageValue(ExpeditionConfig.STORAGE_RETURN_X)
	local y = player:getStorageValue(ExpeditionConfig.STORAGE_RETURN_Y)
	local z = player:getStorageValue(ExpeditionConfig.STORAGE_RETURN_Z)
	if x < 0 or y < 0 or z < 0 then
		local town = player:getTown()
		if town then
			return town:getTemplePosition()
		end
		return Position(32369, 32241, 7)
	end
	return Position(x, y, z)
end

local function markActive(player, expeditionId, slot)
	player:setStorageValue(ExpeditionConfig.STORAGE_ACTIVE, 1)
	player:setStorageValue(ExpeditionConfig.STORAGE_EXPEDITION_ID, expeditionId and 1 or -1)
	player:setStorageValue(ExpeditionConfig.STORAGE_SLOT, slot or -1)
	-- Store expedition id string via KV when available; storage holds flag only.
	local kv = player:kv()
	if kv then
		kv:set("expedition_id", expeditionId or "")
	end
end

local function clearActive(player)
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
	elseif player.updateHazard then
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

local function persistAutomation(player, automation)
	if CombatAutomationStore and CombatAutomationStore.persist then
		local state = CombatAutomation and CombatAutomation.getState and CombatAutomation.getState(player)
		CombatAutomationStore.persist(player, {
			slots = automation and automation.slots or {},
			autoTarget = state and state.config and state.config.autoTarget or nil,
		})
		return
	end
end

local function loadPersistedAutomation(player)
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
	sessionsByKey[session.key] = session
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		sessionsByPlayerId[id] = session
	end
end

function ExpeditionManager.unbindSession(session)
	if not session then
		return
	end
	if session.key then
		sessionsByKey[session.key] = nil
	end
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		sessionsByPlayerId[id] = nil
	end
	if session.playerId then
		sessionsByPlayerId[session.playerId] = nil
	end
end

function ExpeditionManager.saveReturnPos(player)
	saveReturn(player)
end

function ExpeditionManager.loadReturnPos(player)
	return loadReturn(player)
end

function ExpeditionManager.markActiveFlag(player, expeditionId, slot)
	markActive(player, expeditionId, slot)
end

function ExpeditionManager.clearActiveFlag(player)
	clearActive(player)
end

function ExpeditionManager.persistAutomation(player, automation)
	persistAutomation(player, automation)
end

function ExpeditionManager.loadPersistedAutomation(player)
	return loadPersistedAutomation(player)
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

local function meetsExpeditionLevel(player, levelMin)
	if isGodPlayer(player) then
		return true
	end
	return player:getLevel() >= levelMin
end

--- Collect online party for a hunt/boss: only leader can start; members pulled in.
--- Returns eligible Players list, or nil + error when joiner cannot start.
--- `extraPlayers`: optional Players (e.g. account-team companions) to include even
--- when Party:addMember failed / getMembers is empty - otherwise they stay at the
--- host's world tile while the host teleports into the instance alone.
local function isSessionCompanion(session, player)
	if not player then
		return false
	end
	if session and session.companionIds and session.companionIds[player:getId()] then
		return true
	end
	return TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(player)
end

local function countHumanMembers(session)
	if not session then
		return 0
	end
	local n = 0
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		if p and not isSessionCompanion(session, p) then
			n = n + 1
		end
	end
	return n
end

--- Online human teammates expected to accept before a team expedition starts.
local function collectExpectedHumanTeammates(host)
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

local function awaitingHumanCount(session)
	if type(session.awaitingHumanGuids) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(session.awaitingHumanGuids) do
		n = n + 1
	end
	return n
end

local function clearAcceptTimeout(session)
	if not session then
		return
	end
	if session.acceptTimeoutEvent then
		stopEvent(session.acceptTimeoutEvent)
		session.acceptTimeoutEvent = nil
	end
	session.acceptDeadline = nil
end

local function armAcceptTimeout(session)
	if not session then
		return
	end
	clearAcceptTimeout(session)
	local sec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
	session.acceptDeadline = os.time() + sec
	local key = session.key
	session.acceptTimeoutEvent = addEvent(function()
		local live = ExpeditionManager.getSessionByKey(key)
		if not live or live.entered or live.starting then
			return
		end
		if live.state ~= "waiting" then
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
local function collectHuntJoinParty(player, levelMin, extraPlayers, opts)
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
		elseif not meetsExpeditionLevel(member, levelMin) then
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
			local needPz = not skipPzCheck
				and not isTeamCompanion
				and PzTeleport
				and PzTeleport.isAllowed
			if needPz then
				local allowed = PzTeleport.isAllowed(member)
				if not allowed then
					if member:getId() == player:getId() then
						return nil, "You can only start an expedition from a protection zone."
					end
					member:sendTextMessage(
						MESSAGE_EVENT_ADVANCE,
						"You were not pulled into the expedition (must be in a protection zone)."
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

local function memberStanceFromConfig(member)
	if ExpeditionConfig and ExpeditionConfig.configuredStanceForPlayer then
		return ExpeditionConfig.configuredStanceForPlayer(member)
	end
	local stance = (ExpeditionConfig and ExpeditionConfig.stanceForPlayer and ExpeditionConfig.stanceForPlayer(member))
		or "melee"
	local rangedDist = (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4
	return stance, rangedDist
end

local function prepareMemberAutomation(member, loadout, isHost)
	local automation
	if isHost then
		automation = ExpeditionManager.sanitizeAutomation(loadout, member)
		if #(automation.slots or {}) == 0 then
			automation = loadPersistedAutomation(member)
		else
			persistAutomation(member, automation)
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
		automation = loadPersistedAutomation(member)
	end
	return automation
end

local function registerSessionMember(session, member, host, opts)
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
		local stance, rangedDist = memberStanceFromConfig(member)
		session.memberStance[memberId] = stance
		session.memberRangedDistance = session.memberRangedDistance or {}
		session.memberRangedDistance[memberId] = rangedDist
	end
	session.memberAutomation = session.memberAutomation or {}
	local isHost = memberId == hostId
	local automation = prepareMemberAutomation(member, loadout, isHost)
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
		saveReturn(member, hostWorldPos)
	else
		saveReturn(member)
	end
	markActive(member, catalog and catalog.id or "", channel)
	if SampleSpells and SampleSpells.ensure then
		SampleSpells.ensure(member)
	end
	member:registerEvent("ExpeditionPlayerDeath")
	ExpeditionAI.enablePersistence(member)
	sessionsByPlayerId[memberId] = session
end

function ExpeditionManager.join(player, expeditionId, _role, loadout, lure, options)
	if not player then
		return
	end
	options = options or {}
	-- Switch leave→join already returned from an active expedition; do not require PZ
	-- again (return travel can briefly leave the player off a PZ tile / torn-down hold).
	if not options.skipPzCheck and PzTeleport and PzTeleport.isAllowed then
		local allowed, pzErr = PzTeleport.isAllowed(player)
		if not allowed then
			ExpeditionProtocol.sendError(player, pzErr or "You can only start an expedition from a protection zone.")
			return
		end
	end
	local function recoverStaleSession(session)
		if not session then
			return
		end
		clearActive(player)
		ExpeditionManager.clearAreaEffects(player)
		ExpeditionProtocol.sendEnded(player)
		if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
			TeamManager.undeploy(player)
		end
	end

	local staleSession = ExpeditionManager.resolveSession(player)
	if staleSession and not ExpeditionManager.isInExpedition(player) then
		recoverStaleSession(staleSession)
	elseif staleSession and (staleSession.deadPlayerIds and staleSession.deadPlayerIds[player:getId()]) then
		recoverStaleSession(staleSession)
	end
	if ExpeditionManager.isInExpedition(player) then
		-- Switch leave→join can still see a sticky session for one tick; force clear.
		if options.skipPzCheck then
			ExpeditionManager.leave(player, {
				silent = true,
				keepTeamDeployed = true,
				skipTeamUndeploy = true,
			})
			clearActive(player)
		end
		if ExpeditionManager.isInExpedition(player) then
			ExpeditionProtocol.sendError(player, "Already on an expedition.")
			return
		end
	end
	-- Companion-death races can leave STORAGE_ACTIVE set without a live session.
	if player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
		clearActive(player)
		if TeamManager and TeamManager.undeploy then
			pcall(TeamManager.undeploy, player)
		end
		ExpeditionProtocol.sendEnded(player)
	end
	if RaidInstance and RaidInstance.getActive and type(expeditionId) == "string" and RaidInstance.getActive(expeditionId) then
		ExpeditionProtocol.sendError(player, "Use joinRaid for active raids.")
		return
	end

	-- Catalog ids are numeric (hunt subarea / bossRaceId); optional role disambiguates collisions.
	local catalog = ExpeditionConfig.getById(expeditionId, _role)
	if not catalog then
		ExpeditionProtocol.sendError(
			player,
			string.format("Unknown expedition (%s).", tostring(expeditionId or ""))
		)
		return
	end
	if catalog.exclusiveKitno and QuestsKitnoBoss and QuestsKitnoBoss.canJoin then
		local can, kitnoErr = QuestsKitnoBoss.canJoin(player, catalog)
		if not can then
			ExpeditionProtocol.sendError(player, kitnoErr or "This exclusive boss is locked.")
			return
		end
	end
	local kind = "hunt"
	local contentRole = catalog.role
	if contentRole ~= "boss" and contentRole ~= "monster" then
		contentRole = catalog.kind == "boss" and "boss" or "monster"
	end

	if contentRole == "boss" and ActivityBoostSoloBoss and ActivityBoostSoloBoss.canJoin then
		local solo = ActivityBoostSoloBoss.get(player)
		if solo and tostring(solo.expeditionId) == tostring(catalog.id) then
			local can, rushErr = ActivityBoostSoloBoss.canJoin(player, catalog.id)
			if not can then
				ExpeditionProtocol.sendError(player, rushErr or "Boss Rush unavailable.")
				return
			end
			ActivityBoostSoloBoss.markAttempt(player, catalog.id)
		end
	end

	local levelMin = catalog.levelMin or 1
	if not meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		return
	end

	local sessionLure = nil
	local sessionLureMax = nil
	if contentRole ~= "boss" then
		sessionLureMax = tonumber(catalog.lureMax) or ExpeditionConfig.LURE_MAX
		sessionLure = ExpeditionConfig.normalizeLure(lure, sessionLureMax)
	end
	local stopOpts = ExpeditionConfig.normalizeStopOptions(options)

	if ListingsStore and ListingsStore.hasPendingMembers and ListingsStore.hasPendingMembers(player) then
		-- Instant join removed pending accepts; ignore leftover pending for Start.
	end

	-- Capture host world tile before companions spawn at instance entry.
	local hostWorldPos = player:getPosition()

	-- Build the private instance before team login so companions can spawn at entry.
	local instanceId = ExpeditionInstance.allocate()
	if instanceId == nil then
		ExpeditionProtocol.sendError(player, "No expedition instances available.")
		return
	end

	local instance, err = ExpeditionInstance.build(instanceId, catalog, player:getGuid() + os.time())
	if not instance then
		ExpeditionInstance.free(instanceId)
		ExpeditionProtocol.sendError(player, err or "Failed to build expedition instance.")
		return
	end

	-- Account companions deploy when the expedition actually starts (after teammates accept).
	local soloBoss = contentRole == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(catalog)

	-- Host only until teammates accept; companions join at synchronized entry.
	local members, partyErr = collectHuntJoinParty(player, levelMin, nil, {
		ignoreParty = true,
		skipPzCheck = options.skipPzCheck == true,
	})
	if not members then
		ExpeditionInstance.teardown(instance)
		ExpeditionProtocol.sendError(player, partyErr or "Unable to gather party for expedition.")
		return
	end

	local expectedTeammates = soloBoss and {} or collectExpectedHumanTeammates(player)
	-- Direct hunt→hunt switch (skipPzCheck): do not pull in listing members who
	-- were not part of the mid-hunt accept; only preAcceptedPlayers transfer.
	if options.skipPzCheck then
		expectedTeammates = {}
	end
	local bossName = nil
	if contentRole == "boss" then
		bossName = ExpeditionConfig.bossTypeName(catalog)
		if not bossName then
			ExpeditionInstance.teardown(instance)
			ExpeditionProtocol.sendError(player, "Unknown boss type for this expedition.")
			return
		end
		local bossCheckMembers = { player }
		for _, teammate in ipairs(expectedTeammates) do
			bossCheckMembers[#bossCheckMembers + 1] = teammate
		end
		local canFight, _, _, cdErr = ExpeditionConfig.partyCanFightBoss(bossCheckMembers, bossName)
		if not canFight then
			ExpeditionInstance.teardown(instance)
			ExpeditionProtocol.sendError(player, cdErr or "A team member is on boss cooldown.")
			return
		end
		ExpeditionConfig.applyBossCooldown({ player }, bossName)
	end

	local playerIds = {}
	local companionIds = {}
	local memberStance = {}
	local memberRangedDistance = {}
	local memberAutomation = {}
	local memberGuids = {}
	local hostId = player:getId()
	local hostAutomation = nil
	local key = playerKey(player)
	local channel = allocateHuntChannel(catalog.id, key)

	for _, member in ipairs(members) do
		local memberId = member:getId()
		playerIds[#playerIds + 1] = memberId
		memberGuids[member:getGuid()] = memberId
		local stance, rangedDist = memberStanceFromConfig(member)
		memberStance[memberId] = stance
		memberRangedDistance[memberId] = rangedDist
		local isHost = memberId == hostId
		local automation = prepareMemberAutomation(member, loadout, isHost)
		memberAutomation[memberId] = automation
		if isHost then
			hostAutomation = automation
		end
		saveReturn(member)
		markActive(member, catalog.id, channel)
		if SampleSpells and SampleSpells.ensure then
			SampleSpells.ensure(member)
		end
		member:registerEvent("ExpeditionPlayerDeath")
		ExpeditionAI.enablePersistence(member)
	end

	local awaitingHumanGuids = {}
	local readyTeammates = {}
	local hostGuid = player:getGuid()
	local preAcceptedById = {}
	if type(options.preAcceptedPlayers) == "table" then
		for _, teammate in ipairs(options.preAcceptedPlayers) do
			if teammate and teammate.getId then
				preAcceptedById[teammate:getId()] = true
			end
		end
	end
	-- Direct hunt→hunt switch: teammates already accepted while still in the prior session.
	for _, teammate in ipairs(options.preAcceptedPlayers or {}) do
		if teammate and teammate.getGuid and not ExpeditionManager.getSessionByPlayer(teammate) then
			if meetsExpeditionLevel(teammate, levelMin) then
				readyTeammates[#readyTeammates + 1] = teammate
			else
				ExpeditionProtocol.sendError(
					teammate,
					string.format("Level too low for this expedition (need %d, you are %d).", levelMin, teammate:getLevel())
				)
			end
		end
	end
	for _, teammate in ipairs(expectedTeammates) do
		if teammate and teammate.getGuid and not ExpeditionManager.getSessionByPlayer(teammate) then
			if preAcceptedById[teammate:getId()] then
				-- Already queued via preAcceptedPlayers.
			elseif meetsExpeditionLevel(teammate, levelMin) then
				local allowed = true
				-- Switch hops skip PZ: teammates are still on the prior hunt footprint.
				if not options.skipPzCheck and PzTeleport and PzTeleport.isAllowed then
					allowed = PzTeleport.isAllowed(teammate) == true
				end
				local isReady = ListingsStore
					and ListingsStore.isMemberReady
					and ListingsStore.isMemberReady(hostGuid, teammate:getGuid())
				if isReady and allowed then
					readyTeammates[#readyTeammates + 1] = teammate
				elseif allowed then
					awaitingHumanGuids[teammate:getGuid()] = teammate:getName()
				elseif isReady and not allowed then
					-- Ready but not in PZ: fall back to accept modal if they become eligible.
					awaitingHumanGuids[teammate:getGuid()] = teammate:getName()
				end
			end
		end
	end

	local session = {
		key = key,
		playerId = hostId,
		playerIds = playerIds,
		companionIds = companionIds,
		guid = player:getGuid(),
		memberGuids = memberGuids,
		catalog = catalog,
		kind = kind,
		role = contentRole,
		encounter = contentRole == "boss" and ExpeditionConfig.bossEncounter(catalog) or nil,
		channel = channel,
		stance = memberStance[hostId],
		memberStance = memberStance,
		memberRangedDistance = memberRangedDistance,
		instance = instance,
		wave = 0,
		alive = 0,
		kills = 0,
		lure = sessionLure,
		lureMax = sessionLureMax,
		waveLure = nil,
		state = (awaitingHumanCount({ awaitingHumanGuids = awaitingHumanGuids }) > 0 or #readyTeammates > 0)
				and "waiting"
			or "idle",
		startedAt = os.time(),
		positionIndex = 0,
		holdPos = nil,
		automation = hostAutomation or { slots = {} },
		memberAutomation = memberAutomation,
		lastSyncedAttackByPlayer = {},
		prevAutoTargetByPlayer = {},
		stopOnInsufficientGold = stopOpts.stopOnInsufficientGold,
		stopOnInsufficientCap = stopOpts.stopOnInsufficientCap,
		awaitingHumanGuids = awaitingHumanGuids,
		pendingStart = {
			loadout = loadout,
			hostWorldPos = hostWorldPos,
			soloBoss = soloBoss,
		},
	}
	sessionsByKey[key] = session
	for _, mid in ipairs(playerIds) do
		sessionsByPlayerId[mid] = session
	end
	ExpeditionConfig.pickAnchor(session)

	if instance and instance.entry then
		session.holdPos = Position(instance.entry.x, instance.entry.y, instance.entry.z)
		session.positionIndex = 0
		local holds = ExpeditionConfig.catalogPositions and ExpeditionConfig.catalogPositions(catalog) or {}
		for i, h in ipairs(holds) do
			if h and h.x == instance.entry.x and h.y == instance.entry.y and h.z == instance.entry.z then
				session.positionIndex = i
				break
			end
		end
	end

	ExpeditionManager.broadcastStatus(session)

	-- Auto-pull Ready members (skip accept modal). Attach silently, then enter or wait.
	for _, teammate in ipairs(readyTeammates) do
		if TeamManager and TeamManager.forceJoinFriendToParty then
			pcall(TeamManager.forceJoinFriendToParty, player, teammate)
		end
		ExpeditionManager.attachFriendToSession(teammate, session, player, { skipMaybeStart = true })
		teammate:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("You were Ready — joining %s's expedition: %s.", player:getName(), catalog.name)
		)
	end

	if awaitingHumanCount(session) > 0 then
		armAcceptTimeout(session)
		ExpeditionManager.broadcastStatus(session)
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"Waiting for %d teammate(s) to accept before starting %s.",
				awaitingHumanCount(session),
				catalog.name
			)
		)
		ExpeditionManager.inviteTeamFriends(player, session)
		logger.info(
			"[Expedition] {} waiting for teammates on {} role={} instance={} awaiting={} readyPulled={} timeout={}s",
			player:getName(),
			catalog.id,
			contentRole,
			instance.instanceId,
			awaitingHumanCount(session),
			#readyTeammates,
			math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
		)
		return
	end

	ExpeditionManager.startExpeditionEntry(session)
end

function ExpeditionManager.startExpeditionEntry(session)
	if not session or session.entered or session.starting then
		return
	end
	session.starting = true
	local host = Player(session.playerId)
	if not host then
		ExpeditionManager.teardownSession(session)
		return
	end

	local pending = session.pendingStart or {}
	local loadout = pending.loadout
	local hostWorldPos = pending.hostWorldPos or host:getPosition()
	local soloBoss = pending.soloBoss == true
	local catalog = session.catalog
	local contentRole = session.role
	local instance = session.instance
	local key = session.key
	local sessionLure = session.lure

	-- Clear waiting UI on clients before companion deploy / entry teleports.
	clearAcceptTimeout(session)
	session.state = "idle"
	session.awaitingHumanGuids = nil
	session.pendingStart = nil
	ExpeditionManager.broadcastStatus(session)

	local function finishEntry(s)
		if not s then
			return
		end
		s.entered = true
		s.starting = nil
		ExpeditionConfig.pickAnchor(s)
		local sessionKey = s.key
		local role = contentRole
		local syncMs = ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500
		addEvent(function()
			local live = ExpeditionManager.getSessionByKey(sessionKey)
			if not live or live.state == "ended" then
				return
			end
			beginExpeditionHunt(live, role)
			logger.info(
				"[Expedition] party entered {} role={} instance={} channel={} members={} lure={} anchor={}",
				catalog.id,
				role,
				instance.instanceId,
				tostring(live.channel or "-"),
				#ExpeditionManager.sessionMemberIds(live),
				tostring(sessionLure or "-"),
				tostring(live.anchorPlayerId or "-")
			)
		end, syncMs)
	end

	local function teleportMembers(s)
		local enteredAny = false
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
			local p = Player(mid)
			if p then
				p:setFollowCreature(nil)
				local atEntry = false
				local ppos = p:getPosition()
				local engineId = p.getInstanceId and p:getInstanceId() or 0
				if ppos and instance.entry
					and engineId == instance.instanceId
					and ppos.x == instance.entry.x
					and ppos.y == instance.entry.y
					and ppos.z == instance.entry.z
				then
					atEntry = true
				end
				if not atEntry then
					local ok = false
					if InstanceWorld and InstanceWorld.enterInstance then
						ok = InstanceWorld.enterInstance(p, instance.instanceId, instance.entry, "hunt:" .. tostring(s.key or catalog.id))
					else
						if p.setInstanceId then
							p:setInstanceId(instance.instanceId)
						end
						ok = p:teleportTo(instance.entry)
					end
					if not ok then
						logger.error(
							"[Expedition] {} teleport failed to {},{},{} ({})",
							p:getName(),
							instance.entry.x,
							instance.entry.y,
							instance.entry.z,
							catalog.id
						)
						if mid == s.playerId then
							ExpeditionProtocol.sendError(p, "Failed to enter expedition (teleport blocked).")
							ExpeditionManager.leaveAll(s, { silent = true })
							return false
						end
						ExpeditionProtocol.sendError(p, "Failed to enter expedition (teleport blocked).")
						ExpeditionManager.leave(p, { silent = true })
					else
						if ExpeditionInstance.sendMagicEffect then
							ExpeditionInstance.sendMagicEffect(s.instance, p:getPosition(), CONST_ME_TELEPORT)
						else
							p:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
						end
						enteredAny = true
						local stance = s.memberStance and s.memberStance[mid] or s.stance
						if contentRole == "boss" then
							local encounter = ExpeditionConfig.bossEncounter and ExpeditionConfig.bossEncounter(catalog)
								or "lever"
							local label = encounter == "solo" and "Solo boss" or "Lever boss"
							p:sendTextMessage(
								MESSAGE_EVENT_ADVANCE,
								string.format("%s expedition started: %s (stance: %s)", label, catalog.name, stance or "melee")
							)
						else
							p:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Expedition started: " .. catalog.name)
						end
						ExpeditionProtocol.sendStatus(p, s)
					end
				else
					enteredAny = true
					ExpeditionProtocol.sendStatus(p, s)
				end
			end
		end
		if not enteredAny then
			ExpeditionManager.teardownSession(s)
			return false
		end
		return true
	end

	local function deployAndEnter()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s then
			logger.warn("[Expedition] enter aborted (session gone) key={}", key)
			return
		end
		local liveHost = Player(s.playerId)
		if not liveHost then
			logger.warn("[Expedition] enter aborted (host offline) key={}", key)
			ExpeditionManager.teardownSession(s)
			return
		end

		-- Login companions in the city (host tile), register them, then teleport the
		-- whole party together. Spawning at instance.entry races InstanceWorld login
		-- rescue (hunt tile / private id before session bind) and left everyone in town.
		if not soloBoss and TeamManager and TeamManager.deploy then
			local spawnPos = liveHost:getPosition() or hostWorldPos
			local depCompanions, depErr = TeamManager.deploy(liveHost, {
				position = spawnPos,
				companionsOnly = true,
				inviteFriends = false,
			})
			if not depCompanions then
				ExpeditionManager.cancelWaitingSession(s, depErr or "Failed to deploy account team.")
				return
			end
			local companionById = {}
			for _, companion in ipairs(depCompanions) do
				if companion and companion.getId then
					companionById[companion:getId()] = true
				end
			end
			for _, companion in ipairs(depCompanions) do
				local already = false
				for _, mid in ipairs(s.playerIds or {}) do
					if companion and companion.getId and mid == companion:getId() then
						already = true
						break
					end
				end
				if not already then
					registerSessionMember(s, companion, liveHost, {
						loadout = loadout,
						hostWorldPos = hostWorldPos,
						companionById = companionById,
					})
				end
			end
		end

		if not teleportMembers(s) then
			return
		end
		finishEntry(s)
		logger.info(
			"[Expedition] {} joined {} role={} instance={} members={} (entered)",
			liveHost:getName(),
			catalog.id,
			contentRole,
			instance.instanceId,
			#ExpeditionManager.sessionMemberIds(s)
		)
		ExpeditionManager.broadcastStatus(s)
	end

	local attempts = 0
	local function waitGroundThenEnter()
		attempts = attempts + 1
		local s = ExpeditionManager.getSessionByKey(key)
		if not s then
			logger.warn("[Expedition] enter aborted (session gone) key={} attempts={}", key, attempts)
			return
		end
		if not Player(s.playerId) then
			logger.warn("[Expedition] enter aborted (host offline) key={} attempts={}", key, attempts)
			ExpeditionManager.teardownSession(s)
			return
		end
		if not ExpeditionInstance.hasGround(instance.entry) and attempts < 12 then
			addEvent(waitGroundThenEnter, 100)
			return
		end
		deployAndEnter()
	end
	waitGroundThenEnter()
end

function ExpeditionManager.maybeStartExpeditionEntry(session)
	if not session or session.entered or session.starting then
		return
	end
	if awaitingHumanCount(session) > 0 then
		return
	end
	ExpeditionManager.startExpeditionEntry(session)
end

function ExpeditionManager.cancelWaitingSession(session, reason)
	if not session or session.entered then
		return
	end
	clearAcceptTimeout(session)
	local message = tostring(reason or "Expedition cancelled.")
	for guid in pairs(teamInvitesByFriendGuid) do
		local invite = teamInvitesByFriendGuid[guid]
		if invite and invite.sessionKey == session.key then
			teamInvitesByFriendGuid[guid] = nil
			local friend = Player(guid)
			if friend then
				ExpeditionProtocol.send(friend, { type = "teamExpeditionInviteCleared" })
			end
		end
	end
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		if p then
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			clearActive(p)
			ExpeditionManager.clearAreaEffects(p)
			ExpeditionProtocol.sendEnded(p)
			p:unregisterEvent("ExpeditionPlayerDeath")
		end
	end
	if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(Player(session.playerId)) then
		local host = Player(session.playerId)
		if host then
			TeamManager.undeploy(host)
		end
	end
	ExpeditionManager.teardownSession(session)
end

--- Invite online team friends / listing members to join this hunt/boss session (accept → auto-party + enter).
function ExpeditionManager.inviteTeamFriends(host, session)
	if not host or not session then
		return
	end
	if session.kind == "raid" then
		return
	end
	-- Solo boss fights are host-only (no companions, no friend pull-ins).
	if session.role == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(session.catalog) then
		return
	end
	local expeditionId = session.catalog and session.catalog.id or ""
	local expeditionName = session.catalog and session.catalog.name or expeditionId
	local timeoutSec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
	local expires = session.acceptDeadline or (os.time() + timeoutSec)

	local inviteNames = {}
	local seen = {}
	local function pushName(name)
		name = tostring(name or "")
		if name == "" then
			return
		end
		local key = name:lower()
		if seen[key] then
			return
		end
		seen[key] = true
		inviteNames[#inviteNames + 1] = name
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
	local party = host:getParty()
	if party then
		local leader = party:getLeader()
		if leader and leader:getId() == host:getId() then
			for _, member in ipairs(party:getMembers() or {}) do
				if member then
					pushName(member:getName())
				end
			end
		end
	end

	for _, name in ipairs(inviteNames) do
		local friend = Player(name)
		if friend and friend:getId() ~= host:getId() then
			if session.awaitingHumanGuids and not session.awaitingHumanGuids[friend:getGuid()] then
				-- Not part of this team start.
			elseif ExpeditionManager.getSessionByPlayer(friend) then
				-- Already on an expedition.
			else
				local allowed = false
				if TeamStore and TeamStore.isFriend and TeamStore.isFriend(host, friend:getGuid()) then
					allowed = true
				elseif ListingsStore and ListingsStore.isListingMember and ListingsStore.isListingMember(host:getGuid(), friend:getGuid()) then
					allowed = true
				elseif party then
					for _, member in ipairs(party:getMembers() or {}) do
						if member and member:getId() == friend:getId() then
							allowed = true
							break
						end
					end
				end
				if allowed then
					teamInvitesByFriendGuid[friend:getGuid()] = {
						hostGuid = host:getGuid(),
						hostName = host:getName(),
						sessionKey = session.key,
						expeditionId = expeditionId,
						expeditionName = expeditionName,
						expires = expires,
					}
					ExpeditionProtocol.send(friend, {
						type = "teamExpeditionInvite",
						hostName = host:getName(),
						hostGuid = host:getGuid(),
						expeditionId = expeditionId,
						expeditionName = expeditionName,
						expires = expires,
						acceptDeadline = expires,
						acceptTimeoutSec = timeoutSec,
					})
					friend:sendTextMessage(
						MESSAGE_EVENT_ADVANCE,
						string.format(
							"%s invited you to expedition: %s. Accept from the expedition panel.",
							host:getName(),
							expeditionName
						)
					)
				end
			end
		end
	end
end

function ExpeditionManager.declineTeamInvite(player)
	if not player then
		return
	end
	local invite = teamInvitesByFriendGuid[player:getGuid()]
	teamInvitesByFriendGuid[player:getGuid()] = nil
	ExpeditionProtocol.send(player, { type = "teamExpeditionInviteCleared" })
	if invite and invite.sessionKey then
		local session = ExpeditionManager.getSessionByKey(invite.sessionKey)
		if session and session.state == "waiting" and session.awaitingHumanGuids then
			if session.awaitingHumanGuids[player:getGuid()] then
				ExpeditionManager.cancelWaitingSession(
					session,
					string.format("%s declined the expedition invite.", player:getName())
				)
			end
		end
	end
end

--- Friend accepted expedition play: leave/disband old party, force-join host party, enter session.
function ExpeditionManager.acceptTeamInvite(player)
	if not player then
		return
	end
	if PzTeleport and PzTeleport.isAllowed then
		local allowed, pzErr = PzTeleport.isAllowed(player)
		if not allowed then
			ExpeditionProtocol.sendError(player, pzErr or "You can only join an expedition from a protection zone.")
			return
		end
	end
	local invite = teamInvitesByFriendGuid[player:getGuid()]
	if not invite then
		ExpeditionProtocol.sendError(player, "No pending team expedition invite.")
		return
	end
	if invite.expires and os.time() > invite.expires then
		teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "That expedition invite expired.")
		return
	end
	if ExpeditionManager.getSessionByPlayer(player) then
		teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Already on an expedition.")
		return
	end

	local session = ExpeditionManager.getSessionByKey(invite.sessionKey)
	if not session or session.state == "ended" then
		teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "That expedition is no longer active.")
		return
	end
	if session.role == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(session.catalog) then
		teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Solo boss expeditions cannot be joined by friends.")
		return
	end

	local host = Player(session.playerId)
	if not host then
		-- Try resolve by guid from invite.
		host = nil
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
			local p = Player(mid)
			if p and p:getGuid() == invite.hostGuid then
				host = p
				break
			end
		end
	end
	if not host then
		teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Expedition host is offline.")
		return
	end

	local allowed = false
	if TeamStore and TeamStore.isFriend and TeamStore.isFriend(host, player:getGuid()) then
		allowed = true
	elseif ListingsStore and ListingsStore.isListingMember and ListingsStore.isListingMember(host:getGuid(), player:getGuid()) then
		allowed = true
	else
		local party = host:getParty()
		if party then
			for _, member in ipairs(party:getMembers() or {}) do
				if member and member:getId() == player:getId() then
					allowed = true
					break
				end
			end
		end
	end
	if not allowed then
		teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Only friends or listing members can join this team expedition.")
		return
	end

	local sessionRole = session.role
	if sessionRole ~= "boss" and sessionRole ~= "monster" then
		sessionRole = session.catalog and session.catalog.role or "monster"
	end
	if sessionRole == "boss" then
		local bossName = ExpeditionConfig.bossTypeName(session.catalog)
		if not bossName then
			ExpeditionProtocol.sendError(player, "Unknown boss type for this expedition.")
			return
		end
		local canFight, _, _, cdErr = ExpeditionConfig.partyCanFightBoss({ player }, bossName)
		if not canFight then
			ExpeditionProtocol.sendError(player, cdErr or "You are on boss cooldown.")
			return
		end
	end

	if TeamManager and TeamManager.forceJoinFriendToParty then
		local ok, err = TeamManager.forceJoinFriendToParty(host, player)
		if not ok then
			ExpeditionProtocol.sendError(player, err or "Failed to join expedition party.")
			return
		end
	end

	teamInvitesByFriendGuid[player:getGuid()] = nil
	ExpeditionManager.attachFriendToSession(player, session, host)
end

function ExpeditionManager.attachFriendToSession(friend, session, host, opts)
	opts = opts or {}
	if not friend or not session then
		return
	end
	if ExpeditionManager.getSessionByPlayer(friend) then
		return
	end
	if session.role == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(session.catalog) then
		ExpeditionProtocol.sendError(friend, "Solo boss expeditions cannot be joined by friends.")
		return
	end

	local friendId = friend:getId()
	local catalog = session.catalog
	local instance = session.instance
	if not instance or not instance.entry then
		ExpeditionProtocol.sendError(friend, "Expedition instance unavailable.")
		return
	end

	local sessionRole = session.role
	if sessionRole ~= "boss" and sessionRole ~= "monster" then
		sessionRole = catalog and catalog.role or "monster"
	end
	if sessionRole == "boss" then
		local bossName = ExpeditionConfig.bossTypeName(catalog)
		if not bossName then
			ExpeditionProtocol.sendError(friend, "Unknown boss type for this expedition.")
			return
		end
		local canFight, _, _, cdErr = ExpeditionConfig.partyCanFightBoss({ friend }, bossName)
		if not canFight then
			ExpeditionProtocol.sendError(friend, cdErr or "You are on boss cooldown.")
			return
		end
		ExpeditionConfig.applyBossCooldown({ friend }, bossName)
	end

	saveReturn(friend)
	markActive(friend, catalog and catalog.id or "", session.channel or 0)
	if SampleSpells and SampleSpells.ensure then
		SampleSpells.ensure(friend)
	end
	friend:registerEvent("ExpeditionPlayerDeath")
	ExpeditionAI.enablePersistence(friend)

	session.playerIds = session.playerIds or { session.playerId }
	session.playerIds[#session.playerIds + 1] = friendId
	session.memberGuids = session.memberGuids or {}
	session.memberGuids[friend:getGuid()] = friendId
	session.memberStance = session.memberStance or {}
	do
		local stance, rangedDist = memberStanceFromConfig(friend)
		session.memberStance[friendId] = stance
		session.memberRangedDistance = session.memberRangedDistance or {}
		session.memberRangedDistance[friendId] = rangedDist
	end
	session.memberAutomation = session.memberAutomation or {}
	session.memberAutomation[friendId] = prepareMemberAutomation(friend, nil, false)
	sessionsByPlayerId[friendId] = session

	if session.state == "waiting" or not session.entered then
		if session.awaitingHumanGuids then
			session.awaitingHumanGuids[friend:getGuid()] = nil
		end
		if not opts.skipMaybeStart then
			friend:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format(
					"Accepted %s's expedition: %s. Waiting for the team to start...",
					host and host:getName() or "team",
					catalog and catalog.name or (catalog and catalog.id) or "expedition"
				)
			)
		end
		ExpeditionProtocol.send(friend, { type = "teamExpeditionInviteCleared" })
		ExpeditionProtocol.sendStatus(friend, session)
		ExpeditionManager.broadcastStatus(session)
		if not opts.skipMaybeStart then
			ExpeditionManager.maybeStartExpeditionEntry(session)
		end
		logger.info(
			"[Expedition] friend {} accepted waiting session {}",
			friend:getName(),
			tostring(session.key)
		)
		return
	end

	friend:setFollowCreature(nil)
	local entered = false
	if InstanceWorld and InstanceWorld.enterInstance then
		entered = InstanceWorld.enterInstance(friend, instance.instanceId, instance.entry, "hunt:" .. tostring(session.key or ""))
	else
		if friend.setInstanceId then
			friend:setInstanceId(instance.instanceId)
		end
		entered = friend:teleportTo(instance.entry)
	end
	if not entered then
		ExpeditionProtocol.sendError(friend, "Failed to enter expedition (teleport blocked).")
		ExpeditionManager.leave(friend, { silent = true })
		return
	end
	if ExpeditionInstance.sendMagicEffect then
		ExpeditionInstance.sendMagicEffect(instance, friend:getPosition(), CONST_ME_TELEPORT)
	else
		friend:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	end
	friend:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format(
			"Joined %s's expedition: %s",
			host and host:getName() or "team",
			catalog and catalog.name or (catalog and catalog.id) or "expedition"
		)
	)
	ExpeditionProtocol.send(friend, { type = "teamExpeditionInviteCleared" })
	ExpeditionProtocol.sendStatus(friend, session)
	ExpeditionManager.broadcastStatus(session)
	ExpeditionConfig.pickAnchor(session)
	local friendSessionKey = session.key
	addEvent(function()
		local live = ExpeditionManager.getSessionByKey(friendSessionKey)
		if live and Player(friendId) then
			syncClientMaps(live)
		end
	end, ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500)
	logger.info(
		"[Expedition] friend {} joined session {} via team invite",
		friend:getName(),
		tostring(session.key)
	)
end

local function sessionMemberIds(session)
	return ExpeditionManager.sessionMemberIds(session)
end

--- Drop one hunt/boss member without tearing down the party session (unless last).
local function removeHuntMember(session, player, opts)
	opts = opts or {}
	if not session or not player then
		return
	end
	local playerId = player:getId()
	sessionsByPlayerId[playerId] = nil

	if type(session.playerIds) == "table" then
		local nextIds = {}
		for _, id in ipairs(session.playerIds) do
			if id ~= playerId then
				nextIds[#nextIds + 1] = id
			end
		end
		session.playerIds = nextIds
	end
	if session.memberGuids then
		session.memberGuids[player:getGuid()] = nil
	end
	if session.companionIds then
		session.companionIds[playerId] = nil
	end
	if session.memberStance then
		session.memberStance[playerId] = nil
	end
	if session.memberRangedDistance then
		session.memberRangedDistance[playerId] = nil
	end
	if session.memberAutomation then
		session.memberAutomation[playerId] = nil
	end
	if session.prevAutoTargetByPlayer then
		session.prevAutoTargetByPlayer[playerId] = nil
	end
	if session.lastSyncedAttackByPlayer then
		session.lastSyncedAttackByPlayer[playerId] = nil
	end
	if session.deadPlayerIds and not opts.keepDeadFlag then
		session.deadPlayerIds[playerId] = nil
	end

	if ExpeditionAI.stopPlayer then
		ExpeditionAI.stopPlayer(session, player)
	else
		player:setFollowCreature(nil)
		player:setTarget(nil)
		player:setIdleCombat(false)
		player:removeCondition(CONDITION_INFIGHT)
		ExpeditionProtocol.sendAttackTarget(player, 0)
	end
	player:unregisterEvent("ExpeditionPlayerDeath")
	clearActive(player)

	if session.playerId == playerId then
		-- Promote a remaining member as host when the leader leaves.
		local remaining = ExpeditionManager.sessionMemberIds(session)
		session.playerId = remaining[1]
		if session.playerId then
			local host = Player(session.playerId)
			if host then
				session.guid = host:getGuid()
			end
			if session.memberAutomation and session.memberAutomation[session.playerId] then
				session.automation = session.memberAutomation[session.playerId]
			end
			if session.memberStance and session.memberStance[session.playerId] then
				session.stance = session.memberStance[session.playerId]
			end
		else
			session.playerId = nil
		end
	end

	if session.anchorPlayerId == playerId then
		ExpeditionManager.reselectAnchor(session)
	end

	if not opts.skipEnded then
		ExpeditionProtocol.sendEnded(player)
	end
end

local function cancelTeardownEvent(session)
	if session and session.teardownEvent then
		stopEvent(session.teardownEvent)
		session.teardownEvent = nil
	end
end

local function disbandExpeditionParty(session)
	if not session or session.kind == "raid" then
		return
	end
	local host = Player(session.playerId)
	if not host then
		return
	end
	local party = host:getParty()
	if not party then
		return
	end
	local leader = party:getLeader()
	if not leader or leader:getId() ~= host:getId() then
		return
	end
	pcall(function()
		party:disband()
	end)
end

local function cleanupSession(session, player)
	if not session or session._cleaned then
		return
	end
	session._cleaned = true
	cancelTeardownEvent(session)
	ExpeditionAI.stop(session)
	if session.role == "boss" and session.kind ~= "raid" then
		ExpeditionBoss.clear(session)
	elseif session.kind ~= "raid" then
		ExpeditionWaves.clear(session)
	end
	ExpeditionInstance.teardown(session.instance)
	if session.kind ~= "raid" then
		releaseHuntChannel(session.catalog and session.catalog.id, session.channel)
	end
	if session.key then
		sessionsByKey[session.key] = nil
	end
	for _, id in ipairs(sessionMemberIds(session)) do
		sessionsByPlayerId[id] = nil
		local p = Player(id)
		if p then
			p:unregisterEvent("ExpeditionPlayerDeath")
		end
	end
	if session.playerId then
		sessionsByPlayerId[session.playerId] = nil
	end
	if player then
		sessionsByPlayerId[player:getId()] = nil
		player:unregisterEvent("ExpeditionPlayerDeath")
	end
	disbandExpeditionParty(session)
end

--- Leave all living members (boss victory / party teardown).
function ExpeditionManager.leaveAll(session, opts)
	opts = opts or {}
	if not session then
		return
	end
	local ids = {}
	for _, id in ipairs(sessionMemberIds(session)) do
		ids[#ids + 1] = id
	end
	for _, id in ipairs(ids) do
		local p = Player(id)
		if p then
			ExpeditionManager.leave(p, opts)
		end
	end
	if sessionsByKey[session.key] == session then
		cleanupSession(session, nil)
	end
end

--- End the expedition for all members (supplies / capacity safety options).
--- Shared raids only eject the triggering player; private hunts/bosses end for everyone.
--- opts.keepTeamDeployed: switch hunts - leave companions online for the next join.
--- opts.skipTeleport: leave in place (direct hunt→hunt hop; no city return).
function ExpeditionManager.abort(session, reason, opts)
	opts = opts or {}
	if not session or session.aborting then
		return
	end
	-- Hunt death owns this session - do not clobber with a generic abort.
	if session.endedByDeath then
		return
	end
	session.aborting = true
	-- Halt AI / relocate walks before any member teleports; leftover autoWalk after a
	-- city warp causes client stackpos desync (parseCreatureMove: no creature found).
	if ExpeditionAI and ExpeditionAI.stop then
		ExpeditionAI.stop(session)
	end
	local message = tostring(reason or "Expedition stopped.")
	local leaveOpts = { silent = true }
	if opts.keepTeamDeployed then
		leaveOpts.keepTeamDeployed = true
		leaveOpts.skipTeamUndeploy = true
	end
	if opts.skipTeleport then
		leaveOpts.skipTeleport = true
	end
	if session.kind == "raid" then
		local p = Player(session.playerId)
		if p then
			if not opts.silent then
				p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			end
			ExpeditionManager.leave(p, leaveOpts)
		end
		return
	end
	if not opts.silent then
		for _, id in ipairs(sessionMemberIds(session)) do
			local p = Player(id)
			if p then
				p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			end
		end
	end
	local ok, err = pcall(function()
		ExpeditionManager.leaveAll(session, leaveOpts)
	end)
	if not ok then
		logger.error(
			"[Expedition] abort leaveAll failed key={}: {}",
			tostring(session.key),
			tostring(err)
		)
		-- Allow a later leave/stop attempt to retry instead of sticking forever.
		session.aborting = false
	end
end

--- Hunt death: notify survivors, eject from the private instance, sweep immediately.
--- Clients keep the frozen death frame until they confirm (upstream-aligned).
local function rememberHuntDeath(session, member)
	if not session or not member then
		return session and session.pendingHuntDeath or nil
	end
	if session.pendingHuntDeath then
		return session.pendingHuntDeath
	end
	local pos = member.getPosition and member:getPosition() or nil
	session.pendingHuntDeath = {
		id = member:getId(),
		name = member:getName(),
		position = pos and { x = pos.x, y = pos.y, z = pos.z } or nil,
	}
	return session.pendingHuntDeath
end

local function huntDeathMessage(pending, reason)
	if reason and reason ~= "" then
		return tostring(reason)
	end
	local name = (pending and pending.name) or "Adventurer"
	return string.format("%s is dead. The expedition has ended.", name)
end

local function collectHumanViewers(session, deadMember)
	local humans = {}
	local deadId = deadMember and deadMember:getId() or nil
	if not deadId and session and session.pendingHuntDeath then
		deadId = session.pendingHuntDeath.id
	end
	for _, id in ipairs(sessionMemberIds(session)) do
		if not deadId or id ~= deadId then
			local p = Player(id)
			if p and not isSessionCompanion(session, p) then
				humans[#humans + 1] = p
			end
		end
	end
	return humans
end

local function logoutExpeditionCompanions(session)
	if not session then
		return
	end
	local seen = {}
	local function logoutOne(id)
		if not id or seen[id] then
			return
		end
		seen[id] = true
		local companion = Player(id)
		if not companion or not isSessionCompanion(session, companion) then
			return
		end
		removeHuntMember(session, companion, { skipEnded = true, keepDeadFlag = true })
		clearActive(companion)
		if TeamManager and TeamManager.safeLogoutCompanion then
			TeamManager.safeLogoutCompanion(companion, 0)
		elseif Game.logoutCompanion then
			pcall(Game.logoutCompanion, companion)
		end
	end
	if session.companionIds then
		for id in pairs(session.companionIds) do
			logoutOne(id)
		end
	end
	local pending = session.pendingHuntDeath
	if pending and pending.id then
		logoutOne(pending.id)
	end
end

local function teleportHumanToReturn(player)
	if not player then
		return false
	end
	local returnPos = loadReturn(player)
	if not returnPos then
		return false
	end
	if InstanceWorld and InstanceWorld.travel then
		InstanceWorld.travel(player, returnPos)
	else
		player:teleportTo(returnPos)
	end
	if player.getHealth and player:getHealth() > 0 then
		player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	end
	return true
end

local function ejectPlayerFromExpedition(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	clearActive(player)
	ExpeditionManager.clearAreaEffects(player)
	player:setIdleCombat(false)
	player:removeCondition(CONDITION_INFIGHT)
	if not opts.skipTeleport then
		teleportHumanToReturn(player)
	end
	if not opts.skipTeamUndeploy and TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
		TeamManager.undeploy(player)
	end
	ExpeditionProtocol.sendEnded(player)
end

--- End expedition membership/HUD without undeploy; used before immediate return travel.
local function releaseHumanFromExpeditionDeath(player)
	ejectPlayerFromExpedition(player, { skipTeleport = true, skipTeamUndeploy = true })
end

--- Clear expedition HUD/membership, then move out of the private instance.
--- Client scene freeze keeps the death frame until the player confirms.
local function releaseAndReturnHumanFromHuntDeath(player)
	releaseHumanFromExpeditionDeath(player)
	teleportHumanToReturn(player)
end

local function sweepHuntDeathSession(session)
	if not session or session._cleaned then
		return
	end
	session.pendingHuntDeath = nil
	session.state = "ended"
	if sessionsByKey[session.key] == session then
		cleanupSession(session, nil)
	end
end

local function resolveSessionForHuntDeath(deadRef, player)
	if player then
		return ExpeditionManager.resolveSession(player)
	end
	local deadId = deadRef
	if type(deadId) ~= "number" then
		return nil
	end
	for _, s in pairs(sessionsByKey) do
		if s.companionIds and s.companionIds[deadId] then
			return s
		end
	end
	for _, s in pairs(sessionsByKey) do
		if s.pendingHuntDeath and s.pendingHuntDeath.id == deadId then
			return s
		end
	end
	return nil
end

local function endHuntByDeath(session, deadMember, reason)
	if not session or session.kind == "raid" then
		return
	end
	if session._cleaned then
		return
	end
	if session.endedByDeath then
		sweepHuntDeathSession(session)
		return
	end
	session.endedByDeath = true
	session.aborting = true
	session.state = "ended"

	local ok, err = pcall(function()
		local pending = rememberHuntDeath(session, deadMember)
		local subjectName = (pending and pending.name) or (deadMember and deadMember:getName()) or "Adventurer"
		local message = huntDeathMessage(pending, reason)

		if deadMember then
			session.deadPlayerIds = session.deadPlayerIds or {}
			session.deadPlayerIds[deadMember:getId()] = true
			if ExpeditionAI and ExpeditionAI.stopPlayer then
				ExpeditionAI.stopPlayer(session, deadMember)
			end
		elseif pending and pending.id then
			session.deadPlayerIds = session.deadPlayerIds or {}
			session.deadPlayerIds[pending.id] = true
		end

		logger.info("[Expedition] {} died in session {} - sweeping instance", subjectName, tostring(session.key))

		if ExpeditionAI and ExpeditionAI.stop then
			ExpeditionAI.stop(session)
		end

		local subjectId = (pending and pending.id) or (deadMember and deadMember:getId()) or nil
		for _, p in ipairs(collectHumanViewers(session, deadMember)) do
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			ExpeditionProtocol.sendHuntDeath(p, {
				subjectName = subjectName,
				subjectId = subjectId,
				message = message,
			})
			releaseAndReturnHumanFromHuntDeath(p)
		end

		-- Deceased human: stock death dialog only (no hunt-death modal), but still leave the instance.
		if deadMember and not isSessionCompanion(session, deadMember) then
			releaseAndReturnHumanFromHuntDeath(deadMember)
		end

		logoutExpeditionCompanions(session)
	end)
	if not ok then
		logger.error("[Expedition] endHuntByDeath failed ({}): {}", tostring(session.key), tostring(err))
	end
	sweepHuntDeathSession(session)
end

--- Public entry for player death, companion logout, and AI watchdog.
function ExpeditionManager.notifyHuntMemberDeath(deadRef, reason)
	local player = deadRef
	if type(deadRef) == "number" then
		player = Player(deadRef)
	end
	if not player and type(deadRef) ~= "number" then
		return
	end

	local session = resolveSessionForHuntDeath(deadRef, player)
	if not session or session.kind == "raid" then
		return
	end
	if session._cleaned then
		return
	end
	if session.endedByDeath then
		sweepHuntDeathSession(session)
		return
	end

	if player then
		ExpeditionManager.cancelLeave(player)
	end
	if player and session.anchorPlayerId == player:getId() then
		ExpeditionManager.reselectAnchor(session)
	end
	if not player then
		if not session.pendingHuntDeath then
			session.pendingHuntDeath = {
				id = deadRef,
				name = "Companion",
			}
		end
	end
	endHuntByDeath(session, player, reason)
end

--- Hunt-death modal confirmed: ensure return travel, undeploy, and resync client map.
function ExpeditionManager.ackHuntDeath(player)
	if not player then
		return
	end
	ExpeditionManager.cancelLeave(player)
	local privateBase = (InstanceWorld and InstanceWorld.PRIVATE_BASE) or 3000000
	if player.getInstanceId and player:getInstanceId() >= privateBase then
		teleportHumanToReturn(player)
	end
	ejectPlayerFromExpedition(player, { skipTeleport = true })
	if ExpeditionProtocol.sendInstanceBounds then
		ExpeditionProtocol.sendInstanceBounds(player)
	end
	if player.sendMapDescription then
		local pos = player:getPosition()
		if pos then
			player:sendMapDescription(pos)
		end
	end
end

--- Free instance/slot/session when the player is offline (e.g. disconnect mid victory delay).
--- STORAGE_ACTIVE is cleared on next login via the stranded-rescue path.
function ExpeditionManager.teardownSession(session)
	cleanupSession(session, nil)
end

--- Solo/boss: once no living humans remain, kick remaining members and sweep.
--- Hunt death (player or companion) uses endHuntByDeath instead.
--- Presence is spatial (zone players), not a storage flag. Raids stay up for late join.
function ExpeditionManager.endIfNoPlayers(session, opts)
	opts = opts or {}
	if not session or sessionsByKey[session.key] ~= session then
		return false
	end
	if session.kind == "raid" then
		return false
	end
	if session.state == "ended" then
		return true
	end
	-- Before entry teleport, the player is intentionally outside the zone.
	if not session.entered and not opts.byDeath then
		return false
	end
	if ExpeditionInstance.hasLivingPlayers(session.instance, {
		excludeIds = session.deadPlayerIds,
		excludeCompanions = opts.byDeath == true,
	}) then
		return false
	end

	session.state = "ended"
	session.endedByDeath = opts.byDeath == true or session.endedByDeath
	ExpeditionManager.leaveAll(session, { silent = true })
	return true
end

function ExpeditionManager.setLure(player, lure)
	if not player then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		ExpeditionProtocol.sendError(player, "Not on an expedition.")
		return
	end
	if session.kind == "raid" or session.role == "boss" then
		ExpeditionProtocol.sendError(player, "Lure is only available on monster hunt expeditions.")
		return
	end
	local value = math.floor(tonumber(lure) or 0)
	local lureMax = tonumber(session.lureMax)
		or (session.catalog and tonumber(session.catalog.lureMax))
		or ExpeditionConfig.LURE_MAX
	if not ExpeditionConfig.isValidLure(value, lureMax) then
		local values = ExpeditionConfig.lureValuesUpTo(lureMax)
		if type(values) == "table" and #values > 0 then
			ExpeditionProtocol.sendError(
				player,
				string.format("Lure must be one of: %s.", table.concat(values, ", "))
			)
		else
			local lureMin = ExpeditionConfig.LURE_MIN or 1
			ExpeditionProtocol.sendError(player, string.format("Lure must be between %d and %d.", lureMin, lureMax or lureMin))
		end
		return
	end
	if session.lure == value then
		ExpeditionManager.broadcastStatus(session)
		return
	end
	session.lure = value
	-- Applies on the next wave spawn only; current wave keeps session.waveLure.
	ExpeditionManager.broadcastStatus(session)
	if session.state == "hunting" and session.waveLure and session.waveLure ~= value then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("Lure set to %d (applies next wave).", value)
		)
	else
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Lure set to %d.", value))
	end
end

function ExpeditionManager.setStopOptions(player, options)
	if not player then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		ExpeditionProtocol.sendError(player, "Not on an expedition.")
		return
	end
	local stopOpts = ExpeditionConfig.normalizeStopOptions(options)
	session.stopOnInsufficientGold = stopOpts.stopOnInsufficientGold
	session.stopOnInsufficientCap = stopOpts.stopOnInsufficientCap
	ExpeditionManager.broadcastStatus(session)
end

--- Cancel a pending voluntary leave countdown (client Cancel, forced leave, logout).
--- Any human with a team leave-pending entry may cancel the shared countdown.
function ExpeditionManager.cancelLeave(player)
	if not player then
		return false
	end
	local playerId = player:getId()
	local pending = leavePendingByPlayerId[playerId]
	if not pending then
		return false
	end
	if pending.team and pending.sessionKey then
		local teamPending = leavePendingBySessionKey[pending.sessionKey]
		if not teamPending then
			leavePendingByPlayerId[playerId] = nil
			return false
		end
		if teamPending.event then
			stopEvent(teamPending.event)
		end
		leavePendingBySessionKey[pending.sessionKey] = nil
		local session = ExpeditionManager.getSessionByKey(pending.sessionKey)
		if session then
			for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
				leavePendingByPlayerId[id] = nil
				local p = Player(id)
				if p and not isSessionCompanion(session, p) then
					ExpeditionProtocol.send(p, { type = "leaveCancelled" })
				end
			end
		else
			leavePendingByPlayerId[playerId] = nil
		end
		return true
	end
	if pending.event then
		stopEvent(pending.event)
	end
	leavePendingByPlayerId[playerId] = nil
	return true
end

--- Finish a voluntary leave countdown. Uses sessionKey so team abort still runs
--- when the initiator is briefly unresolvable via Player(id) in a delayed event.
local function completeLeaveCountdown(sessionKey, initiatorId, initiatorName, switchTo)
	local leaveOpts = { silent = not switchTo }
	if switchTo then
		leaveOpts.silent = true
		leaveOpts.keepTeamDeployed = true
		leaveOpts.skipTeamUndeploy = true
		leaveOpts.skipTeleport = true
	end
	local s = sessionKey and ExpeditionManager.getSessionByKey(sessionKey) or nil
	if not s then
		local p = Player(initiatorId)
		if p then
			logger.info(
				"[Expedition] leave countdown complete solo (no session) by={}",
				tostring(initiatorName or initiatorId)
			)
			ExpeditionManager.leave(p, leaveOpts)
		end
	else
		-- Do not use state=="waiting": waves/boss AI reuse that for post-entry
		-- intermission. Pre-entry lobby is handled immediately in requestLeave.
		local humanCount = countHumanMembers(s)
		local teamStop = s.kind ~= "raid" and humanCount >= 2
		local name = initiatorName or "A teammate"
		if teamStop then
			if not s.entered then
				ExpeditionManager.cancelWaitingSession(s, name .. " cancelled the expedition.")
			else
				local reason = switchTo and (name .. " changed the expedition.")
					or (name .. " stopped the expedition.")
				logger.info(
					"[Expedition] leave countdown complete teamStop key={} by={}",
					tostring(sessionKey),
					name
				)
				ExpeditionManager.abort(
					s,
					reason,
					switchTo and { keepTeamDeployed = true, skipTeleport = true, silent = true } or nil
				)
			end
		else
			local p = Player(initiatorId)
			if p then
				logger.info(
					"[Expedition] leave countdown complete solo key={} by={}",
					tostring(sessionKey),
					name
				)
				ExpeditionManager.leave(p, leaveOpts)
			else
				logger.warn(
					"[Expedition] leave countdown complete solo missing player key={} id={}",
					tostring(sessionKey),
					tostring(initiatorId)
				)
			end
		end
	end
	if switchTo then
		local joiner = Player(initiatorId)
		if joiner then
			-- Leave→join must not see a sticky session (InstanceWorld delayed leave /
			-- companion teardown races). Force-clear once more before joining.
			if ExpeditionManager.isInExpedition(joiner) or ExpeditionManager.resolveSession(joiner) then
				ExpeditionManager.leave(joiner, {
					silent = true,
					keepTeamDeployed = true,
					skipTeamUndeploy = true,
					skipTeleport = true,
				})
			end
			clearActive(joiner)
			local joinOpts = {}
			for k, v in pairs(switchTo.options or {}) do
				joinOpts[k] = v
			end
			joinOpts.skipPzCheck = true
			ExpeditionManager.join(
				joiner,
				switchTo.id,
				switchTo.role,
				switchTo.loadout,
				switchTo.lure,
				joinOpts
			)
			-- If join bounced (still sticky / level / etc), rescue off a dead private instance.
			if not ExpeditionManager.isInExpedition(joiner) and InstanceWorld and InstanceWorld.rescueIfStranded then
				pcall(InstanceWorld.rescueIfStranded, joiner)
			end
		end
	end
end

local function clearLeavePendingForSession(sessionKey, fallbackPlayerId)
	leavePendingBySessionKey[sessionKey] = nil
	local s = ExpeditionManager.getSessionByKey(sessionKey)
	for _, id in ipairs(s and ExpeditionManager.sessionMemberIds(s) or { fallbackPlayerId }) do
		leavePendingByPlayerId[id] = nil
	end
end

--- Voluntary leave: enforce LEAVE_COUNTDOWN_SEC server-side, then eject.
--- Forced/silent paths should call leave() directly.
--- opts.switchTo = { id, role, loadout, lure, options } joins that expedition after leave.
function ExpeditionManager.requestLeave(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	local playerId = player:getId()
	if leavePendingByPlayerId[playerId] then
		-- Update switch destination if the player picks another hunt mid-countdown.
		if opts.switchTo then
			leavePendingByPlayerId[playerId].switchTo = opts.switchTo
			leavePendingByPlayerId[playerId].initiatorName = player:getName()
		end
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		-- Sticky client HUD after restart - eject immediately.
		ExpeditionManager.leave(player, opts.switchTo and {
			silent = true,
			keepTeamDeployed = true,
			skipTeamUndeploy = true,
		} or nil)
		if opts.switchTo then
			local joinOpts = {}
			for k, v in pairs(opts.switchTo.options or {}) do
				joinOpts[k] = v
			end
			joinOpts.skipPzCheck = true
			ExpeditionManager.join(
				player,
				opts.switchTo.id,
				opts.switchTo.role,
				opts.switchTo.loadout,
				opts.switchTo.lure,
				joinOpts
			)
		end
		return
	end

	-- Pre-entry (team-accept lobby / not yet teleported): cancel immediately.
	if not session.entered then
		local switchTo = opts.switchTo
		ExpeditionManager.cancelWaitingSession(
			session,
			player:getName() .. " cancelled the expedition."
		)
		if switchTo then
			local joinOpts = {}
			for k, v in pairs(switchTo.options or {}) do
				joinOpts[k] = v
			end
			joinOpts.skipPzCheck = true
			ExpeditionManager.join(
				player,
				switchTo.id,
				switchTo.role,
				switchTo.loadout,
				switchTo.lure,
				joinOpts
			)
		end
		return
	end

	local sec = math.max(0, math.floor(tonumber(ExpeditionConfig.LEAVE_COUNTDOWN_SEC) or 5))
	local switchTo = opts.switchTo
	local sessionKey = session.key
	local leaverName = player:getName()

	if sec <= 0 then
		completeLeaveCountdown(sessionKey, playerId, leaverName, switchTo)
		return
	end

	-- Team-wide stop only with 2+ humans. state=="waiting" is also wave/boss
	-- intermission after entry — conflating it made solo stop call
	-- cancelWaitingSession (no-op when entered) and never eject.
	local humanCount = countHumanMembers(session)
	local teamStop = session.kind ~= "raid" and humanCount >= 2
	if teamStop then
		if leavePendingBySessionKey[sessionKey] then
			-- Allow a newer switch target to replace the pending one.
			if switchTo then
				leavePendingBySessionKey[sessionKey].switchTo = switchTo
				leavePendingBySessionKey[sessionKey].initiatorId = playerId
				leavePendingBySessionKey[sessionKey].initiatorName = leaverName
			end
			return
		end
		-- Pass primitives into addEvent (TFS-safe). switchTo lives on the pending
		-- record so the delayed callback does not depend on requestLeave upvalues.
		local pendingInfo = {
			startedAt = os.time(),
			sessionKey = sessionKey,
			team = true,
			switchTo = switchTo,
			initiatorId = playerId,
			initiatorName = leaverName,
		}
		local event = addEvent(function(key, pid)
			local pending = leavePendingBySessionKey[key]
			local to = pending and pending.switchTo or nil
			local name = (pending and pending.initiatorName) or nil
			clearLeavePendingForSession(key, pid)
			completeLeaveCountdown(key, pid, name, to)
		end, sec * 1000, sessionKey, playerId)
		pendingInfo.event = event
		leavePendingBySessionKey[sessionKey] = pendingInfo
		for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
			local p = Player(id)
			if p and not isSessionCompanion(session, p) then
				leavePendingByPlayerId[id] = pendingInfo
				ExpeditionProtocol.send(p, {
					type = "leavePending",
					countdownSec = sec,
					initiator = leaverName,
					reason = opts.reason,
					expeditionName = opts.expeditionName,
				})
			end
		end
		return
	end

	leavePendingByPlayerId[playerId] = {
		startedAt = os.time(),
		switchTo = switchTo,
		sessionKey = sessionKey,
		initiatorName = leaverName,
	}
	local event = addEvent(function(pid)
		local pending = leavePendingByPlayerId[pid]
		local to = pending and pending.switchTo or nil
		local name = pending and pending.initiatorName or nil
		local key = pending and pending.sessionKey or nil
		leavePendingByPlayerId[pid] = nil
		completeLeaveCountdown(key, pid, name, to)
	end, sec * 1000, playerId)
	leavePendingByPlayerId[playerId].event = event
	ExpeditionProtocol.send(player, {
		type = "leavePending",
		countdownSec = sec,
		reason = opts.reason,
		expeditionName = opts.expeditionName,
	})
end

local function clearPendingSwitch(session, opts)
	opts = opts or {}
	if not session or not session.pendingSwitch then
		return
	end
	local pending = session.pendingSwitch
	if pending.timeoutEvent then
		stopEvent(pending.timeoutEvent)
	end
	session.pendingSwitch = nil
	if opts.silent then
		return
	end
	local payload = {
		type = "switchCancelled",
		reason = opts.reason,
		expeditionName = opts.expeditionName or pending.catalogName,
	}
	local notifyIds = pending.notifyIds or {}
	if #notifyIds == 0 then
		if pending.initiatorId then
			notifyIds[#notifyIds + 1] = pending.initiatorId
		end
		for guid in pairs(pending.awaitingGuids or {}) do
			local p = Player(guid)
			if p then
				notifyIds[#notifyIds + 1] = p:getId()
			end
		end
		for guid in pairs(pending.acceptedGuids or {}) do
			local p = Player(guid)
			if p then
				notifyIds[#notifyIds + 1] = p:getId()
			end
		end
	end
	local seen = {}
	for _, id in ipairs(notifyIds) do
		if id and not seen[id] then
			seen[id] = true
			local p = Player(id)
			if p then
				ExpeditionProtocol.send(p, payload)
			end
		end
	end
end

local function collectSessionHumans(session)
	local humans = {}
	if not session then
		return humans
	end
	for _, id in ipairs(sessionMemberIds(session)) do
		local p = Player(id)
		if p and not isSessionCompanion(session, p) then
			humans[#humans + 1] = p
		end
	end
	return humans
end

local function pendingSwitchAwaitingNames(pending)
	local names = {}
	for _, name in pairs((pending and pending.awaitingGuids) or {}) do
		names[#names + 1] = name
	end
	return names
end

local function switchDestinationLevelMin(switchTo)
	if not switchTo then
		return 1
	end
	local catalog = ExpeditionConfig.getById and ExpeditionConfig.getById(switchTo.id, switchTo.role) or nil
	if not catalog then
		return 1
	end
	return catalog.levelMin or 1
end

--- Players among `players` who fail the destination levelMin (gods always pass).
local function underleveledForSwitch(players, levelMin)
	local blocked = {}
	for _, p in ipairs(players or {}) do
		if p and p.getLevel and not meetsExpeditionLevel(p, levelMin) then
			blocked[#blocked + 1] = p
		end
	end
	return blocked
end

--- Tear down the current hunt in place and join the next (no city return).
--- Validates host + pre-accepted teammates against the destination levelMin *before*
--- aborting the prior session so a failed transfer cannot strand anyone mid-instance.
local function performDirectSwitch(host, session, switchTo, preAcceptedPlayers)
	if not host or not switchTo then
		return
	end
	local hostId = host:getId()
	local others = {}
	for _, p in ipairs(preAcceptedPlayers or {}) do
		if p and p.getId and p:getId() ~= hostId then
			others[#others + 1] = p
		end
	end
	local levelMin = switchDestinationLevelMin(switchTo)
	local toCheck = { host }
	for _, p in ipairs(others) do
		toCheck[#toCheck + 1] = p
	end
	local blocked = underleveledForSwitch(toCheck, levelMin)
	if #blocked > 0 then
		local names = {}
		for _, p in ipairs(blocked) do
			names[#names + 1] = p:getName()
			ExpeditionProtocol.sendError(
				p,
				string.format("Level too low for this expedition (need %d, you are %d).", levelMin, p:getLevel())
			)
		end
		local msg = string.format(
			"Expedition change cancelled: %s must be at least level %d. Continuing the current expedition.",
			table.concat(names, ", "),
			levelMin
		)
		if session then
			clearPendingSwitch(session, {
				reason = "level",
				expeditionName = switchTo.catalogName,
			})
		end
		host:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
		for _, p in ipairs(others) do
			if p then
				p:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
			end
		end
		logger.info(
			"[Expedition] switch blocked by level host={} need={} blocked={}",
			host:getName(),
			levelMin,
			table.concat(names, ",")
		)
		return
	end
	if session then
		clearPendingSwitch(session, { silent = true })
		ExpeditionManager.abort(session, "Changing expedition.", {
			keepTeamDeployed = true,
			skipTeleport = true,
			silent = true,
		})
	elseif ExpeditionManager.isInExpedition(host) or ExpeditionManager.resolveSession(host) then
		ExpeditionManager.leave(host, {
			silent = true,
			keepTeamDeployed = true,
			skipTeamUndeploy = true,
			skipTeleport = true,
		})
	end
	clearActive(host)
	local joinOpts = {}
	for k, v in pairs(switchTo.options or {}) do
		joinOpts[k] = v
	end
	joinOpts.skipPzCheck = true
	if #others > 0 then
		joinOpts.preAcceptedPlayers = others
	end
	ExpeditionManager.join(host, switchTo.id, switchTo.role, switchTo.loadout, switchTo.lure, joinOpts)
	-- Rescue anyone who did not land in the new expedition (host join ok but teammate
	-- dropped, or host join failed). Old session is already gone at this point.
	if InstanceWorld and InstanceWorld.rescueIfStranded then
		if not ExpeditionManager.isInExpedition(host) then
			pcall(InstanceWorld.rescueIfStranded, host)
		end
		for _, p in ipairs(others) do
			if p and not ExpeditionManager.isInExpedition(p) then
				pcall(InstanceWorld.rescueIfStranded, p)
			end
		end
	end
end

local function tryCompletePendingSwitch(session)
	if not session or not session.pendingSwitch then
		return
	end
	local pending = session.pendingSwitch
	if awaitingHumanCount({ awaitingHumanGuids = pending.awaitingGuids }) > 0 then
		return
	end
	local host = Player(pending.initiatorId)
	if not host then
		clearPendingSwitch(session, { reason = "host_offline" })
		return
	end
	local accepted = {}
	for guid in pairs(pending.acceptedGuids or {}) do
		local p = Player(guid)
		if p and ExpeditionManager.getSessionByPlayer(p) == session then
			accepted[#accepted + 1] = p
		end
	end
	local switchTo = pending.switchTo
	logger.info(
		"[Expedition] {} switch accepted → {} (teammates={})",
		host:getName(),
		tostring(switchTo and switchTo.id or ""),
		#accepted
	)
	performDirectSwitch(host, session, switchTo, accepted)
end

local function armPendingSwitchTimeout(session)
	if not session or not session.pendingSwitch then
		return
	end
	local pending = session.pendingSwitch
	if pending.timeoutEvent then
		stopEvent(pending.timeoutEvent)
	end
	local sec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
	pending.deadline = os.time() + sec
	local key = session.key
	pending.timeoutEvent = addEvent(function()
		local live = ExpeditionManager.getSessionByKey(key)
		if not live or not live.pendingSwitch then
			return
		end
		local catalogName = live.pendingSwitch.catalogName
		live.pendingSwitch.timeoutEvent = nil
		logger.info("[Expedition] switch confirm timed out key={}", tostring(key))
		clearPendingSwitch(live, {
			reason = "timeout",
			expeditionName = catalogName,
		})
		local host = Player(live.playerId)
		if host then
			host:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				"Expedition change timed out. Continuing the current expedition."
			)
		end
	end, sec * 1000)
end

--- Move the team from the current expedition directly into another (no city hop).
--- With teammates: confirm while still hunting; decline/timeout keeps the current expedition.
function ExpeditionManager.requestSwitch(player, expeditionId, role, loadout, lure, options)
	if not player then
		return
	end
	local catalog = ExpeditionConfig.getById and ExpeditionConfig.getById(expeditionId, role) or nil
	if not catalog then
		ExpeditionProtocol.sendError(
			player,
			string.format("Unknown expedition (%s).", tostring(expeditionId or ""))
		)
		return
	end
	local contentRole = role
	if contentRole ~= "boss" and contentRole ~= "monster" then
		contentRole = catalog.role == "boss" and "boss" or "monster"
	end
	local switchTo = {
		id = expeditionId,
		role = contentRole,
		loadout = loadout,
		lure = lure,
		options = options or {},
		catalogName = catalog.name,
	}
	if not ExpeditionManager.isInExpedition(player) then
		ExpeditionManager.join(player, switchTo.id, switchTo.role, switchTo.loadout, switchTo.lure, switchTo.options)
		return
	end

	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		ExpeditionManager.join(player, switchTo.id, switchTo.role, switchTo.loadout, switchTo.lure, {
			skipPzCheck = true,
		})
		return
	end
	if session.kind == "raid" or session.kind == "worldboss" then
		ExpeditionProtocol.sendError(player, "Leave this activity before changing expedition.")
		return
	end
	if session.pendingSwitch then
		ExpeditionProtocol.sendError(player, "An expedition change is already pending.")
		return
	end
	local levelMin = catalog.levelMin or 1
	if not meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		return
	end
	ExpeditionManager.cancelLeave(player)

	local humans = collectSessionHumans(session)
	local others = {}
	for _, member in ipairs(humans) do
		if member:getId() ~= player:getId() then
			others[#others + 1] = member
		end
	end
	local underleveled = underleveledForSwitch(others, levelMin)
	if #underleveled > 0 then
		local names = {}
		for _, p in ipairs(underleveled) do
			names[#names + 1] = p:getName()
		end
		ExpeditionProtocol.sendError(
			player,
			string.format(
				"Cannot change expedition: %s must be at least level %d.",
				table.concat(names, ", "),
				levelMin
			)
		)
		return
	end

	if #others == 0 then
		logger.info(
			"[Expedition] {} solo switch → {} (direct)",
			player:getName(),
			tostring(catalog.id)
		)
		performDirectSwitch(player, session, switchTo, nil)
		return
	end

	local awaitingGuids = {}
	for _, member in ipairs(others) do
		awaitingGuids[member:getGuid()] = member:getName()
	end
	session.pendingSwitch = {
		switchTo = switchTo,
		initiatorId = player:getId(),
		initiatorName = player:getName(),
		catalogName = catalog.name,
		awaitingGuids = awaitingGuids,
		acceptedGuids = {},
		notifyIds = (function()
			local ids = { player:getId() }
			for _, member in ipairs(others) do
				ids[#ids + 1] = member:getId()
			end
			return ids
		end)(),
	}
	armPendingSwitchTimeout(session)
	local deadline = session.pendingSwitch.deadline
	ExpeditionProtocol.send(player, {
		type = "switchWaiting",
		expeditionId = catalog.id,
		expeditionName = catalog.name,
		acceptDeadline = deadline,
		awaiting = pendingSwitchAwaitingNames(session.pendingSwitch),
	})
	for _, member in ipairs(others) do
		ExpeditionProtocol.send(member, {
			type = "switchConfirm",
			initiator = player:getName(),
			expeditionId = catalog.id,
			expeditionName = catalog.name,
			acceptDeadline = deadline,
		})
	end
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format(
			"Waiting for %d teammate(s) to accept changing to %s. The current expedition continues until then.",
			#others,
			catalog.name
		)
	)
	logger.info(
		"[Expedition] {} requested switch → {} awaiting={}",
		player:getName(),
		tostring(catalog.id),
		#others
	)
end

function ExpeditionManager.acceptSwitch(player)
	if not player then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or not session.pendingSwitch then
		ExpeditionProtocol.send(player, { type = "switchCancelled", reason = "none" })
		return
	end
	local pending = session.pendingSwitch
	local guid = player:getGuid()
	if not pending.awaitingGuids or not pending.awaitingGuids[guid] then
		if pending.acceptedGuids and pending.acceptedGuids[guid] then
			return
		end
		ExpeditionProtocol.sendError(player, "You are not part of this expedition change.")
		return
	end
	local levelMin = switchDestinationLevelMin(pending.switchTo)
	if not meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		clearPendingSwitch(session, {
			reason = "level",
			expeditionName = pending.catalogName,
		})
		local host = Player(pending.initiatorId)
		local msg = string.format(
			"%s cannot join %s (need level %d). Continuing the current expedition.",
			player:getName(),
			tostring(pending.catalogName or "the new expedition"),
			levelMin
		)
		if host then
			host:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You cannot change to that expedition. Continuing the current one.")
		logger.info(
			"[Expedition] switch accept blocked by level player={} need={}",
			player:getName(),
			levelMin
		)
		return
	end
	pending.awaitingGuids[guid] = nil
	pending.acceptedGuids = pending.acceptedGuids or {}
	pending.acceptedGuids[guid] = player:getName()
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("You accepted changing to %s.", tostring(pending.catalogName or "the new expedition"))
	)
	local host = Player(pending.initiatorId)
	if host then
		host:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("%s accepted the expedition change.", player:getName())
		)
		ExpeditionProtocol.send(host, {
			type = "switchWaiting",
			expeditionId = pending.switchTo and pending.switchTo.id or nil,
			expeditionName = pending.catalogName,
			acceptDeadline = pending.deadline,
			awaiting = pendingSwitchAwaitingNames(pending),
		})
	end
	tryCompletePendingSwitch(session)
end

function ExpeditionManager.declineSwitch(player)
	if not player then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or not session.pendingSwitch then
		ExpeditionProtocol.send(player, { type = "switchCancelled", reason = "none" })
		return
	end
	local pending = session.pendingSwitch
	local name = pending.catalogName
	clearPendingSwitch(session, {
		reason = "declined",
		expeditionName = name,
	})
	local host = Player(pending.initiatorId)
	if host then
		host:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"%s declined changing expedition. Continuing the current expedition.",
				player:getName()
			)
		)
	end
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You declined the expedition change.")
	logger.info(
		"[Expedition] {} declined switch by {}",
		tostring(pending.initiatorName),
		player:getName()
	)
end

function ExpeditionManager.cancelSwitch(player)
	if not player then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or not session.pendingSwitch then
		return
	end
	local pending = session.pendingSwitch
	if pending.initiatorId ~= player:getId() then
		ExpeditionProtocol.sendError(player, "Only the player who requested the change can cancel it.")
		return
	end
	clearPendingSwitch(session, {
		reason = "cancelled",
		expeditionName = pending.catalogName,
	})
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Expedition change cancelled. Continuing the current expedition.")
end

function ExpeditionManager.leave(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	ExpeditionManager.cancelLeave(player)
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		-- Idempotent recovery: server session may be gone after restart while the
		-- client still shows STOP EXPEDITION from a sticky status opcode.
		clearActive(player)
		ExpeditionManager.clearAreaEffects(player)
		ExpeditionProtocol.sendEnded(player)
		if not opts.skipTeamUndeploy and TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
			TeamManager.undeploy(player)
		end
		return
	end
	if session.kind == "raid" and RaidInstance and RaidInstance.leave then
		RaidInstance.leave(player, opts)
		return
	end
	if session.kind == "worldboss" and ActivityBoostWorldBoss and ActivityBoostWorldBoss.leave then
		ActivityBoostWorldBoss.leave(player, opts)
		return
	end

	-- Leaving mid switch-confirm cancels the change for everyone still hunting.
	if session.pendingSwitch and not opts.keepTeamDeployed then
		clearPendingSwitch(session, { reason = "left" })
	end

	if ActivityBoostActivities and ActivityBoostActivities.noteHuntProgress then
		pcall(ActivityBoostActivities.noteHuntProgress, player, session)
	end

	-- Switch hunts: keep account-team companions online and redeploy into the next
	-- instance (avoids logout→login races that look like companion deaths).
	if opts.keepTeamDeployed then
		opts.skipTeamUndeploy = true
	end

	local function parkCompanionForSwitch(member)
		if not member then
			return
		end
		removeHuntMember(session, member, { skipEnded = true })
		clearActive(member)
		if opts.skipTeleport then
			return
		end
		local returnPos = loadReturn(member)
		if not returnPos then
			return
		end
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(member, true)
		end
		if InstanceWorld and InstanceWorld.travel then
			InstanceWorld.travel(member, returnPos)
		else
			member:teleportTo(returnPos)
		end
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(member, false)
		end
	end

	-- Primary squaddie leaving: eject companions from this session first.
	-- Default: logout via undeploy. Switch: park them in town and keep deployment.
	if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
		local companionIds = {}
		for _, id in ipairs(sessionMemberIds(session)) do
			local member = Player(id)
			if member and member:getId() ~= player:getId() and TeamManager.isCompanion(member) then
				companionIds[#companionIds + 1] = id
			end
		end
		if opts.keepTeamDeployed then
			for _, id in ipairs(companionIds) do
				parkCompanionForSwitch(Player(id))
			end
			session = ExpeditionManager.getSessionByPlayer(player)
			if not session then
				clearActive(player)
				ExpeditionManager.clearAreaEffects(player)
				if not opts.skipTeleport then
					local returnPos = loadReturn(player)
					if returnPos then
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, true)
						end
						if InstanceWorld and InstanceWorld.travel then
							InstanceWorld.travel(player, returnPos)
						else
							player:teleportTo(returnPos)
						end
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, false)
						end
					end
				end
				ExpeditionProtocol.sendEnded(player)
				return
			end
		elseif not opts.skipTeamUndeploy then
			for _, id in ipairs(companionIds) do
				local member = Player(id)
				if member then
					ExpeditionManager.leave(member, { silent = true, skipTeamUndeploy = true })
				end
			end
			-- Re-fetch session; may already be cleaned if we were last.
			session = ExpeditionManager.getSessionByPlayer(player)
			if not session then
				clearActive(player)
				ExpeditionManager.clearAreaEffects(player)
				if not opts.skipTeleport then
					local returnPos = loadReturn(player)
					if returnPos then
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, true)
						end
						if InstanceWorld and InstanceWorld.travel then
							InstanceWorld.travel(player, returnPos)
						else
							player:teleportTo(returnPos)
						end
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, false)
						end
					end
				end
				ExpeditionProtocol.sendEnded(player)
				if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
					TeamManager.undeploy(player)
				end
				return
			end
		end
	end

	local returnPos = loadReturn(player)
	local memberCount = #sessionMemberIds(session)
	local isLast = memberCount <= 1
	local wasVictory = opts.victory == true
	local shouldCleanup = isLast

	-- Detach before return travel so InstanceWorld rebinds to city/hub instead of
	-- treating the warp as an in-hunt relocate (which also schedules a delayed leave
	-- that can abort a follow-up switch join).
	removeHuntMember(session, player, { skipEnded = true })
	if not isLast then
		local remainingOnline = false
		for _, id in ipairs(sessionMemberIds(session)) do
			if Player(id) then
				remainingOnline = true
				break
			end
		end
		if not remainingOnline then
			shouldCleanup = true
		else
			ExpeditionManager.broadcastStatus(session)
		end
	end

	ExpeditionManager.clearAreaEffects(player)
	if session.pendingHuntDeath and session.pendingHuntDeath.id == player:getId() then
		session.pendingHuntDeath = nil
	end
	local skipTeleport = opts.skipTeleport == true
	if not skipTeleport then
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(player, true)
		end
		if InstanceWorld and InstanceWorld.travel then
			InstanceWorld.travel(player, returnPos)
		else
			player:teleportTo(returnPos)
		end
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(player, false)
		end
		if player.getHealth and player:getHealth() > 0 then
			player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
		end
	end

	-- Sweep after the last member leaves.
	if shouldCleanup then
		cleanupSession(session, player)
	end

	ExpeditionProtocol.sendEnded(player)
	if not opts.skipTeamUndeploy and TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
		TeamManager.undeploy(player)
	end
	if not opts.silent then
		if wasVictory then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Expedition complete.")
		else
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You left the expedition.")
		end
	end
end

function ExpeditionManager.onDeath(player)
	if not player then
		return
	end
	local session = ExpeditionManager.resolveSession(player)
	if session and session.kind == "raid" and RaidInstance and RaidInstance.onPlayerDeath then
		RaidInstance.onPlayerDeath(player)
		return
	end
	ExpeditionManager.notifyHuntMemberDeath(player, nil)
end

--- Death-screen Ok / forced logout: free the instance. Idle combat normally
--- blocks disconnect logout while hunting, so this path is death or force-remove.
function ExpeditionManager.onLogout(player)
	if not player then
		return true
	end
	ExpeditionManager.cancelLeave(player)
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		local guid = player:getGuid()
		for _, s in pairs(sessionsByKey) do
			if s.guid == guid then
				session = s
				break
			end
			if s.memberGuids and s.memberGuids[guid] then
				session = s
				break
			end
		end
	end
	if not session then
		if player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
			clearActive(player)
		end
		return true
	end

	if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
		for _, id in ipairs(sessionMemberIds(session)) do
			local member = Player(id)
			if member and member:getId() ~= player:getId() and isSessionCompanion(session, member) then
				-- Tear companions out of the session and logout after primary disconnect.
				removeHuntMember(session, member, { skipEnded = true })
				clearActive(member)
				pcall(function()
					if TeamManager.safeLogoutCompanion then
						TeamManager.safeLogoutCompanion(member)
					elseif Game.logoutCompanion then
						Game.logoutCompanion(member)
					end
				end)
			end
		end
		pcall(function()
			TeamManager.undeploy(player)
		end)
	end

	if session.kind == "raid" and RaidInstance and RaidInstance.leave then
		-- Leave the shared raid without tearing it down for other players.
		RaidInstance.leave(player, { silent = true })
		return true
	end

	if session.endedByDeath then
		clearActive(player)
		return true
	end

	-- Headless companions may logout after death (often with HP already restored).
	-- Skip hunt-death takeover while a voluntary abort/leaveAll is already ejecting.
	-- Healthy companion logout is voluntary undeploy/switch — not a hunt death.
	if isSessionCompanion(session, player) or (session.pendingHuntDeath and session.pendingHuntDeath.id == player:getId()) then
		if session.aborting or session._cleaned then
			removeHuntMember(session, player, { skipEnded = true })
			clearActive(player)
			return true
		end
		local hp = player.getHealth and player:getHealth() or 0
		local pendingDeath = session.pendingHuntDeath and session.pendingHuntDeath.id == player:getId()
		if isSessionCompanion(session, player) and hp > 0 and not pendingDeath and not session.endedByDeath then
			removeHuntMember(session, player, { skipEnded = true })
			clearActive(player)
			return true
		end
		ExpeditionManager.notifyHuntMemberDeath(player, nil)
		return true
	end

	local memberCount = #sessionMemberIds(session)
	if memberCount <= 1 then
		cleanupSession(session, player)
		clearActive(player)
	else
		removeHuntMember(session, player, { skipEnded = true })
		clearActive(player)
		ExpeditionManager.broadcastStatus(session)
		if #sessionMemberIds(session) == 0 then
			cleanupSession(session, nil)
		end
	end
	return true
end

local function rebindMemberId(session, oldId, newId, player)
	if not session or not oldId or not newId then
		return
	end
	sessionsByPlayerId[oldId] = nil
	sessionsByPlayerId[newId] = session
	if session.playerId == oldId then
		session.playerId = newId
	end
	if session.anchorPlayerId == oldId then
		session.anchorPlayerId = newId
	end
	if type(session.playerIds) == "table" then
		for i, id in ipairs(session.playerIds) do
			if id == oldId then
				session.playerIds[i] = newId
			end
		end
	end
	if session.memberStance and session.memberStance[oldId] ~= nil then
		session.memberStance[newId] = session.memberStance[oldId]
		session.memberStance[oldId] = nil
	end
	if session.memberRangedDistance and session.memberRangedDistance[oldId] ~= nil then
		session.memberRangedDistance[newId] = session.memberRangedDistance[oldId]
		session.memberRangedDistance[oldId] = nil
	end
	if session.memberAutomation and session.memberAutomation[oldId] ~= nil then
		session.memberAutomation[newId] = session.memberAutomation[oldId]
		session.memberAutomation[oldId] = nil
		if session.playerId == newId then
			session.automation = session.memberAutomation[newId]
		end
	end
	if session.prevAutoTargetByPlayer and session.prevAutoTargetByPlayer[oldId] ~= nil then
		session.prevAutoTargetByPlayer[newId] = session.prevAutoTargetByPlayer[oldId]
		session.prevAutoTargetByPlayer[oldId] = nil
	end
	if session.lastSyncedAttackByPlayer and session.lastSyncedAttackByPlayer[oldId] ~= nil then
		session.lastSyncedAttackByPlayer[newId] = session.lastSyncedAttackByPlayer[oldId]
		session.lastSyncedAttackByPlayer[oldId] = nil
	end
	if session.deadPlayerIds and session.deadPlayerIds[oldId] then
		session.deadPlayerIds[newId] = true
		session.deadPlayerIds[oldId] = nil
	end
	if player and session.memberGuids then
		session.memberGuids[player:getGuid()] = newId
	end
end

function ExpeditionManager.onLogin(player)
	if not player then
		return
	end
	player:registerEvent("ExpeditionExtendedOpcode")
	player:registerEvent("ExpeditionPlayerLogout")
	-- CombatAutomationLogin also arms the loop; only ensure opcode + sample spells here
	-- so we do not double-send empty automationConfig and wipe a client upload race.
	if CombatAutomation and CombatAutomation.refreshLoop then
		pcall(function()
			if CombatAutomationStore and CombatAutomationStore.getConfig then
				CombatAutomationStore.getConfig(player)
			else
				CombatAutomation.refreshLoop(player)
			end
		end)
	end
	if SampleSpells and SampleSpells.ensure then
		SampleSpells.ensure(player)
	end

	local session = nil
	local oldMemberId = nil
	local guid = player:getGuid()
	for _, s in pairs(sessionsByKey) do
		if s.guid == guid then
			session = s
			oldMemberId = s.playerId
			break
		end
		if s.memberGuids and s.memberGuids[guid] then
			session = s
			oldMemberId = s.memberGuids[guid]
			break
		end
	end

	if session and session.endedByDeath then
		local oldId = oldMemberId or session.playerId
		if oldId and oldId ~= player:getId() then
			rebindMemberId(session, oldId, player:getId(), player)
		end
		ejectPlayerFromExpedition(player, {})
		return
	end

	if session and session.state == "ended" then
		ejectPlayerFromExpedition(player, {})
		if sessionsByKey[session.key] == session then
			cleanupSession(session, player)
		end
		return
	end

	if session then
		-- Re-bind player id after reconnect (idle combat kept the session alive).
		local oldId = oldMemberId or session.playerId
		rebindMemberId(session, oldId, player:getId(), player)
		if session.kind == "raid" and type(session.playerIds) == "table" then
			local active = RaidInstance and RaidInstance.getActive and RaidInstance.getActive(session.raidName)
			if active and active.memberKeys and active.memberKeys[oldId] then
				active.memberKeys[player:getId()] = active.memberKeys[oldId]
				active.memberKeys[oldId] = nil
			end
		end
		-- Spatial membership: once entered, being outside the instance ends the run.
		if ExpeditionInstance.contains(session.instance, player:getPosition()) then
			session.entered = true
		elseif session.entered and not ExpeditionManager.reconcilePresence(player) then
			ExpeditionProtocol.sendCatalog(player)
			if RaidInstance and RaidInstance.sendActiveRaids then
				RaidInstance.sendActiveRaids(player)
			end
			return
		end
		local pid = player:getId()
		if not session.memberAutomation or type(session.memberAutomation[pid]) ~= "table" then
			session.memberAutomation = session.memberAutomation or {}
			session.memberAutomation[pid] = loadPersistedAutomation(player)
		end
		if session.playerId == pid then
			session.automation = session.memberAutomation[pid]
		end
		session.memberStance = session.memberStance or {}
		do
			local stance, rangedDist = memberStanceFromConfig(player)
			session.memberStance[pid] = stance
			session.memberRangedDistance = session.memberRangedDistance or {}
			session.memberRangedDistance[pid] = rangedDist
		end
		player:registerEvent("ExpeditionPlayerDeath")
		ExpeditionAI.enablePersistence(player)
		-- Reconnect: clear dedupe so the client receives attackTarget again.
		session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
		session.lastSyncedAttackByPlayer[pid] = nil
		if session.entered then
			ExpeditionAI.start(session)
		end
		ExpeditionProtocol.sendCatalog(player)
		if RaidInstance and RaidInstance.sendActiveRaids then
			RaidInstance.sendActiveRaids(player)
		end
		ExpeditionProtocol.sendStatus(player, session)
		local playerId = player:getId()
		local sessionKey = session.key
		addEvent(function()
			local p = Player(playerId)
			local s = ExpeditionManager.getSessionByKey and ExpeditionManager.getSessionByKey(sessionKey)
			if p and s and ExpeditionAI.resyncAttackTarget then
				ExpeditionAI.resyncAttackTarget(s, p)
			elseif p and CombatAutomation and CombatAutomation.resyncAttackTarget then
				CombatAutomation.resyncAttackTarget(p)
			end
		end, 1500)
		return
	end

	-- Rescue after restart / deferred teardown: stranded on a dead instance.
	if InstanceWorld and InstanceWorld.rescueIfStranded then
		InstanceWorld.rescueIfStranded(player)
	elseif player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
		local returnPos = loadReturn(player)
		clearActive(player)
		ExpeditionManager.clearAreaEffects(player)
		player:setIdleCombat(false)
		player:teleportTo(returnPos)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Your expedition was interrupted. You were returned to safety.")
	end

	ExpeditionProtocol.sendCatalog(player)
	if RaidInstance and RaidInstance.sendActiveRaids then
		RaidInstance.sendActiveRaids(player)
	end
	-- Sticky Rotten Blood / hazard icons can survive instance teleports; clear when
	-- there is no live hunt to re-apply them.
	ExpeditionManager.clearAreaEffects(player)
	-- Always clear client sticky status when there is no live session (e.g. after
	-- server restart mid-raid while the browser kept the old status in memory).
	ExpeditionProtocol.sendEnded(player)
end

function ExpeditionManager.onStartup()
	sessionsByKey = {}
	sessionsByPlayerId = {}
	leavePendingByPlayerId = {}
	huntChannelsByPlace = {}
	if ExpeditionInstance and ExpeditionInstance.resetSlots then
		ExpeditionInstance.resetSlots()
	end
	logger.info("[Expedition] manager ready ({} catalog entries)", #ExpeditionConfig.Catalog)
end
