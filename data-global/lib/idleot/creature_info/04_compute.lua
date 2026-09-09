-- Pure combat-power formula (no Crystal globals).
-- Mirrors packages/asset-pipeline crystal_monsters.compute_combat_power + weights.
CreatureInfo = CreatureInfo or {}

local CP_HP_SOFT_START = 80000
local CP_HP_SOFT_CAP = 30000
local CP_RESIST_TAKEN_FLOOR = 0.03

-- Defaults; HUNT_LEVEL_FIT weights from 02_levels densityExp / optimize sync.
local DEFAULT_WEIGHTS = {
	health = 1,
	armor = 0.980019587864914,
	mitigation = 0.7641856861632816,
	resist = 0.9941757884773436,
	dps = 0.81632397618286,
	speed = 0.9736514467958334,
	healRef = 100.2979895210889,
	armorScale = 80,
	speedRef = 200,
	densityExp = 0.6637017678242599,
}

local function resolveWeights(weights)
	local w = {}
	for k, v in pairs(DEFAULT_WEIGHTS) do
		w[k] = v
	end
	if type(weights) == "table" then
		for k, v in pairs(weights) do
			if type(v) == "number" then
				w[k] = v
			end
		end
	end
	-- Prefer live densityExp from 02_levels when present.
	if CreatureInfo.huntDensityExp then
		w.densityExp = tonumber(CreatureInfo.huntDensityExp()) or w.densityExp
	end
	return w
end

local function powTerm(value, weight)
	if not (weight and weight > 0) then
		return 1
	end
	if not (value and value > 0) then
		return 0
	end
	return value ^ weight
end

local function softCap(value, cap)
	if not (cap and cap > 0) or not (value and value > 0) then
		return math.max(0, value or 0)
	end
	return (value * cap) / (value + cap)
end

local function softCapHealthAbove(health)
	local hp = math.max(1, health or 1)
	if hp <= CP_HP_SOFT_START then
		return hp
	end
	return CP_HP_SOFT_START + softCap(hp - CP_HP_SOFT_START, CP_HP_SOFT_CAP)
end

local function mitigationToughnessFactor(mitigation)
	mitigation = tonumber(mitigation) or 0
	if not (mitigation > 0) then
		return 1
	end
	if mitigation < 1 then
		local taken = math.max(0.05, 1 - mitigation)
		return 1 / taken
	end
	return mitigation
end

local function resistTakenFactor(meanElementPercent)
	local taken = math.max(CP_RESIST_TAKEN_FLOOR, 1 - (tonumber(meanElementPercent) or 0) / 100)
	return 1 / taken
end

local function speedDpsFactor(speed, ref)
	speed = tonumber(speed) or 0
	ref = tonumber(ref) or 0
	if not (speed > 0) or not (ref > 0) then
		return 1
	end
	return math.sqrt(speed / ref)
end

local function healthWithHealing(health, expectedHealDps, healRef)
	local hp = math.max(1, health or 1)
	expectedHealDps = tonumber(expectedHealDps) or 0
	healRef = tonumber(healRef) or 0
	if not (expectedHealDps > 0) or not (healRef > 0) then
		return hp
	end
	return hp * (1 + expectedHealDps / healRef)
end

--- traits: { hp|health, expectedDps, expectedHealDps, armor, defense, mitigation,
---           meanElementPercent, speed, softCapHp }
function CreatureInfo.computeCombatPower(traits, weights)
	if type(traits) ~= "table" then
		return 0
	end
	local dps = math.max(0, tonumber(traits.expectedDps) or tonumber(traits.expected_dps) or 0)
	if dps <= 0 then
		return 0
	end

	local w = resolveWeights(weights)
	local health = tonumber(traits.hp) or tonumber(traits.health) or 0
	local healDps = tonumber(traits.expectedHealDps) or tonumber(traits.expected_heal_dps) or 0
	local armor = tonumber(traits.armor) or 0
	local defense = tonumber(traits.defense) or 0
	local mitigation = tonumber(traits.mitigation) or 0
	local meanEl = tonumber(traits.meanElementPercent) or tonumber(traits.mean_element_percent) or 0
	local speed = tonumber(traits.speed) or 0
	local softCapHp = traits.softCapHp == true or traits.soft_cap_hp == true

	local rawHp = healthWithHealing(math.max(1, health), healDps, w.healRef)
	local hp = softCapHp and softCapHealthAbove(rawHp) or rawHp
	local bestArmor = math.max(math.max(0, armor), math.max(0, defense))
	local armorFactor = 1 + bestArmor / math.max(1e-6, w.armorScale)
	local mit = mitigationToughnessFactor(mitigation)
	local resist = resistTakenFactor(meanEl)
	local speedFactor = speedDpsFactor(speed, w.speedRef)

	local prod = powTerm(hp, w.health)
		* powTerm(armorFactor, w.armor)
		* powTerm(mit, w.mitigation)
		* powTerm(resist, w.resist)
		* powTerm(dps, w.dps)
		* powTerm(speedFactor, w.speed)
	return math.sqrt(prod)
end

function CreatureInfo.defaultCombatPowerWeights()
	return resolveWeights(nil)
end

--- Round like asset-pipeline round_combat_power (2 decimals).
function CreatureInfo.roundCombatPower(value)
	value = tonumber(value) or 0
	if value <= 0 then
		return 0
	end
	return math.floor(value * 100 + 0.5) / 100
end
