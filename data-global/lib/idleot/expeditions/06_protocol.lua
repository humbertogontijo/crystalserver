ExpeditionProtocol = ExpeditionProtocol or {}

function ExpeditionProtocol.send(player, payload)
	if not player then
		return false
	end
	return player:sendExtendedOpcode(ExpeditionConfig.OPCODE, JsonParser.encode(payload))
end

--- Sync staff flag for GOD spectators (/goto into hunts) without paging the full catalog.
function ExpeditionProtocol.sendGodFlags(player)
	if not player then
		return false
	end
	return ExpeditionProtocol.send(player, {
		type = "godFlags",
		god = PzTeleport.isGod(player),
	})
end

--- Catalog paging limits per extended-opcode JSON blob.
local CATALOG_PAGE_SIZE = 60
local CATALOG_PAGE_BYTES = 48000

--- Split catalog rows into pages whose encoded rows fit CATALOG_PAGE_BYTES
--- (extended-opcode strings are capped at 64KB) and at most CATALOG_PAGE_SIZE rows.
local function catalogPages(catalog)
	local pages, chunk, bytes = {}, {}, 0
	for _, row in ipairs(catalog) do
		local size = #JsonParser.encode(row) + 1
		if #chunk > 0 and (#chunk >= CATALOG_PAGE_SIZE or bytes + size > CATALOG_PAGE_BYTES) then
			pages[#pages + 1] = chunk
			chunk, bytes = {}, 0
		end
		chunk[#chunk + 1] = row
		bytes = bytes + size
	end
	pages[#pages + 1] = chunk
	return pages
end

function ExpeditionProtocol.sendCatalog(player)
	local god = PzTeleport.isGod(player)
	local pages = catalogPages(ExpeditionProtocol.catalogRows(player))
	local ok = true
	for page, chunk in ipairs(pages) do
		local sent = ExpeditionProtocol.send(player, {
			type = "catalog",
			page = page,
			pages = #pages,
			god = god,
			catalog = chunk,
		})
		if not sent then
			ok = false
		end
	end
	return ok
end

--- Boss creature sheet (bosstiary race ids). Not bestiary - dedicated expedition payload.
function ExpeditionProtocol.sendBossDetail(player, creatureId, nameHint, bosstiaryClassHint)
	if not player then
		return false
	end
	if not ExpeditionBossDetail or not ExpeditionBossDetail.build then
		return ExpeditionProtocol.sendError(player, "Boss details are unavailable.")
	end
	local detail, err = ExpeditionBossDetail.build(player, creatureId, nameHint, bosstiaryClassHint)
	if not detail then
		return ExpeditionProtocol.send(player, {
			type = "bossDetail",
			ok = false,
			id = tonumber(creatureId) or 0,
			error = err or "Unknown boss.",
		})
	end
	return ExpeditionProtocol.send(player, {
		type = "bossDetail",
		ok = true,
		detail = detail,
	})
end

--- Cave walker progress for the HUD: phase (walking | pacing | fighting | parked |
--- manual | complete), waypoint i/n and laps done. Nil before the walk starts.
local function caveStatus(session)
	local cave = session.cave
	local route = cave and ExpeditionConfig.caveRoute(session.catalog)
	if not route then
		return nil
	end
	local phase = ({ walk = "walking", pace = "pacing", halt = "fighting" })[cave.mode] or "walking"
	if session.lureFinished then
		phase = "complete"
	elseif cave.manual then
		phase = "manual"
	elseif cave.parked then
		phase = "parked"
	end
	return {
		phase = phase,
		waypoint = cave.entryIdx and 0 or cave.idx,
		waypoints = #route.waypoints,
		lap = cave.lap or 0,
	}
end

function ExpeditionProtocol.sendStatus(player, session)
	if not session then
		return false
	end
	local elapsed = 0
	if session.startedAt then
		elapsed = math.max(0, os.time() - session.startedAt)
	end
	local kind = ExpeditionAI.sessionKind(session)
	local role = session.role or (session.catalog and session.catalog.role) or "monster"
	if role ~= "boss" and role ~= "monster" then
		role = "monster"
	end
	local expeditionId = session.catalog and session.catalog.id or ""
	local expeditionName = (session.catalog and session.catalog.name)
		or session.displayName
		or ""
	local status = {
		expeditionId = expeditionId,
		expeditionName = expeditionName,
		kind = kind,
		role = role,
		stance = session.stance,
		wave = session.wave or session.pitIndex or 0,
		alive = session.alive or 0,
		kills = session.kills or 0,
		state = session.state or "idle",
		elapsedSec = elapsed,
	}
	if session.kind == "arena" or (session.catalog and session.catalog.role == "arena") then
		local total = session.arenaSpec and session.arenaSpec.creatures and #session.arenaSpec.creatures or 10
		status.arenaPit = session.pitIndex or session.wave or 0
		status.arenaPits = total
	end
	if player and session.memberStance and session.memberStance[player:getId()] then
		status.stance = session.memberStance[player:getId()]
	end
	if kind == "raid" then
		status.raidName = session.raidName or expeditionId
		if expeditionName == "" then
			status.expeditionName = session.displayName or status.raidName or ""
		end
		status.players = type(session.playerIds) == "table" and #session.playerIds or 1
	else
		local memberCount = 1
		if ExpeditionManager and ExpeditionManager.sessionMemberIds then
			memberCount = #ExpeditionManager.sessionMemberIds(session)
		elseif type(session.playerIds) == "table" and #session.playerIds > 0 then
			memberCount = #session.playerIds
		end
		status.players = memberCount
		if session.anchorPlayerId then
			status.anchorId = session.anchorPlayerId
			status.isAnchor = (player and player:getId() == session.anchorPlayerId) and true or false
			local anchor = Player(session.anchorPlayerId)
			if anchor then
				status.anchorName = anchor:getName()
			end
		end
	end
	if session.bossRaceId and session.bossRaceId > 0 then
		status.bossCreatureId = session.bossRaceId
	elseif session.catalog and session.catalog.creatureId then
		status.bossCreatureId = session.catalog.creatureId
	end
	if role == "boss" and session.bossDifficulty ~= nil then
		local lever = ExpeditionConfig.bossDifficultyLever(session.catalog)
		if lever then
			status.bossDifficulty = tonumber(session.bossDifficulty) or 0
			status.bossDifficultyMax = BossDifficulty.max(lever)
		end
	end
	-- Relative seconds (not a timestamp) so the client is immune to clock skew.
	if role == "boss" and session.state == "hunting" and session.bossEndsAt then
		status.bossRemainingSec = math.max(0, session.bossEndsAt - os.time())
		status.bossTimeLimitSec = session.bossTimeLimitSec
	end
	if role == "monster" and kind ~= "raid" then
		local lureMax = tonumber(session.lureMax)
			or (session.catalog and tonumber(session.catalog.lureMax))
			or CavebotConfig.LURE_MAX
			or 2
		status.lure = session.lure or CavebotConfig.LURE_DEFAULT
		status.lureMax = lureMax
		status.metrics = ExpeditionMetrics and ExpeditionMetrics.summary(session) or nil
		status.cave = caveStatus(session)
	end
	status.stopOnInsufficientGold = session.stopOnInsufficientGold == true
	status.stopOnInsufficientCap = session.stopOnInsufficientCap == true
	status.entered = session.entered == true
	status.manual = player ~= nil and session.manualIds ~= nil and session.manualIds[player:getId()] == true
	-- Pre-entry teammate accepts only (boss AI uses "waiting" after entry).
	local teamAccept = session.state == "pending"
		and not session.entered
		and type(session.awaitingHumanGuids) == "table"
	if teamAccept then
		status.teamAccept = true
		local roster = {}
		local seen = {}
		local acceptedCount = 0
		for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
			local p = Player(id)
			local isCompanion = Alts and Alts.isCompanion and Alts.isCompanion(p)
			local headless = p and p.isHeadless and p:isHeadless()
			if p and not isCompanion and not headless then
				local name = p:getName()
				local key = name:lower()
				if not seen[key] then
					seen[key] = true
					acceptedCount = acceptedCount + 1
					roster[#roster + 1] = { name = name, accepted = true }
				end
			end
		end
		local awaiting = {}
		for guid, name in pairs(session.awaitingHumanGuids) do
			if type(name) == "string" and name ~= "" then
				local p = Player(guid)
				-- Drop headless from pending accept display.
				if p and p.isHeadless and p:isHeadless() then
					-- skip
				else
					local key = name:lower()
					if not seen[key] then
						seen[key] = true
						awaiting[#awaiting + 1] = name
					end
				end
			end
		end
		table.sort(awaiting)
		for _, name in ipairs(awaiting) do
			roster[#roster + 1] = { name = name, accepted = false }
		end
		status.awaiting = awaiting
		status.awaitingCount = #awaiting
		status.roster = roster
		status.acceptedCount = acceptedCount
		status.totalCount = #roster
		local timeoutSec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or 45))
		local deadline = tonumber(session.acceptDeadline) or (os.time() + timeoutSec)
		status.acceptDeadline = deadline
		status.acceptTimeoutSec = timeoutSec
		status.acceptRemainSec = math.max(0, deadline - os.time())
	end
	-- Party / account-team member vitals for primary client HUD.
	local members = {}
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(id)
		if p then
			members[#members + 1] = {
				name = p:getName(),
				id = id,
				level = p:getLevel(),
				health = p:getHealth(),
				maxHealth = p:getMaxHealth(),
				mana = p:getMana(),
				maxMana = p:getMaxMana(),
				alt = Alts and Alts.isCompanion and Alts.isCompanion(p) or false,
			}
		end
	end
	if #members > 0 then
		status.members = members
	end
	return ExpeditionProtocol.send(player, {
		type = "status",
		status = status,
	})
end

--- The player's own walk / follow owns their movement (true) or the AI has it back.
function ExpeditionProtocol.sendManualControl(player, active)
	return ExpeditionProtocol.send(player, { type = "manualControl", active = active == true })
end

function ExpeditionProtocol.sendEnded(player)
	return ExpeditionProtocol.send(player, { type = "ended" })
end

--- Hunt member died: client freezes the scene, shows the modal, then acks to leave.
function ExpeditionProtocol.sendHuntDeath(player, payload)
	if not player or type(payload) ~= "table" then
		return false
	end
	return ExpeditionProtocol.send(player, {
		type = "huntDeath",
		subjectName = tostring(payload.subjectName or "Adventurer"),
		subjectId = payload.subjectId and (tonumber(payload.subjectId) or payload.subjectId) or nil,
		message = tostring(payload.message or ""),
	})
end

--- Current instance identity (topbar place/channel). Bounds are server-enforced.
function ExpeditionProtocol.sendInstanceBounds(player, desc)
	if not desc then
		return ExpeditionProtocol.send(player, { type = "instanceBounds" })
	end
	local payload = {
		type = "instanceBounds",
		subareaId = tonumber(desc.subareaId) or 0,
		kind = tostring(desc.kind or ""),
		name = tostring(desc.name or ""),
		key = tostring(desc.key or ""),
		channel = math.floor(tonumber(desc.channel) or 0),
	}
	local hunt = ExpeditionProtocol.openWorldHunt(player, payload)
	if hunt then
		payload.expeditionId = tostring(hunt.id)
		payload.expeditionName = tostring(hunt.name or hunt.id)
	end
	local sent = ExpeditionProtocol.send(player, payload)
	if CavebotProtocol then
		CavebotProtocol.sendState(player)
	end
	return sent
end

--- Catalog hunt matching a public hunt / wild layer the player stands in (expedition hint).
function ExpeditionProtocol.openWorldHunt(player, payload)
	if payload.kind ~= "hunt" and payload.kind ~= "wild" then
		return nil
	end
	if payload.key == "" or Instance.isPrivate(payload.key) then
		return nil
	end
	local function isHunt(entry)
		return entry and entry.role ~= "boss" and entry.role ~= "arena" and entry.kind ~= "boss"
	end
	for _, entry in ipairs(InstanceWorld.huntsAt and InstanceWorld.huntsAt(player:getPosition()) or {}) do
		if isHunt(entry) then
			return entry
		end
	end
	if payload.kind == "hunt" then
		local entry = ExpeditionConfig.getById(payload.subareaId, "monster")
		if isHunt(entry) then
			return entry
		end
	end
	return nil
end

function ExpeditionProtocol.sendError(player, message)
	if player then
		logger.warn("[Expedition] {} error: {}", player:getName(), tostring(message or ""))
	else
		logger.warn("[Expedition] error: {}", tostring(message or ""))
	end
	return ExpeditionProtocol.send(player, { type = "error", message = message })
end

function ExpeditionProtocol.handle(player, buffer)
	local msg = JsonParser.decode(buffer)
	if not msg or type(msg) ~= "table" then
		logger.warn(
			"[Expedition] {} sent invalid opcode payload (len={})",
			player and player:getName() or "?",
			buffer and #buffer or 0
		)
		return
	end
	if CombatAutomationProtocol and CombatAutomationProtocol.handleAction then
		if CombatAutomationProtocol.handleAction(player, msg) then
			return
		end
	end
	-- Discovery POI FAB: exclusive walk into discovery radius (validated server-side).
	-- Handled here so it works in and out of expeditions.
	if msg.action == "discoverWalk" then
		if DiscoverySystem and DiscoverySystem.walkTowardViewpoint then
			DiscoverySystem.walkTowardViewpoint(player, msg.x, msg.y, msg.z)
		end
		return
	end
	-- Keep staff flag in sync for raids/world bosses before catalog pages arrive.
	ExpeditionProtocol.sendGodFlags(player)
	local action = msg.action
	if action == "list" then
		ExpeditionProtocol.sendCatalog(player)
		if RaidInstance and RaidInstance.sendActiveRaids then
			RaidInstance.sendActiveRaids(player)
		end
		if ExpeditionManager.reconcilePresence then
			ExpeditionManager.reconcilePresence(player)
		end
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session and ExpeditionManager.isInExpedition(player) then
			ExpeditionProtocol.sendStatus(player, session)
		else
			-- Clear sticky client status after restart / failed leave / stale HUD.
			ExpeditionProtocol.sendEnded(player)
		end
		if InstanceWorld and InstanceWorld.sendBounds then
			InstanceWorld.sendBounds(player, true)
		end
	elseif action == "join" then
		logger.info(
			"[Expedition] {} join id={} role={} lure={}",
			player:getName(),
			tostring(msg.id or ""),
			tostring(msg.role or ""),
			tostring(msg.lure or "")
		)
		local role = msg.role
		if msg.scope == "lobby" then
			-- Lobby starts gather the room first (call / deploy) and then join with scope "lobby".
			local ok, err = LobbyStart.request(player, { loadout = msg.loadout })
			if not ok then
				ExpeditionProtocol.sendError(player, err or "Could not start the lobby.")
			end
		elseif role == "boss" and ExpeditionManager.prepareBoss then
			ExpeditionManager.prepareBoss(player, msg.id, msg.loadout, {
				stopOnInsufficientGold = msg.stopOnInsufficientGold,
				stopOnInsufficientCap = msg.stopOnInsufficientCap,
				bossDifficulty = msg.bossDifficulty,
				scope = "solo",
			})
		else
			ExpeditionManager.join(player, msg.id, role, msg.loadout, msg.lure, {
				stopOnInsufficientGold = msg.stopOnInsufficientGold,
				stopOnInsufficientCap = msg.stopOnInsufficientCap,
				scope = "solo",
			})
		end
	elseif action == "prepareBoss" then
		logger.info(
			"[Expedition] {} prepareBoss id={} previewOnly={}",
			player:getName(),
			tostring(msg.id or ""),
			tostring(msg.previewOnly or false)
		)
		ExpeditionManager.prepareBoss(player, msg.id, msg.loadout, {
			stopOnInsufficientGold = msg.stopOnInsufficientGold,
			stopOnInsufficientCap = msg.stopOnInsufficientCap,
			bossDifficulty = msg.bossDifficulty,
			previewOnly = msg.previewOnly == true,
		})
	elseif action == "joinRaid" then
		logger.info(
			"[Expedition] {} joinRaid name={}",
			player:getName(),
			tostring(msg.name or msg.id or "")
		)
		if RaidInstance and RaidInstance.join then
			RaidInstance.join(player, msg.name or msg.id, msg.loadout, {
				stopOnInsufficientGold = msg.stopOnInsufficientGold,
				stopOnInsufficientCap = msg.stopOnInsufficientCap,
			})
		else
			ExpeditionProtocol.sendError(player, "Raids are unavailable.")
		end
	elseif action == "joinSoulPit" then
		logger.info("[Expedition] {} joinSoulPit", player:getName())
		if SoulPitExpedition and SoulPitExpedition.start then
			local ok, err = SoulPitExpedition.start(player)
			if not ok then
				ExpeditionProtocol.sendError(player, err or "Soul Pit failed.")
			end
		else
			ExpeditionProtocol.sendError(player, "Soul Pit is unavailable.")
		end
	elseif action == "leave" then
		logger.info("[Expedition] {} leave reason={}", player:getName(), tostring(msg.reason or ""))
		ExpeditionManager.requestLeave(player, {
			reason = msg.reason,
			expeditionName = msg.expeditionName,
		})
	elseif action == "switch" then
		logger.info(
			"[Expedition] {} switch id={} role={} lure={}",
			player:getName(),
			tostring(msg.id or ""),
			tostring(msg.role or ""),
			tostring(msg.lure or "")
		)
		ExpeditionManager.requestSwitch(player, msg.id, msg.role, msg.loadout, msg.lure, {
			stopOnInsufficientGold = msg.stopOnInsufficientGold,
			stopOnInsufficientCap = msg.stopOnInsufficientCap,
		})
	elseif action == "acceptSwitch" then
		logger.info("[Expedition] {} acceptSwitch", player:getName())
		ExpeditionManager.acceptSwitch(player)
	elseif action == "declineSwitch" then
		logger.info("[Expedition] {} declineSwitch", player:getName())
		ExpeditionManager.declineSwitch(player)
	elseif action == "cancelSwitch" then
		logger.info("[Expedition] {} cancelSwitch", player:getName())
		ExpeditionManager.cancelSwitch(player)
	elseif action == "cancelLeave" then
		logger.info("[Expedition] {} cancelLeave", player:getName())
		ExpeditionManager.cancelLeave(player)
	elseif action == "channelCancel" then
		logger.info("[Expedition] {} channelCancel", player:getName())
		if InstanceTeleport and InstanceTeleport.handleChannelCancel then
			InstanceTeleport.handleChannelCancel(player)
		elseif ExpeditionManager.cancelLeave then
			ExpeditionManager.cancelLeave(player)
		end
	elseif action == "ackHuntDeath" then
		logger.info("[Expedition] {} ackHuntDeath", player:getName())
		if ExpeditionManager.ackHuntDeath then
			ExpeditionManager.ackHuntDeath(player)
		end
	elseif action == "acceptTeamInvite" then
		logger.info("[Expedition] {} acceptTeamInvite", player:getName())
		ExpeditionManager.acceptTeamInvite(player)
	elseif action == "declineTeamInvite" then
		logger.info("[Expedition] {} declineTeamInvite", player:getName())
		ExpeditionManager.declineTeamInvite(player)
	elseif action == "setLure" then
		ExpeditionManager.setLure(player, msg.lure)
	elseif action == "setStopOptions" then
		ExpeditionManager.setStopOptions(player, {
			stopOnInsufficientGold = msg.stopOnInsufficientGold,
			stopOnInsufficientCap = msg.stopOnInsufficientCap,
		})
	elseif action == "listActiveRaids" then
		if RaidInstance and RaidInstance.sendActiveRaids then
			RaidInstance.sendActiveRaids(player)
		end
	elseif action == "getBossDetail" then
		local creatureId = tonumber(msg.id or msg.creatureId)
		local nameHint = msg.name
		local classHint = msg.bosstiaryClass
		if (not nameHint or nameHint == "") and creatureId then
			local entry = ExpeditionConfig.getById and ExpeditionConfig.getById(creatureId, "boss") or nil
			if entry then
				nameHint = entry.name
				classHint = classHint or entry.bosstiaryClass
			end
		end
		ExpeditionProtocol.sendBossDetail(player, creatureId, nameHint, classHint)
	else
		logger.warn(
			"[Expedition] {} unknown action '{}'",
			player:getName(),
			tostring(action or "")
		)
	end
end
