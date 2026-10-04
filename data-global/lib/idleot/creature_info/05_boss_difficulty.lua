-- Boss difficulty level helpers (pure).
CreatureInfo = CreatureInfo or {}

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
