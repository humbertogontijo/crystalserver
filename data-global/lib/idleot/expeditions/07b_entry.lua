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
	-- scope "lobby": the host's lobby (members in the room + companions) starts together.
	-- Anything else is a solo run: host only, no companions.
	if options.scope == "lobby" then
		local startLobby = EM_PRIV.startLobby(player, options)
		if not startLobby then
			ExpeditionProtocol.sendError(player, "Only the lobby host can start a lobby expedition.")
			return
		end
		options.lobbyId = startLobby.id
	else
		options.scope = "solo"
		options.lobbyId = nil
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
		if Alts.getDeployment(player) then
			Alts.undeploy(player)
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
		IdleSafe.call("Alts.undeploy", Alts.undeploy, player)
		ExpeditionProtocol.sendEnded(player)
	end
	if type(expeditionId) == "string" and RaidInstance.getActive(expeditionId) then
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
	if catalog.exclusiveKitno then
		local can, kitnoErr = QuestsKitnoBoss.canJoin(player, catalog)
		if not can then
			ExpeditionProtocol.sendError(player, kitnoErr or "This exclusive boss is locked.")
			return
		end
	end
	if catalog.exclusiveArena then
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
	elseif catalog.soulPit then
		kind = "soulpit"
	end

	-- Today's Fiendish Hunt offer: forced Fiendish of the offered race; killing it ends the hunt.
	if contentRole == "monster" then
		local offer = ActivityBoostFiendishHunt.get(player)
		if offer and not offer.complete and tostring(offer.expeditionId) == tostring(catalog.id) then
			options = options or {}
			options.skipOpenWorldForge = true
			options.forceFiendishCreatureId = tonumber(offer.creatureId) or options.forceFiendishCreatureId
		end
	end

	if contentRole == "boss" and not PzTeleport.isGod(player) then
		local availabilityErr = ExpeditionConfig.bossAvailabilityError(catalog)
		if availabilityErr then
			ExpeditionProtocol.sendError(player, availabilityErr)
			return
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

	-- Lobby starts are all-or-nothing: an underleveled teammate blocks the start instead
	-- of being left behind in the lobby room.
	if options.scope == "lobby" and not options.skipPzCheck then
		local soloOnly = contentRole == "arena"
			or (contentRole == "boss" and ExpeditionConfig.isSoloBoss(catalog))
		local blocked = soloOnly and {}
			or ExpeditionManager.underleveled(EM_PRIV.collectExpectedHumanTeammates(player, options), levelMin)
		if #blocked > 0 then
			local names = {}
			for _, p in ipairs(blocked) do
				names[#names + 1] = string.format("%s (%d)", p:getName(), p:getLevel())
				ExpeditionProtocol.sendError(
					p,
					string.format("Level too low for this expedition (need %d, you are %d).", levelMin, p:getLevel())
				)
			end
			ExpeditionProtocol.sendError(
				player,
				string.format("%s requires level %d: %s.", catalog.name, levelMin, table.concat(names, ", "))
			)
			return
		end
	end

	-- Gate host + party / accepted listing teammates before allocating an instance.
	do
		local soloOrSwitch = (contentRole == "boss" and ExpeditionConfig.isSoloBoss(catalog))
			or contentRole == "arena"
			or options.skipPzCheck == true
		local staminaErr = EM_PRIV.partyStaminaError(EM_PRIV.collectStaminaGatePlayers(player, {
			skipPartyGate = soloOrSwitch,
			preAcceptedPlayers = options.preAcceptedPlayers,
			scope = options.scope,
			lobbyId = options.lobbyId,
		}))
		if staminaErr then
			ExpeditionProtocol.sendError(player, staminaErr)
			return
		end
	end

	local sessionLure = nil
	local sessionLureMax = nil
	if contentRole ~= "boss" and contentRole ~= "arena" then
		sessionLureMax = tonumber(catalog.lureMax) or CavebotConfig.LURE_MAX
		-- Ignore client lure; the cave route carries the hunt's pack size.
		local route = ExpeditionConfig.caveRoute(catalog)
		sessionLure = route and route.lure or ExpeditionConfig.lureFromDensity(sessionLureMax)
	end
	local bossLever = contentRole == "boss" and ExpeditionConfig.bossLever(catalog) or nil
	local sessionBossDifficulty = nil
	if bossLever and BossDifficulty.isEnabled(bossLever) then
		sessionBossDifficulty = BossDifficulty.normalize(bossLever, options.bossDifficulty)
		local gatePlayers = { player }
		for _, teammate in ipairs(EM_PRIV.collectExpectedHumanTeammates(player, options)) do
			gatePlayers[#gatePlayers + 1] = teammate
		end
		local maxAllowed = BossDifficulty.groupMax(gatePlayers, bossLever)
		if sessionBossDifficulty > maxAllowed then
			ExpeditionProtocol.sendError(
				player,
				string.format("Difficulty %d is locked for your team (highest unlocked: %d).", sessionBossDifficulty, maxAllowed)
			)
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

	-- Capture host world tile before companions spawn at instance entry.
	local hostWorldPos = player:getPosition()

	-- Build the private instance before team login so companions can spawn at entry.
	-- Transient catalogs (soul pit) have no numeric id: use the region they are built in.
	local subareaId = tonumber(catalog.id) or (catalog.center and InstanceWorld.subareaIdAt(catalog.center)) or 0
	local instanceId = ExpeditionInstance.allocate(kind, subareaId, player:getGuid())
	if instanceId == nil then
		ExpeditionProtocol.sendError(player, "No expedition instances available.")
		return
	end

	local instanceSpec = bossLever and ExpeditionConfig.bossLeverInstanceSpec(catalog, bossLever) or catalog
	local instance, err = ExpeditionInstance.build(instanceId, instanceSpec, player:getGuid() + os.time())
	if not instance then
		ExpeditionInstance.free(instanceId)
		ExpeditionProtocol.sendError(player, err or "Failed to build expedition instance.")
		return
	end

	-- Account companions deploy when the expedition actually starts (after teammates accept).
	local soloBoss = (contentRole == "boss" and ExpeditionConfig.isSoloBoss(catalog))
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

	local expectedTeammates = (soloBoss or options.skipPzCheck) and {}
		or EM_PRIV.collectExpectedHumanTeammates(player, options)
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
	-- The team's reserved engine channel on this hunt subarea.
	local channel = Instance.channel(instanceId)

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
		EM_PRIV.markActive(member, catalog.id)
		SampleSpells.ensure(member)
		member:registerEvent("ExpeditionPlayerDeath")
		ExpeditionAI.enablePersistence(member)
	end

	local awaitingHumanGuids = {}
	local readyTeammates = {}
	local hostGuid = player:getGuid()
	local preAcceptedById = {}
	if type(options.preAcceptedPlayers) == "table" then
		for _, teammate in ipairs(options.preAcceptedPlayers) do
			if teammate then
				preAcceptedById[teammate:getId()] = true
			end
		end
	end
	-- Direct hunt→hunt switch: teammates already accepted while still in the prior session.
	for _, teammate in ipairs(options.preAcceptedPlayers or {}) do
		if teammate and not ExpeditionManager.getSessionByPlayer(teammate) then
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
		if teammate and not ExpeditionManager.getSessionByPlayer(teammate) then
			if preAcceptedById[teammate:getId()] then
				-- Already queued via preAcceptedPlayers.
			elseif EM_PRIV.hasUiClient(teammate) and EM_PRIV.meetsExpeditionLevel(teammate, levelMin) then
				local allowed = true
				-- Switch hops skip combat check: teammates are still on the prior hunt footprint.
				if not options.skipPzCheck then
					allowed = EM_PRIV.expeditionTeleportCombatOk(teammate) == true
				end
				-- Being inside the lobby room is ready; anyone else gets the accept prompt.
				if allowed then
					readyTeammates[#readyTeammates + 1] = teammate
				else
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
		scope = options.scope,
		lobbyId = options.lobbyId,
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

	-- All-or-nothing team start: every expected teammate is pulled in or awaited, or nobody goes.
	session.requiredHumanGuids = { [hostGuid] = player:getName() }
	for _, teammate in ipairs(readyTeammates) do
		session.requiredHumanGuids[teammate:getGuid()] = teammate:getName()
	end
	for guid, name in pairs(awaitingHumanGuids) do
		session.requiredHumanGuids[guid] = name
	end
	local leftBehind = {}
	local requiredTeammates = {}
	for _, teammate in ipairs(expectedTeammates) do
		requiredTeammates[#requiredTeammates + 1] = teammate
	end
	for _, teammate in ipairs(options.preAcceptedPlayers or {}) do
		requiredTeammates[#requiredTeammates + 1] = teammate
	end
	for _, teammate in ipairs(requiredTeammates) do
		if teammate and teammate:getGuid() ~= hostGuid
			and not session.requiredHumanGuids[teammate:getGuid()]
		then
			session.requiredHumanGuids[teammate:getGuid()] = teammate:getName()
			leftBehind[#leftBehind + 1] = teammate:getName()
		end
	end
	if #leftBehind > 0 then
		local message = string.format("%s cannot join %s, so nobody enters.", table.concat(leftBehind, ", "), catalog.name)
		ExpeditionProtocol.sendError(player, message)
		ExpeditionManager.cancelWaitingSession(session, message)
		return
	end

	ExpeditionManager.broadcastStatus(session)

	-- Auto-pull Ready members (skip accept modal). Attach silently, then enter or wait.
	for _, teammate in ipairs(readyTeammates) do
		IdleSafe.call("Alts.forceJoinToParty", Alts.forceJoinToParty, player, teammate)
		ExpeditionManager.attachFriendToSession(teammate, session, player, { skipMaybeStart = true })
		teammate:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("Joining %s's lobby expedition: %s.", player:getName(), catalog.name)
		)
	end

	EM_PRIV.notifyLobbies(ExpeditionManager.sessionMemberIds(session))

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
		ExpeditionPersist.clearSnapshot(snapshot)
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
	local instanceId = ExpeditionInstance.allocate("hunt", catalog.id, hostGuid)
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
	local channel = Instance.channel(instanceId)
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
		scope = snapshot.scope,
		lobbyId = tonumber(snapshot.lobbyId),
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
	local bound = not instanceId or player:getInstanceId() == instanceId
	if onTiles and bound then
		return true
	end
	player:setFollowCreature(nil)
	local entered = InstanceWorld.enterInstance(player, instanceId, session.instance.entry)
	if not entered then
		return false
	end
	Game.runInInstance(player:getInstanceId(), function()
		player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	end)
	return true
end

--- Push expedition HUD/catalog once a real client attaches to a headless session member.
function ExpeditionManager.syncSessionClientIfNeeded(player)
	if player:getClient().version == 0 then
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
	IdleSafe.call("ExpeditionAI.start", ExpeditionAI.start, session)
	ExpeditionProtocol.sendCatalog(player)
	RaidInstance.sendActiveRaids(player)
	ExpeditionProtocol.sendStatus(player, session)
	local sessionKey = session.key
	addEvent(function()
		local p = Player(pid)
		if p and ExpeditionManager.getSessionByKey(sessionKey) then
			IdleSafe.call("CombatAutomation.resyncAttackTarget", CombatAutomation.resyncAttackTarget, p)
		end
	end, ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500)
	return true
end

function EM_PRIV.syncRunningHuntClients(session)
	if not session or not session.entered then
		return
	end
	for _, member in ipairs(ExpeditionManager.onlinePlayers(session)) do
		if member:getClient().version > 0 then
			ExpeditionManager.syncSessionClientIfNeeded(member)
		else
			ExpeditionProtocol.sendStatus(member, session)
		end
	end
end

--- Humans to log back in for a restored hunt: host first, then the other saved humans.
function EM_PRIV.restoredHumanGuids(snapshot, hostGuid)
	local guids = { hostGuid }
	local seen = { [hostGuid] = true }
	for _, rawGuid in ipairs(snapshot.humanGuids or {}) do
		local guid = math.floor(tonumber(rawGuid) or 0)
		if guid > 0 and not seen[guid] then
			seen[guid] = true
			guids[#guids + 1] = guid
		end
	end
	return guids
end

--- Companion deploys for a restored hunt, one { controllerGuid, names } per controlling human.
--- Snapshots saved before companions were recorded redeploy the host's default team (names nil).
function EM_PRIV.restoredCompanionGroups(snapshot, hostGuid, humanGuids)
	if type(snapshot.companions) ~= "table" then
		return { { controllerGuid = hostGuid } }
	end
	local isHuman = {}
	for _, guid in ipairs(humanGuids) do
		isHuman[guid] = true
	end
	local groups = {}
	local byController = {}
	for _, entry in ipairs(snapshot.companions) do
		local name = type(entry) == "table" and entry.name or nil
		if type(name) == "string" and name ~= "" then
			local controllerGuid = math.floor(tonumber(entry.controllerGuid) or 0)
			if not isHuman[controllerGuid] then
				controllerGuid = hostGuid
			end
			local group = byController[controllerGuid]
			if not group then
				group = { controllerGuid = controllerGuid, names = {} }
				byController[controllerGuid] = group
				groups[#groups + 1] = group
			end
			group.names[#group.names + 1] = name
		end
	end
	return groups
end

--- Log every saved human back in headless, redeploy their companions and resume the hunt.
--- All-or-nothing: if any member cannot be brought back, nobody is and the hunt is dropped.
function EM_PRIV.startRestoredHuntOnStartup(session, snapshot)
	if not session or not snapshot or session.entered or session.starting or session.state == "ended" then
		return false
	end
	local hostGuid = math.floor(tonumber(snapshot.hostGuid) or session.guid or 0)
	local instance = session.instance
	local spawnPos = instance and instance.entry
	if hostGuid <= 0 or not spawnPos then
		return false
	end

	local sessionKey = session.key
	local catalog = session.catalog
	local instanceId = Instance.normalize(instance.instanceId)
	local humanGuids = EM_PRIV.restoredHumanGuids(snapshot, hostGuid)
	local companionGroups = EM_PRIV.restoredCompanionGroups(snapshot, hostGuid, humanGuids)
	local humans = {}
	local companions = {}
	local controllers = {}

	session.guid = hostGuid
	session.starting = true
	session.restoring = true

	local function abort(reason)
		logger.warn("[ExpeditionPersist] restore of {} aborted, nobody deployed: {}", tostring(sessionKey), tostring(reason))
		for _, controller in ipairs(controllers) do
			local live = Player(controller:getId())
			if live then
				Alts.undeploy(live)
			end
		end
		local live = ExpeditionManager.getSessionByKey(sessionKey)
		if live then
			live.starting = nil
			live.restoring = nil
			ExpeditionManager.teardownSession(live)
		end
		ExpeditionPersist.clearSnapshot(snapshot)
		for _, guid in ipairs(humanGuids) do
			local p = Alts.findOnlinePlayerByGuid(guid)
			if p and not EM_PRIV.hasUiClient(p) then
				Game.headlessLogout(p)
			elseif p then
				InstanceWorld.rescueIfStranded(p)
			end
		end
	end

	local function beginRestoredHunt()
		local s = ExpeditionManager.getSessionByKey(sessionKey)
		if not s or s.state == "ended" then
			return
		end
		EM_PRIV.beginExpeditionHunt(s, s.role)
		EM_PRIV.syncRunningHuntClients(s)
		logger.info(
			"[ExpeditionPersist] started restored hunt {} catalog={} instance={} humans={} members={} lure={} anchor={}",
			tostring(sessionKey),
			tostring(catalog and catalog.id),
			tostring(instanceId),
			#humans,
			#ExpeditionManager.sessionMemberIds(s),
			tostring(s.lure or "-"),
			tostring(s.anchorPlayerId or "-")
		)
	end

	local function finish()
		local live = ExpeditionManager.getSessionByKey(sessionKey)
		if not live or live.state == "ended" then
			abort("session ended during restore")
			return
		end
		for _, member in ipairs(humans) do
			if not Player(member:getId()) then
				abort(member:getName() .. " went offline during restore")
				return
			end
		end
		for _, entry in ipairs(companions) do
			if not Player(entry.player:getId()) then
				abort(entry.player:getName() .. " went offline during restore")
				return
			end
		end

		local host = humans[1]
		local registered = {}
		for _, id in ipairs(live.playerIds or {}) do
			registered[id] = true
		end
		local function register(member, controller, opts)
			if not registered[member:getId()] then
				registered[member:getId()] = true
				EM_PRIV.registerSessionMember(live, member, controller, opts)
			end
		end
		for _, human in ipairs(humans) do
			-- Saved humans are humans even if a client detach left a companion mark.
			Alts.clearCompanionMark(human)
			register(human, host, {})
		end
		live.playerId = host:getId()
		live.automation = live.memberAutomation[host:getId()] or live.automation
		local companionById = {}
		for _, entry in ipairs(companions) do
			companionById[entry.player:getId()] = true
		end
		for _, entry in ipairs(companions) do
			register(entry.player, entry.controller, { hostWorldPos = spawnPos, companionById = companionById })
		end

		for _, id in ipairs(ExpeditionManager.sessionMemberIds(live)) do
			local member = Player(id)
			if not member or not EM_PRIV.teleportPlayerIntoRunningHunt(member, live) then
				abort(string.format("%s could not enter the hunt", member and member:getName() or tostring(id)))
				return
			end
		end

		ExpeditionManager.markEntered(live)
		live.starting = nil
		live.restoring = nil
		live.state = "idle"
		live.awaitingHumanGuids = nil
		ExpeditionConfig.pickAnchor(live)
		if ExpeditionPersist.isPersistableHunt(live) then
			IdleSafe.call("ExpeditionPersist.writeSession", ExpeditionPersist.writeSession, live)
		end

		addEvent(function()
			if ExpeditionInstance.hasGround(spawnPos) then
				beginRestoredHunt()
			else
				addEvent(beginRestoredHunt, 100)
			end
		end, ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500)
	end

	local function deployGroup(index)
		local group = companionGroups[index]
		if not group then
			finish()
			return
		end
		local controller = nil
		for _, human in ipairs(humans) do
			if human:getGuid() == group.controllerGuid then
				controller = human
				break
			end
		end
		if not controller or not Player(controller:getId()) then
			abort(string.format("companion controller guid %s unavailable", tostring(group.controllerGuid)))
			return
		end
		Alts.deploy(controller, {
			names = group.names,
			position = spawnPos,
			instanceId = instanceId,
			inviteFriends = false,
			onComplete = function(deployed, err)
				if not deployed then
					abort(string.format("companions of %s: %s", controller:getName(), tostring(err or "deploy failed")))
					return
				end
				controllers[#controllers + 1] = controller
				for _, companion in ipairs(deployed) do
					companions[#companions + 1] = { player = companion, controller = controller }
				end
				deployGroup(index + 1)
			end,
		})
	end

	-- Async login so server boot does not stall the dispatcher; the batch is all-or-nothing.
	Game.headlessLoginBatch(humanGuids, spawnPos, function(players, err)
		if not players then
			abort(string.format("could not log in %d human(s): %s", #humanGuids, tostring(err or "unknown")))
			return
		end
		local byGuid = {}
		for _, p in ipairs(players) do
			byGuid[p:getGuid()] = p
		end
		for _, guid in ipairs(humanGuids) do
			if not byGuid[guid] then
				abort(string.format("guid %d missing from login batch", guid))
				return
			end
			humans[#humans + 1] = byGuid[guid]
		end
		deployGroup(1)
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
	local snapshot = ExpeditionPersist.getPendingSnapshot(player)
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
		if not host and hostGuid > 0 then
			host = Alts.findOnlinePlayerByGuid(hostGuid)
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

--- Names of required humans / companions that are not live, alive session members.
function EM_PRIV.missingRosterMembers(session)
	local presentGuids = {}
	local presentNames = {}
	for _, p in ipairs(ExpeditionManager.onlinePlayers(session)) do
		if p:getHealth() > 0 then
			presentGuids[p:getGuid()] = true
			presentNames[p:getName():lower()] = true
		end
	end
	local missing = {}
	for guid, name in pairs(session.requiredHumanGuids or {}) do
		if not presentGuids[guid] then
			missing[#missing + 1] = tostring(name)
		end
	end
	for _, name in ipairs(session.requiredCompanionNames or {}) do
		if not presentNames[name:lower()] then
			missing[#missing + 1] = name
		end
	end
	table.sort(missing)
	return missing
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
		ExpeditionManager.markEntered(s)
		s.starting = nil
		s.persistedForRestart = nil
		EM_PRIV.applyEntryBossCooldown(s, ExpeditionManager.sessionMemberIds(s))
		ExpeditionConfig.pickAnchor(s)
		if ExpeditionPersist.isPersistableHunt(s) then
			IdleSafe.call("ExpeditionPersist.writeSession", ExpeditionPersist.writeSession, s)
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
		local missing = EM_PRIV.missingRosterMembers(s)
		if #missing > 0 then
			ExpeditionManager.cancelWaitingSession(
				s,
				string.format("%s could not be deployed to %s, so nobody enters.", table.concat(missing, ", "), catalog.name)
			)
			return false
		end
		local enteredAny = false
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
			local p = Player(mid)
			if p then
				p:setFollowCreature(nil)
				local atEntry = false
				local ppos = p:getPosition()
				local engineId = Instance.of(p)
				if ppos and instance.entry
					and engineId == instance.instanceId
					and ppos.x == instance.entry.x
					and ppos.y == instance.entry.y
					and ppos.z == instance.entry.z
				then
					atEntry = true
				end
				if not atEntry then
					local ok = InstanceWorld.enterInstance(p, instance.instanceId, instance.entry)
					if not ok then
						logger.error(
							"[Expedition] {} teleport failed to {},{},{} ({})",
							p:getName(),
							instance.entry.x,
							instance.entry.y,
							instance.entry.z,
							catalog.id
						)
						local message = string.format("%s could not enter %s, so nobody enters.", p:getName(), catalog.name)
						for _, other in ipairs(ExpeditionManager.onlinePlayers(s)) do
							ExpeditionProtocol.sendError(other, message)
						end
						ExpeditionManager.leaveAll(s, { silent = true })
						return false
					else
						InstanceTeleport.sendArrivalEffect(p, InstanceTeleport.KIND_EXPEDITION)
						enteredAny = true
						local stance = s.memberStance and s.memberStance[mid] or s.stance
						if contentRole == "boss" then
							local encounter = ExpeditionConfig.bossEncounter(catalog)
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
			if companion then
				companionById[companion:getId()] = true
			end
		end
		regOpts = regOpts or {}
		regOpts.companionById = companionById
		for _, companion in ipairs(depCompanions) do
			local already = false
			for _, mid in ipairs(s.playerIds or {}) do
				if companion and mid == companion:getId() then
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
		local members = ExpeditionManager.onlinePlayers(s)
		local staminaErr = EM_PRIV.partyStaminaError(members)
		if staminaErr then
			ExpeditionProtocol.sendError(liveHost, staminaErr)
			ExpeditionManager.cancelWaitingSession(s, staminaErr)
			return
		end

		-- Lobby starts deploy companions into the lobby room first; they channel with the humans.
		local lobbyScoped = s.scope == "lobby" and not soloBoss
		if lobbyScoped then
			s.requiredCompanionNames = Alts.companionNamesFor(liveHost)
		end
		local preDeployed = nil
		if lobbyScoped then
			local dep = Alts.getDeployment(liveHost)
			if dep then
				preDeployed = {}
				for _, id in ipairs(dep.companionIds or {}) do
					local c = Player(id)
					if c and c:getHealth() > 0 then
						preDeployed[#preDeployed + 1] = c
					end
				end
				registerDeployedCompanions(s, liveHost, preDeployed, {
					loadout = loadout,
					hostWorldPos = hostWorldPos,
				})
			end
		end

		local cooldownErr = EM_PRIV.entryBossCooldownError(s)
		if cooldownErr then
			ExpeditionProtocol.sendError(liveHost, cooldownErr)
			ExpeditionManager.cancelWaitingSession(s, cooldownErr)
			return
		end

		local memberIds = {}
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
			local p = Player(mid)
			if p and (preDeployed or not EM_PRIV.isSessionCompanion(s, p)) then
				memberIds[#memberIds + 1] = mid
			end
		end
		if #memberIds == 0 then
			memberIds = { liveHost:getId() }
		end

		local sessionKey = s.key
		local function doEnter(live, host)
			-- Companions deployed for the entry are members only now.
			local entryCooldownErr = EM_PRIV.entryBossCooldownError(live)
			if entryCooldownErr then
				ExpeditionProtocol.sendError(host, entryCooldownErr)
				ExpeditionManager.cancelWaitingSession(live, entryCooldownErr)
				return
			end
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

		local needDeploy = lobbyScoped and not preDeployed and Alts.deploy

		-- Expedition switch: the change already channeled before the old hunt ended.
		if skipEntryChannel then
			if not needDeploy then
				doEnter(s, liveHost)
				return
			end
			Alts.deploy(liveHost, {
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

		Alts.deploy(liveHost, {
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
					InstanceTeleport.cancel(host)
					ExpeditionManager.cancelWaitingSession(live, depErr or "Failed to deploy account team.")
					return
				end
				registerDeployedCompanions(live, host, depCompanions, {
					loadout = loadout,
					hostWorldPos = hostWorldPos,
				})
				local cooldownErr = EM_PRIV.entryBossCooldownError(live)
				if cooldownErr then
					ExpeditionProtocol.sendError(host, cooldownErr)
					ExpeditionManager.cancelWaitingSession(live, cooldownErr)
					InstanceTeleport.cancel(host)
					return
				end
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
	for _, p in ipairs(ExpeditionManager.onlinePlayers(session)) do
		p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
		EM_PRIV.clearActive(p)
		ExpeditionManager.clearAreaEffects(p)
		ExpeditionProtocol.sendEnded(p)
		p:unregisterEvent("ExpeditionPlayerDeath")
	end
	if Alts.getDeployment(Player(session.playerId)) then
		local host = Player(session.playerId)
		if host then
			Alts.undeploy(host)
		end
	end
	ExpeditionManager.teardownSession(session)
end

--- Lobby mates (or party members) of `host` may join its waiting expedition.
function EM_PRIV.isStartTeammate(host, player)
	if not host or not player then
		return false
	end
	if LobbyManager.isLobbyMate(host, player) then
		return true
	end
	local party = host:getParty()
	for _, member in ipairs(party and party:getMembers() or {}) do
		if member and member:getId() == player:getId() then
			return true
		end
	end
	return false
end

--- Prompt awaiting lobby teammates to join this hunt/boss session (accept -> auto-party + enter).
function ExpeditionManager.inviteTeamFriends(host, session)
	if not host or not session then
		return
	end
	if session.kind == "raid" then
		return
	end
	-- Solo boss fights are host-only (no companions, no friend pull-ins).
	if session.role == "boss" and ExpeditionConfig.isSoloBoss(session.catalog) then
		return
	end
	local expeditionId = session.catalog and session.catalog.id or ""
	local expeditionName = session.catalog and session.catalog.name or expeditionId
	local timeoutSec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
	local expires = session.acceptDeadline or (os.time() + timeoutSec)

	for guid in pairs(session.awaitingHumanGuids or {}) do
		local friend = Player(guid)
		if friend and friend:getId() ~= host:getId() and not ExpeditionManager.getSessionByPlayer(friend)
			and EM_PRIV.isStartTeammate(host, friend)
		then
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
	if session.role == "boss" and ExpeditionConfig.isSoloBoss(session.catalog) then
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Solo boss expeditions cannot be joined by friends.")
		return
	end

	local host = Player(session.playerId)
	if not host then
		-- Try resolve by guid from invite.
		host = nil
		for _, p in ipairs(ExpeditionManager.onlinePlayers(session)) do
			if p:getGuid() == invite.hostGuid then
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

	local allowed = EM_PRIV.isStartTeammate(host, player)
	if not allowed then
		EM_PRIV.teamInvitesByFriendGuid[player:getGuid()] = nil
		ExpeditionProtocol.sendError(player, "Only lobby members can join this expedition.")
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

	local ok, err = Alts.forceJoinToParty(host, player)
	if not ok then
		ExpeditionProtocol.sendError(player, err or "Failed to join expedition party.")
		return
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
	if session.role == "boss" and ExpeditionConfig.isSoloBoss(session.catalog) then
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
	end

	EM_PRIV.saveReturn(friend)
	EM_PRIV.markActive(friend, catalog and catalog.id or "")
	SampleSpells.ensure(friend)
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
		local entered = InstanceWorld.enterInstance(p, inst.instanceId, inst.entry)
		if not entered then
			ExpeditionProtocol.sendError(p, "Failed to enter expedition (teleport blocked).")
			ExpeditionManager.leave(p, { silent = true })
			return
		end
		EM_PRIV.applyEntryBossCooldown(live, { p:getId() })
		InstanceTeleport.sendArrivalEffect(p, InstanceTeleport.KIND_EXPEDITION)
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
	EM_PRIV.notifyLobbies({ playerId })
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
	party:disband()
end

function EM_PRIV.cleanupSession(session, player, opts)
	if not session or session._cleaned then
		return
	end
	session._cleaned = true
	EM_PRIV.notifyLobbies(EM_PRIV.sessionMemberIds(session))
	ExpeditionAI.stop(session)
	if session.kind == "arena" or session.role == "arena" then
		IdleSafe.call("QuestArena.onSessionCleanup", QuestArena.onSessionCleanup, session, opts)
	elseif session.role == "boss" and session.kind ~= "raid" then
		ExpeditionBoss.clear(session)
	elseif session.kind ~= "raid" then
		ExpeditionPack.clear(session)
	end
	if session.lifetime then
		session.lifetime:dispose()
	end
	ExpeditionInstance.teardown(session.instance)
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
	if not ExpeditionPersist.isServerShuttingDown() and not session.persistedForRestart then
		IdleSafe.call("ExpeditionPersist.clearSession", ExpeditionPersist.clearSession, session)
	end
	IdleEvents.emit("session.ended", session)
end

--- Leave all living members (boss victory / party teardown).
--- opts.goHometownPlayerId: that member recalls to town temple instead of open-world return.
