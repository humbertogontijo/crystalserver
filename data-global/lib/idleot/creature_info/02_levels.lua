-- CP → level maps. Creatures, bosses, raids: recommended ≈ 1.5 × CP^0.6.
-- Hunts: recommended ≈ (1 + (S − HUNT_LEVEL_REF_POWER) / HUNT_LEVEL_SCALE)^HUNT_LEVEL_EXP
-- with S the mix-weighted mean creature CP.
-- levelMin ≈ recommended × 0.6 for both.
-- HUNT_LEVEL_* are refit against TibiaWiki recommended hunt levels by `make generate`.
CreatureInfo = CreatureInfo or {}

local MONSTER_LEVEL_STEP = 5
local MONSTER_LEVEL_COEF = 1.5
local MONSTER_LEVEL_EXP = 0.6
local PARTY_LEVEL_RATIO = 0.6
local HUNT_LEVEL_REF_POWER = 0
local HUNT_LEVEL_SCALE = 0.55
local HUNT_LEVEL_EXP = 0.748
--- Pack: (Σ share_i × CP_i) × density^HUNT_DENSITY_EXP
local HUNT_DENSITY_EXP = 0

local function roundLevelToStep(level, step)
	level = tonumber(level) or 1
	step = tonumber(step) or 1
	if level <= 0 then
		return 1
	end
	if step <= 0 then
		return math.max(1, math.floor(level + 0.5))
	end
	return math.max(1, math.floor((level / step) + 0.5) * step)
end

local function monsterLevelStepForRaw(rawLevel)
	rawLevel = tonumber(rawLevel) or 1
	if rawLevel < 20 then
		return 1
	end
	return MONSTER_LEVEL_STEP
end

local function levelsFromRaw(raw)
	raw = math.max(1, raw)
	local recommended = roundLevelToStep(raw, monsterLevelStepForRaw(raw))
	local partyRaw = recommended * PARTY_LEVEL_RATIO
	local party = roundLevelToStep(partyRaw, monsterLevelStepForRaw(partyRaw))
	return {
		levelMin = math.max(1, math.min(recommended, party)),
		recommendedLevel = recommended,
	}
end

--- Creatures, bosses, raids: recommended from CP; levelMin = recommended × partyRatio.
function CreatureInfo.levelsFromCombatPower(combatPower)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return { levelMin = 1, recommendedLevel = 1 }
	end
	return levelsFromRaw(MONSTER_LEVEL_COEF * (combatPower ^ MONSTER_LEVEL_EXP))
end

--- Hunts: packCombatPower from huntCombatPowerFromMix (mean creature CP).
function CreatureInfo.huntLevelsFromPackCombatPower(packCombatPower)
	local above = math.max(0, (tonumber(packCombatPower) or 0) - HUNT_LEVEL_REF_POWER)
	return levelsFromRaw((1 + above / HUNT_LEVEL_SCALE) ^ HUNT_LEVEL_EXP)
end

function CreatureInfo.huntDensityExp()
	return HUNT_DENSITY_EXP
end
