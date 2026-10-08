-- One engine call per tick for the spatial work of combat automation and formations
-- (Game.scanMonsters / Game.tileMask); Lua keeps the scoring policy. Engine-only: the
-- asset pipeline loads 04_geo.lua but not this file.

CombatGeo.MASK_STANDABLE = 1
CombatGeo.MASK_FREE = 2
CombatGeo.MASK_SIGHT = 4

--- Monsters `self` may auto-attack in its viewport (or `rangeX` x `rangeY`): its
--- instance, clear shot, outside protection zones, attackable, not a player's summon.
--- Empty while `self` stands in a protection zone.
function Player:combatScan(rangeX, rangeY)
	local pos = self:getPosition()
	local tile = Tile(pos)
	if not tile or tile:hasFlag(TILESTATE_PROTECTIONZONE) then
		return {}
	end
	return Game.scanMonsters(pos, {
		rangeX = rangeX or CombatGeo.VIEWPORT_X,
		rangeY = rangeY or CombatGeo.VIEWPORT_Y,
		instance = self:getInstanceId(),
		sightFrom = pos,
		outsidePz = true,
		attackable = true,
		noPlayerSummons = true,
	})
end

--- Tile flags around `center` (see Game.tileMask), keyed by CombatGeo.tileKey; nil
--- entries are not standable. `self` does not occupy its own tile; `sightTo` is a
--- position or a list of them (MASK_SIGHT: clear sight to all).
function CombatGeo.tileMask(center, radius, self, instanceId, sightTo)
	return Game.tileMask(center, radius, { instance = instanceId, self = self, sightTo = sightTo })
end

function CombatGeo.maskFree(flags)
	return flags ~= nil and flags % 4 >= CombatGeo.MASK_FREE
end

function CombatGeo.maskSight(flags)
	return flags ~= nil and flags % 8 >= CombatGeo.MASK_SIGHT
end

function CombatGeo.maskFreeNeighbours(flags)
	return flags and math.floor(flags / 8) or 0
end
