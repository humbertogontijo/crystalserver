-- Hazard trait transforms + pack/boss level helpers (pure; inject hazardConfig).
CreatureInfo = CreatureInfo or {}

local EPS = 1e-6

--- Default mirrors config.lua.dist HAZARD_* keys (camelCase for Lua tables).
CreatureInfo.DEFAULT_HAZARD_CONFIG = {
	criticalChance = 750, -- /10000
	criticalInterval = 2000, -- ms (informational for expected model)
	criticalMultiplier = 25, -- stage per (points-1), /10000 with base 5000
	damageMultiplier = 200, -- points * mult / 10000 added to damage
	defenseMultiplier = 0, -- points * mult / 10000 player damage reduction
	dodgeMultiplier = 85, -- points * mult / 10000 dodge chance
}

local function copyTraits(traits)
	local out = {}
	if type(traits) ~= "table" then
		return out
	end
	for k, v in pairs(traits) do
		out[k] = v
	end
	return out
end

local function mergeHazardConfig(hazardConfig)
	local cfg = {}
	for k, v in pairs(CreatureInfo.DEFAULT_HAZARD_CONFIG) do
		cfg[k] = v
	end
	if type(hazardConfig) == "table" then
		for k, v in pairs(hazardConfig) do
			if type(v) == "number" then
				cfg[k] = v
			end
		end
	end
	return cfg
end

--- Expected crit damage factor vs non-crit hit (C++: crit adds (5000+stage)/10000 of base).
--- Crit chance = criticalChance/10000; ignore interval for steady-state expectation.
local function expectedCritFactor(points, cfg)
	points = math.max(0, math.floor(tonumber(points) or 0))
	if points <= 0 then
		return 1
	end
	local pCrit = math.min(1, (tonumber(cfg.criticalChance) or 0) / 10000)
	local stage = (points - 1) * (tonumber(cfg.criticalMultiplier) or 0)
	local critExtra = (5000 + stage) / 10000
	-- E[mult] = (1-p) * 1 + p * (1 + critExtra) = 1 + p * critExtra
	return 1 + pCrit * critExtra
end

--- Apply engine hazard combat effects onto traits for CP estimation.
function CreatureInfo.applyHazardToTraits(traits, points, hazardConfig)
	local out = copyTraits(traits)
	points = math.max(0, math.floor(tonumber(points) or 0))
	if points <= 0 then
		return out
	end
	local cfg = mergeHazardConfig(hazardConfig)

	local dps = tonumber(out.expectedDps) or tonumber(out.expected_dps) or 0
	local dmgBoost = points * (tonumber(cfg.damageMultiplier) or 0) / 10000
	local critF = expectedCritFactor(points, cfg)
	out.expectedDps = dps * (1 + dmgBoost) * critF

	local hp = tonumber(out.hp) or tonumber(out.health) or 0
	local dodgeP = math.min(0.95, points * (tonumber(cfg.dodgeMultiplier) or 0) / 10000)
	local defFrac = math.min(0.95, points * (tonumber(cfg.defenseMultiplier) or 0) / 10000)
	local denom = math.max(EPS, 1 - dodgeP) * math.max(EPS, 1 - defFrac)
	out.hp = hp / denom
	out.health = out.hp

	return out
end

--- Read live Crystal config when available; else defaults.
function CreatureInfo.hazardConfigFromServer()
	local cfg = mergeHazardConfig(nil)
	if not configManager or not configKeys then
		return cfg
	end
	local function num(key, fallback)
		local ok, value = pcall(function()
			return configManager.getNumber(key)
		end)
		if ok and type(value) == "number" then
			return value
		end
		return fallback
	end
	cfg.criticalChance = num(configKeys.HAZARD_CRITICAL_CHANCE, cfg.criticalChance)
	cfg.criticalInterval = num(configKeys.HAZARD_CRITICAL_INTERVAL, cfg.criticalInterval)
	cfg.criticalMultiplier = num(configKeys.HAZARD_CRITICAL_MULTIPLIER, cfg.criticalMultiplier)
	cfg.damageMultiplier = num(configKeys.HAZARD_DAMAGE_MULTIPLIER, cfg.damageMultiplier)
	cfg.defenseMultiplier = num(configKeys.HAZARD_DEFENSE_MULTIPLIER, cfg.defenseMultiplier)
	cfg.dodgeMultiplier = num(configKeys.HAZARD_DODGE_MULTIPLIER, cfg.dodgeMultiplier)
	return cfg
end

local function traitsFromInfo(info)
	if type(info) ~= "table" then
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
		softCapHp = info.softCapHp == true,
	}
end

--- Pack CP + levels after applying hazard points to each creature's traits.
function CreatureInfo.levelsForHazardPack(creatures, creatureDensity, points, hazardConfig)
	if type(creatures) ~= "table" then
		return nil
	end
	points = math.max(0, math.floor(tonumber(points) or 0))
	local cfg = mergeHazardConfig(hazardConfig)
	local dens = tonumber(creatureDensity) or 1
	local mix = {}
	for i, row in ipairs(creatures) do
		local id = row and tonumber(row.creatureId)
		local info = id and CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(id) or nil
		local traits = traitsFromInfo(info)
		if not traits and row then
			traits = {
				hp = tonumber(row.hp) or 0,
				expectedDps = tonumber(row.expectedDps) or 0,
				expectedHealDps = tonumber(row.expectedHealDps) or 0,
				armor = tonumber(row.armor) or 0,
				defense = tonumber(row.defense) or 0,
				mitigation = tonumber(row.mitigation) or 0,
				meanElementPercent = tonumber(row.meanElementPercent) or 0,
				speed = tonumber(row.speed) or 0,
				softCapHp = row.softCapHp == true,
			}
		end
		local power = 0
		if traits and (tonumber(traits.expectedDps) or 0) > 0 then
			local scaled = CreatureInfo.applyHazardToTraits(traits, points, cfg)
			power = CreatureInfo.computeCombatPower(scaled)
		else
			power = tonumber(row and row.combatPower) or (info and tonumber(info.combatPower)) or 0
			-- Fallback: cannot recompute; approximate with damage-only multiplier.
			if points > 0 and power > 0 then
				local dmgBoost = points * (cfg.damageMultiplier or 0) / 10000
				power = power * (1 + dmgBoost) * expectedCritFactor(points, cfg)
			end
		end
		mix[i] = {
			creatureId = id,
			percent = row and tonumber(row.percent) or 0,
			count = row and tonumber(row.count),
			combatPower = power,
		}
	end
	local packCp = CreatureInfo.huntCombatPowerFromMix(mix, dens)
	if packCp <= 0 then
		return nil
	end
	local levels = CreatureInfo.huntLevelsFromPackCombatPower(packCp)
	levels.combatPower = CreatureInfo.roundCombatPower(packCp)
	return levels
end

--- Boss difficulty scale: hpMult / dmgMult applied to traits, then boss level curve.
function CreatureInfo.levelsForBossDifficulty(traits, difficulty, bossScale)
	difficulty = math.max(0, math.floor(tonumber(difficulty) or 0))
	bossScale = type(bossScale) == "table" and bossScale or {}
	local hpPer = tonumber(bossScale.hpPerLevel) or 0.04
	local dmgPer = tonumber(bossScale.dmgPerLevel) or 0.03
	local scaled = copyTraits(traits)
	local hp = tonumber(scaled.hp) or tonumber(scaled.health) or 0
	local dps = tonumber(scaled.expectedDps) or 0
	scaled.hp = hp * (1 + difficulty * hpPer)
	scaled.health = scaled.hp
	scaled.expectedDps = dps * (1 + difficulty * dmgPer)
	scaled.softCapHp = true
	local cp = CreatureInfo.computeCombatPower(scaled)
	if cp <= 0 then
		return {
			combatPower = 0,
			levelMin = 1,
			recommendedLevel = 1,
			hpMult = 1 + difficulty * hpPer,
			dmgMult = 1 + difficulty * dmgPer,
		}
	end
	local levels = CreatureInfo.levelsFromCombatPower(cp, false)
	levels.combatPower = CreatureInfo.roundCombatPower(cp)
	levels.hpMult = 1 + difficulty * hpPer
	levels.dmgMult = 1 + difficulty * dmgPer
	return levels
end
