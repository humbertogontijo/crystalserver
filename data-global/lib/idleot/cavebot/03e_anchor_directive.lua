-- Cavebot walker, the anchor's movement directive for the current walker mode.

local geo = CombatGeo
local sameTile, toPosition = geo.sameTile, geo.toPosition
local routeOf = Cavebot.routeOf
local overResumeLoad = CAVE_PRIV.overResumeLoad

--- Directive for the anchor: walk the route (luring), wait for stragglers, or hold
--- a halt. In a halt it walks straight onto the halt tile and fights from it without chasing
--- while more than LURE_RESUME_LOAD is on screen; below that it fights with its
--- normal stance (follow / positioning). A ranged anchor fights with its stance
--- (distance, kiting, area-spell steps) as soon as it reached the halt tile, or the
--- parked hold, and returns to it between fights. Second value: followers
--- trail in line (true) or take formation (false).
function Cavebot.anchorDirective(run, anchor)
	local cave, route = run.cave, routeOf(run)
	local here = anchor:getPosition()
	local front = Cavebot.travelFront(run, here)
	local halt = cave.halt
	local tile = cave.parked and route.waypoints[1] or (halt and halt.pos) or nil
	if cave.parked or cave.mode == "halt" then
		local visible = cave.visible or 0
		if tile and overResumeLoad(cave.load) then
			if (cave.parked or (halt and halt.reached)) and CombatAutomationMovement.rangedStance(anchor) then
				return { kind = "hold", pos = toPosition(tile), priority = "soft", reach = 0, front = front, quiet = true, home = true }, false
			end
			local priority = sameTile(here, tile) and "soft" or "relocate"
			return {
				kind = "hold",
				pos = toPosition(tile),
				priority = priority,
				reach = 0,
				front = front,
				luring = true,
				quiet = true,
				halt = cave.mode == "halt" and not cave.parked,
			},
				false
		end
		-- Parked with an empty screen: drift back onto the hold. A ranged anchor keeps
		-- fighting around the tile.
		local home = tile ~= nil and (visible == 0 or CombatAutomationMovement.rangedStance(anchor))
		return { kind = "hold", pos = toPosition(home and tile or here), priority = "soft", front = front, home = home }, false
	end
	if cave.mode == "pace" then
		return { kind = "hold", pos = toPosition(here), priority = "soft", front = front, luring = true }, true
	end
	local target = Cavebot.walkTarget(run)
	return {
		kind = "hold",
		pos = toPosition(target or here),
		priority = "relocate",
		reach = CavebotConfig.WAYPOINT_REACH,
		front = front,
		luring = true,
	},
		true
end
