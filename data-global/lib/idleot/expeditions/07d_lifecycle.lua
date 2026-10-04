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
	-- World boss uses arena knockout; never tear down the band fight on death.
	if session and session.kind == "worldboss" then
		if ActivityBoostWorldBoss and ActivityBoostWorldBoss.onPlayerDeath then
			ActivityBoostWorldBoss.onPlayerDeath(player)
		end
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
		if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
			for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
				local member = Player(id)
				if member and member:getId() ~= player:getId() and EM_PRIV.isSessionCompanion(session, member) then
					EM_PRIV.removeHuntMember(session, member, { skipEnded = true })
					EM_PRIV.clearActive(member)
					pcall(function()
						if TeamManager.safeLogoutCompanion then
							TeamManager.safeLogoutCompanion(member)
						elseif Game.headlessLogout then
							Game.headlessLogout(member)
						end
					end)
				end
			end
			pcall(function()
				TeamManager.undeploy(player)
			end)
		end
		EM_PRIV.clearActive(player)
		return true
	end

	if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
		for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
			local member = Player(id)
			if member and member:getId() ~= player:getId() and EM_PRIV.isSessionCompanion(session, member) then
				-- Tear companions out of the session and logout after primary disconnect.
				EM_PRIV.removeHuntMember(session, member, { skipEnded = true })
				EM_PRIV.clearActive(member)
				pcall(function()
					if TeamManager.safeLogoutCompanion then
						TeamManager.safeLogoutCompanion(member)
					elseif Game.headlessLogout then
						Game.headlessLogout(member)
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

	if session.kind == "worldboss" and ActivityBoostWorldBoss and ActivityBoostWorldBoss.leave then
		-- Clear openPvp / skulls / SoftDeath before disconnect (same as voluntary leave).
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
	if SampleSpells and SampleSpells.ensure then
		SampleSpells.ensure(player)
	end

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
			if RaidInstance and RaidInstance.sendActiveRaids then
				RaidInstance.sendActiveRaids(player)
			end
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
		if RaidInstance and RaidInstance.sendActiveRaids then
			RaidInstance.sendActiveRaids(player)
		end
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
		local kv = player.kv and player:kv() or nil
		local expeditionId = kv and kv.get and kv:get("expedition_id") or nil
		if ActivityBoostWorldBoss and ActivityBoostWorldBoss.clearArenaState then
			if type(expeditionId) == "string" and expeditionId:find("^worldboss:", 1, false) then
				ActivityBoostWorldBoss.clearArenaState(player)
			end
		end
		local returnPos = EM_PRIV.loadReturn(player)
		EM_PRIV.clearActive(player)
		ExpeditionManager.clearAreaEffects(player)
		player:setIdleCombat(false)
		EM_PRIV.teleportPlayerHome(player, returnPos)
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
	EM_PRIV.sessionsByKey = {}
	EM_PRIV.sessionsByPlayerId = {}
	EM_PRIV.leavePendingByPlayerId = {}
	EM_PRIV.huntChannelsByPlace = {}
	if ExpeditionInstance and ExpeditionInstance.resetSlots then
		ExpeditionInstance.resetSlots()
	end
	if ExpeditionPersist and ExpeditionPersist.loadAll then
		pcall(ExpeditionPersist.loadAll)
	end
	if ExpeditionPersist and ExpeditionPersist.restoreAllOnStartup then
		pcall(ExpeditionPersist.restoreAllOnStartup)
	end
	logger.info("[Expedition] manager ready ({} catalog entries)", #ExpeditionConfig.Catalog)
end

function ExpeditionManager.onServerSave()
	if ExpeditionPersist and ExpeditionPersist.saveAllLive then
		pcall(ExpeditionPersist.saveAllLive, EM_PRIV.sessionsByKey)
	end
end
