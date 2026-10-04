-- Expedition boss difficulty (instance-scoped).
ExpeditionDifficulty = ExpeditionDifficulty or {}

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

local function catalogBossDiffMax(catalog)
	local max = tonumber(catalog and catalog.bossDifficultyMax) or ExpeditionDifficulty.BOSS_DIFF_MAX
	return math.max(
		ExpeditionDifficulty.BOSS_DIFF_MIN,
		math.min(ExpeditionDifficulty.BOSS_DIFF_MAX, math.floor(max))
	)
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

function ExpeditionDifficulty.maxAllowedBossDifficulty(players, catalog)
	local levelMax = levelGateMaxBoss(players, catalog)
	local unlockMax = select(1, ExpeditionDifficulty.partyMinBossUnlock(players, catalog))
	return math.min(levelMax, unlockMax)
end

--- Returns ok, message, maxAllowed, reason ("ok"|"level"|"unlock"|"team")
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
