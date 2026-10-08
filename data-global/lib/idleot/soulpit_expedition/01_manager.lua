-- Soul Pit as an expedition-style private instance (raid pattern).
-- Consumes a soul core, runs SoulPit.waves inside an expedition slot.

SoulPitExpedition = SoulPitExpedition or {}

local SOUL_CORE_SUFFIX = " soul core"

local function findSoulCore(player)
	-- Prefer items whose name ends with " soul core".
	local candidates = {}
	local function scanContainer(container)
		if not container then
			return
		end
		for i = 0, container:getSize() - 1 do
			local it = container:getItem(i)
			if it then
				local name = it:getName() and it:getName():lower() or ""
				if name:sub(-#SOUL_CORE_SUFFIX) == SOUL_CORE_SUFFIX then
					candidates[#candidates + 1] = it
				elseif it:isContainer() then
					scanContainer(it)
				end
			end
		end
	end
	for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
		local it = player:getSlotItem(slot)
		if it then
			local name = it:getName() and it:getName():lower() or ""
			if name:sub(-#SOUL_CORE_SUFFIX) == SOUL_CORE_SUFFIX then
				candidates[#candidates + 1] = it
			elseif it:isContainer() then
				scanContainer(it)
			end
		end
	end
	return candidates[1]
end

local function monsterNameFromCore(item)
	if not item then
		return nil
	end
	local name = item:getName() or ""
	local monsterName = name:gsub("[Ss]oul [Cc]ore", ""):gsub("^%s+", ""):gsub("%s+$", "")
	local variation = SoulPit.getMonsterVariationNameBySoulCore(name:lower())
	if variation then
		monsterName = variation
	end
	return monsterName
end

function SoulPitExpedition.spawnWave(session)
	if not session or not session.instance or not session.soulPitMonster then
		return
	end
	-- Never spawn into a released (or reused) instance.
	if not Instance.isLive(session.instance.instanceId) or session.state == "ended" then
		return
	end
	local waves = SoulPit.waves
	local stage = (session.wave or 0) + 1
	local wave = waves[stage]
	if not wave then
		session.state = "cleared"
		return
	end
	session.wave = stage
	session.state = "combat"
	local monsterName = session.soulPitMonster
	local origin = session.instance.entry or session.instance.origin
	local spawned = 0

	local function spawnAt(stack)
		local pos = Position(origin.x + math.random(-3, 3), origin.y + math.random(-3, 3), origin.z)
		local monster = nil
		local instanceId = session.instance and session.instance.instanceId or nil
		if Game.createSoulPitMonster then
			monster = Game.createSoulPitMonster(monsterName, pos, stack, true, true, nil, instanceId)
		else
			monster = Game.createMonster(monsterName, pos, true, true, nil, instanceId)
		end
		if monster then
			monster:registerEvent("IdleMonsterDeath")
			if stack == 40 and SoulPit and SoulPit.bossAbilities and SoulPit.possibleAbilities then
				local abilityName = SoulPit.possibleAbilities[math.random(1, #SoulPit.possibleAbilities)]
				local ability = SoulPit.bossAbilities[abilityName]
				if ability and ability.apply then
					pcall(ability.apply, monster)
				end
			end
			spawned = spawned + 1
		end
	end

	for stack, amount in pairs(wave.stacks or {}) do
		for _ = 1, amount do
			spawnAt(stack)
		end
	end
	session.alive = (session.alive or 0) + spawned
	if ExpeditionProtocol and ExpeditionProtocol.sendStatus then
		for _, pid in ipairs(session.playerIds or { session.playerId }) do
			local p = Player(pid)
			if p then
				ExpeditionProtocol.sendStatus(p, session)
			end
		end
	end
end

function SoulPitExpedition.onMonsterDeath(session)
	if not session or session.kind ~= "soulpit" then
		return
	end
	session.alive = math.max(0, (session.alive or 1) - 1)
	session.kills = (session.kills or 0) + 1
	if session.alive <= 0 then
		local waves = SoulPit.waves
		if session.wave >= #waves then
			session.state = "cleared"
			-- Grant animus mastery like stock Soul Pit.
			if session.soulPitMonster then
				for _, pid in ipairs(session.playerIds or { session.playerId }) do
					local p = Player(pid)
					if p and p.addAnimusMastery then
						p:addAnimusMastery(session.soulPitMonster)
						p:sendTextMessage(
							MESSAGE_EVENT_ADVANCE,
							string.format("You defeated the %s soul core!", session.soulPitMonster)
						)
					end
				end
			end
		else
			ExpeditionManager.scope(session):timer("wave", (SoulPit and SoulPit.checkMonstersDelay) or 4500, function()
				if (session.alive or 0) <= 0 and session.state ~= "cleared" then
					SoulPitExpedition.spawnWave(session)
				end
			end)
		end
	end
end

IdleEvents.on("monster.died", function(monster)
	SoulPitExpedition.onMonsterDeath(ExpeditionManager.getSessionByInstanceId(monster:getInstanceId()))
end, "SoulPitExpedition")

function SoulPitExpedition.start(player)
	if not player or not ExpeditionManager or not ExpeditionInstance then
		return false, "Expeditions unavailable."
	end
	if ExpeditionSafety and not ExpeditionSafety.hasStamina(player) then
		return false, "You need stamina to enter an expedition."
	end
	if PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
		-- GOD may enter Soul Pit regardless of level.
	elseif player:getLevel() < ((SoulPit and SoulPit.requiredLevel) or 8) then
		return false, string.format("Need level %d.", (SoulPit and SoulPit.requiredLevel) or 8)
	end
	if ExpeditionManager.getSessionByPlayer(player) then
		return false, "Already on an expedition."
	end
	if PzTeleport and PzTeleport.isAllowed then
		local allowed, pzErr = PzTeleport.isAllowed(player)
		if not allowed then
			return false, pzErr or "You can only start Soul Pit from a protection zone."
		end
	end

	local core = findSoulCore(player)
	if not core then
		return false, "Carry a soul core to start Soul Pit."
	end
	local monsterName = monsterNameFromCore(core)
	if not monsterName or monsterName == "" then
		return false, "Invalid soul core."
	end
	-- Verify monster type exists.
	local mType = MonsterType(monsterName)
	if not mType then
		return false, string.format("Unknown monster '%s'.", monsterName)
	end

	if not core:remove(1) then
		return false, "Could not consume soul core."
	end

	local catalog = {
		id = "soul-pit",
		name = "Soul Pit: " .. monsterName,
		kind = "hunt",
		role = "monster", -- avoid ExpeditionBoss.spawn; we drive waves ourselves
		levelMin = (SoulPit and SoulPit.requiredLevel) or 8,
		creatureId = 0,
		creatureIds = {},
		center = { x = 32369, y = 32241, z = 8 },
		spawnIntervalMs = 60000,
		soulPit = true,
	}

	ExpeditionConfig.setTransient("soul-pit", catalog)
	local ok, err = pcall(function()
		ExpeditionManager.join(player, "soul-pit", "boss", nil, nil)
	end)
	ExpeditionConfig.clearTransient("soul-pit")

	if not ok then
		return false, tostring(err)
	end

	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		return false, "Failed to start Soul Pit."
	end
	session.kind = "soulpit"
	session.soulPitMonster = monsterName
	session.role = "monster"
	session.wave = 0
	session.alive = 0
	-- Cancel the boss spawn timer if join armed one.
	ExpeditionManager.scope(session):cancel("bossSpawn")
	pcall(ExpeditionPack.clear, session)
	-- First wave shortly after enter.
	ExpeditionManager.scope(session):timer("wave", 2000, function()
		SoulPitExpedition.spawnWave(session)
	end)

	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Soul Pit started: " .. monsterName)
	return true
end
