-- Auto-split from 07_manager.lua (shared EM_PRIV). Do not redefine ExpeditionManager.
function ExpeditionManager.join(player, expeditionId, _role, loadout, lure, options)
	if not player then
		return
	end
	options = options or {}
	if not EM_PRIV.playerHasExpeditionStamina(player) then
		ExpeditionProtocol.sendError(player, "You need stamina to enter an expedition.")
		return
	end
	-- Switch leave→join already returned from an active expedition; do not re-check
	-- combat lock mid-hop. Open-world join: combat lock only (non-PZ uses longer IT).
	if not options.skipPzCheck then
		local allowed, combatErr = EM_PRIV.expeditionTeleportCombatOk(player)
		if not allowed then
			ExpeditionProtocol.sendError(player, combatErr or "You cannot teleport while PZ-locked.")
			return
		end
	end
	local function recoverStaleSession(session)
		if not session then
			return
		end
		EM_PRIV.clearActive(player)
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
		-- Switch hop can still see a sticky session for one tick; clear in place (no city).
		if options.skipPzCheck then
			ExpeditionManager.leave(player, {
				silent = true,
				keepTeamDeployed = true,
				skipTeamUndeploy = true,
				skipTeleport = true,
			})
			EM_PRIV.clearActive(player)
		end
		if ExpeditionManager.isInExpedition(player) then
			ExpeditionProtocol.sendError(player, "Already on an expedition.")
			return
		end
	end
	-- Companion-death races can leave STORAGE_ACTIVE set without a live session.
	if player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
		EM_PRIV.clearActive(player)
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
	if catalog.exclusiveArena and QuestArena and QuestArena.canJoin then
		local can, arenaErr = QuestArena.canJoin(player, catalog)
		if not can then
			ExpeditionProtocol.sendError(player, arenaErr or "This arena challenge is locked.")
			return
		end
	end
	local kind = "hunt"
	local contentRole = catalog.role
	if contentRole ~= "boss" and contentRole ~= "monster" and contentRole ~= "arena" then
		contentRole = catalog.kind == "boss" and "boss" or "monster"
	end
	if contentRole == "arena" then
		kind = "arena"
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

	-- Today's Fiendish Hunt offer: forced Fiendish of the offered race; killing it ends the hunt.
	if contentRole == "monster" and ActivityBoostFiendishHunt and ActivityBoostFiendishHunt.get then
		local offer = ActivityBoostFiendishHunt.get(player)
		if offer and not offer.complete and tostring(offer.expeditionId) == tostring(catalog.id) then
			options = options or {}
			options.skipOpenWorldForge = true
			options.forceFiendishCreatureId = tonumber(offer.creatureId) or options.forceFiendishCreatureId
		end
	end

	local levelMin = catalog.levelMin or 1
	if not EM_PRIV.meetsExpeditionLevel(player, levelMin) then
		ExpeditionProtocol.sendError(
			player,
			string.format("Level too low for this expedition (need %d, you are %d).", levelMin, player:getLevel())
		)
		return
	end

	-- Gate host + party / accepted listing teammates before allocating an instance.
	do
		local soloOrSwitch = (contentRole == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(catalog))
			or contentRole == "arena"
			or options.skipPzCheck == true
		local staminaErr = EM_PRIV.partyStaminaError(EM_PRIV.collectStaminaGatePlayers(player, {
			skipPartyGate = soloOrSwitch,
			preAcceptedPlayers = options.preAcceptedPlayers,
		}))
		if staminaErr then
			ExpeditionProtocol.sendError(player, staminaErr)
			return
		end
	end

	local sessionLure = nil
	local sessionLureMax = nil
	if contentRole ~= "boss" and contentRole ~= "arena" then
		sessionLureMax = tonumber(catalog.lureMax) or ExpeditionConfig.LURE_MAX
		-- Ignore client lure; the cave route carries the hunt's pack size.
		local route = ExpeditionConfig.caveRoute(catalog)
		sessionLure = route and route.lure or ExpeditionConfig.lureFromDensity(sessionLureMax)
	end
	local sessionBossDifficulty = nil
	if contentRole == "boss" and ExpeditionDifficulty then
		sessionBossDifficulty = ExpeditionDifficulty.normalizeBossDifficulty(options.bossDifficulty, catalog)
		local gatePlayers = { player }
		for _, teammate in ipairs(EM_PRIV.collectExpectedHumanTeammates(player) or {}) do
			gatePlayers[#gatePlayers + 1] = teammate
		end
		local okDiff, diffErr =
			ExpeditionDifficulty.canAttemptBossDifficulty(gatePlayers, catalog, sessionBossDifficulty, player)
		if not okDiff then
			ExpeditionProtocol.sendError(player, diffErr or "Boss difficulty too high for party.")
			return
		end
	end
	local stopOpts = ExpeditionConfig.normalizeStopOptions(options)
	if options.stopOnInsufficientGold ~= nil or options.stopOnInsufficientCap ~= nil then
		stopOpts = ExpeditionConfig.normalizeStopOptions({
			stopOnInsufficientGold = options.stopOnInsufficientGold,
			stopOnInsufficientCap = options.stopOnInsufficientCap,
		})
	end

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
	local soloBoss = (contentRole == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(catalog))
		or contentRole == "arena"

	-- Host only until teammates accept; companions join at synchronized entry.
	local members, partyErr = EM_PRIV.collectHuntJoinParty(player, levelMin, nil, {
		ignoreParty = true,
		skipPzCheck = options.skipPzCheck == true,
	})
	if not members then
		ExpeditionInstance.teardown(instance)
		ExpeditionProtocol.sendError(player, partyErr or "Unable to gather party for expedition.")
		return
	end

	local expectedTeammates = (soloBoss or options.skipPzCheck) and {} or EM_PRIV.collectExpectedHumanTeammates(player)
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
	local key = EM_PRIV.playerKey(player)
	local channel = EM_PRIV.allocateHuntChannel(catalog.id, key)

	for _, member in ipairs(members) do
		local memberId = member:getId()
		playerIds[#playerIds + 1] = memberId
		memberGuids[member:getGuid()] = memberId
		local stance, rangedDist = EM_PRIV.memberStanceFromConfig(member)
		memberStance[memberId] = stance
		memberRangedDistance[memberId] = rangedDist
		local isHost = memberId == hostId
		local automation = EM_PRIV.prepareMemberAutomation(member, loadout, isHost)
		memberAutomation[memberId] = automation
		if isHost then
			hostAutomation = automation
		end
		EM_PRIV.saveReturn(member)
		EM_PRIV.markActive(member, catalog.id, channel)
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
			if EM_PRIV.meetsExpeditionLevel(teammate, levelMin) then
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
			elseif EM_PRIV.hasUiClient(teammate) and EM_PRIV.meetsExpeditionLevel(teammate, levelMin) then
				local allowed = true
				-- Switch hops skip combat check: teammates are still on the prior hunt footprint.
				if not options.skipPzCheck then
					allowed = EM_PRIV.expeditionTeleportCombatOk(teammate) == true
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
		guid = hostGuid,
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
		alive = 0,
		kills = 0,
		lure = sessionLure,
		lureMax = sessionLureMax,
		bossDifficulty = sessionBossDifficulty,
		skipOpenWorldForge = options.skipOpenWorldForge == true,
		forceFiendishCreatureId = tonumber(options.forceFiendishCreatureId),
		state = (EM_PRIV.awaitingHumanCount({ awaitingHumanGuids = awaitingHumanGuids }) > 0 or #readyTeammates > 0)
				and "pending"
			or "idle",
		startedAt = os.time(),
		holdPos = nil,
		automation = hostAutomation or { slots = {} },
		memberAutomation = memberAutomation,
		stopOnInsufficientGold = stopOpts.stopOnInsufficientGold,
		stopOnInsufficientCap = stopOpts.stopOnInsufficientCap,
		awaitingHumanGuids = awaitingHumanGuids,
		pendingStart = {
			loadout = loadout,
			hostWorldPos = hostWorldPos,
			soloBoss = soloBoss,
			skipEntryChannel = options.skipEntryChannel == true,
		},
	}
	EM_PRIV.sessionsByKey[key] = session
	for _, mid in ipairs(playerIds) do
		EM_PRIV.sessionsByPlayerId[mid] = session
	end
	ExpeditionConfig.pickAnchor(session)

	if instance and instance.entry then
		session.holdPos = Position(instance.entry.x, instance.entry.y, instance.entry.z)
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

	if EM_PRIV.awaitingHumanCount(session) > 0 then
		EM_PRIV.armAcceptTimeout(session)
		ExpeditionManager.broadcastStatus(session)
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"Waiting for %d teammate(s) to accept before starting %s.",
				EM_PRIV.awaitingHumanCount(session),
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
			EM_PRIV.awaitingHumanCount(session),
			#readyTeammates,
			math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
		)
		return
	end

	ExpeditionManager.startExpeditionEntry(session)
end

--- Rebuild a monster-hunt instance/session from a persist snapshot (no players yet).
function EM_PRIV.bootstrapRestoredHunt(snapshot)
	if not snapshot or not snapshot.catalogId or not snapshot.sessionKey then
		return false
	end
	if ExpeditionManager.getSessionByKey(snapshot.sessionKey) then
		return false
	end
	local catalog = ExpeditionConfig.getById(snapshot.catalogId, snapshot.catalogRole or "monster")
	if not catalog then
		if ExpeditionPersist and ExpeditionPersist.clearSnapshot then
			ExpeditionPersist.clearSnapshot(snapshot)
		end
		return false
	end
	local contentRole = catalog.role
	if contentRole ~= "boss" and contentRole ~= "monster" and contentRole ~= "arena" then
		contentRole = catalog.kind == "boss" and "boss" or "monster"
	end
	if contentRole ~= "monster" then
		return false
	end

	local hostGuid = math.floor(tonumber(snapshot.hostGuid) or 0)
	local instanceId = ExpeditionInstance.allocate()
	if instanceId == nil then
		return false
	end
	local instance, err = ExpeditionInstance.build(instanceId, catalog, hostGuid + os.time())
	if not instance then
		ExpeditionInstance.free(instanceId)
		logger.warn(
			"[ExpeditionPersist] bootstrap failed for {}: {}",
			tostring(snapshot.sessionKey),
			tostring(err)
		)
		return false
	end

	local sessionKey = snapshot.sessionKey
	local channel = EM_PRIV.allocateHuntChannel(catalog.id, sessionKey)
	local restoredRoute = ExpeditionConfig.caveRoute(catalog)
	local sessionLure = math.max(
		1,
		math.floor(
			(restoredRoute and restoredRoute.lure)
				or tonumber(snapshot.lure)
				or ExpeditionConfig.lureFromDensity(snapshot.lureMax)
				or 1
		)
	)
	local session = {
		key = sessionKey,
		playerId = nil,
		playerIds = {},
		companionIds = {},
		guid = hostGuid,
		memberGuids = {},
		catalog = catalog,
		kind = "hunt",
		role = contentRole,
		channel = channel,
		instance = instance,
		alive = 0,
		kills = 0,
		lure = sessionLure,
		lureMax = snapshot.lureMax,
		skipOpenWorldForge = snapshot.skipOpenWorldForge == true,
		forceFiendishCreatureId = tonumber(snapshot.forceFiendishCreatureId),
		state = "idle",
		startedAt = os.time(),
		holdPos = nil,
		automation = { slots = {} },
		memberAutomation = {},
		memberStance = {},
		memberRangedDistance = {},
		stopOnInsufficientGold = snapshot.stopOnInsufficientGold == true,
		stopOnInsufficientCap = snapshot.stopOnInsufficientCap == true,
		awaitingHumanGuids = nil,
	}
	EM_PRIV.sessionsByKey[sessionKey] = session
	if instance.entry then
		session.holdPos = Position(instance.entry.x, instance.entry.y, instance.entry.z)
	end
	logger.info(
		"[ExpeditionPersist] restored hunt {} catalog={} instance={} channel={}",
		sessionKey,
		tostring(catalog.id),
		instance.instanceId,
		tostring(channel)
	)
	return true
end

function EM_PRIV.teleportPlayerIntoRunningHunt(player, session)
	if not player or not session or not session.instance or not session.instance.entry then
		return false
	end
	local instanceId = session.instance.instanceId
	-- Headless restore logs players onto hunt tiles at instance 0. Occupancy
	-- contains() is true there, but they are not bound to the private hunt id —
	-- skipping enterInstance leaves them stranded while monsters spawn privately.
	local onTiles = ExpeditionInstance.contains(session.instance, player:getPosition())
	local bound = not instanceId
		or not player.getInstanceId
		or player:getInstanceId() == instanceId
	if onTiles and bound then
		return true
	end
	player:setFollowCreature(nil)
	if not (InstanceWorld and InstanceWorld.enterInstance) then
		logger.error("[Expedition] InstanceWorld.enterInstance missing — cannot enter hunt")
		return false
	end
	local entered = InstanceWorld.enterInstance(
		player,
		instanceId,
		session.instance.entry,
		"hunt:" .. tostring(session.key or "")
	)
	if not entered then
		return false
	end
	if ExpeditionInstance.sendMagicEffect then
		ExpeditionInstance.sendMagicEffect(session.instance, player:getPosition(), CONST_ME_TELEPORT)
	else
		player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	end
	return true
end

--- Push expedition HUD/catalog once a real client attaches to a headless session member.
function ExpeditionManager.syncSessionClientIfNeeded(player)
	if not player or not player.getProtocolVersion or player:getProtocolVersion() == 0 then
		return false
	end
	local pid = player:getId()
	if EM_PRIV.expeditionClientSynced[pid] then
		return false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or session.state == "ended" or not session.entered then
		return false
	end
	EM_PRIV.expeditionClientSynced[pid] = true
	player:registerEvent("ExpeditionPlayerDeath")
	ExpeditionAI.enablePersistence(player)
	if ExpeditionAI and ExpeditionAI.start then
		pcall(ExpeditionAI.start, session)
	end
	ExpeditionProtocol.sendCatalog(player)
	if RaidInstance and RaidInstance.sendActiveRaids then
		RaidInstance.sendActiveRaids(player)
	end
	ExpeditionProtocol.sendStatus(player, session)
	local sessionKey = session.key
	addEvent(function()
		local p = Player(pid)
		if p and ExpeditionManager.getSessionByKey(sessionKey) and CombatAutomation and CombatAutomation.resyncAttackTarget then
			pcall(CombatAutomation.resyncAttackTarget, p)
		end
	end, ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500)
	return true
end

function EM_PRIV.syncRunningHuntClients(session)
	if not session or not session.entered then
		return
	end
	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local member = Player(mid)
		if member then
			if member.getProtocolVersion and member:getProtocolVersion() > 0 then
				ExpeditionManager.syncSessionClientIfNeeded(member)
			else
				ExpeditionProtocol.sendStatus(member, session)
			end
		end
	end
end

--- Deploy headless host + companions and resume the hunt right after a restart.
function EM_PRIV.startRestoredHuntOnStartup(session, snapshot)
	if not session or not snapshot or session.entered or session.starting or session.state == "ended" then
		return false
	end
	local hostGuid = math.floor(tonumber(snapshot.hostGuid) or session.guid or 0)
	if hostGuid <= 0 then
		return false
	end
	local offlineHost = TeamStore and TeamStore.resolvePlayerByGuid and TeamStore.resolvePlayerByGuid(hostGuid)
	if not offlineHost then
		logger.warn(
			"[ExpeditionPersist] startup start failed for {}: host guid {} unavailable",
			tostring(session.key),
			tostring(hostGuid)
		)
		return false
	end

	session.guid = hostGuid
	session.starting = true

	for _, rawGuid in ipairs(snapshot.humanGuids or {}) do
		local guid = math.floor(tonumber(rawGuid) or 0)
		if guid > 0 then
			session.memberGuids = session.memberGuids or {}
			if not session.memberGuids[guid] or session.memberGuids[guid] == 0 then
				session.memberGuids[guid] = 0
			end
		end
	end

	local instance = session.instance
	local catalog = session.catalog
	local spawnPos = instance and instance.entry
	local instanceId = instance and math.floor(tonumber(instance.instanceId) or 0) or 0
	if not spawnPos then
		session.starting = nil
		return false
	end

	local hostName = offlineHost:getName()
	local sessionKey = session.key

	local function finishRestoredHunt(headlessHost, companions)
		local live = ExpeditionManager.getSessionByKey(sessionKey)
		if not live or live.state == "ended" or not headlessHost then
			if live then
				live.starting = nil
			end
			return
		end

		EM_PRIV.registerSessionMember(live, headlessHost, headlessHost, {})
		live.playerId = headlessHost:getId()
		live.memberGuids = live.memberGuids or {}
		live.memberGuids[hostGuid] = headlessHost:getId()
		-- Account quick-loot is applied in Game.headlessLogin → ensureAccountQuickLootFilter;
		-- log restores so we can confirm headless loot filter without OTC.
		logger.debug(
			"[ExpeditionPersist] restored host {} guid={} headless={} protocol={} (account quickloot applied on headlessLogin)",
			headlessHost:getName(),
			tostring(headlessHost:getGuid()),
			tostring(headlessHost.isHeadless and headlessHost:isHeadless() or false),
			tostring(headlessHost.getProtocolVersion and headlessHost:getProtocolVersion() or -1)
		)
		EM_PRIV.teleportPlayerIntoRunningHunt(headlessHost, live)

		companions = companions or {}
		local companionById = {}
		for _, companion in ipairs(companions) do
			if companion and companion.getId then
				companionById[companion:getId()] = true
			end
		end
		for _, companion in ipairs(companions) do
			local already = false
			for _, mid in ipairs(live.playerIds or {}) do
				if companion and companion.getId and mid == companion:getId() then
					already = true
					break
				end
			end
			if not already then
				EM_PRIV.registerSessionMember(live, companion, offlineHost, {
					hostWorldPos = spawnPos,
					companionById = companionById,
				})
			end
			EM_PRIV.teleportPlayerIntoRunningHunt(companion, live)
		end

		live.entered = true
		live.starting = nil
		live.state = "idle"
		live.awaitingHumanGuids = nil
		ExpeditionConfig.pickAnchor(live)
		if ExpeditionPersist and ExpeditionPersist.writeSession and ExpeditionPersist.isPersistableHunt(live) then
			pcall(ExpeditionPersist.writeSession, live)
		end

		local contentRole = live.role
		local syncMs = ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500
		addEvent(function()
			local s = ExpeditionManager.getSessionByKey(sessionKey)
			if not s or s.state == "ended" then
				return
			end
			if not ExpeditionInstance.hasGround(instance.entry) then
				addEvent(function()
					local retry = ExpeditionManager.getSessionByKey(sessionKey)
					if retry and retry.state ~= "ended" then
						EM_PRIV.beginExpeditionHunt(retry, contentRole)
						EM_PRIV.syncRunningHuntClients(retry)
						logger.info(
							"[ExpeditionPersist] started restored hunt {} catalog={} instance={} members={} lure={} anchor={}",
							tostring(sessionKey),
							tostring(catalog and catalog.id),
							tostring(instance.instanceId),
							#ExpeditionManager.sessionMemberIds(retry),
							tostring(retry.lure or "-"),
							tostring(retry.anchorPlayerId or "-")
						)
					end
				end, 100)
				return
			end
			EM_PRIV.beginExpeditionHunt(s, contentRole)
			EM_PRIV.syncRunningHuntClients(s)
			logger.info(
				"[ExpeditionPersist] started restored hunt {} catalog={} instance={} members={} lure={} anchor={}",
				tostring(sessionKey),
				tostring(catalog and catalog.id),
				tostring(instance.instanceId),
				#ExpeditionManager.sessionMemberIds(s),
				tostring(s.lure or "-"),
				tostring(s.anchorPlayerId or "-")
			)
		end, syncMs)
	end

	local function deployCompanionsThenFinish(headlessHost)
		if not TeamManager or not TeamManager.deploy then
			finishRestoredHunt(headlessHost, {})
			return
		end
		TeamManager.deploy(headlessHost, {
			position = spawnPos,
			instanceId = instanceId,
			companionsOnly = true,
			inviteFriends = false,
			onComplete = function(depCompanions, depErr)
				if not depCompanions then
					logger.warn(
						"[ExpeditionPersist] companion deploy failed for {}: {}",
						tostring(sessionKey),
						tostring(depErr or "unknown")
					)
					finishRestoredHunt(headlessHost, {})
					return
				end
				finishRestoredHunt(headlessHost, depCompanions)
			end,
		})
	end

	local function onHostReady(headlessHost)
		if not headlessHost then
			logger.warn(
				"[ExpeditionPersist] startup start failed for {}: could not login headless host",
				tostring(sessionKey)
			)
			session.starting = nil
			return
		end
		deployCompanionsThenFinish(headlessHost)
	end

	-- Async host login so server boot does not stall the dispatcher.
	if not Game.headlessLoginBatch then
		logger.warn(
			"[ExpeditionPersist] startup start failed for {}: headlessLoginBatch unavailable",
			tostring(sessionKey)
		)
		session.starting = nil
		return false
	end
	Game.headlessLoginBatch({ hostName }, spawnPos, function(players, err)
		local host = players and players[1] or nil
		if not host and hostGuid > 0 then
			Game.headlessLoginBatch({ hostGuid }, spawnPos, function(players2, err2)
				onHostReady(players2 and players2[1] or nil)
				if not (players2 and players2[1]) then
					logger.warn(
						"[ExpeditionPersist] async host login failed for {}: {}",
						tostring(sessionKey),
						tostring(err2 or err or "unknown")
					)
				end
			end, instanceId)
			return
		end
		if not host then
			logger.warn(
				"[ExpeditionPersist] async host login failed for {}: {}",
				tostring(sessionKey),
				tostring(err or "unknown")
			)
		end
		onHostReady(host)
	end, instanceId)
	return true
end

--- Bootstrap + start a persisted hunt on server boot.
function ExpeditionManager.restoreHuntOnStartup(snapshot)
	if not snapshot or not snapshot.sessionKey then
		return false
	end
	local session = ExpeditionManager.getSessionByKey(snapshot.sessionKey)
	if not session then
		if not EM_PRIV.bootstrapRestoredHunt(snapshot) then
			return false
		end
		session = ExpeditionManager.getSessionByKey(snapshot.sessionKey)
	end
	if not session or session.entered or session.state == "ended" then
		return session ~= nil and session.entered == true
	end
	return EM_PRIV.startRestoredHuntOnStartup(session, snapshot)
end

function EM_PRIV.findRunningHuntForPlayer(player)
	if not player then
		return nil
	end
	local snapshot = ExpeditionPersist and ExpeditionPersist.getPendingSnapshot(player)
	local session = snapshot and snapshot.sessionKey and ExpeditionManager.getSessionByKey(snapshot.sessionKey)
	if session and session.state ~= "ended" and session.entered then
		return session
	end
	local guid = player:getGuid()
	for _, s in pairs(EM_PRIV.sessionsByKey) do
		if s.state ~= "ended" and s.entered and (s.guid == guid or (s.memberGuids and s.memberGuids[guid])) then
			return s
		end
	end
	return nil
end

--- Teleport a late-login human into a hunt already running since server boot.
function ExpeditionManager.attachPlayerToRunningHunt(player)
	if not player then
		return false
	end
	local session = EM_PRIV.findRunningHuntForPlayer(player)
	if not session or session.state == "ended" or not session.entered then
		return false
	end

	local hostGuid = math.floor(tonumber(session.guid) or 0)
	local playerGuid = player:getGuid()
	local existing = ExpeditionManager.getSessionByPlayer(player)
	if existing and existing.key ~= session.key then
		return false
	end

	-- Host already online headless — real client takes over that player.
	-- Still require the private instance id (restore can leave them on tiles at id 0).
	if playerGuid == hostGuid and session.playerId and session.playerId == player:getId() then
		if not EM_PRIV.teleportPlayerIntoRunningHunt(player, session) then
			ExpeditionProtocol.sendError(player, "Failed to rejoin expedition (teleport blocked).")
			return false
		end
		ExpeditionManager.syncSessionClientIfNeeded(player)
		return true
	end

	if playerGuid == hostGuid then
		if not session.playerId or session.playerId ~= player:getId() then
			EM_PRIV.registerSessionMember(session, player, player, {})
			session.playerId = player:getId()
			session.automation = session.memberAutomation[player:getId()] or session.automation
		end
		session.memberGuids = session.memberGuids or {}
		session.memberGuids[playerGuid] = player:getId()
	else
		local host = session.playerId and Player(session.playerId) or nil
		if not host and hostGuid > 0 and TeamStore and TeamStore.findOnlinePlayerByGuid then
			host = TeamStore.findOnlinePlayerByGuid(hostGuid)
		end
		if ExpeditionManager.getSessionByPlayer(player) then
			-- already registered
		else
			ExpeditionManager.attachFriendToSession(player, session, host, { skipMaybeStart = true })
		end
	end

	if not EM_PRIV.teleportPlayerIntoRunningHunt(player, session) then
		ExpeditionProtocol.sendError(player, "Failed to rejoin expedition (teleport blocked).")
		return false
	end

	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		"Rejoined your running expedition: " .. (session.catalog and session.catalog.name or "hunt")
	)
	ExpeditionProtocol.sendStatus(player, session)
	ExpeditionManager.broadcastStatus(session)
	EM_PRIV.syncHuntPersist(session)
	logger.info(
		"[ExpeditionPersist] {} rejoined running hunt {} (members={})",
		player:getName(),
		tostring(session.key),
		#ExpeditionManager.sessionMemberIds(session)
	)
	return true
end

function ExpeditionManager.startExpeditionEntry(session)
	if not session or session.entered or session.starting then
		return
	end
	session.starting = true
	session.startingAt = os.time()
	local host = Player(session.playerId)
	if not host then
		ExpeditionManager.teardownSession(session)
		return
	end

	local pending = session.pendingStart or {}
	local loadout = pending.loadout
	local hostWorldPos = pending.hostWorldPos or host:getPosition()
	local soloBoss = pending.soloBoss == true
	local skipEntryChannel = pending.skipEntryChannel == true
	local catalog = session.catalog
	local contentRole = session.role
	local instance = session.instance
	local key = session.key
	local sessionLure = session.lure

	-- Clear waiting UI on clients before companion deploy / entry teleports.
	EM_PRIV.clearAcceptTimeout(session)
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
		s.persistedForRestart = nil
		ExpeditionConfig.pickAnchor(s)
		if ExpeditionPersist and ExpeditionPersist.writeSession and ExpeditionPersist.isPersistableHunt(s) then
			pcall(ExpeditionPersist.writeSession, s)
		end
		local sessionKey = s.key
		local role = contentRole
		local syncMs = ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500
		addEvent(function()
			local live = ExpeditionManager.getSessionByKey(sessionKey)
			if not live or live.state == "ended" then
				return
			end
			EM_PRIV.beginExpeditionHunt(live, role)
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
					if not (InstanceWorld and InstanceWorld.enterInstance) then
						logger.error("[Expedition] InstanceWorld.enterInstance missing — cannot enter hunt")
					else
						ok = InstanceWorld.enterInstance(p, instance.instanceId, instance.entry, "hunt:" .. tostring(s.key or catalog.id))
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
						InstanceTeleport.sendArrivalEffect(p, InstanceTeleport.KIND_EXPEDITION)
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

	local function registerDeployedCompanions(s, host, depCompanions, regOpts)
		if not depCompanions then
			return
		end
		local companionById = {}
		for _, companion in ipairs(depCompanions) do
			if companion and companion.getId then
				companionById[companion:getId()] = true
			end
		end
		regOpts = regOpts or {}
		regOpts.companionById = companionById
		for _, companion in ipairs(depCompanions) do
			local already = false
			for _, mid in ipairs(s.playerIds or {}) do
				if companion and companion.getId and mid == companion:getId() then
					already = true
					break
				end
			end
			if not already then
				EM_PRIV.registerSessionMember(s, companion, host, regOpts)
			end
		end
	end

	local function enterAfterPrep(s, liveHost)
		local members = {}
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
			local p = Player(mid)
			if p then
				members[#members + 1] = p
			end
		end
		local staminaErr = EM_PRIV.partyStaminaError(members)
		if staminaErr then
			ExpeditionProtocol.sendError(liveHost, staminaErr)
			ExpeditionManager.cancelWaitingSession(s, staminaErr)
			return
		end

		local memberIds = {}
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
			local p = Player(mid)
			if p and not EM_PRIV.isSessionCompanion(s, p) then
				memberIds[#memberIds + 1] = mid
			end
		end
		if #memberIds == 0 then
			memberIds = { liveHost:getId() }
		end

		local sessionKey = s.key
		local function doEnter(live, host)
			if not teleportMembers(live) then
				return
			end
			finishEntry(live)
			logger.info(
				"[Expedition] {} joined {} role={} instance={} members={} (entered)",
				host:getName(),
				catalog.id,
				contentRole,
				instance.instanceId,
				#ExpeditionManager.sessionMemberIds(live)
			)
			ExpeditionManager.broadcastStatus(live)
		end

		local needDeploy = not soloBoss and TeamManager and TeamManager.deploy

		-- Expedition switch: the change already channeled before the old hunt ended.
		if skipEntryChannel then
			if not needDeploy then
				doEnter(s, liveHost)
				return
			end
			TeamManager.deploy(liveHost, {
				position = instance.entry,
				instanceId = instance.instanceId,
				companionsOnly = true,
				inviteFriends = false,
				onComplete = function(depCompanions, depErr)
					local live = ExpeditionManager.getSessionByKey(sessionKey)
					if not live or live.state == "ended" or live.entered or not live.starting then
						return
					end
					local host = Player(live.playerId)
					if not host then
						ExpeditionManager.teardownSession(live)
						return
					end
					if not depCompanions then
						ExpeditionManager.cancelWaitingSession(live, depErr or "Failed to deploy account team.")
						return
					end
					registerDeployedCompanions(live, host, depCompanions, {
						loadout = loadout,
						hostWorldPos = hostWorldPos,
					})
					doEnter(live, host)
				end,
			})
			return
		end

		-- InstanceTeleport required for expedition entry.
		if not InstanceTeleport or not InstanceTeleport.requestExpedition then
			ExpeditionProtocol.sendError(liveHost, "Instance teleport is unavailable.")
			ExpeditionManager.cancelWaitingSession(s, "Instance teleport is unavailable.")
			return
		end

		-- Overlap IT channel with companion deploy. Hop when both channel timer and prep are done.
		local ok, groupKeyOrErr = InstanceTeleport.requestExpedition({
			initiatorId = liveHost:getId(),
			memberIds = memberIds,
			holdUntilReady = needDeploy and true or false,
			onComplete = function()
				local live = ExpeditionManager.getSessionByKey(sessionKey)
				if not live or live.state == "ended" or live.entered then
					return
				end
				local host = Player(live.playerId)
				if not host then
					ExpeditionManager.teardownSession(live)
					return
				end
				doEnter(live, host)
			end,
			onCancel = function()
				local live = ExpeditionManager.getSessionByKey(sessionKey)
				if live and not live.entered then
					ExpeditionManager.cancelWaitingSession(live, "Expedition entry cancelled.")
				end
			end,
		})
		if not ok then
			ExpeditionProtocol.sendError(liveHost, groupKeyOrErr or "Could not start expedition teleport.")
			ExpeditionManager.cancelWaitingSession(s, tostring(groupKeyOrErr or "Could not start expedition teleport."))
			return
		end
		local groupKey = groupKeyOrErr

		if not needDeploy then
			return
		end

		TeamManager.deploy(liveHost, {
			position = instance.entry,
			instanceId = instance.instanceId,
			companionsOnly = true,
			inviteFriends = false,
			onComplete = function(depCompanions, depErr)
				local live = ExpeditionManager.getSessionByKey(sessionKey)
				if not live or live.state == "ended" or live.entered or not live.starting then
					return
				end
				local host = Player(live.playerId)
				if not host then
					ExpeditionManager.teardownSession(live)
					return
				end
				if not depCompanions then
					if InstanceTeleport.cancel then
						InstanceTeleport.cancel(host)
					end
					ExpeditionManager.cancelWaitingSession(live, depErr or "Failed to deploy account team.")
					return
				end
				registerDeployedCompanions(live, host, depCompanions, {
					loadout = loadout,
					hostWorldPos = hostWorldPos,
				})
				-- Marks prep ready; hop fires once the channel timer has also elapsed.
				InstanceTeleport.markReady(groupKey)
			end,
		})
	end

	-- Live-world tiles (no clone): entry ground is either present now or the catalog
	-- center is bad. Do not poll — there is no async tile-ready event to wait on.
	local s = ExpeditionManager.getSessionByKey(key)
	if not s then
		logger.warn("[Expedition] enter aborted (session gone) key={}", key)
		return
	end
	if not Player(s.playerId) then
		logger.warn("[Expedition] enter aborted (host offline) key={}", key)
		ExpeditionManager.teardownSession(s)
		return
	end
	if not ExpeditionInstance.hasGround(instance.entry) then
		local entry = instance.entry
		logger.error(
			"[Expedition] enter aborted (no ground at entry {},{},{}) key={} catalog={}",
			entry and entry.x or "?",
			entry and entry.y or "?",
			entry and entry.z or "?",
			key,
			tostring(catalog and catalog.id)
		)
		local host = Player(s.playerId)
		if host then
			ExpeditionProtocol.sendError(host, "Failed to enter expedition (invalid hunt tile).")
		end
		ExpeditionManager.teardownSession(s)
		return
	end

	local liveHost = Player(s.playerId)
	enterAfterPrep(s, liveHost)
end

function ExpeditionManager.maybeStartExpeditionEntry(session)
	if not session or session.entered or session.starting then
		return
	end
	if EM_PRIV.awaitingHumanCount(session) > 0 then
		return
	end
	ExpeditionManager.startExpeditionEntry(session)
end

function ExpeditionManager.cancelWaitingSession(session, reason)
	if not session or session.entered then
		return
	end
	EM_PRIV.clearAcceptTimeout(session)
	local message = tostring(reason or "Expedition cancelled.")
	for guid in pairs(EM_PRIV.teamInvitesByFriendGuid) do
		local invite = EM_PRIV.teamInvitesByFriendGuid[guid]
		if invite and invite.sessionKey == session.key then
			EM_PRIV.teamInvitesByFriendGuid[guid] = nil
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
			EM_PRIV.clearActive(p)
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
					EM_PRIV.teamInvitesByFriendGuid[friend:getGuid()] = {
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
							"%s invited you to expedition: %s. Accept from the notification on the left.",
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
	local invite = EM_PRIV.teamInvitesByFriendGuid[player:getGuid()]
	EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
	ExpeditionProtocol.send(player, { type = "teamExpeditionInviteCleared" })
	if invite and invite.sessionKey then
		local session = ExpeditionManager.getSessionByKey(invite.sessionKey)
		if session and session.state == "pending" and session.awaitingHumanGuids then
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
	if not EM_PRIV.playerHasExpeditionStamina(player) then
		ExpeditionProtocol.sendError(player, "You need stamina to enter an expedition.")
		return
	end
	local allowed, combatErr = EM_PRIV.expeditionTeleportCombatOk(player)
	if not allowed then
		ExpeditionProtocol.sendError(player, combatErr or "You cannot teleport while PZ-locked.")
		return
	end
	local invite = EM_PRIV.teamInvitesByFriendGuid[player:getGuid()]
	if not invite then
		ExpeditionProtocol.sendError(player, "No pending team expedition invite.")
		return
	end
	if invite.expires and os.time() > invite.expires then
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "That expedition invite expired.")
		return
	end
	if ExpeditionManager.getSessionByPlayer(player) then
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Already on an expedition.")
		return
	end

	local session = ExpeditionManager.getSessionByKey(invite.sessionKey)
	if not session or session.state == "ended" then
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "That expedition is no longer active.")
		return
	end
	if session.role == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(session.catalog) then
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
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
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
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
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
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

	EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
	ExpeditionManager.attachFriendToSession(player, session, host)
end

function ExpeditionManager.attachFriendToSession(friend, session, host, opts)
	opts = opts or {}
	if not friend or not session then
		return
	end
	if not EM_PRIV.playerHasExpeditionStamina(friend) then
		ExpeditionProtocol.sendError(friend, "You need stamina to enter an expedition.")
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

	EM_PRIV.saveReturn(friend)
	EM_PRIV.markActive(friend, catalog and catalog.id or "", session.channel or 0)
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
		local stance, rangedDist = EM_PRIV.memberStanceFromConfig(friend)
		session.memberStance[friendId] = stance
		session.memberRangedDistance = session.memberRangedDistance or {}
		session.memberRangedDistance[friendId] = rangedDist
	end
	session.memberAutomation = session.memberAutomation or {}
	session.memberAutomation[friendId] = EM_PRIV.prepareMemberAutomation(friend, nil, false)
	EM_PRIV.sessionsByPlayerId[friendId] = session

	if not session.entered then
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

	local function finishLateFriendEnter(p)
		local live = ExpeditionManager.getSessionByKey(session.key)
		if not live or live.state == "ended" or not live.entered then
			ExpeditionManager.leave(p, { silent = true })
			return
		end
		local inst = live.instance
		if not inst or not inst.entry then
			ExpeditionProtocol.sendError(p, "Failed to enter expedition (instance missing).")
			ExpeditionManager.leave(p, { silent = true })
			return
		end
		if not (InstanceWorld and InstanceWorld.enterInstance) then
			logger.error("[Expedition] InstanceWorld.enterInstance missing — cannot accept invite")
			ExpeditionProtocol.sendError(p, "Failed to enter expedition (instance API missing).")
			ExpeditionManager.leave(p, { silent = true })
			return
		end
		local entered = InstanceWorld.enterInstance(p, inst.instanceId, inst.entry, "hunt:" .. tostring(live.key or ""))
		if not entered then
			ExpeditionProtocol.sendError(p, "Failed to enter expedition (teleport blocked).")
			ExpeditionManager.leave(p, { silent = true })
			return
		end
		if InstanceTeleport and InstanceTeleport.sendArrivalEffect then
			InstanceTeleport.sendArrivalEffect(p, InstanceTeleport.KIND_EXPEDITION)
		end
		local hostPlayer = host or (live.playerId and Player(live.playerId)) or nil
		p:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"Joined %s's expedition: %s",
				hostPlayer and hostPlayer:getName() or "team",
				catalog and catalog.name or (catalog and catalog.id) or "expedition"
			)
		)
		ExpeditionProtocol.send(p, { type = "teamExpeditionInviteCleared" })
		ExpeditionProtocol.sendStatus(p, live)
		ExpeditionManager.broadcastStatus(live)
		ExpeditionConfig.pickAnchor(live)
		local friendSessionKey = live.key
		addEvent(function()
			local s = ExpeditionManager.getSessionByKey(friendSessionKey)
			if s and Player(friendId) then
				EM_PRIV.syncClientMaps(s)
			end
		end, ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500)
		logger.info(
			"[Expedition] friend {} joined session {} via team invite",
			p:getName(),
			tostring(live.key)
		)
		EM_PRIV.syncHuntPersist(live)
	end

	if InstanceTeleport and InstanceTeleport.armSoloExpedition then
		local ok, err = InstanceTeleport.armSoloExpedition(friend, {
			onComplete = finishLateFriendEnter,
			onCancel = function(p)
				if p then
					ExpeditionManager.leave(p, { silent = true })
				end
			end,
		})
		if not ok then
			ExpeditionProtocol.sendError(friend, err or "Could not start expedition teleport.")
			ExpeditionManager.leave(friend, { silent = true })
			return
		end
		ExpeditionProtocol.send(friend, { type = "teamExpeditionInviteCleared" })
		ExpeditionProtocol.sendStatus(friend, session)
		return
	end

	finishLateFriendEnter(friend)
end

function EM_PRIV.sessionMemberIds(session)
	return ExpeditionManager.sessionMemberIds(session)
end

--- Drop one hunt/boss member without tearing down the party session (unless last).
function EM_PRIV.removeHuntMember(session, player, opts)
	opts = opts or {}
	if not session or not player then
		return
	end
	local playerId = player:getId()
	EM_PRIV.sessionsByPlayerId[playerId] = nil

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
	if session.deadPlayerIds and not opts.keepDeadFlag then
		session.deadPlayerIds[playerId] = nil
	end

	ExpeditionAI.stopPlayer(session, player)
	player:unregisterEvent("ExpeditionPlayerDeath")
	EM_PRIV.clearActive(player)

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
	EM_PRIV.syncHuntPersist(session)
end

function EM_PRIV.cancelTeardownEvent(session)
	if session and session.teardownEvent then
		stopEvent(session.teardownEvent)
		session.teardownEvent = nil
	end
end

function EM_PRIV.disbandExpeditionParty(session)
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

function EM_PRIV.cleanupSession(session, player, opts)
	if not session or session._cleaned then
		return
	end
	session._cleaned = true
	EM_PRIV.cancelTeardownEvent(session)
	ExpeditionAI.stop(session)
	if session.kind == "arena" or session.role == "arena" then
		if QuestArena and QuestArena.onSessionCleanup then
			pcall(QuestArena.onSessionCleanup, session, opts)
		elseif QuestArena and QuestArena.clear then
			pcall(QuestArena.clear, session)
		end
	elseif session.role == "boss" and session.kind ~= "raid" then
		ExpeditionBoss.clear(session)
	elseif session.kind ~= "raid" then
		ExpeditionPack.clear(session)
	end
	ExpeditionInstance.teardown(session.instance)
	if session.kind ~= "raid" then
		EM_PRIV.releaseHuntChannel(session.catalog and session.catalog.id, session.channel)
	end
	if session.key then
		EM_PRIV.sessionsByKey[session.key] = nil
	end
	for _, id in ipairs(EM_PRIV.sessionMemberIds(session)) do
		EM_PRIV.sessionsByPlayerId[id] = nil
		local p = Player(id)
		if p then
			p:unregisterEvent("ExpeditionPlayerDeath")
		end
	end
	if session.playerId then
		EM_PRIV.sessionsByPlayerId[session.playerId] = nil
	end
	if player then
		EM_PRIV.sessionsByPlayerId[player:getId()] = nil
		player:unregisterEvent("ExpeditionPlayerDeath")
	end
	-- Switch hops keep the account team party intact for the next join/deploy.
	if not (opts and (opts.keepTeamDeployed or opts.keepParty)) then
		EM_PRIV.disbandExpeditionParty(session)
	end
	if ExpeditionPersist and ExpeditionPersist.clearSession and not ExpeditionPersist.isServerShuttingDown() and not session.persistedForRestart then
		pcall(ExpeditionPersist.clearSession, session)
	end
end

--- Leave all living members (boss victory / party teardown).
--- opts.goHometownPlayerId: that member recalls to town temple instead of open-world return.
