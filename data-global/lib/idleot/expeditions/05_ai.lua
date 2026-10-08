-- Expedition session AI: the single session tick (CombatAutomationConfig.TICK_MS), persistence,
-- movement directives, catch-up and manual control (players may walk themselves;
-- the AI takes over again once they stop). Targeting / stance / casting live in
-- CombatAutomation (per player, playerOnThink).

ExpeditionAI = ExpeditionAI or {}

local geo = CombatGeo

local function memberIds(session)
	if ExpeditionManager and ExpeditionManager.sessionMemberIds then
		return ExpeditionManager.sessionMemberIds(session)
	end
	if session and session.playerId then
		return { session.playerId }
	end
	return {}
end

function ExpeditionAI.sessionKind(session)
	return session.kind or (session.catalog and session.catalog.kind) or "hunt"
end
local sessionKind = ExpeditionAI.sessionKind

function ExpeditionAI.enablePersistence(player)
	if not player then
		return
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session and session.state == "ended" then
			return
		end
	end
	if PzTeleport.isGod(player) then
		if player.isIdleCombat and player:isIdleCombat() then
			player:setIdleCombat(false)
		end
		return
	end
	if not player:isIdleCombat() then
		player:setIdleCombat(true)
	end
	if player.kv then
		player:kv():remove("combat-protection")
	end
	if not player:getCondition(CONDITION_INFIGHT) then
		local condition = Condition(CONDITION_INFIGHT)
		condition:setParameter(CONDITION_PARAM_TICKS, 60000)
		player:addCondition(condition)
	end
end

function ExpeditionAI.onAutoResumed(player)
	if not player then
		return
	end
	if CombatAutomationMovement and CombatAutomationMovement.onAutoResumed then
		CombatAutomationMovement.onAutoResumed(player)
	elseif player.clearWalkTask then
		player:clearWalkTask()
	end
	ExpeditionAI.enablePersistence(player)
end

--- Suggest AUTO on once at hunt start (do not force-lock; player may toggle off).
local function suggestAutoOn(player)
	if not player or not CombatAutomationStore then
		return
	end
	local config = CombatAutomationStore.getConfig(player)
	config.autoTarget = config.autoTarget
		or {
			enabled = false,
			stance = CombatAutomationConfig.stanceForPlayer(player),
			rangedDistance = CombatAutomationConfig.RANGED_DISTANCE_DEFAULT,
			mode = "A",
		}
	if config.autoTarget.enabled ~= true then
		config.autoTarget.enabled = true
		CombatAutomationStore.persist(player, config)
		CombatAutomationStore.applyToRuntime(player, config)
		if CombatAutomationProtocol and CombatAutomationProtocol.sendConfig then
			CombatAutomationProtocol.sendConfig(player, config)
		end
	end
end

local function clearPlayerCombat(player)
	if not player then
		return
	end
	if player.getFollowCreature and player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
	player:setTarget(nil)
	if CombatAutomation and CombatAutomation.resyncAttackTarget then
		CombatAutomation.resyncAttackTarget(player)
	end
	player:setIdleCombat(false)
	player:removeCondition(CONDITION_INFIGHT)
	if CombatAutomationMovement then
		CombatAutomationMovement.clearDirective(player)
		CombatAutomationMovement.clearWalkDedupe(player)
	end
	if player.clearPathLeash then
		player:clearPathLeash()
	end
	-- Think pipeline stops when idleCombat clears; do not re-arm combat here.
end

-- ---------------------------------------------------------------------------
-- Catch-up (teleport last resort; walking back is CombatAutomationMovement's)
-- ---------------------------------------------------------------------------

local CATCH_UP_OFFSETS = { { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }
for i, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
	table.insert(CATCH_UP_OFFSETS, i, off)
end

local function findCatchUpTile(player, anchor)
	local apos = anchor:getPosition()
	for _, off in ipairs(CATCH_UP_OFFSETS) do
		local pos = Position(apos.x + off[1], apos.y + off[2], apos.z)
		if geo.tileFree(pos, player) then
			return pos
		end
	end
	return apos
end

local function teleportNearAnchor(session, player, anchor)
	if not player.teleportTo then
		return
	end
	player:teleportTo(findCatchUpTile(player, anchor))
	if CombatAutomationMovement then
		CombatAutomationMovement.clearWalkDedupe(player)
	end
	session.catchUpTeleports = (session.catchUpTeleports or 0) + 1
end

--- Lagging companions walk back (CombatAutomationMovement catch-up). Teleport is the
--- last resort: another floor, or beyond CATCH_UP_TELEPORT_SQM without closing in
--- for CATCH_UP_STALL_MS.
local function catchUpMember(session, player, anchor)
	if player:getId() == anchor:getId() or (session.manualIds and session.manualIds[player:getId()]) then
		return
	end
	-- On an errand, or the party is crossing to another floor on foot (portal, stairs).
	if PlayerErrand.owns(player) or (session.catchUpHeldUntil or 0) > geo.nowMs() then
		if session._catchUp then
			session._catchUp[player:getId()] = nil
		end
		return
	end
	local ppos = player:getPosition()
	local apos = anchor:getPosition()
	if not ppos or not apos then
		return
	end
	session._catchUp = session._catchUp or {}
	local pid = player:getId()
	if ppos.z ~= apos.z then
		session._catchUp[pid] = nil
		teleportNearAnchor(session, player, anchor)
		return
	end
	local dist = geo.chebyshev(ppos, apos)
	if dist <= CombatAutomationConfig.CATCH_UP_TELEPORT_SQM then
		session._catchUp[pid] = nil
		return
	end
	local now = geo.nowMs()
	local track = session._catchUp[pid] or geo.Progress.new(now)
	session._catchUp[pid] = track
	if geo.Progress.improve(track, dist, now) then
		return
	end
	if geo.Progress.stalled(track, now, CombatAutomationConfig.CATCH_UP_STALL_MS) then
		session._catchUp[pid] = nil
		teleportNearAnchor(session, player, anchor)
	end
end

function ExpeditionAI.stopPlayer(session, player)
	if not session or not player then
		return
	end
	clearPlayerCombat(player)
end

--- How the cavebot walker sees an expedition session (run host, cavebot/02_run.lua).
Cavebot.sessionHost = {
	memberIds = memberIds,
	anchor = function(session)
		return ExpeditionConfig.getAnchorPlayer(session)
	end,
	route = function(session)
		return session.catalog and ExpeditionConfig.caveRoute(session.catalog) or nil
	end,
	alive = function(session)
		return session.state ~= "ended" and not session.endedByDeath
	end,
	walks = ExpeditionPack.walksCave,
	notify = function(session)
		ExpeditionManager.broadcastStatus(session)
	end,
	onStart = function(session)
		session.state = "hunting"
	end,
	priorityTarget = ExpeditionPack.forcedFiendish,
	--- Paused members (manual control, a paused cavebot, AUTO attack off). Pausing restarts
	--- catch-up tracking; a resumable pause (manual / paused cavebot) tells that client so
	--- it can offer Resume Auto.
	onPauseChange = function(session, player, reason, prev)
		if reason and not prev and session._catchUp then
			session._catchUp[player:getId()] = nil
		end
		local now, was = Cavebot.isResumablePause(reason), Cavebot.isResumablePause(prev)
		if now ~= was then
			ExpeditionProtocol.sendManualControl(player, now)
		end
	end,
	--- Raids fight without an anchor.
	directives = function(session)
		return { noAnchor = sessionKind(session) == "raid", holdPos = session.holdPos }
	end,
	metrics = ExpeditionMetrics,
}

function ExpeditionAI.syncPathLeash(session)
	if not session then
		return
	end
	local radius = ExpeditionConfig.anchorPathBiasRadius and ExpeditionConfig.anchorPathBiasRadius() or 0
	local anchor = nil
	if radius > 0 and ExpeditionConfig.getAnchorPlayer then
		anchor = ExpeditionConfig.getAnchorPlayer(session)
	end
	local anchorId = anchor and anchor:getId() or 0
	local anchorPos = anchor and anchor.getPosition and anchor:getPosition() or nil
	local manual = session.manualIds or {}
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and player.clearPathLeash then
			if not anchorPos or PzTeleport.isGod(player) or id == anchorId or radius <= 0 or manual[id] then
				player:clearPathLeash()
			else
				player:setPathLeash(anchorPos, radius)
			end
		end
	end
end

function ExpeditionAI.tick(session)
	if not session then
		return
	end
	if session.state == "ended" or session.endedByDeath then
		return
	end
	if session.companionIds and ExpeditionManager and ExpeditionManager.notifyHuntMemberDeath then
		for companionId in pairs(session.companionIds) do
			local companion = Player(companionId)
			if not companion or (companion.getHealth and companion:getHealth() <= 0) then
				ExpeditionManager.notifyHuntMemberDeath(companion or companionId, nil)
				return
			end
		end
	end
	local ids = memberIds(session)
	local anyOnline = false
	for _, id in ipairs(ids) do
		if Player(id) then
			anyOnline = true
			break
		end
	end
	if not anyOnline then
		if ExpeditionManager.endIfNoPlayers then
			ExpeditionManager.endIfNoPlayers(session, { immediate = true })
		end
		return
	end
	if ExpeditionManager.endIfNoPlayers and ExpeditionManager.endIfNoPlayers(session) then
		return
	end

	local role = session.role or (session.catalog and session.catalog.role) or "monster"
	if role == "boss" and ExpeditionBoss and ExpeditionBoss.ensureKillableSession then
		ExpeditionBoss.ensureKillableSession(session)
	end

	-- Map-spawn hunts walk their cave route; boss / raid / arena pull to the anchor.
	Cavebot.step(session)
	if session.state == "ended" then
		return
	end
	ExpeditionPack.tickPull(session)
	ExpeditionAI.syncPathLeash(session)

	local anchor = nil
	if sessionKind(session) ~= "raid" then
		anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	end

	for _, id in ipairs(ids) do
		local player = Player(id)
		if player then
			if ExpeditionManager.reconcilePresence and not ExpeditionManager.reconcilePresence(player) then
				-- left area
			elseif PzTeleport.isGod(player) then
				-- spectate
			else
				ExpeditionAI.enablePersistence(player)
				if anchor then
					catchUpMember(session, player, anchor)
				end
			end
		end
	end
end

--- Sole session-tick driver every CombatAutomationConfig.TICK_MS. Do not also schedule from
--- playerOnThink / CombatAutomation.onThink — those own per-player combat only.
function ExpeditionAI.start(session)
	if not session or session.state == "ended" then
		return
	end
	for _, id in ipairs(memberIds(session)) do
		ExpeditionAI.enablePersistence(Player(id))
	end
	ExpeditionManager.scope(session):every(CombatAutomationConfig.TICK_MS, function()
		if session.state ~= "ended" then
			ExpeditionAI.tick(session)
		end
	end, "ai")

	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not PzTeleport.isGod(player) then
			suggestAutoOn(player)
		end
	end
	Cavebot.syncDirectives(session, Cavebot.sessionHost.directives(session))
	ExpeditionAI.syncPathLeash(session)
end

function ExpeditionAI.stop(session)
	if not session then
		return
	end
	if session.scope then
		session.scope:cancel("ai")
	end
	session._catchUp = nil
	local manual = session.manualIds or {}
	session.manualIds = nil
	session.pauseReasons = nil
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player then
			clearPlayerCombat(player)
			if manual[id] then
				ExpeditionProtocol.sendManualControl(player, false)
			end
		end
	end
end
