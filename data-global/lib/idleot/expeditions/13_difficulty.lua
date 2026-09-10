-- Expedition hazard + boss difficulty (instance-scoped).
ExpeditionDifficulty = ExpeditionDifficulty or {}

ExpeditionDifficulty.HAZARD_MIN = 0
ExpeditionDifficulty.HAZARD_MAX = 12
ExpeditionDifficulty.HAZARD_DEFAULT = 0

ExpeditionDifficulty.BOSS_DIFF_MIN = 0
ExpeditionDifficulty.BOSS_DIFF_MAX = 25
ExpeditionDifficulty.BOSS_DIFF_DEFAULT = 0

-- Boss trait/HP scale per difficulty step (also used for CP gating).
ExpeditionDifficulty.BOSS_SCALE = {
	hpPerLevel = 0.04,
	dmgPerLevel = 0.03,
}

ExpeditionDifficulty.KV_BOSS_DIFF = "expedition.bossDifficulty"

local pendingBossByPlayerId = {}

local function catalogHazardMax(catalog)
	local max = tonumber(catalog and catalog.hazardMax) or ExpeditionDifficulty.HAZARD_MAX
	return math.max(ExpeditionDifficulty.HAZARD_MIN, math.min(ExpeditionDifficulty.HAZARD_MAX, math.floor(max)))
end

local function catalogBossDiffMax(catalog)
	local max = tonumber(catalog and catalog.bossDifficultyMax) or ExpeditionDifficulty.BOSS_DIFF_MAX
	return math.max(
		ExpeditionDifficulty.BOSS_DIFF_MIN,
		math.min(ExpeditionDifficulty.BOSS_DIFF_MAX, math.floor(max))
	)
end

function ExpeditionDifficulty.normalizeHazard(value, catalog)
	local n = math.floor(tonumber(value) or ExpeditionDifficulty.HAZARD_DEFAULT)
	local lo = ExpeditionDifficulty.HAZARD_MIN
	local hi = catalogHazardMax(catalog)
	if n < lo then
		n = lo
	elseif n > hi then
		n = hi
	end
	return n
end

function ExpeditionDifficulty.normalizeBossDifficulty(value, catalog)
	local n = math.floor(tonumber(value) or ExpeditionDifficulty.BOSS_DIFF_DEFAULT)
	local lo = ExpeditionDifficulty.BOSS_DIFF_MIN
	local hi = catalogBossDiffMax(catalog)
	if n < lo then
		n = lo
	elseif n > hi then
		n = hi
	end
	return n
end

function ExpeditionDifficulty.hazardConfig()
	if CreatureInfo and CreatureInfo.hazardConfigFromServer then
		return CreatureInfo.hazardConfigFromServer()
	end
	return CreatureInfo and CreatureInfo.DEFAULT_HAZARD_CONFIG or {}
end

function ExpeditionDifficulty.levelsForHazard(catalog, hazardLevel)
	if not catalog or not CreatureInfo or not CreatureInfo.levelsForHazardPack then
		return { combatPower = 0, levelMin = catalog and catalog.levelMin or 1, recommendedLevel = 1 }
	end
	local H = ExpeditionDifficulty.normalizeHazard(hazardLevel, catalog)
	local levels = CreatureInfo.levelsForHazardPack(
		catalog.creatures,
		catalog.creatureDensity,
		H,
		ExpeditionDifficulty.hazardConfig()
	)
	if levels then
		return levels
	end
	return {
		combatPower = tonumber(catalog.combatPower) or 0,
		levelMin = tonumber(catalog.levelMin) or 1,
		recommendedLevel = tonumber(catalog.recommendedLevel) or 1,
	}
end

local function bossTraitsFromCatalog(catalog)
	if not catalog or not CreatureInfo then
		return nil
	end
	local info = nil
	if catalog.creatureId and CreatureInfo.getByCreatureId then
		info = CreatureInfo.getByCreatureId(catalog.creatureId)
	end
	if not info and catalog.name and CreatureInfo.get then
		info = CreatureInfo.get(catalog.name)
	end
	if not info then
		return nil
	end
	return {
		hp = tonumber(info.hp) or 0,
		health = tonumber(info.hp) or 0,
		expectedDps = tonumber(info.expectedDps) or 0,
		expectedHealDps = tonumber(info.expectedHealDps) or 0,
		armor = tonumber(info.armor) or 0,
		defense = tonumber(info.defense) or 0,
		mitigation = tonumber(info.mitigation) or 0,
		meanElementPercent = tonumber(info.meanElementPercent) or 0,
		speed = tonumber(info.speed) or 0,
	}
end

function ExpeditionDifficulty.levelsForBossDifficulty(catalog, difficulty)
	local D = ExpeditionDifficulty.normalizeBossDifficulty(difficulty, catalog)
	local traits = bossTraitsFromCatalog(catalog)
	local scale = catalog and catalog.bossDifficultyScale or ExpeditionDifficulty.BOSS_SCALE
	if traits and CreatureInfo and CreatureInfo.levelsForBossDifficulty then
		return CreatureInfo.levelsForBossDifficulty(traits, D, scale)
	end
	return {
		combatPower = tonumber(catalog and catalog.combatPower) or 0,
		levelMin = tonumber(catalog and catalog.levelMin) or 1,
		recommendedLevel = tonumber(catalog and catalog.recommendedLevel) or 1,
		hpMult = 1 + D * (tonumber(scale.hpPerLevel) or 0.04),
		dmgMult = 1 + D * (tonumber(scale.dmgPerLevel) or 0.03),
	}
end

function ExpeditionDifficulty.partyMinLevel(players)
	local minLevel = nil
	if type(players) ~= "table" then
		return 1
	end
	for _, p in ipairs(players) do
		if p and p.getLevel then
			local god = false
			if p.getGroup then
				local g = p:getGroup()
				if g and g.getAccess and g:getAccess() then
					god = true
				end
			end
			if not god then
				local lv = p:getLevel() or 1
				if not minLevel or lv < minLevel then
					minLevel = lv
				end
			end
		end
	end
	return minLevel or 1
end

local function isGodPlayer(player)
	if not player or not player.getGroup then
		return false
	end
	local g = player:getGroup()
	return g and g.getAccess and g:getAccess() and true or false
end

local function catalogRaceIds(catalog)
	local out = {}
	local seen = {}
	local function push(id)
		id = math.floor(tonumber(id) or 0)
		if id <= 0 or seen[id] then
			return
		end
		seen[id] = true
		out[#out + 1] = id
	end
	if type(catalog) ~= "table" then
		return out
	end
	if type(catalog.creatures) == "table" then
		for _, row in ipairs(catalog.creatures) do
			push(row and row.creatureId)
		end
	end
	if type(catalog.creatureIds) == "table" then
		for _, id in ipairs(catalog.creatureIds) do
			push(id)
		end
	end
	push(catalog.creatureId)
	return out
end

--- Bestiary progress for one race: frac in [0,1], kills, need (toKill), name.
--- Missing / non-bestiary races return nil (skipped by caller).
function ExpeditionDifficulty.bestiaryRaceProgress(player, raceId)
	raceId = math.floor(tonumber(raceId) or 0)
	if raceId <= 0 or not player then
		return nil
	end
	local mType = MonsterType and MonsterType(raceId) or nil
	if not mType then
		return nil
	end
	local toKill = 0
	if mType.BestiarytoKill then
		toKill = math.floor(tonumber(mType:BestiarytoKill()) or 0)
	end
	if toKill <= 0 then
		-- Not a bestiary creature (or unset thresholds): do not gate the hunt.
		return nil
	end
	local kills = 0
	if player.getBestiaryKillCount then
		kills = math.floor(tonumber(player:getBestiaryKillCount(raceId)) or 0)
	end
	if kills < 0 then
		kills = 0
	end
	local frac = kills / toKill
	if frac > 1 then
		frac = 1
	end
	local name = (mType.name and mType:name()) or tostring(raceId)
	return {
		raceId = raceId,
		name = name,
		kills = kills,
		need = toKill,
		frac = frac,
	}
end

--- Personal hazard unlock from weakest hunt bestiary entry.
--- Returns unlocked (0..hazardMax), plus binding race progress table (or nil).
function ExpeditionDifficulty.getPersonalHazardMax(player, catalog)
	local hi = catalogHazardMax(catalog)
	if isGodPlayer(player) then
		return hi, nil
	end
	local races = catalogRaceIds(catalog)
	if #races == 0 then
		return hi, nil
	end
	local minFrac = nil
	local binding = nil
	for _, raceId in ipairs(races) do
		local prog = ExpeditionDifficulty.bestiaryRaceProgress(player, raceId)
		if prog then
			if not minFrac or prog.frac < minFrac then
				minFrac = prog.frac
				binding = prog
			end
		end
	end
	if minFrac == nil then
		-- No bestiary races in mix: do not lock by unlock.
		return hi, nil
	end
	local unlocked = math.floor(minFrac * hi)
	if unlocked < ExpeditionDifficulty.HAZARD_MIN then
		unlocked = ExpeditionDifficulty.HAZARD_MIN
	elseif unlocked > hi then
		unlocked = hi
	end
	return unlocked, binding
end

function ExpeditionDifficulty.partyMinHazardUnlock(players, catalog)
	local hi = catalogHazardMax(catalog)
	if type(players) ~= "table" or #players == 0 then
		return hi, nil, nil
	end
	local minUnlock = nil
	local bindingPlayer = nil
	local bindingProg = nil
	for _, p in ipairs(players) do
		if p and not isGodPlayer(p) then
			if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(p) then
				-- Hirelings do not hold bestiary unlock progress.
			elseif p.isHeadless and p:isHeadless() then
				-- Skip headless park accounts.
			else
				local unlocked, prog = ExpeditionDifficulty.getPersonalHazardMax(p, catalog)
				if not minUnlock or unlocked < minUnlock then
					minUnlock = unlocked
					bindingPlayer = p
					bindingProg = prog
				end
			end
		end
	end
	if minUnlock == nil then
		return hi, nil, nil
	end
	return minUnlock, bindingPlayer, bindingProg
end

function ExpeditionDifficulty.partyMinBossUnlock(players, catalog)
	local hi = catalogBossDiffMax(catalog)
	local fallback = ExpeditionDifficulty.BOSS_DIFF_DEFAULT
	if type(players) ~= "table" or #players == 0 then
		return fallback, nil
	end
	local minUnlock = nil
	local bindingPlayer = nil
	for _, p in ipairs(players) do
		if p then
			if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(p) then
				-- skip park companions
			elseif p.isHeadless and p:isHeadless() then
				-- skip
			else
				-- Include gods: GM accounts must still follow KV unlock for the spinner max.
				local unlocked = ExpeditionDifficulty.getPersonalBossMax(p, catalog)
				if not minUnlock or unlocked < minUnlock then
					minUnlock = unlocked
					bindingPlayer = p
				end
			end
		end
	end
	if minUnlock == nil then
		return fallback, nil
	end
	return math.min(hi, minUnlock), bindingPlayer
end

local function levelGateMaxHazard(players, catalog)
	local hi = catalogHazardMax(catalog)
	local partyLevel = ExpeditionDifficulty.partyMinLevel(players)
	local allowed = ExpeditionDifficulty.HAZARD_MIN
	for step = ExpeditionDifficulty.HAZARD_MIN, hi do
		local levels = ExpeditionDifficulty.levelsForHazard(catalog, step)
		local need = tonumber(levels.levelMin) or 1
		if partyLevel >= need then
			allowed = step
		else
			break
		end
	end
	return allowed, partyLevel
end

local function levelGateMaxBoss(players, catalog)
	local hi = catalogBossDiffMax(catalog)
	local partyLevel = ExpeditionDifficulty.partyMinLevel(players)
	local allowed = ExpeditionDifficulty.BOSS_DIFF_MIN
	for step = ExpeditionDifficulty.BOSS_DIFF_MIN, hi do
		local levels = ExpeditionDifficulty.levelsForBossDifficulty(catalog, step)
		local need = tonumber(levels.levelMin) or 1
		if partyLevel >= need then
			allowed = step
		else
			break
		end
	end
	return allowed, partyLevel
end

function ExpeditionDifficulty.maxAllowedHazard(players, catalog)
	local levelMax = levelGateMaxHazard(players, catalog)
	local unlockMax = select(1, ExpeditionDifficulty.partyMinHazardUnlock(players, catalog))
	return math.min(levelMax, unlockMax)
end

function ExpeditionDifficulty.maxAllowedBossDifficulty(players, catalog)
	local levelMax = levelGateMaxBoss(players, catalog)
	local unlockMax = select(1, ExpeditionDifficulty.partyMinBossUnlock(players, catalog))
	return math.min(levelMax, unlockMax)
end

--- Returns ok, message, maxAllowed, reason ("ok"|"level"|"unlock"|"team")
function ExpeditionDifficulty.canAttemptHazard(players, catalog, step, requester)
	local H = ExpeditionDifficulty.normalizeHazard(step, catalog)
	local levelMax, partyLevel = levelGateMaxHazard(players, catalog)
	local unlockMax, unlockPlayer, unlockProg = ExpeditionDifficulty.partyMinHazardUnlock(players, catalog)
	local maxAllowed = math.min(levelMax, unlockMax)
	if H <= maxAllowed then
		return true, nil, maxAllowed, "ok"
	end
	if H > levelMax then
		local levels = ExpeditionDifficulty.levelsForHazard(catalog, H)
		return false,
			string.format(
				"Hazard %d requires level %d (party min is %d).",
				H,
				tonumber(levels.levelMin) or 1,
				partyLevel or 1
			),
			maxAllowed,
			"level"
	end
	-- Unlock-bound
	local localUnlock = requester and select(1, ExpeditionDifficulty.getPersonalHazardMax(requester, catalog))
		or unlockMax
	if requester and localUnlock < H and (not unlockPlayer or unlockPlayer:getId() == requester:getId()) then
		local prog = unlockProg or select(2, ExpeditionDifficulty.getPersonalHazardMax(requester, catalog))
		if prog then
			return false,
				string.format(
					"Hazard %d locked — bestiary on %s %d/%d (you unlock %d).",
					H,
					tostring(prog.name or "?"),
					tonumber(prog.kills) or 0,
					tonumber(prog.need) or 0,
					localUnlock
				),
				maxAllowed,
				"unlock"
		end
		return false,
			string.format("Hazard %d locked — bestiary unlock is %d.", H, localUnlock),
			maxAllowed,
			"unlock"
	end
	local name = unlockPlayer and unlockPlayer.getName and unlockPlayer:getName() or "teammate"
	return false,
		string.format(
			"Hazard %d locked for teammate %s (unlocked %d).",
			H,
			name,
			unlockMax
		),
		maxAllowed,
		"team"
end

function ExpeditionDifficulty.canAttemptBossDifficulty(players, catalog, step, requester)
	local D = ExpeditionDifficulty.normalizeBossDifficulty(step, catalog)
	local levelMax, partyLevel = levelGateMaxBoss(players, catalog)
	local unlockMax, unlockPlayer = ExpeditionDifficulty.partyMinBossUnlock(players, catalog)
	local maxAllowed = math.min(levelMax, unlockMax)
	if D <= maxAllowed then
		return true, nil, maxAllowed, "ok"
	end
	if D > levelMax then
		local levels = ExpeditionDifficulty.levelsForBossDifficulty(catalog, D)
		return false,
			string.format(
				"Difficulty %d requires level %d (party min is %d).",
				D,
				tonumber(levels.levelMin) or 1,
				partyLevel or 1
			),
			maxAllowed,
			"level"
	end
	local localUnlock = requester and ExpeditionDifficulty.getPersonalBossMax(requester, catalog) or unlockMax
	if requester and localUnlock < D and (not unlockPlayer or unlockPlayer:getId() == requester:getId()) then
		return false,
			string.format(
				"Difficulty %d locked — clear lower difficulties first (you unlock %d).",
				D,
				localUnlock
			),
			maxAllowed,
			"unlock"
	end
	local name = unlockPlayer and unlockPlayer.getName and unlockPlayer:getName() or "teammate"
	return false,
		string.format(
			"Difficulty %d locked for teammate %s (unlocked %d).",
			D,
			name,
			unlockMax
		),
		maxAllowed,
		"team"
end

local function worldHazardLevelAt(player)
	if not player or not Hazard or not Hazard.getByName then
		return 0
	end
	local pos = player.getPosition and player:getPosition()
	if not pos then
		return 0
	end
	local zones = pos.getZones and pos:getZones()
	if type(zones) ~= "table" then
		return 0
	end
	for _, zone in ipairs(zones) do
		local name = zone.getName and zone:getName()
		local hazard = name and Hazard.getByName(name)
		if hazard and hazard.getPlayerCurrentLevel then
			return tonumber(hazard:getPlayerCurrentLevel(player)) or 0
		end
	end
	return 0
end

function ExpeditionDifficulty.effectiveHazardPoints(session, player)
	local exp = tonumber(session and session.hazardLevel) or 0
	local world = worldHazardLevelAt(player)
	return math.max(exp, world)
end

function ExpeditionDifficulty.applyPlayerPoints(player, session)
	if not player or not player.setHazardSystemPoints then
		return
	end
	local points = 0
	if session and session.role == "monster" then
		points = ExpeditionDifficulty.effectiveHazardPoints(session, player)
	end
	pcall(function()
		player:setHazardSystemPoints(points)
	end)
end

function ExpeditionDifficulty.applySessionPoints(session)
	if not session or not ExpeditionManager or not ExpeditionManager.sessionMemberIds then
		return
	end
	for _, pid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(pid)
		if p then
			ExpeditionDifficulty.applyPlayerPoints(p, session)
		end
	end
end

function ExpeditionDifficulty.flagMonster(monster, session)
	if not monster or not monster.hazard then
		return
	end
	local points = tonumber(session and session.hazardLevel) or 0
	if points <= 0 and session then
		-- Still flag if world hazard may apply via engine; prefer explicit expedition.
		points = ExpeditionDifficulty.effectiveHazardPoints(session, nil)
	end
	if points <= 0 then
		return
	end
	pcall(function()
		monster:hazard(true)
		monster:hazardCrit(true)
		monster:hazardDodge(true)
		monster:hazardDamageBoost(true)
		monster:hazardDefenseBoost(true)
	end)
end

function ExpeditionDifficulty.bossScaleMults(difficulty, catalog)
	local levels = ExpeditionDifficulty.levelsForBossDifficulty(catalog, difficulty)
	return tonumber(levels.hpMult) or 1, tonumber(levels.dmgMult) or 1
end

function ExpeditionDifficulty.applyBossScale(monster, session)
	if not monster or not session or session.role ~= "boss" then
		return
	end
	local D = tonumber(session.bossDifficulty) or 0
	if D <= 0 then
		return
	end
	local hpMult, dmgMult = ExpeditionDifficulty.bossScaleMults(D, session.catalog)
	if (hpMult <= 1 and dmgMult <= 1) then
		return
	end
	pcall(function()
		if monster.scaleCombat then
			monster:scaleCombat(hpMult, dmgMult)
			return
		end
		if hpMult > 1 then
			local maxHp = monster:getMaxHealth()
			local newMax = math.max(1, math.floor(maxHp * hpMult))
			if monster.setMaxHealth then
				monster:setMaxHealth(newMax)
			end
			if monster.setHealth then
				monster:setHealth(newMax)
			end
		end
	end)
end

function ExpeditionDifficulty.getPersonalBossMax(player, catalog)
	local hi = catalogBossDiffMax(catalog)
	local fallback = ExpeditionDifficulty.BOSS_DIFF_DEFAULT
	if not player or not catalog then
		return fallback
	end
	-- Fail closed: missing KV must not advertise the catalog max (was returning hi → spinner 0..25).
	local ok, unlocked = pcall(function()
		local scoped = player:kv():scoped(ExpeditionDifficulty.KV_BOSS_DIFF)
		local raceId = tonumber(catalog.creatureId) or tonumber(catalog.id) or 0
		return tonumber(scoped:get(tostring(raceId))) or ExpeditionDifficulty.BOSS_DIFF_DEFAULT
	end)
	if not ok or unlocked == nil then
		return fallback
	end
	if unlocked < ExpeditionDifficulty.BOSS_DIFF_DEFAULT then
		unlocked = ExpeditionDifficulty.BOSS_DIFF_DEFAULT
	end
	return math.min(hi, math.max(ExpeditionDifficulty.BOSS_DIFF_DEFAULT, math.floor(unlocked)))
end

function ExpeditionDifficulty.unlockBossDifficulty(player, catalog, difficulty)
	if not player or not catalog then
		return
	end
	local D = ExpeditionDifficulty.normalizeBossDifficulty(difficulty, catalog)
	local raceId = tonumber(catalog.creatureId) or tonumber(catalog.id) or 0
	local scoped = player:kv():scoped(ExpeditionDifficulty.KV_BOSS_DIFF)
	local cur = tonumber(scoped:get(tostring(raceId))) or ExpeditionDifficulty.BOSS_DIFF_DEFAULT
	if D >= cur and D < catalogBossDiffMax(catalog) then
		scoped:set(tostring(raceId), math.min(catalogBossDiffMax(catalog), D + 1))
	elseif D > cur then
		scoped:set(tostring(raceId), D)
	end
end

function ExpeditionDifficulty.setPendingBoss(playerId, pending)
	pendingBossByPlayerId[playerId] = pending
end

function ExpeditionDifficulty.getPendingBoss(playerId)
	return pendingBossByPlayerId[playerId]
end

function ExpeditionDifficulty.clearPendingBoss(playerId)
	pendingBossByPlayerId[playerId] = nil
end

function ExpeditionDifficulty.redGreenMods(catalog, difficulty)
	local levels = ExpeditionDifficulty.levelsForBossDifficulty(catalog, difficulty)
	local red = {
		string.format("Required level: %d", tonumber(levels.levelMin) or 1),
		string.format("Boss HP +%d%%", math.floor(((tonumber(levels.hpMult) or 1) - 1) * 100)),
		string.format("Boss damage +%d%%", math.floor(((tonumber(levels.dmgMult) or 1) - 1) * 100)),
	}
	local green = {
		string.format("Combat power: %.0f", tonumber(levels.combatPower) or 0),
	}
	return red, green
end
