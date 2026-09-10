-- Mirrors packages/asset-pipeline/src/expedition/domain/hunt-levels.ts (+ hunt-level-fit.generated.ts).
CreatureInfo = CreatureInfo or {}

local BOSS_LEVEL_OFFSET = -545
local BOSS_LEVEL_LOG_COEF = 80
local BOSS_LEVEL_CP_KNEE = 100000
local BOSS_LEVEL_LOG_COEF_HI = 120
local BOSS_LEVEL_STEP = 25

local MONSTER_LEVEL_STEP = 5
local MONSTER_LEVEL_COEF = 0.64586146108913
local MONSTER_LEVEL_EXP = 0.7488898225301996
local PARTY_LEVEL_RATIO = 0.6
--- Pack: Σ CP_i × n_i^HUNT_DENSITY_EXP (n_i = viewport count of creature i).
local HUNT_DENSITY_EXP = 0.6451901942271987

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

local function bossLevelFromCombatPower(combatPower)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	local ln = math.log(combatPower)
	if combatPower <= BOSS_LEVEL_CP_KNEE then
		return roundLevelToStep(BOSS_LEVEL_OFFSET + BOSS_LEVEL_LOG_COEF * ln, BOSS_LEVEL_STEP)
	end
	local lnKnee = math.log(BOSS_LEVEL_CP_KNEE)
	local atKnee = BOSS_LEVEL_OFFSET + BOSS_LEVEL_LOG_COEF * lnKnee
	return roundLevelToStep(atKnee + BOSS_LEVEL_LOG_COEF_HI * (ln - lnKnee), BOSS_LEVEL_STEP)
end

--- One power-law for creatures and hunt packs.
local function rawMonsterLevelFromCombatPower(combatPower)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	return MONSTER_LEVEL_COEF * (combatPower ^ MONSTER_LEVEL_EXP)
end

local function monsterLevelFromCombatPower(combatPower)
	local raw = rawMonsterLevelFromCombatPower(combatPower)
	return roundLevelToStep(raw, monsterLevelStepForRaw(raw))
end

local function recommendedLevelFromCombatPower(combatPower, isMonster)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	if isMonster then
		return monsterLevelFromCombatPower(combatPower)
	end
	return bossLevelFromCombatPower(combatPower)
end

local function levelMinFromCombatPower(combatPower, isMonster)
	combatPower = tonumber(combatPower) or 0
	if combatPower <= 0 then
		return 1
	end
	if not isMonster then
		return recommendedLevelFromCombatPower(combatPower, false)
	end
	local recommended = recommendedLevelFromCombatPower(combatPower, true)
	local partyRaw = recommended * PARTY_LEVEL_RATIO
	-- Step from the party value, not rec — otherwise rec 19→min 11 and rec 20→min 10.
	local party = roundLevelToStep(partyRaw, monsterLevelStepForRaw(partyRaw))
	return math.max(1, math.min(recommended, party))
end

--- Same curves as asset-pipeline levelsFromCombatPower(combatPower, isMonster).
function CreatureInfo.levelsFromCombatPower(combatPower, isMonster)
	local recommendedLevel = recommendedLevelFromCombatPower(combatPower, isMonster)
	local levelMin = levelMinFromCombatPower(combatPower, isMonster)
	return {
		levelMin = math.min(levelMin, recommendedLevel),
		recommendedLevel = recommendedLevel,
	}
end

--- Expedition hunt levels from viewport pack combat power (same power-law).
function CreatureInfo.huntLevelsFromPackCombatPower(packCombatPower)
	return CreatureInfo.levelsFromCombatPower(packCombatPower, true)
end

function CreatureInfo.huntDensityExp()
	return HUNT_DENSITY_EXP
end
