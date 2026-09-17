-- Shared CP → level map for creatures, hunt packs, bosses, and raids.
-- Player formula: recommended ≈ 1.5 × CP^0.6 ; levelMin ≈ recommended × 0.6
-- Constants synced from hunt_level_fit_generated.py via `make optimize`.
CreatureInfo = CreatureInfo or {}

local MONSTER_LEVEL_STEP = 5
local MONSTER_LEVEL_COEF = 1.5
local MONSTER_LEVEL_EXP = 0.6
local PARTY_LEVEL_RATIO = 0.6
--- Pack: Σ CP_i × n_i^HUNT_DENSITY_EXP
local HUNT_DENSITY_EXP = 0.75

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

local function rawLevelFromCombatPower(combatPower)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	return MONSTER_LEVEL_COEF * (combatPower ^ MONSTER_LEVEL_EXP)
end

local function levelFromCombatPower(combatPower)
	local raw = rawLevelFromCombatPower(combatPower)
	return roundLevelToStep(raw, monsterLevelStepForRaw(raw))
end

local function recommendedLevelFromCombatPower(combatPower)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	return levelFromCombatPower(combatPower)
end

local function levelMinFromCombatPower(combatPower)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	local recommended = recommendedLevelFromCombatPower(combatPower)
	local partyRaw = recommended * PARTY_LEVEL_RATIO
	local party = roundLevelToStep(partyRaw, monsterLevelStepForRaw(partyRaw))
	return math.max(1, math.min(recommended, party))
end

--- One meaning everywhere: recommended from CP; levelMin = recommended × partyRatio.
function CreatureInfo.levelsFromCombatPower(combatPower)
	local recommendedLevel = recommendedLevelFromCombatPower(combatPower)
	local levelMin = levelMinFromCombatPower(combatPower)
	return {
		levelMin = math.min(levelMin, recommendedLevel),
		recommendedLevel = recommendedLevel,
	}
end

function CreatureInfo.huntLevelsFromPackCombatPower(packCombatPower)
	return CreatureInfo.levelsFromCombatPower(packCombatPower)
end

function CreatureInfo.huntDensityExp()
	return HUNT_DENSITY_EXP
end
