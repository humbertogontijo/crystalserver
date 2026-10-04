-- Expedition session AI: the single session tick (AI_TICK_MS), persistence,
-- movement directives and catch-up. Targeting / stance / casting live in
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
	if player:getId() == anchor:getId() then
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
	if dist <= (tonumber(ExpeditionConfig.CATCH_UP_TELEPORT_SQM) or 15) then
		session._catchUp[pid] = nil
		return
	end
	local now = geo.nowMs()
	local track = session._catchUp[pid]
	if not track or dist < track.dist then
		session._catchUp[pid] = { dist = dist, at = now }
		return
	end
	if now - track.at > (tonumber(ExpeditionConfig.CATCH_UP_STALL_MS) or 10000) then
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
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and player.clearPathLeash then
			if not anchorPos or PzTeleport.isGod(player) or id == anchorId or radius <= 0 then
				player:clearPathLeash()
			else
				player:setPathLeash(anchorPos, radius)
			end
		end
	end
end

--- Movement directives: the anchor walks the cave route (ExpeditionCavebot) or holds
--- the session holdPos (boss / arena / before the walk starts); the others trail the
--- anchor in line while it walks and take formation around it while it fights.
function ExpeditionAI.syncDirectives(session)
	if not session or not CombatAutomationMovement then
		return
	end
	local move = CombatAutomationMovement
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	local anchorId = anchor and anchor:getId() or session.anchorPlayerId
	local raid = sessionKind(session) == "raid"

	local anchorDirective, walking = nil, false
	if not raid and anchor then
		if session.cave and ExpeditionCavebot then
			anchorDirective, walking = ExpeditionCavebot.anchorDirective(session, anchor)
		elseif session.holdPos then
			local hold = session.holdPos
			anchorDirective = { kind = "hold", pos = Position(hold.x, hold.y, hold.z), priority = "soft" }
		end
	end

	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not PzTeleport.isGod(player) then
			if raid then
				move.clearDirective(player)
			elseif id == anchorId then
				if anchorDirective then
					move.setDirective(player, anchorDirective)
				else
					move.clearDirective(player)
				end
			elseif anchorId and anchorDirective then
				if walking then
					move.setDirective(player, { kind = "follow", targetId = anchorId })
				else
					move.setDirective(player, { kind = "anchorStance", targetId = anchorId, front = anchorDirective.front })
				end
			else
				move.clearDirective(player)
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

	-- Map-spawn hunts: pack tracking + cave walker (boss / raid: pull to anchor).
	if ExpeditionPack and ExpeditionPack.tickLure then
		ExpeditionPack.tickLure(session)
		if session.state == "ended" then
			return
		end
	end

	ExpeditionAI.syncDirectives(session)
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

--- Sole session-tick driver at AI_TICK_MS (250). Do not also schedule from
--- playerOnThink / CombatAutomation.onThink — those own per-player combat only.
function ExpeditionAI.start(session)
	if not session or session.state == "ended" then
		return
	end
	if session.aiEvent then
		stopEvent(session.aiEvent)
		session.aiEvent = nil
	end
	for _, id in ipairs(memberIds(session)) do
		ExpeditionAI.enablePersistence(Player(id))
	end
	local key = session.key
	local tickMs = ExpeditionConfig.AI_TICK_MS or 250
	local function loop()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state == "ended" then
			if s then
				s.aiEvent = nil
			end
			return
		end
		ExpeditionAI.tick(s)
		s = ExpeditionManager.getSessionByKey(key)
		if s and s.state ~= "ended" then
			s.aiEvent = addEvent(loop, tickMs)
		elseif s then
			s.aiEvent = nil
		end
	end
	session.aiEvent = addEvent(loop, tickMs)

	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not PzTeleport.isGod(player) then
			suggestAutoOn(player)
		end
	end
	ExpeditionAI.syncDirectives(session)
	ExpeditionAI.syncPathLeash(session)
end

function ExpeditionAI.stop(session)
	if not session then
		return
	end
	if session.aiEvent then
		stopEvent(session.aiEvent)
		session.aiEvent = nil
	end
	session._catchUp = nil
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player then
			clearPlayerCombat(player)
		end
	end
end
