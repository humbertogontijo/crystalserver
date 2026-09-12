ExpeditionProtocol = ExpeditionProtocol or {}

function ExpeditionProtocol.send(player, payload)
	if not player then
		return false
	end
	return player:sendExtendedOpcode(ExpeditionConfig.OPCODE, ExpeditionJson.encode(payload))
end

--- Sync staff flag for GOD spectators (/goto into hunts) without paging the full catalog.
function ExpeditionProtocol.sendGodFlags(player)
	if not player then
		return false
	end
	return ExpeditionProtocol.send(player, {
		type = "godFlags",
		god = PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) or false,
	})
end

function ExpeditionProtocol.sendCatalog(player)
	local catalog = ExpeditionConfig.catalogForClient(player)
	local pageSize = ExpeditionConfig.CATALOG_PAGE_SIZE or 60
	local total = #catalog
	if total == 0 then
		return ExpeditionProtocol.send(player, {
			type = "catalog",
			page = 1,
			pages = 1,
			god = PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) or false,
			catalog = {},
		})
	end
	local pages = math.ceil(total / pageSize)
	local ok = true
	for page = 1, pages do
		local chunk = {}
		local from = (page - 1) * pageSize + 1
		local to = math.min(page * pageSize, total)
		for i = from, to do
			chunk[#chunk + 1] = catalog[i]
		end
		local sent = ExpeditionProtocol.send(player, {
			type = "catalog",
			page = page,
			pages = pages,
			god = PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) or false,
			catalog = chunk,
		})
		if not sent then
			ok = false
		end
	end
	return ok
end

--- Precomputed walk routes for one hunt (detail map / HUD). Kept off the bulk catalog.
function ExpeditionProtocol.sendHuntRoutes(player, expeditionId)
	if not player or expeditionId == nil or expeditionId == "" then
		return false
	end
	local entry = ExpeditionConfig.findById and ExpeditionConfig.findById(expeditionId) or nil
	if not entry then
		for _, e in ipairs(ExpeditionConfig.Catalog or {}) do
			if tostring(e.id) == tostring(expeditionId) then
				entry = e
				break
			end
		end
	end
	local routes = entry and ExpeditionConfig.holdRoutes and ExpeditionConfig.holdRoutes(entry) or {}
	return ExpeditionProtocol.send(player, {
		type = "huntRoutes",
		id = expeditionId,
		routes = routes,
	})
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

--- Hazard unlock / bestiary fields for a catalog entry (live status + lobby preview).
local function attachHazardInfo(out, player, catalog, members)
	if not out or not ExpeditionDifficulty or not catalog then
		return out
	end
	local hazardMax = tonumber(catalog.hazardMax) or ExpeditionDifficulty.HAZARD_MAX
	out.hazardMin = ExpeditionDifficulty.HAZARD_MIN
	out.hazardMax = hazardMax
	local party = members
	if type(party) ~= "table" or #party == 0 then
		party = player and { player } or {}
	end
	local maxAllowed = ExpeditionDifficulty.maxAllowedHazard(party, catalog)
	out.hazardMaxAllowed = maxAllowed
	local personalUnlock, binding = ExpeditionDifficulty.getPersonalHazardMax(player, catalog)
	out.hazardUnlocked = personalUnlock
	if binding then
		out.hazardBestiaryRaceId = binding.raceId
		out.hazardBestiaryName = binding.name
		out.hazardBestiaryKills = binding.kills
		out.hazardBestiaryNeed = binding.need
	end
	if maxAllowed < hazardMax then
		local ok, err, _, reason =
			ExpeditionDifficulty.canAttemptHazard(party, catalog, maxAllowed + 1, player)
		if not ok and err then
			out.hazardLockHint = err
			out.hazardLockReason = reason
		end
	end
	return out
end

--- Lobby / manage preview for a hunt that is not (yet) the live session.
function ExpeditionProtocol.sendHazardInfo(player, expeditionId)
	if not player then
		return false
	end
	expeditionId = tostring(expeditionId or "")
	local catalog = ExpeditionConfig.getById and ExpeditionConfig.getById(expeditionId) or nil
	if not catalog then
		return ExpeditionProtocol.send(player, {
			type = "hazardInfo",
			expeditionId = expeditionId,
			ok = false,
		})
	end
	local members = { player }
	if ListingsStore and ListingsStore.getByHost then
		local listing = ListingsStore.getByHost(player)
		if not listing and ListingsStore.findMembership then
			local membership = ListingsStore.findMembership(player)
			listing = membership and membership.listing or nil
		end
		if listing and type(listing.members) == "table" then
			members = {}
			for _, m in ipairs(listing.members) do
				if m.status == (SocialConfig and SocialConfig.MEMBER_STATUS_ACCEPTED or "accepted") then
					local p = Player(m.guid) or (m.name and Player(m.name)) or nil
					if p then
						members[#members + 1] = p
					end
				end
			end
			if #members == 0 then
				members = { player }
			end
		end
	end
	local payload = {
		type = "hazardInfo",
		ok = true,
		expeditionId = tostring(catalog.id or expeditionId),
	}
	attachHazardInfo(payload, player, catalog, members)
	return ExpeditionProtocol.send(player, payload)
end

function ExpeditionProtocol.sendStatus(player, session)
	if not session then
		return false
	end
	local elapsed = 0
	if session.startedAt then
		elapsed = math.max(0, os.time() - session.startedAt)
	end
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	if kind == "boss" then
		-- Legacy sessions before kind collapse.
		kind = "hunt"
	end
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
		status.bossDifficulty = tonumber(session.bossDifficulty) or 0
		if ExpeditionDifficulty then
			local levels = ExpeditionDifficulty.levelsForBossDifficulty(session.catalog, status.bossDifficulty)
			status.bossRequiredLevel = levels and levels.levelMin or nil
			status.bossCombatPower = levels and levels.combatPower or nil
		end
	end
	if role == "monster" and kind ~= "raid" then
		local lureMax = tonumber(session.lureMax)
			or (session.catalog and tonumber(session.catalog.lureMax))
			or ExpeditionConfig.LURE_MAX
			or 2
		status.lure = session.lure or ExpeditionConfig.LURE_DEFAULT or 1
		status.waveLure = session.waveLure or session.lure or ExpeditionConfig.LURE_DEFAULT or 1
		status.lureMin = ExpeditionConfig.LURE_MIN or 1
		status.lureMax = lureMax
		status.lureValues = ExpeditionConfig.lureValuesUpTo(lureMax)
		if ExpeditionDifficulty then
			status.hazard = tonumber(session.hazardLevel) or ExpeditionDifficulty.HAZARD_DEFAULT
			local members = { player }
			if ExpeditionManager and ExpeditionManager.sessionMemberIds then
				members = {}
				for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
					local m = Player(mid)
					if m then
						members[#members + 1] = m
					end
				end
			end
			attachHazardInfo(status, player, session.catalog, members)
			local levels = ExpeditionDifficulty.levelsForHazard(session.catalog, status.hazard)
			status.hazardRequiredLevel = levels and levels.levelMin or nil
			status.hazardCombatPower = levels and levels.combatPower or nil
		end
		-- Live walk target + catalog stands for HUD minimap flags.
		local holds = ExpeditionConfig.catalogPositions and ExpeditionConfig.catalogPositions(session.catalog)
			or {}
		if #holds > 0 then
			local slim = {}
			local n = math.min(8, #holds)
			for i = 1, n do
				local p = holds[i]
				slim[i] = {
					x = tonumber(p.x) or 0,
					y = tonumber(p.y) or 0,
					z = tonumber(p.z) or 7,
				}
			end
			status.positions = slim
		end
		local idx = math.floor(tonumber(session.positionIndex) or 1)
		if idx < 1 then
			idx = 1
		end
		status.positionIndex = idx
		local hold = session.holdPos
		if hold and hold.x and hold.y then
			status.holdPos = {
				x = tonumber(hold.x) or 0,
				y = tonumber(hold.y) or 0,
				z = tonumber(hold.z) or 7,
			}
		elseif status.positions and status.positions[idx] then
			status.holdPos = status.positions[idx]
		end
		local routes = ExpeditionConfig.holdRoutes and ExpeditionConfig.holdRoutes(session.catalog) or nil
		-- Routes are large; only attach once per session (HUD fetches via huntDetail otherwise).
		if type(routes) == "table" and #routes > 0 and not session._routesSent then
			status.routes = routes
			session._routesSent = true
		end
	end
	status.stopOnInsufficientGold = session.stopOnInsufficientGold == true
	status.stopOnInsufficientCap = session.stopOnInsufficientCap == true
	status.entered = session.entered == true
	-- Pre-entry teammate accepts only. Hunt/boss AI also uses state "waiting" after entry
	-- (formation / spawn delay) — do not treat that as the accept lobby.
	local teamAccept = session.state == "waiting"
		and not session.entered
		and type(session.awaitingHumanGuids) == "table"
	if teamAccept then
		status.teamAccept = true
		local roster = {}
		local seen = {}
		local acceptedCount = 0
		for _, id in ipairs(ExpeditionManager.sessionMemberIds(session)) do
			local p = Player(id)
			local isCompanion = TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(p)
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
				companion = TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(p) or false,
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
		instanceId = tonumber(desc.instanceId) or 0,
		kind = tostring(desc.kind or ""),
		name = tostring(desc.name or ""),
		key = tostring(desc.key or ""),
		channel = math.floor(tonumber(desc.channel) or 0),
	}
	return ExpeditionProtocol.send(player, payload)
end

function ExpeditionProtocol.sendError(player, message)
	if player then
		logger.warn("[Expedition] {} error: {}", player:getName(), tostring(message or ""))
	else
		logger.warn("[Expedition] error: {}", tostring(message or ""))
	end
	return ExpeditionProtocol.send(player, { type = "error", message = message })
end

--- Sync AI attack target to the client (vanilla has no S→C set-attack opcode).
function ExpeditionProtocol.sendAttackTarget(player, creatureId)
	local id = 0
	if creatureId and creatureId > 0 then
		id = creatureId
	end
	return ExpeditionProtocol.send(player, {
		type = "attackTarget",
		creatureId = id,
	})
end

--- Fired when combat automation successfully casts/uses a slot.
--- Client uses exhaustMs for per-slot cooldown overlay + words floater.
function ExpeditionProtocol.sendAutomationCast(player, payload)
	if CombatAutomationProtocol and CombatAutomationProtocol.sendCast then
		return CombatAutomationProtocol.sendCast(player, payload)
	end
	if not player or type(payload) ~= "table" then
		return false
	end
	return ExpeditionProtocol.send(player, {
		type = "automationCast",
		slotId = tostring(payload.slotId or ""),
		kind = tostring(payload.kind or ""),
		words = tostring(payload.words or ""),
		label = tostring(payload.label or payload.words or ""),
		exhaustMs = math.max(0, math.floor(tonumber(payload.exhaustMs) or 0)),
	})
end

function ExpeditionProtocol.handle(player, buffer)
	local msg = ExpeditionJson.decode(buffer)
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
	-- Handled here so it works in and out of expeditions without unlocking client autoWalk.
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
			"[Expedition] {} join id={} role={} lure={} hazard={}",
			player:getName(),
			tostring(msg.id or ""),
			tostring(msg.role or ""),
			tostring(msg.lure or ""),
			tostring(msg.hazard or "")
		)
		local role = msg.role
		if role == "boss" and ExpeditionManager.prepareBoss then
			ExpeditionManager.prepareBoss(player, msg.id, msg.loadout, {
				stopOnInsufficientGold = msg.stopOnInsufficientGold,
				stopOnInsufficientCap = msg.stopOnInsufficientCap,
				bossDifficulty = msg.bossDifficulty,
			})
		else
			ExpeditionManager.join(player, msg.id, role, msg.loadout, msg.lure, {
				stopOnInsufficientGold = msg.stopOnInsufficientGold,
				stopOnInsufficientCap = msg.stopOnInsufficientCap,
				hazard = msg.hazard,
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
			hazard = msg.hazard,
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
	elseif action == "setHazard" then
		ExpeditionManager.setHazardLevel(player, msg.hazard)
	elseif action == "hazardInfo" then
		ExpeditionProtocol.sendHazardInfo(player, msg.id or msg.expeditionId)
	elseif action == "setStopOptions" then
		ExpeditionManager.setStopOptions(player, {
			stopOnInsufficientGold = msg.stopOnInsufficientGold,
			stopOnInsufficientCap = msg.stopOnInsufficientCap,
		})
	elseif action == "listActiveRaids" then
		if RaidInstance and RaidInstance.sendActiveRaids then
			RaidInstance.sendActiveRaids(player)
		end
	elseif action == "getRoutes" then
		ExpeditionProtocol.sendHuntRoutes(player, msg.id)
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
