-- Auto-split from 07_manager.lua (shared EM_PRIV). Do not redefine ExpeditionManager.
function ExpeditionManager.leaveAll(session, opts)
	opts = opts or {}
	if not session then
		return
	end
	local ids = {}
	for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
		ids[#ids + 1] = id
	end
	local goHometownId = tonumber(opts.goHometownPlayerId)
	for _, id in ipairs(ids) do
		local p = Player(id)
		if p then
			local memberOpts = opts
			if goHometownId and id == goHometownId then
				memberOpts = {}
				for k, v in pairs(opts) do
					memberOpts[k] = v
				end
				memberOpts.goHometown = true
				memberOpts.goHometownPlayerId = nil
			end
			ExpeditionManager.leave(p, memberOpts)
		end
	end
	if EM_PRIV.sessionsByKey[session.key] == session then
		EM_PRIV.cleanupSession(session, nil, opts)
	end
end

--- Delayed leaveAll after victory/failure messaging (boss clear, Fiendish Hunt).
--- opts: victory, endMsg, delayMs (defaults to ExpeditionConfig.LOOT_GRACE_MS)
function ExpeditionManager.scheduleSessionExit(session, opts)
	opts = opts or {}
	if not session then
		return
	end
	local victory = opts.victory == true
	local endMsg = opts.endMsg
	local delayMs = tonumber(opts.delayMs) or (ExpeditionConfig.LOOT_GRACE_MS or 5000)
	local key = session.key
	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end
	local function exitSession()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state == "ended" then
			return
		end
		local anyOnline = false
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s) or {}) do
			local p = Player(mid)
			if p then
				anyOnline = true
				if endMsg then
					p:sendTextMessage(MESSAGE_EVENT_ADVANCE, endMsg)
				end
			end
		end
		if anyOnline then
			ExpeditionManager.leaveAll(s, { silent = true, victory = victory })
		else
			ExpeditionManager.teardownSession(s)
		end
	end
	-- The loot window is the exit channel.
	local channeled = InstanceTeleport
		and InstanceTeleport.requestExpeditionExit
		and InstanceTeleport.requestExpeditionExit({
			memberIds = ExpeditionManager.sessionMemberIds(session),
			durationMs = delayMs,
			onComplete = exitSession,
		})
	if not channeled then
		session.waitingEvent = addEvent(exitSession, delayMs)
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
	if opts.goHometownPlayerId then
		leaveOpts.goHometownPlayerId = opts.goHometownPlayerId
	end
	if session.kind == "raid" then
		local p = Player(session.playerId)
		if p then
			if not opts.silent then
				p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			end
			if opts.goHometownPlayerId and p:getId() == opts.goHometownPlayerId then
				leaveOpts.goHometown = true
			end
			ExpeditionManager.leave(p, leaveOpts)
		end
		return
	end
	if not opts.silent then
		for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
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
function EM_PRIV.rememberHuntDeath(session, member)
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

function EM_PRIV.huntDeathMessage(pending, reason)
	if reason and reason ~= "" then
		return tostring(reason)
	end
	local name = (pending and pending.name) or "Adventurer"
	return string.format("%s is dead. The expedition has ended.", name)
end

function EM_PRIV.collectHumanViewers(session, deadMember)
	local humans = {}
	local seen = {}
	local deadId = deadMember and deadMember:getId() or nil
	if not deadId and session and session.pendingHuntDeath then
		deadId = session.pendingHuntDeath.id
	end

	-- Anyone with a live UI needs the hunt-death modal. Do not use isSessionCompanion:
	-- sticky companionIds after client attach would skip the player and leave them
	-- stranded in a swept instance with no modal.
	local function consider(p)
		if not p then
			return
		end
		local id = p:getId()
		if deadId and id == deadId then
			return
		end
		if seen[id] then
			return
		end
		if not EM_PRIV.hasUiClient(p) then
			return
		end
		seen[id] = true
		humans[#humans + 1] = p
	end

	for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
		consider(Player(id))
	end

	-- Fallback: UI clients still inside the private instance (stale playerIds).
	local instance = session and session.instance
	local instanceId = instance and (instance.instanceId or instance.slot)
	if instanceId and Game.getPlayers then
		for _, p in ipairs(Game.getPlayers()) do
			if p and p.getInstanceId and p:getInstanceId() == instanceId then
				consider(p)
			end
		end
	end
	return humans
end

function EM_PRIV.logoutExpeditionCompanions(session)
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
		if not companion or not EM_PRIV.isSessionCompanion(session, companion) then
			return
		end
		EM_PRIV.removeHuntMember(session, companion, { skipEnded = true, keepDeadFlag = true })
		EM_PRIV.clearActive(companion)
		if Alts and Alts.safeLogoutCompanion then
			Alts.safeLogoutCompanion(companion, 0)
		elseif Game.headlessLogout then
			-- Fallback: park to open-world return before save+logout (loginPosition).
			local returnPos = EM_PRIV.loadReturn(companion)
			if InstanceWorld and InstanceWorld.exitToOpenWorld then
				pcall(InstanceWorld.exitToOpenWorld, companion, returnPos)
			elseif returnPos then
				pcall(function()
					companion:teleportTo(returnPos)
				end)
			end
			pcall(Game.headlessLogout, companion)
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

function EM_PRIV.teleportHumanToReturn(player)
	if not player then
		return false
	end
	local returnPos = EM_PRIV.loadReturn(player)
	if not returnPos then
		return false
	end
	local ok = EM_PRIV.returnToLobby(player, returnPos)
	if ok and player.getHealth and player:getHealth() > 0 then
		local now = player:getPosition()
		if now then
			now:sendMagicEffect(CONST_ME_TELEPORT)
		end
	end
	return ok
end

function EM_PRIV.ejectPlayerFromExpedition(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	EM_PRIV.clearActive(player)
	ExpeditionManager.clearAreaEffects(player)
	player:setIdleCombat(false)
	player:removeCondition(CONDITION_INFIGHT)
	if not opts.skipTeleport then
		EM_PRIV.teleportHumanToReturn(player)
	end
	if not opts.skipTeamUndeploy and Alts and Alts.getDeployment and Alts.getDeployment(player) then
		Alts.undeploy(player)
	end
	ExpeditionProtocol.sendEnded(player)
end

--- End expedition membership/HUD without undeploy; used before immediate return travel.
function EM_PRIV.releaseHumanFromExpeditionDeath(player)
	EM_PRIV.ejectPlayerFromExpedition(player, { skipTeleport = true, skipTeamUndeploy = true })
end

--- Clear expedition HUD/membership, then move out of the private instance.
--- Client scene freeze keeps the death frame until the player confirms.
function EM_PRIV.releaseAndReturnHumanFromHuntDeath(player)
	EM_PRIV.releaseHumanFromExpeditionDeath(player)
	EM_PRIV.teleportHumanToReturn(player)
end

function EM_PRIV.sweepHuntDeathSession(session)
	if not session or session._cleaned then
		return
	end
	session.pendingHuntDeath = nil
	session.state = "ended"
	if EM_PRIV.sessionsByKey[session.key] == session then
		EM_PRIV.cleanupSession(session, nil)
	end
end

function EM_PRIV.resolveSessionForHuntDeath(deadRef, player)
	if player then
		return ExpeditionManager.resolveSession(player)
	end
	local deadId = deadRef
	if type(deadId) ~= "number" then
		return nil
	end
	for _, s in pairs(EM_PRIV.sessionsByKey) do
		if s.companionIds and s.companionIds[deadId] then
			return s
		end
	end
	for _, s in pairs(EM_PRIV.sessionsByKey) do
		if s.pendingHuntDeath and s.pendingHuntDeath.id == deadId then
			return s
		end
	end
	return nil
end

function EM_PRIV.endHuntByDeath(session, deadMember, reason)
	if not session or session.kind == "raid" then
		return
	end
	if session.persistedForRestart or (ExpeditionPersist and ExpeditionPersist.isServerShuttingDown()) then
		return
	end
	if session._cleaned then
		return
	end
	if session.endedByDeath then
		EM_PRIV.sweepHuntDeathSession(session)
		return
	end
	session.endedByDeath = true
	session.aborting = true
	session.state = "ended"

	local ok, err = pcall(function()
		local pending = EM_PRIV.rememberHuntDeath(session, deadMember)
		local subjectName = (pending and pending.name) or (deadMember and deadMember:getName()) or "Adventurer"
		local message = EM_PRIV.huntDeathMessage(pending, reason)

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

		if session.role == "boss" then
			EM_PRIV.refundBossCooldownForSession(session)
		end

		if ExpeditionAI and ExpeditionAI.stop then
			ExpeditionAI.stop(session)
		end

		local subjectId = (pending and pending.id) or (deadMember and deadMember:getId()) or nil
		for _, p in ipairs(EM_PRIV.collectHumanViewers(session, deadMember)) do
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			ExpeditionProtocol.sendHuntDeath(p, {
				subjectName = subjectName,
				subjectId = subjectId,
				message = message,
			})
			EM_PRIV.releaseAndReturnHumanFromHuntDeath(p)
		end

		-- Deceased human: stock death dialog only (no hunt-death modal), but still leave the instance.
		if deadMember and not EM_PRIV.isSessionCompanion(session, deadMember) then
			EM_PRIV.releaseAndReturnHumanFromHuntDeath(deadMember)
		end

		EM_PRIV.logoutExpeditionCompanions(session)
	end)
	if not ok then
		logger.error("[Expedition] endHuntByDeath failed ({}): {}", tostring(session.key), tostring(err))
	end
	EM_PRIV.sweepHuntDeathSession(session)
end

--- Public entry for player death, companion logout, and AI watchdog.
function ExpeditionManager.notifyHuntMemberDeath(deadRef, reason)
	if ExpeditionPersist and ExpeditionPersist.isServerShuttingDown() then
		return
	end
	local player = deadRef
	if type(deadRef) == "number" then
		player = Player(deadRef)
	end
	if not player and type(deadRef) ~= "number" then
		return
	end

	local session = EM_PRIV.resolveSessionForHuntDeath(deadRef, player)
	if not session or session.kind == "raid" or session.kind == "worldboss" then
		return
	end
	if session.persistedForRestart then
		return
	end
	if session._cleaned then
		return
	end
	if session.endedByDeath then
		EM_PRIV.sweepHuntDeathSession(session)
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
				name = "Alt",
			}
		end
	end
	EM_PRIV.endHuntByDeath(session, player, reason)
end

--- Hunt-death modal confirmed: ensure return travel, undeploy, and resync client map.
function ExpeditionManager.ackHuntDeath(player)
	if not player then
		return
	end
	ExpeditionManager.cancelLeave(player)
	local privateBase = (InstanceWorld and InstanceWorld.PRIVATE_BASE) or 3000000
	if player.getInstanceId and player:getInstanceId() >= privateBase then
		EM_PRIV.teleportHumanToReturn(player)
	end
	EM_PRIV.ejectPlayerFromExpedition(player, { skipTeleport = true })
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
	EM_PRIV.cleanupSession(session, nil)
end

--- Solo/boss: once no living humans remain, kick remaining members and sweep.
--- Hunt death (player or companion) uses endHuntByDeath instead.
--- Presence is spatial (zone players), not a storage flag. Raids stay up for late join.
function ExpeditionManager.endIfNoPlayers(session, opts)
	opts = opts or {}
	if not session or EM_PRIV.sessionsByKey[session.key] ~= session then
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
	-- Lure is predefined per hold; player configuration is disabled.
	if not player then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session then
		ExpeditionManager.broadcastStatus(session)
	end
end

--- Boss join: levers that declare `difficulty` open the native dialog first; every other
--- boss joins directly.
function ExpeditionManager.prepareBoss(player, expeditionId, loadout, options)
	if not player then
		return
	end
	options = options or {}
	local catalog = ExpeditionConfig.getById(expeditionId, "boss")
	if not catalog then
		ExpeditionProtocol.sendError(player, "Unknown boss expedition.")
		return
	end
	local levelMin = catalog.levelMin or 1
	if not EM_PRIV.meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		return
	end
	local bossName = ExpeditionConfig.bossTypeName(catalog)
	if not bossName then
		ExpeditionProtocol.sendError(player, "Unknown boss type for this expedition.")
		return
	end
	local gatePlayers = { player }
	for _, teammate in ipairs(EM_PRIV.collectExpectedHumanTeammates(player, options)) do
		gatePlayers[#gatePlayers + 1] = teammate
	end
	if not options.previewOnly then
		local canFight, _, _, cdErr = ExpeditionConfig.partyCanFightBoss(gatePlayers, bossName)
		if not canFight then
			ExpeditionProtocol.sendError(player, cdErr or "A team member is on boss cooldown.")
			return
		end
	end

	local lever = ExpeditionConfig.bossDifficultyLever(catalog)
	local opened = lever
		and BossDifficulty.open(player, {
			lever = lever,
			players = gatePlayers,
			banners = EM_PRIV.collectBossDifficultyBannerNames(player, options),
			selected = options.bossDifficulty,
			onStart = function(D)
				if options.previewOnly then
					player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Boss difficulty set to %d.", D))
					return
				end
				options.bossDifficulty = D
				ExpeditionManager.join(player, catalog.id, "boss", loadout, nil, options)
			end,
		})
	if opened then
		return
	end
	if options.previewOnly then
		ExpeditionProtocol.sendError(player, "This boss has no difficulty selection.")
		return
	end
	options.bossDifficulty = nil
	ExpeditionManager.join(player, catalog.id, "boss", loadout, nil, options)
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

--- Cancel a pending voluntary leave countdown or InstanceTeleport channel.
--- Hometown (recall): initiator-only via IT policy. Expedition switch/entry: any member.
function ExpeditionManager.cancelLeave(player)
	if not player then
		return false
	end
	if InstanceTeleport and InstanceTeleport.isPending and InstanceTeleport.isPending(player) then
		if InstanceTeleport.cancel(player) then
			return true
		end
		-- Policy denied (e.g. non-initiator recall) — fall through to leavePending if any.
	end
	local playerId = player:getId()
	local pending = EM_PRIV.leavePendingByPlayerId[playerId]
	if not pending then
		return false
	end
	if pending.team and pending.sessionKey then
		local teamPending = EM_PRIV.leavePendingBySessionKey[pending.sessionKey]
		if not teamPending then
			EM_PRIV.leavePendingByPlayerId[playerId] = nil
			return false
		end
		if teamPending.event then
			stopEvent(teamPending.event)
		end
		EM_PRIV.leavePendingBySessionKey[pending.sessionKey] = nil
		local session = ExpeditionManager.getSessionByKey(pending.sessionKey)
		if session then
			for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
				EM_PRIV.leavePendingByPlayerId[id] = nil
				local p = Player(id)
				if p and not EM_PRIV.isSessionCompanion(session, p) then
					ExpeditionProtocol.send(p, { type = "leaveCancelled" })
				end
			end
		else
			EM_PRIV.leavePendingByPlayerId[playerId] = nil
		end
		return true
	end
	if pending.event then
		stopEvent(pending.event)
	end
	EM_PRIV.leavePendingByPlayerId[playerId] = nil
	ExpeditionProtocol.send(player, { type = "leaveCancelled" })
	return true
end

-- Forward-declared: defined below (used by switch countdown completion).
local performDirectSwitch

--- Finish a voluntary leave countdown. Uses sessionKey so team abort still runs
--- when the initiator is briefly unresolvable via Player(id) in a delayed event.
--- When switchTo is set: hop hunt→hunt in place (no city return) after the countdown.
--- leaveMeta.goHometown: initiator recalls to town temple.
function EM_PRIV.completeLeaveCountdown(sessionKey, initiatorId, initiatorName, switchTo, leaveMeta)
	leaveMeta = leaveMeta or {}
	local goHometown = leaveMeta.goHometown == true
	local s = sessionKey and ExpeditionManager.getSessionByKey(sessionKey) or nil
	if switchTo then
		local joiner = Player(initiatorId)
		if not joiner then
			logger.warn(
				"[Expedition] switch countdown complete missing player key={} id={}",
				tostring(sessionKey),
				tostring(initiatorId)
			)
			return
		end
		logger.info(
			"[Expedition] switch countdown complete → {} by={}",
			tostring(switchTo.id),
			tostring(initiatorName or joiner:getName())
		)
		performDirectSwitch(joiner, s, switchTo, {}, { channeled = true })
		return
	end

	local leaveOpts = { silent = false, goHometown = goHometown }
	if not s then
		local p = Player(initiatorId)
		if p then
			logger.info(
				"[Expedition] leave countdown complete solo (no session) by={} goHometown={}",
				tostring(initiatorName or initiatorId),
				tostring(goHometown)
			)
			ExpeditionManager.leave(p, leaveOpts)
		end
		return
	end

	-- Team stop is decided by human count, not session state ("waiting" also covers
	-- the boss intermission after entry); the pre-entry lobby is handled in requestLeave.
	local humanCount = EM_PRIV.countHumanMembers(s)
	local teamStop = s.kind ~= "raid" and humanCount >= 2
	local name = initiatorName or "A teammate"
	if teamStop then
		if not s.entered then
			ExpeditionManager.cancelWaitingSession(s, name .. " cancelled the expedition.")
			if goHometown then
				local p = Player(initiatorId)
				if p and InstanceTeleport and InstanceTeleport.executeHometown then
					InstanceTeleport.executeHometown(p, { fromExpedition = true })
				end
			end
		else
			logger.info(
				"[Expedition] leave countdown complete teamStop key={} by={} goHometown={}",
				tostring(sessionKey),
				name,
				tostring(goHometown)
			)
			local abortMsg = goHometown and (name .. " recalled.") or (name .. " stopped the expedition.")
			local abortOpts = {}
			if goHometown then
				abortOpts.goHometownPlayerId = initiatorId
			end
			ExpeditionManager.abort(s, abortMsg, abortOpts)
		end
		return
	end

	local p = Player(initiatorId)
	if p then
		logger.info(
			"[Expedition] leave countdown complete solo key={} by={} goHometown={}",
			tostring(sessionKey),
			name,
			tostring(goHometown)
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

function EM_PRIV.clearLeavePendingForSession(sessionKey, fallbackPlayerId)
	EM_PRIV.leavePendingBySessionKey[sessionKey] = nil
	local s = ExpeditionManager.getSessionByKey(sessionKey)
	for _, id in ipairs(s and ExpeditionManager.sessionMemberIds(s) or { fallbackPlayerId }) do
		EM_PRIV.leavePendingByPlayerId[id] = nil
	end
end

--- Voluntary leave: enforce LEAVE_COUNTDOWN_SEC server-side, then eject.
--- Forced/silent paths should call leave() directly.
--- opts.switchTo = { id, role, loadout, lure, options }: after the same countdown,
--- hop directly into that expedition (no city return).
function ExpeditionManager.requestLeave(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	local playerId = player:getId()
	if EM_PRIV.leavePendingByPlayerId[playerId] then
		-- Update switch destination if the player picks another hunt mid-countdown.
		if opts.switchTo then
			EM_PRIV.leavePendingByPlayerId[playerId].switchTo = opts.switchTo
			EM_PRIV.leavePendingByPlayerId[playerId].initiatorName = player:getName()
		end
		return
	end
	if InstanceTeleport and InstanceTeleport.isPending and InstanceTeleport.isPending(player) then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		if opts.switchTo then
			-- Sticky HUD / no live session: hop straight into the destination.
			performDirectSwitch(player, nil, opts.switchTo, {})
		else
			local goHometown = opts.reason == "recall" or opts.goHometown == true
			ExpeditionManager.leave(player, { goHometown = goHometown })
		end
		return
	end

	-- Pre-entry (team-accept lobby / not yet teleported): cancel immediately.
	if not session.entered then
		local switchTo = opts.switchTo
		local goHometown = opts.reason == "recall" or opts.goHometown == true
		ExpeditionManager.cancelWaitingSession(
			session,
			player:getName() .. " cancelled the expedition."
		)
		if switchTo then
			performDirectSwitch(player, nil, switchTo, {})
		elseif goHometown and InstanceTeleport and InstanceTeleport.executeHometown then
			InstanceTeleport.executeHometown(player, { fromExpedition = true })
		end
		return
	end

	local switchTo = opts.switchTo
	local sessionKey = session.key
	local leaverName = player:getName()
	local goHometown = opts.reason == "recall" or opts.goHometown == true
	local stopToLobby = opts.reason == "stop" and not goHometown and not switchTo

	-- Recall / switch / lobby stop: shared InstanceTeleport channel (server-timed).
	if (goHometown or switchTo or stopToLobby) and InstanceTeleport then
		if InstanceTeleport.isPending(player) then
			return
		end
		local humans = EM_PRIV.collectSessionHumans(session)
		local memberIds = {}
		for _, member in ipairs(humans) do
			memberIds[#memberIds + 1] = member:getId()
		end
		if #memberIds == 0 then
			memberIds = { playerId }
		end
		local requestFn = InstanceTeleport.requestExpedition
		if goHometown then
			requestFn = InstanceTeleport.requestHometownGroup
		elseif stopToLobby then
			requestFn = InstanceTeleport.requestLobbyGroup
		end
		if not requestFn then
			ExpeditionProtocol.sendError(player, "Teleport is unavailable.")
			return
		end
		local destination = nil
		if stopToLobby and (session.kind == "raid" or session.kind == "worldboss") then
			-- Shared raids / world boss exit to the open world, not the lobby room.
			destination = InstanceTeleport.DEST_OPEN_WORLD
		end
		local ok, err = requestFn({
			initiatorId = playerId,
			memberIds = memberIds,
			destination = destination,
			onComplete = function()
				EM_PRIV.completeLeaveCountdown(sessionKey, playerId, leaverName, switchTo, { goHometown = goHometown })
			end,
			onCancel = function(ids)
				for _, id in ipairs(ids or memberIds) do
					local p = Player(id)
					if p then
						ExpeditionProtocol.send(p, { type = "leaveCancelled" })
					end
				end
			end,
		})
		if not ok then
			ExpeditionProtocol.sendError(player, err or "Could not start teleport.")
		end
		return
	end

	local sec = math.max(0, math.floor(tonumber(ExpeditionConfig.LEAVE_COUNTDOWN_SEC) or 5))
	if sec <= 0 then
		EM_PRIV.completeLeaveCountdown(sessionKey, playerId, leaverName, switchTo, { goHometown = goHometown })
		return
	end

	-- Team-wide stop only with 2+ humans (not by state: "waiting" also covers the
	-- boss intermission after entry).
	local humanCount = EM_PRIV.countHumanMembers(session)
	local teamStop = session.kind ~= "raid" and humanCount >= 2
	if teamStop then
		if EM_PRIV.leavePendingBySessionKey[sessionKey] then
			-- Allow a newer switch target to replace the pending one.
			if switchTo then
				EM_PRIV.leavePendingBySessionKey[sessionKey].switchTo = switchTo
				EM_PRIV.leavePendingBySessionKey[sessionKey].initiatorId = playerId
				EM_PRIV.leavePendingBySessionKey[sessionKey].initiatorName = leaverName
			end
			if goHometown then
				EM_PRIV.leavePendingBySessionKey[sessionKey].goHometown = true
				EM_PRIV.leavePendingBySessionKey[sessionKey].reason = opts.reason
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
			reason = opts.reason,
			goHometown = goHometown,
		}
		local event = addEvent(function(key, pid)
			local pending = EM_PRIV.leavePendingBySessionKey[key]
			local to = pending and pending.switchTo or nil
			local name = (pending and pending.initiatorName) or nil
			local pendingGoHometown = pending and pending.goHometown == true
			EM_PRIV.clearLeavePendingForSession(key, pid)
			EM_PRIV.completeLeaveCountdown(key, pid, name, to, { goHometown = pendingGoHometown })
		end, sec * 1000, sessionKey, playerId)
		pendingInfo.event = event
		EM_PRIV.leavePendingBySessionKey[sessionKey] = pendingInfo
		for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
			local p = Player(id)
			if p and not EM_PRIV.isSessionCompanion(session, p) then
				EM_PRIV.leavePendingByPlayerId[id] = pendingInfo
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

	EM_PRIV.leavePendingByPlayerId[playerId] = {
		startedAt = os.time(),
		switchTo = switchTo,
		sessionKey = sessionKey,
		initiatorName = leaverName,
		reason = opts.reason,
		goHometown = goHometown,
	}
	local event = addEvent(function(pid)
		local pending = EM_PRIV.leavePendingByPlayerId[pid]
		local to = pending and pending.switchTo or nil
		local name = pending and pending.initiatorName or nil
		local key = pending and pending.sessionKey or nil
		local pendingGoHometown = pending and pending.goHometown == true
		EM_PRIV.leavePendingByPlayerId[pid] = nil
		EM_PRIV.completeLeaveCountdown(key, pid, name, to, { goHometown = pendingGoHometown })
	end, sec * 1000, playerId)
	EM_PRIV.leavePendingByPlayerId[playerId].event = event
	ExpeditionProtocol.send(player, {
		type = "leavePending",
		countdownSec = sec,
		reason = opts.reason,
		expeditionName = opts.expeditionName,
	})
end

function EM_PRIV.clearPendingSwitch(session, opts)
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

function EM_PRIV.pendingSwitchAwaitingNames(pending)
	local names = {}
	for _, name in pairs((pending and pending.awaitingGuids) or {}) do
		names[#names + 1] = name
	end
	return names
end

function EM_PRIV.switchDestinationLevelMin(switchTo)
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
function EM_PRIV.underleveledForSwitch(players, levelMin)
	return ExpeditionManager.underleveled(players, levelMin)
end

--- Tear down the current hunt in place and join the next (no city return).
--- Validates host + pre-accepted teammates against the destination levelMin *before*
--- aborting the prior session so a failed transfer cannot strand anyone mid-instance.
--- opts.channeled: the switch channel already ran, so the join enters without a second one.
performDirectSwitch = function(host, session, switchTo, preAcceptedPlayers, opts)
	if not host or not switchTo then
		return
	end
	opts = opts or {}
	local lobbyId = opts.lobbyId or (session and session.lobbyId) or nil
	local hostId = host:getId()
	local others = {}
	for _, p in ipairs(preAcceptedPlayers or {}) do
		if p and p.getId and p:getId() ~= hostId then
			others[#others + 1] = p
		end
	end
	local levelMin = EM_PRIV.switchDestinationLevelMin(switchTo)
	local toCheck = { host }
	for _, p in ipairs(others) do
		toCheck[#toCheck + 1] = p
	end
	local blocked = EM_PRIV.underleveledForSwitch(toCheck, levelMin)
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
			EM_PRIV.clearPendingSwitch(session, {
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
	local staminaErr = EM_PRIV.partyStaminaError(toCheck)
	if staminaErr then
		if session then
			EM_PRIV.clearPendingSwitch(session, {
				reason = "stamina",
				expeditionName = switchTo.catalogName,
			})
		end
		local msg = string.format(
			"Expedition change cancelled: %s Continuing the current expedition.",
			staminaErr
		)
		host:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
		ExpeditionProtocol.sendError(host, staminaErr)
		for _, p in ipairs(others) do
			if p then
				p:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
				if not EM_PRIV.playerHasExpeditionStamina(p) then
					ExpeditionProtocol.sendError(p, "You need stamina to enter an expedition.")
				end
			end
		end
		logger.info("[Expedition] switch blocked by stamina host={} err={}", host:getName(), staminaErr)
		return
	end
	if session then
		EM_PRIV.clearPendingSwitch(session, { silent = true })
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
	EM_PRIV.clearActive(host)
	local joinOpts = {}
	for k, v in pairs(switchTo.options or {}) do
		joinOpts[k] = v
	end
	joinOpts.skipPzCheck = true
	joinOpts.skipEntryChannel = opts.channeled == true
	if lobbyId then
		joinOpts.scope = "lobby"
		joinOpts.lobbyId = lobbyId
	end
	if #others > 0 then
		joinOpts.preAcceptedPlayers = others
	end
	ExpeditionManager.join(host, switchTo.id, switchTo.role, switchTo.loadout, switchTo.lure, joinOpts)
	-- Anyone who did not land in the new expedition goes back to the lobby room.
	-- Old session is already gone at this point.
	local function exitIfNotInExpedition(p)
		if not p or ExpeditionManager.isInExpedition(p) then
			return
		end
		pcall(EM_PRIV.returnToLobby, p)
	end
	exitIfNotInExpedition(host)
	for _, p in ipairs(others) do
		exitIfNotInExpedition(p)
	end
end

function EM_PRIV.tryCompletePendingSwitch(session)
	if not session or not session.pendingSwitch then
		return
	end
	local pending = session.pendingSwitch
	if EM_PRIV.awaitingHumanCount({ awaitingHumanGuids = pending.awaitingGuids }) > 0 then
		return
	end
	local host = Player(pending.initiatorId)
	if not host then
		EM_PRIV.clearPendingSwitch(session, { reason = "host_offline" })
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
	local catalogName = pending.catalogName
	local hostId = host:getId()
	local sessionKey = session.key
	local memberIds = { hostId }
	for _, p in ipairs(accepted) do
		memberIds[#memberIds + 1] = p:getId()
	end
	logger.info(
		"[Expedition] {} switch accepted → {} (teammates={}) — arming IT",
		host:getName(),
		tostring(switchTo and switchTo.id or ""),
		#accepted
	)
	EM_PRIV.clearPendingSwitch(session, { silent = true })
	if not InstanceTeleport or not InstanceTeleport.requestExpedition then
		performDirectSwitch(host, session, switchTo, accepted)
		return
	end
	local ok, err = InstanceTeleport.requestExpedition({
		initiatorId = hostId,
		memberIds = memberIds,
		onComplete = function()
			local joiner = Player(hostId)
			local live = ExpeditionManager.getSessionByKey(sessionKey)
			if not joiner then
				return
			end
			performDirectSwitch(joiner, live, switchTo, accepted, { channeled = true })
		end,
		onCancel = function(ids)
			for _, id in ipairs(ids or memberIds) do
				local p = Player(id)
				if p then
					ExpeditionProtocol.send(p, {
						type = "switchCancelled",
						reason = "cancelled",
						expeditionName = catalogName,
					})
				end
			end
		end,
	})
	if not ok then
		ExpeditionProtocol.sendError(host, err or "Could not start expedition change.")
		for _, p in ipairs(accepted) do
			if p then
				ExpeditionProtocol.send(p, {
					type = "switchCancelled",
					reason = "cancelled",
					expeditionName = catalogName,
				})
			end
		end
	end
end

function EM_PRIV.armPendingSwitchTimeout(session)
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
		EM_PRIV.clearPendingSwitch(live, {
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
	if not EM_PRIV.meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		return
	end
	ExpeditionManager.cancelLeave(player)

	local humans = EM_PRIV.collectSessionHumans(session)
	local others = {}
	for _, member in ipairs(humans) do
		if member:getId() ~= player:getId() then
			others[#others + 1] = member
		end
	end
	local underleveled = EM_PRIV.underleveledForSwitch(others, levelMin)
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
		-- Same LEAVE_COUNTDOWN_SEC as Stop; after countdown hop in place (no city leave).
		logger.info(
			"[Expedition] {} solo switch → {} (countdown then direct join)",
			player:getName(),
			tostring(catalog.id)
		)
		ExpeditionManager.requestLeave(player, {
			switchTo = switchTo,
			reason = "switch",
			expeditionName = catalog.name,
		})
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
	EM_PRIV.armPendingSwitchTimeout(session)
	local deadline = session.pendingSwitch.deadline
	ExpeditionProtocol.send(player, {
		type = "switchWaiting",
		expeditionId = catalog.id,
		expeditionName = catalog.name,
		acceptDeadline = deadline,
		awaiting = EM_PRIV.pendingSwitchAwaitingNames(session.pendingSwitch),
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
	local levelMin = EM_PRIV.switchDestinationLevelMin(pending.switchTo)
	if not EM_PRIV.playerHasExpeditionStamina(player) then
		ExpeditionProtocol.sendError(player, "You need stamina to enter an expedition.")
		EM_PRIV.clearPendingSwitch(session, {
			reason = "stamina",
			expeditionName = pending.catalogName,
		})
		local host = Player(pending.initiatorId)
		local msg = string.format(
			"%s needs stamina for %s. Continuing the current expedition.",
			player:getName(),
			tostring(pending.catalogName or "the new expedition")
		)
		if host then
			host:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You cannot change to that expedition. Continuing the current one.")
		return
	end
	if not EM_PRIV.meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		EM_PRIV.clearPendingSwitch(session, {
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
			awaiting = EM_PRIV.pendingSwitchAwaitingNames(pending),
		})
	end
	EM_PRIV.tryCompletePendingSwitch(session)
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
	EM_PRIV.clearPendingSwitch(session, {
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
	-- Solo change uses leave countdown (no session.pendingSwitch).
	if ExpeditionManager.cancelLeave(player) then
		ExpeditionProtocol.send(player, { type = "leaveCancelled" })
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			"Expedition change cancelled. Continuing the current expedition."
		)
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
	EM_PRIV.clearPendingSwitch(session, {
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
		EM_PRIV.clearActive(player)
		ExpeditionManager.clearAreaEffects(player)
		if not opts.skipTeleport then
			EM_PRIV.teleportAfterLeave(player, nil, opts)
		end
		-- skipTeleport: caller is mid hunt→hunt switch (or death eject). Do not
		-- bind open-world here; join / exitIfNotInExpedition / death return owns it.
		ExpeditionProtocol.sendEnded(player)
		if not opts.skipTeamUndeploy and Alts and Alts.getDeployment and Alts.getDeployment(player) then
			Alts.undeploy(player)
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

	if session.role == "boss" and ExpeditionConfig.clearBossAttempt then
		ExpeditionConfig.clearBossAttempt(player)
	end

	-- Leaving mid switch-confirm cancels the change for everyone still hunting.
	if session.pendingSwitch and not opts.keepTeamDeployed then
		EM_PRIV.clearPendingSwitch(session, { reason = "left" })
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
		EM_PRIV.removeHuntMember(session, member, { skipEnded = true })
		EM_PRIV.clearActive(member)
		if opts.skipTeleport then
			return
		end
		local returnPos = EM_PRIV.loadReturn(member)
		if not returnPos then
			return
		end
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(member, true)
		end
		EM_PRIV.returnToLobby(member, returnPos)
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(member, false)
		end
	end

	-- Primary squaddie leaving: eject companions from this session first.
	-- Default: logout via undeploy. Switch: park them in town and keep deployment.
	if Alts and Alts.getDeployment and Alts.getDeployment(player) then
		local companionIds = {}
		for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
			local member = Player(id)
			if member and member:getId() ~= player:getId() and Alts.isCompanion(member) then
				companionIds[#companionIds + 1] = id
			end
		end
		if opts.keepTeamDeployed then
			for _, id in ipairs(companionIds) do
				parkCompanionForSwitch(Player(id))
			end
			session = ExpeditionManager.getSessionByPlayer(player)
			if not session then
				EM_PRIV.clearActive(player)
				ExpeditionManager.clearAreaEffects(player)
				if not opts.skipTeleport then
					local returnPos = EM_PRIV.loadReturn(player)
					if returnPos or opts.goHometown then
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, true)
						end
						EM_PRIV.teleportAfterLeave(player, returnPos, opts)
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
				EM_PRIV.clearActive(player)
				ExpeditionManager.clearAreaEffects(player)
				if not opts.skipTeleport then
					local returnPos = EM_PRIV.loadReturn(player)
					if returnPos or opts.goHometown then
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, true)
						end
						EM_PRIV.teleportAfterLeave(player, returnPos, opts)
						if InstanceWorld and InstanceWorld.suppressHuntLeave then
							InstanceWorld.suppressHuntLeave(player, false)
						end
					end
				end
				ExpeditionProtocol.sendEnded(player)
				if Alts and Alts.getDeployment and Alts.getDeployment(player) then
					Alts.undeploy(player)
				end
				return
			end
		end
	end

	local returnPos = EM_PRIV.loadReturn(player)
	local memberCount = #EM_PRIV.sessionMemberIds(session)
	local isLast = memberCount <= 1
	local wasVictory = opts.victory == true
	local shouldCleanup = isLast

	-- Detach before return travel so InstanceWorld rebinds to city/hub instead of
	-- treating the warp as an in-hunt relocate (which also schedules a delayed leave
	-- that can abort a follow-up switch join).
	EM_PRIV.removeHuntMember(session, player, { skipEnded = true })
	if not isLast then
		local remainingOnline = false
		for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
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
		EM_PRIV.teleportAfterLeave(player, returnPos, opts)
		if InstanceWorld and InstanceWorld.suppressHuntLeave then
			InstanceWorld.suppressHuntLeave(player, false)
		end
		-- Hometown recall already sent its instance-teleport arrival effect.
		if not opts.goHometown and player.getHealth and player:getHealth() > 0 then
			local now = player:getPosition()
			if now then
				now:sendMagicEffect(CONST_ME_TELEPORT)
			end
		end
	end

	-- Sweep after the last member leaves.
	if shouldCleanup then
		EM_PRIV.cleanupSession(session, player, opts)
	end

	ExpeditionProtocol.sendEnded(player)
	if not opts.skipTeamUndeploy and Alts and Alts.getDeployment and Alts.getDeployment(player) then
		Alts.undeploy(player)
	end
	if not opts.silent then
		if wasVictory then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Expedition complete.")
		elseif opts.goHometown then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You recalled to your hometown.")
		else
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You left the expedition.")
		end
	end
end

