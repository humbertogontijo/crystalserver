-- Pure combat-power formula (no Crystal globals).
-- Runtime SoT: C++ computeCombatPowerFromTraits / MonsterType::getCombatPower.
-- This file remains the offline lupa mirror + custom-weight fit path.
CreatureInfo = CreatureInfo or {}

local CP_RESIST_TAKEN_FLOOR = 0.03

-- Defaults; HUNT_LEVEL_FIT weights from 02_levels densityExp / optimize sync.
local DEFAULT_WEIGHTS = {
	health = 1,
	heal = 1,
	armor = 0.98,
	mitigation = 0.76,
	resist = 0.99,
	dps = 0.82,
	speed = 0.97,
	healRef = 100,
	armorScale = 80,
	speedRef = 200,
	densityExp = 0,
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

--- traits: { hp|health, expectedDps, expectedHealDps, armor, defense, mitigation,
---           meanElementPercent, speed }
--- Runtime SoT is C++ computeCombatPowerFromTraits (Game.computeCombatPowerFromTraits).
--- Offline lupa / custom weight fits still use the local product below (must match C++ defaults).
function CreatureInfo.computeCombatPower(traits, weights)
	if type(traits) ~= "table" then
		return 0
	end
	local dps = math.max(0, tonumber(traits.expectedDps) or tonumber(traits.expected_dps) or 0)
	if dps <= 0 then
		return 0
	end

	-- Prefer engine SoT when weights are default (nil) and binding exists.
	if weights == nil and Game and Game.computeCombatPowerFromTraits then
		return tonumber(Game.computeCombatPowerFromTraits(traits)) or 0
	end

	local w = resolveWeights(weights)
	local health = tonumber(traits.hp) or tonumber(traits.health) or 0
	local healDps = tonumber(traits.expectedHealDps) or tonumber(traits.expected_heal_dps) or 0
	local armor = tonumber(traits.armor) or 0
	local defense = tonumber(traits.defense) or 0
	local mitigation = tonumber(traits.mitigation) or 0
	local meanEl = tonumber(traits.meanElementPercent) or tonumber(traits.mean_element_percent) or 0
	local speed = tonumber(traits.speed) or 0

	local hp = math.max(1, health)
	-- Saturating heal: 1 + h/(h+ref) ∈ (1, 2). Matches C++ computeCombatPowerFromTraits.
	local healFactor = 1
	if healDps > 0 and w.healRef and w.healRef > 0 then
		healFactor = 1 + healDps / (healDps + w.healRef)
	end
	local bestArmor = math.max(math.max(0, armor), math.max(0, defense))
	local armorFactor = 1 + bestArmor / math.max(1e-6, w.armorScale)
	local mit = mitigationToughnessFactor(mitigation)
	local resist = resistTakenFactor(meanEl)
	local speedFactor = speedDpsFactor(speed, w.speedRef)

	local prod = powTerm(hp, w.health)
		* powTerm(healFactor, w.heal)
		* powTerm(armorFactor, w.armor)
		* powTerm(mit, w.mitigation)
		* powTerm(resist, w.resist)
		* powTerm(dps, w.dps)
		* powTerm(speedFactor, w.speed)
	return math.sqrt(prod)
end

--- Round like asset-pipeline round_combat_power (2 decimals).
function CreatureInfo.roundCombatPower(value)
	value = tonumber(value) or 0
	if value <= 0 then
		return 0
	end
	return math.floor(value * 100 + 0.5) / 100
end

--- Resolve Monster / MonsterType / name / creatureId to runtime combat power.
function CreatureInfo.getCombatPower(ref)
	if ref == nil then
		return 0
	end
	if type(ref) == "userdata" then
		if ref.getCombatPower then
			return CreatureInfo.roundCombatPower(ref:getCombatPower() or 0)
		end
		if ref.getType then
			local mType = ref:getType()
			if mType and mType.getCombatPower then
				return CreatureInfo.roundCombatPower(mType:getCombatPower() or 0)
			end
		end
		return 0
	end
	if type(ref) == "number" then
		local mType = MonsterType and MonsterType(ref) or nil
		if mType and mType.getCombatPower then
			return CreatureInfo.roundCombatPower(mType:getCombatPower() or 0)
		end
		local info = CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(ref)
		if info and info.name and MonsterType then
			mType = MonsterType(info.name)
			if mType and mType.getCombatPower then
				return CreatureInfo.roundCombatPower(mType:getCombatPower() or 0)
			end
		end
		return 0
	end
	if type(ref) == "string" then
		local mType = MonsterType and MonsterType(ref) or nil
		if mType and mType.getCombatPower then
			return CreatureInfo.roundCombatPower(mType:getCombatPower() or 0)
		end
	end
	return 0
end
