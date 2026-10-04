-- Knight challenge helpers shared by Challenge (exeta res) and Chivalrous Challenge (exeta amp res).

KnightChallenge = KnightChallenge or {}

KnightChallenge.WHEEL_SPELL = "Chivalrous Challenge"
KnightChallenge.BASE_TARGETS = 4
KnightChallenge.CHAIN_DISTANCE = 7
KnightChallenge.CHALLENGE_DURATION_MS = 6000

function KnightChallenge.chainTargets(creature)
	local targets = KnightChallenge.BASE_TARGETS
	local player = creature and creature:getPlayer()
	if player then
		targets = targets + player:getWheelSpellAdditionalTarget(KnightChallenge.WHEEL_SPELL)
	end
	return targets
end

--- True while the monster keeps distance: ranged by type and not turned melee by Chivalrous Challenge.
function KnightChallenge.isCurrentlyRanged(monster)
	return monster:getTargetDistance() > 1
end

local STILL_RANGED_PRIORITY = 100

--- Chain picker priority for wild, non-boss monsters: their distance from the caster, so the
--- engine (highest priority per hop) reaches the farthest first. 0 rejects.
--- opts.rangedOnly rejects melee monsters and ranks those not yet turned melee above the rest;
--- opts.skipAdjacent rejects monsters next to the caster.
function KnightChallenge.chainPriority(creature, target, opts)
	opts = opts or {}
	if not target:isMonster() or target:getMaster() ~= nil then
		return 0
	end
	local monsterType = target:getType()
	if not monsterType or monsterType:isRewardBoss() then
		return 0
	end
	if opts.rangedOnly and monsterType:getTargetDistance() <= 1 then
		return 0
	end

	local distance = CombatGeo.chebyshev(creature:getPosition(), target:getPosition())
	if opts.skipAdjacent and distance <= 1 then
		return 0
	end
	if opts.rangedOnly and KnightChallenge.isCurrentlyRanged(target) then
		return distance + 1 + STILL_RANGED_PRIORITY
	end
	return distance + 1
end

--- True when at least one of the 8 tiles around the creature is free.
function KnightChallenge.hasRoomAround(creature)
	return CombatGeo.freeNeighbourCount(creature:getPosition(), nil, creature:getInstanceId()) > 0
end
