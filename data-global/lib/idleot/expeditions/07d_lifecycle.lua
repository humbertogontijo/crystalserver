-- Auto-split from 07_manager.lua (shared EM_PRIV). Do not redefine ExpeditionManager.
function ExpeditionManager.onDeath(player)
	if not player then
		return
	end
	local session = ExpeditionManager.resolveSession(player)
	if session and session.kind == "raid" and RaidInstance and RaidInstance.onPlayerDeath then
		RaidInstance.onPlayerDeath(player)
		return
	end
	-- World boss uses the InstancePvp knockout; never tear down the band fight on death.
	if session and session.kind == "worldboss" then
		return
	end
	ExpeditionManager.notifyHuntMemberDeath(player, nil)
end

local ENTRY_HOLD_LOGOUT_SEC = 90

--- An alt switch mid-channel leaves the old body headless on an open-world (safe) tile, where
--- headless players are removed as soon as they can log out. It still has to hop with the party.
local function holdHeadlessForEntry(player)
	if not (player.isHeadless and player:isHeadless()) then
		return false
	end
	if ExpeditionPersist and ExpeditionPersist.isServerShuttingDown() then
		return false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or session.entered or not session.starting or session.state == "ended" then
		return false
	end
	return os.time() - (session.startingAt or 0) < ENTRY_HOLD_LOGOUT_SEC
end

--- Death-screen Ok / forced logout: free the instance. Idle combat normally
--- blocks disconnect logout while hunting, so this path is death or force-remove.
function ExpeditionManager.onLogout(player)
	if not player then
		return true
	end
	if holdHeadlessForEntry(player) then
		return false
	end
	EM_PRIV.expeditionClientSynced[player:getId()] = nil
	ExpeditionManager.cancelLeave(player)
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		local guid = player:getGuid()
		for _, s in pairs(EM_PRIV.sessionsByKey) do
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
			EM_PRIV.clearActive(player)
		end
		return true
	end

	if ExpeditionPersist and ExpeditionPersist.isServerShuttingDown() then
		if session.kind == "worldboss" and ActivityBoostWorldBoss and ActivityBoostWorldBoss.leave then
			ActivityBoostWorldBoss.leave(player, { silent = true, force = true })
			return true
		end
		if ExpeditionPersist.isPersistableHunt(session) then
			pcall(ExpeditionPersist.writeSession, session)
			session.persistedForRestart = true
		end
		if Alts and Alts.getDeployment and Alts.getDeployment(player) then
			for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
				local member = Player(id)
				if member and member:getId() ~= player:getId() and EM_PRIV.isSessionCompanion(session, member) then
					EM_PRIV.removeHuntMember(session, member, { skipEnded = true })
					EM_PRIV.clearActive(member)
					pcall(function()
						if Alts.safeLogoutCompanion then
							Alts.safeLogoutCompanion(member)
						elseif Game.headlessLogout then
							Game.headlessLogout(member)
						end
					end)
				end
			end
			pcall(function()
				Alts.undeploy(player)
			end)
		end
		EM_PRIV.clearActive(player)
		return true
	end

	if Alts and Alts.getDeployment and Alts.getDeployment(player) then
		for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
			local member = Player(id)
			if member and member:getId() ~= player:getId() and EM_PRIV.isSessionCompanion(session, member) then
				-- Tear companions out of the session and logout after primary disconnect.
				EM_PRIV.removeHuntMember(session, member, { skipEnded = true })
				EM_PRIV.clearActive(member)
				pcall(function()
					if Alts.safeLogoutCompanion then
						Alts.safeLogoutCompanion(member)
					elseif Game.headlessLogout then
						Game.headlessLogout(member)
					end
				end)
			end
		end
		pcall(function()
			Alts.undeploy(player)
		end)
	end

	if session.kind == "raid" and RaidInstance and RaidInstance.leave then
		-- Leave the shared raid without tearing it down for other players.
		RaidInstance.leave(player, { silent = true })
		return true
	end

	if session.kind == "worldboss" and ActivityBoostWorldBoss and ActivityBoostWorldBoss.leave then
		-- Clear SoftDeath before disconnect (same as voluntary leave).
		ActivityBoostWorldBoss.leave(player, { silent = true })
		return true
	end

	if session.endedByDeath then
		EM_PRIV.clearActive(player)
		return true
	end

	-- Headless companions may logout after death (often with HP already restored).
	-- Skip hunt-death takeover while a voluntary abort/leaveAll is already ejecting.
	-- Healthy companion logout is voluntary undeploy/switch — not a hunt death.
	if EM_PRIV.isSessionCompanion(session, player) or (session.pendingHuntDeath and session.pendingHuntDeath.id == player:getId()) then
		if session.aborting or session._cleaned then
			EM_PRIV.removeHuntMember(session, player, { skipEnded = true })
			EM_PRIV.clearActive(player)
			return true
		end
		local hp = player.getHealth and player:getHealth() or 0
		local pendingDeath = session.pendingHuntDeath and session.pendingHuntDeath.id == player:getId()
		if EM_PRIV.isSessionCompanion(session, player) and hp > 0 and not pendingDeath and not session.endedByDeath then
			EM_PRIV.removeHuntMember(session, player, { skipEnded = true })
			EM_PRIV.clearActive(player)
			return true
		end
		ExpeditionManager.notifyHuntMemberDeath(player, nil)
		return true
	end

	local memberCount = #EM_PRIV.sessionMemberIds(session)
	if memberCount <= 1 then
		EM_PRIV.cleanupSession(session, player)
		EM_PRIV.clearActive(player)
	else
		EM_PRIV.removeHuntMember(session, player, { skipEnded = true })
		EM_PRIV.clearActive(player)
		ExpeditionManager.broadcastStatus(session)
		if #EM_PRIV.sessionMemberIds(session) == 0 then
			EM_PRIV.cleanupSession(session, nil)
		end
	end
	return true
end

function EM_PRIV.rebindMemberId(session, oldId, newId, player)
	if not session or not oldId or not newId then
		return
	end
	EM_PRIV.sessionsByPlayerId[oldId] = nil
	EM_PRIV.sessionsByPlayerId[newId] = session
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
	if session.deadPlayerIds and session.deadPlayerIds[oldId] then
		session.deadPlayerIds[newId] = true
		session.deadPlayerIds[oldId] = nil
	end
	if player and session.memberGuids then
		session.memberGuids[player:getGuid()] = newId
	end
end

local function isSessionMemberId(session, playerId)
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		if id == playerId then
			return true
		end
	end
	return false
end

local function promoteSessionHost(session, player)
	local playerId = player:getId()
	session.playerId = playerId
	session.guid = player:getGuid()
	EM_PRIV.sessionsByPlayerId[playerId] = session
	if session.memberAutomation and session.memberAutomation[playerId] then
		session.automation = session.memberAutomation[playerId]
	end
	if session.memberStance and session.memberStance[playerId] then
		session.stance = session.memberStance[playerId]
	end
end

--- Same-socket alt switch moved the UI from oldPlayer to newPlayer. Membership is unchanged:
--- the UI body leads the session and the body it left keeps going as a headless companion,
--- as if both had been in the party (and channel) from the start.
function ExpeditionManager.onClientSwitched(oldPlayer, newPlayer)
	if not oldPlayer or not newPlayer then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(newPlayer) or ExpeditionManager.getSessionByPlayer(oldPlayer)
	if not session or session.state == "ended" or not (session.starting or session.entered) then
		return
	end
	local oldId = oldPlayer:getId()
	local newId = newPlayer:getId()
	local oldInSession = isSessionMemberId(session, oldId)
	local newInSession = isSessionMemberId(session, newId)
	if not oldInSession and not newInSession then
		return
	end

	if oldInSession then
		session.companionIds = session.companionIds or {}
		session.companionIds[oldId] = true
		if Alts and Alts.onBecameHeadless then
			pcall(Alts.onBecameHeadless, oldPlayer)
		elseif oldPlayer.setHeadless then
			oldPlayer:setHeadless(true)
		end
	end

	local previousHostId = session.playerId
	if newInSession then
		if session.companionIds then
			session.companionIds[newId] = nil
		end
		local previousHost = previousHostId and Player(previousHostId) or nil
		if previousHostId ~= newId
			and (previousHostId == oldId or not previousHost or not EM_PRIV.hasUiClient(previousHost))
		then
			promoteSessionHost(session, newPlayer)
		end
	end

	if not session.entered then
		if newInSession then
			if InstanceTeleport and InstanceTeleport.adoptMember then
				local adopted = InstanceTeleport.adoptMember(oldPlayer, newPlayer)
				local previousHost = previousHostId and Player(previousHostId) or nil
				if not adopted and previousHost and previousHostId ~= oldId then
					InstanceTeleport.adoptMember(previousHost, newPlayer)
				end
			end
			-- syncSessionClientIfNeeded skips pending sessions; show "entering" on the new client.
			ExpeditionProtocol.sendStatus(newPlayer, session)
		end
	else
		EM_PRIV.syncHuntPersist(session)
	end

	logger.info(
		"[Expedition] client switched {} -> {} key={} host={} entered={}",
		oldPlayer:getName(),
		newPlayer:getName(),
		tostring(session.key),
		tostring(session.playerId),
		tostring(session.entered == true)
	)
end

function ExpeditionManager.onLogin(player)
	if not player then
		return
	end
	player:registerEvent("ExpeditionExtendedOpcode")
	player:registerEvent("ExpeditionPlayerLogout")
	-- CombatAutomationLogin also arms the loop; only ensure opcode + sample spells here
	-- so we do not double-send empty automationConfig and wipe a client upload race.
	if CombatAutomation and CombatAutomation.ensureLoop then
		pcall(function()
			if CombatAutomationStore and CombatAutomationStore.getConfig then
				CombatAutomationStore.getConfig(player)
			else
				CombatAutomation.ensureLoop(player)
			end
		end)
	end
	SampleSpells.ensure(player)

	ExpeditionConfig.refundBossAttemptIfMarked(player)
	if ExpeditionManager.attachPlayerToRunningHunt(player) then
		return
	end

	local session = nil
	local oldMemberId = nil
	local guid = player:getGuid()
	for _, s in pairs(EM_PRIV.sessionsByKey) do
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
			EM_PRIV.rebindMemberId(session, oldId, player:getId(), player)
		end
		EM_PRIV.ejectPlayerFromExpedition(player, {})
		return
	end

	if session and session.state == "ended" then
		EM_PRIV.ejectPlayerFromExpedition(player, {})
		if EM_PRIV.sessionsByKey[session.key] == session then
			EM_PRIV.cleanupSession(session, player)
		end
		return
	end

	if session then
		-- Re-bind player id after reconnect (idle combat kept the session alive).
		local oldId = oldMemberId or session.playerId
		EM_PRIV.rebindMemberId(session, oldId, player:getId(), player)
		if session.kind == "raid" and type(session.playerIds) == "table" then
			local active = RaidInstance and RaidInstance.getActive and RaidInstance.getActive(session.raidName)
			if active and active.memberKeys and active.memberKeys[oldId] then
				active.memberKeys[player:getId()] = active.memberKeys[oldId]
				active.memberKeys[oldId] = nil
			end
		end
		-- Spatial membership: once entered, being outside the instance ends the run.
		-- Occupancy alone is not enough — bind private instance id when on hunt tiles.
		if ExpeditionInstance.contains(session.instance, player:getPosition()) then
			if not EM_PRIV.teleportPlayerIntoRunningHunt(player, session) then
				logger.warn(
					"[Expedition] login rebind failed to enter instance for {} on {}",
					player:getName(),
					tostring(session.key)
				)
			end
			session.entered = true
		elseif session.entered and not ExpeditionManager.reconcilePresence(player) then
			ExpeditionProtocol.sendCatalog(player)
			RaidInstance.sendActiveRaids(player)
			return
		end
		local pid = player:getId()
		if not session.memberAutomation or type(session.memberAutomation[pid]) ~= "table" then
			session.memberAutomation = session.memberAutomation or {}
			session.memberAutomation[pid] = EM_PRIV.loadPersistedAutomation(player)
		end
		if session.playerId == pid then
			session.automation = session.memberAutomation[pid]
		end
		session.memberStance = session.memberStance or {}
		do
			local stance, rangedDist = EM_PRIV.memberStanceFromConfig(player)
			session.memberStance[pid] = stance
			session.memberRangedDistance = session.memberRangedDistance or {}
			session.memberRangedDistance[pid] = rangedDist
		end
		player:registerEvent("ExpeditionPlayerDeath")
		ExpeditionAI.enablePersistence(player)
		if session.entered then
			ExpeditionAI.start(session)
		end
		ExpeditionProtocol.sendCatalog(player)
		RaidInstance.sendActiveRaids(player)
		ExpeditionProtocol.sendStatus(player, session)
		local playerId = player:getId()
		local sessionKey = session.key
		addEvent(function()
			local p = Player(playerId)
			if p and ExpeditionManager.getSessionByKey(sessionKey) and CombatAutomation and CombatAutomation.resyncAttackTarget then
				CombatAutomation.resyncAttackTarget(p)
			end
		end, 1500)
		return
	end

	-- Rescue after restart / deferred teardown: stranded on a dead instance.
	ExpeditionConfig.refundBossAttemptIfMarked(player)
	if InstanceWorld and InstanceWorld.rescueIfStranded then
		InstanceWorld.rescueIfStranded(player)
	elseif player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
		local returnPos = EM_PRIV.loadReturn(player)
		EM_PRIV.clearActive(player)
		ExpeditionManager.clearAreaEffects(player)
		player:setIdleCombat(false)
		EM_PRIV.returnToLobby(player, returnPos)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Your expedition was interrupted. You were returned to safety.")
	end

	ExpeditionProtocol.sendCatalog(player)
	RaidInstance.sendActiveRaids(player)
	-- Sticky Rotten Blood / hazard icons can survive instance teleports; clear when
	-- there is no live hunt to re-apply them.
	ExpeditionManager.clearAreaEffects(player)
	-- Always clear client sticky status when there is no live session (e.g. after
	-- server restart mid-raid while the browser kept the old status in memory).
	ExpeditionProtocol.sendEnded(player)
end

function ExpeditionManager.onStartup()
	EM_PRIV.sessionsByKey = {}
	EM_PRIV.sessionsByPlayerId = {}
	EM_PRIV.leavePendingByPlayerId = {}
	EM_PRIV.huntChannelsByPlace = {}
	ExpeditionInstance.resetSlots()
	pcall(ExpeditionPersist.loadAll)
	pcall(ExpeditionPersist.restoreAllOnStartup)
	logger.info("[Expedition] manager ready ({} catalog entries)", #ExpeditionConfig.Catalog)
end

function ExpeditionManager.onServerSave()
	pcall(ExpeditionPersist.saveAllLive, EM_PRIV.sessionsByKey)
end
