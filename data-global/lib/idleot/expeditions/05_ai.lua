-- Expedition session AI: persistence, directives, relocate settle, teleport catch-up.
-- Targeting / stance / casting live in CombatAutomation (per player).

ExpeditionAI = ExpeditionAI or {}

local function memberIds(session)
	if ExpeditionManager and ExpeditionManager.sessionMemberIds then
		return ExpeditionManager.sessionMemberIds(session)
	end
	if session and session.playerId then
		return { session.playerId }
	end
	return {}
end

local function sameTile(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function syncAttackTarget(session, player, target, force)
	if not session or not player then
		return
	end
	local creatureId = 0
	if target then
		creatureId = target:getId()
	end
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	local pid = player:getId()
	if not force and session.lastSyncedAttackByPlayer[pid] == creatureId then
		return
	end
	session.lastSyncedAttackByPlayer[pid] = creatureId
	session.lastSyncedAttackCreatureId = creatureId
	if ExpeditionProtocol and ExpeditionProtocol.sendAttackTarget then
		ExpeditionProtocol.sendAttackTarget(player, creatureId)
	end
end

function ExpeditionAI.resyncAttackTarget(session, player)
	if not session or not player then
		return
	end
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	session.lastSyncedAttackByPlayer[player:getId()] = nil
	session.lastSyncedAttackCreatureId = nil
	syncAttackTarget(session, player, player:getTarget(), true)
end

function ExpeditionAI.syncAttackTargetIfChanged(session, player)
	if not session or not player then
		return
	end
	local target = player:getTarget()
	local creatureId = 0
	if target then
		creatureId = target:getId()
	end
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	if session.lastSyncedAttackByPlayer[player:getId()] == creatureId then
		return
	end
	syncAttackTarget(session, player, target)
end

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
	if PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
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
	local condition = Condition(CONDITION_INFIGHT)
	condition:setParameter(CONDITION_PARAM_TICKS, 60000)
	player:addCondition(condition)
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
	if player.setIdleCombat then
		if player:isIdleCombat() then
			player:setIdleCombat(false)
		end
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
			stance = (ExpeditionConfig and ExpeditionConfig.stanceForPlayer and ExpeditionConfig.stanceForPlayer(player))
				or "melee",
			rangedDistance = (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 3,
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

local function clearPlayerCombat(session, player)
	if not player then
		return
	end
	if player.getFollowCreature and player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
	player:setTarget(nil)
	if session then
		session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
		session.lastSyncedAttackByPlayer[player:getId()] = nil
	end
	if ExpeditionProtocol and ExpeditionProtocol.sendAttackTarget then
		ExpeditionProtocol.sendAttackTarget(player, 0)
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

--- Teleport lagging non-anchors near the anchor — never onto holdPos (that blocks the wave gate).
local function tileFreeFor(player, pos)
	if not pos or not player then
		return false
	end
	local tile = Tile(pos)
	if not tile or not tile.getGround or not tile:getGround() then
		return false
	end
	if tile.hasProperty and CONST_PROP_BLOCKSOLID and tile:hasProperty(CONST_PROP_BLOCKSOLID) then
		return false
	end
	local top = tile.getTopCreature and tile:getTopCreature()
	if top and top.getId and top:getId() ~= player:getId() then
		return false
	end
	return true
end

local function findCatchUpTile(session, player, anchor)
	local apos = anchor:getPosition()
	if not apos then
		return nil
	end
	local hold = session.holdPos
	local offsets = {
		{ 1, 0 },
		{ -1, 0 },
		{ 0, 1 },
		{ 0, -1 },
		{ 1, 1 },
		{ 1, -1 },
		{ -1, 1 },
		{ -1, -1 },
		{ 2, 0 },
		{ -2, 0 },
		{ 0, 2 },
		{ 0, -2 },
	}
	for _, off in ipairs(offsets) do
		local pos = Position(apos.x + off[1], apos.y + off[2], apos.z)
		if not (hold and sameTile(pos, hold)) and tileFreeFor(player, pos) then
			return pos
		end
	end
	local fallback = Position(apos.x, apos.y - 1, apos.z)
	if hold and sameTile(fallback, hold) then
		fallback = Position(apos.x, apos.y + 1, apos.z)
	end
	return fallback
end

local function teleportCatchUp(session, player, anchor)
	if not session or not player or not anchor then
		return
	end
	if player:getId() == anchor:getId() then
		return
	end
	if PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
		return
	end
	local ppos = player:getPosition()
	local apos = anchor:getPosition()
	if not ppos or not apos then
		return
	end
	local teleportAt = tonumber(ExpeditionConfig.CATCH_UP_TELEPORT_SQM) or 15
	local dist = (ppos.z ~= apos.z) and (teleportAt + 1) or ppos:getDistance(apos)
	if dist > teleportAt and player.teleportTo then
		local dest = findCatchUpTile(session, player, anchor) or apos
		player:teleportTo(dest)
		if CombatAutomationMovement then
			CombatAutomationMovement.clearWalkDedupe(player)
		end
	end
end

--- If a party member (or any creature we can shove) occupies holdPos, step them aside
--- so the anchor can land for the wave gate.
local function clearHoldOccupants(session, hold, anchor)
	if not session or not hold then
		return
	end
	local tile = Tile(hold)
	if not tile then
		return
	end
	local creatures = tile.getCreatures and tile:getCreatures() or nil
	local top = nil
	if type(creatures) ~= "table" or #creatures == 0 then
		top = tile.getTopCreature and tile:getTopCreature()
		if not top then
			return
		end
		creatures = { top }
	end
	local anchorId = anchor and anchor:getId() or 0
	local memberSet = {}
	for _, id in ipairs(memberIds(session)) do
		memberSet[id] = true
	end
	for _, creature in ipairs(creatures) do
		if creature and creature.getId and creature:getId() ~= anchorId then
			local cid = creature:getId()
			if memberSet[cid] and creature.teleportTo then
				local dest = findCatchUpTile(session, creature, anchor or creature)
				if dest and not sameTile(dest, hold) then
					creature:teleportTo(dest)
					if CombatAutomationMovement then
						CombatAutomationMovement.clearWalkDedupe(creature)
					end
				end
			end
		end
	end
end

local function tickCatchUp(session)
	if not session then
		return
	end
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	if kind == "raid" then
		return
	end
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if not anchor then
		return
	end
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
			teleportCatchUp(session, player, anchor)
		end
	end
end

function ExpeditionAI.onPlayerWalk(player)
	if not player or not ExpeditionConfig then
		return
	end
	if player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) ~= 1 then
		return
	end
	if not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or session.state == "ended" then
		return
	end
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	if kind == "raid" then
		return
	end
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if not anchor or player:getId() ~= anchor:getId() then
		return
	end
	tickCatchUp(session)
end

function ExpeditionAI.stopPlayer(session, player)
	if not session or not player then
		return
	end
	clearPlayerCombat(session, player)
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
			local god = PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)
			if not anchorPos or god or id == anchorId or radius <= 0 then
				player:clearPathLeash()
			else
				player:setPathLeash(anchorPos, radius)
			end
		end
	end
end

--- Push hold/follow/anchorStance directives and drive anchor walk to hold during relocate.
function ExpeditionAI.syncDirectives(session)
	if not session or not CombatAutomationMovement then
		return
	end
	local hold = session.holdPos
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	local anchorId = anchor and anchor:getId() or session.anchorPlayerId
	local relocating = session.state == "relocating"
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"

	local function copyHold()
		if not hold then
			return nil
		end
		return Position(hold.x, hold.y, hold.z)
	end

	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
			if kind == "raid" then
				CombatAutomationMovement.clearDirective(player, "hold")
				CombatAutomationMovement.clearDirective(player, "follow")
				CombatAutomationMovement.clearDirective(player, "anchorStance")
			elseif relocating and hold then
				if id == anchorId then
					CombatAutomationMovement.clearDirective(player, "follow")
					CombatAutomationMovement.clearDirective(player, "anchorStance")
					CombatAutomationMovement.setDirective(player, {
						kind = "hold",
						pos = copyHold(),
						priority = "relocate",
					})
				elseif anchorId then
					local followDir = {
						kind = "follow",
						targetId = anchorId,
						holdPos = copyHold(),
						untilGate = "anchorHoldInViewport",
					}
					-- Gate met: stop engine-follow and switch to cardinal stance vs parked anchor.
					if CombatAutomationMovement.isFollowComplete and CombatAutomationMovement.isFollowComplete(player, followDir) then
						CombatAutomationMovement.clearDirective(player, "hold")
						CombatAutomationMovement.clearDirective(player, "follow")
						CombatAutomationMovement.setDirective(player, {
							kind = "anchorStance",
							targetId = anchorId,
							holdPos = copyHold(),
						})
					else
						CombatAutomationMovement.clearDirective(player, "hold")
						CombatAutomationMovement.clearDirective(player, "anchorStance")
						CombatAutomationMovement.setDirective(player, followDir)
					end
				end
			elseif hold and id == anchorId then
				-- Soft hold when idle/waiting with no focus: CombatAutomationMovement demotes when fighting.
				CombatAutomationMovement.setDirective(player, {
					kind = "hold",
					pos = copyHold(),
					priority = "soft",
				})
				CombatAutomationMovement.clearDirective(player, "follow")
				CombatAutomationMovement.clearDirective(player, "anchorStance")
			else
				-- Settled non-anchor: cardinal stance vs parked anchor until they take a combat focus.
				CombatAutomationMovement.clearDirective(player, "hold")
				CombatAutomationMovement.clearDirective(player, "follow")
				if hold and anchorId then
					CombatAutomationMovement.setDirective(player, {
						kind = "anchorStance",
						targetId = anchorId,
						holdPos = copyHold(),
					})
				else
					CombatAutomationMovement.clearDirective(player, "anchorStance")
				end
			end
		end
	end
end

function ExpeditionAI.startRelocateWalk(session)
	if not session then
		return
	end
	if session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	session._relocateFollowReady = nil
	ExpeditionAI.syncDirectives(session)
	ExpeditionAI.syncPathLeash(session)

	local key = session.key
	local POLL_MS = ExpeditionConfig.AI_TICK_MS or 250

	local function loop()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state ~= "relocating" then
			if s then
				s.relocateWalkEvent = nil
			end
			return
		end
		ExpeditionAI.syncDirectives(s)
		ExpeditionAI.syncPathLeash(s)
		local hold = s.holdPos
		local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(s)
		if not hold or not anchor then
			s.relocateWalkEvent = addEvent(loop, POLL_MS)
			return
		end

		if anchor:getFollowCreature() then
			anchor:setFollowCreature(nil)
		end

		-- Keep hold free so getPathTo(exact tile) can succeed for the wave gate.
		clearHoldOccupants(s, hold, anchor)

		-- Drive hold walk via CombatAutomation movement (regular pathfinding).
		if CombatAutomationMovement then
			local cfg = CombatAutomationStore and CombatAutomationStore.getConfig(anchor) or {}
			CombatAutomationMovement.tick(anchor, cfg)
			-- Also tick non-anchors so follow runs even if their combat loop stalled.
			local aid = anchor:getId()
			for _, mid in ipairs(memberIds(s)) do
				if mid ~= aid then
					local member = Player(mid)
					if member and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(member)) then
						local mcfg = CombatAutomationStore and CombatAutomationStore.getConfig(member) or {}
						CombatAutomationMovement.tick(member, mcfg)
					end
				end
			end
		end

		if sameTile(anchor:getPosition(), hold) then
			s._relocateFollowReady = true
			s.relocateWalkEvent = nil
			if ExpeditionWaves and ExpeditionWaves.onRelocatePartySettled then
				ExpeditionWaves.onRelocatePartySettled(s)
			end
			-- Session tick stays on aiEvent (ExpeditionAI.start); do not double-tick here.
			return
		end

		tickCatchUp(s)
		s.relocateWalkEvent = addEvent(loop, POLL_MS)
	end

	session.relocateWalkEvent = addEvent(loop, 0)
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
	if #ids == 0 then
		if ExpeditionManager.endIfNoPlayers then
			ExpeditionManager.endIfNoPlayers(session, { immediate = true })
		end
		return
	end

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

	ExpeditionAI.syncDirectives(session)
	ExpeditionAI.syncPathLeash(session)

	-- Keep instance monsters near the live party anchor (hunts, raids, bosses, …).
	if session.state == "hunting" and ExpeditionWaves and ExpeditionWaves.pullMonstersToAnchor then
		ExpeditionWaves.pullMonstersToAnchor(session)
	end

	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	local anchor = nil
	if kind ~= "raid" then
		anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	end

	for _, id in ipairs(ids) do
		local player = Player(id)
		if player then
			if ExpeditionManager.reconcilePresence and not ExpeditionManager.reconcilePresence(player) then
				-- left area
			elseif PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
				-- spectate
			else
				ExpeditionAI.enablePersistence(player)
				if anchor and kind ~= "raid" then
					teleportCatchUp(session, player, anchor)
				end
				ExpeditionAI.syncAttackTargetIfChanged(session, player)
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
		if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
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
	if session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	session._relocateMember = nil
	session._relocateDestsAssigned = nil
	session._relocateFollowReady = nil
	session._catchUpBoost = nil
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player then
			clearPlayerCombat(session, player)
		end
	end
end
