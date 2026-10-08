-- Automation movement, the expedition anchor's halt tile and melee stance.

local geo = CombatGeo
local chebyshev = geo.chebyshev
local bossFronts, sightClear, inBossFront, BOSS_FRONT_PENALTY = MOVE_PRIV.bossFronts, MOVE_PRIV.sightClear, MOVE_PRIV.inBossFront, MOVE_PRIV.BOSS_FRONT_PENALTY
local dodgeBossFront = MOVE_PRIV.dodgeBossFront

-- ---------------------------------------------------------------------------
-- Expedition anchor halt tile: the shared terrain score (AnchorSpot, also used by
-- hunt generation to place the holds), with boss fronts on top.
-- ---------------------------------------------------------------------------

--- Slot distance a member keeps from the anchor: stance distance + 1 (melee 2, right
--- outside the monster box; ranged d + 1, see `memberTileScore`).
local function slotDistanceOf(config)
	return CombatAutomationConfig.stanceDistanceOf(config) + 1
end

function CombatAutomationMovement.memberSlotDistance(player)
	return slotDistanceOf(player and CombatAutomationStore.getConfig(player))
end

--- Fights from range (stance distance above melee).
function CombatAutomationMovement.rangedStance(player)
	local config = player and CombatAutomationStore.getConfig(player)
	return CombatAutomationConfig.stanceDistanceOf(config) > 1
end

--- Expedition halt tile: the best `AnchorSpot` tile within `steps` walking steps (over
--- standable ground; a blocked walk repicks) of `center`, less BOSS_FRONT_PENALTY in a
--- boss front. `opts`: center (Position, default the anchor), steps, team
--- ({ { id, slotDist }, ... }), exclude (set of `CombatGeo.tileKey` keys that failed
--- to path), avoidMonsters (never pick or walk through a tile a monster stands on; the
--- ring still counts it). Returns pos, score, ring, unserved.
function CombatAutomationMovement.bestAnchorSpot(anchor, opts)
	opts = opts or {}
	local center = opts.center or (anchor and anchor:getPosition())
	if not center then
		return nil
	end
	local z = center.z
	local instanceId = anchor and anchor:getInstanceId()
	local bosses = bossFronts(anchor)
	local team = {}
	for _, entry in ipairs(opts.team or {}) do
		team[#team + 1] = entry.slotDist
	end
	local ctx = AnchorSpot.context({
		standable = function(x, y)
			return geo.tileStandable(Position(x, y, z), instanceId) ~= nil
		end,
		sightClear = function(x, y, tx, ty)
			return sightClear(anchor, Position(x, y, z), Position(tx, ty, z))
		end,
		adjust = bosses[1] and function(x, y)
			return inBossFront(anchor, Position(x, y, z), bosses) and -BOSS_FRONT_PENALTY or 0
		end or nil,
		passable = opts.avoidMonsters and function(x, y)
			local tile = Tile(Position(x, y, z))
			local top = tile and tile:getTopCreature(instanceId)
			return not (top and top:isMonster())
		end or nil,
	}, team)
	local x, y, score, ring, unserved = AnchorSpot.best(ctx, center.x, center.y, opts.steps or 0, opts.exclude)
	if not x then
		return nil
	end
	return Position(x, y, z), score, ring, unserved
end

local function isExpeditionAnchor(state)
	local directive = state and state.directive
	return directive ~= nil and directive.kind == "hold"
end

--- Engine follow tracks a moving target well until adjacent.
local function followTarget(player, target)
	local follow = player:getFollowCreature()
	if not follow or follow:getId() ~= target:getId() then
		player:setFollowCreature(target)
	end
end

local function anchorMeleeStance(player, target, state)
	if chebyshev(player:getPosition(), target:getPosition()) <= 1 then
		dodgeBossFront(player, target, state)
		return
	end
	followTarget(player, target)
end

--- Melee anchor holding a halt tile with its target adjacent: only a boss dodge moves
--- it (no chasing while luring).
local function haltStep(player, target, config, state)
	return CombatAutomationConfig.stanceDistanceOf(config) <= 1
		and chebyshev(player:getPosition(), target:getPosition()) <= 1
		and dodgeBossFront(player, target, state)
end


MOVE_PRIV.followTarget = followTarget
MOVE_PRIV.slotDistanceOf = slotDistanceOf
MOVE_PRIV.isExpeditionAnchor = isExpeditionAnchor
MOVE_PRIV.anchorMeleeStance = anchorMeleeStance
MOVE_PRIV.haltStep = haltStep
