-- CaveBot walker for map-spawn lure hunts: expedition sessions and open-world runs
-- (Cavebot.routeOf, 02_run.lua). The anchor walks a closed cave route and attacks on
-- the way. The lure (CavebotPack.lureCount) is the monsters targeting a member on the
-- anchor's screen plus every monster chasing a member on that member's screen, so a pack
-- on a trailing member counts too; idle monsters, monsters on other players and monsters
-- nobody in the party can see never do. The leash only waits for those same chasers.
--
-- Leash: while walking, the anchor stands still ("pace") when a chaser trails the
-- member it targets by more than LURE_LAG_SQM (it would lose its lock) or the anchor by
-- more than LURE_LEASH_SQM, until every chaser is back inside the resume distances; a
-- wait that stops closing in for LURE_LAG_STALL_MS gives those chasers up. The walk
-- onto a halt tile never waits: the anchor takes the open tile before the pack closes
-- the box around it.
--
-- Once lureMax is reached it halts: at the next hold when that hold is already on
-- screen, else at the best spot within LURE_FULL_SPOT_STEPS of the anchor (the walk
-- then resumes toward the same waypoint); reaching a hold with more than
-- LURE_RESUME_LOAD in the lure halts there too. A halt fights (without chasing) until
-- the lure load (summed monster health fractions) drops to LURE_RESUME_LOAD, then walks
-- on. The halt spot is the best tile within HALT_SPOT_STEPS of the hold by the terrain
-- score generation placed the hold with (CombatAutomationMovement.bestAnchorSpot /
-- AnchorSpot), for the actual party, never a tile a monster stands on or that is only
-- reached through one; it is picked again when it cannot be reached (then the most
-- open free tile next to the anchor), and a boss dodge step moves it along. A lure-full
-- halt in a cramped spot walks on instead when the next hold is close. A monster blocking the path halts the walk until
-- it dies. Single-hold routes park on their hold and fight respawns.
--
-- Fiendish Hunt: the forced Fiendish on screen halts the walk until it dies; out of
-- sight within FIENDISH_DETOUR_SQM of the anchor, the anchor detours off the route
-- toward it. An unreachable Fiendish is ignored for FIENDISH_IGNORE_MS.
--
-- Paused (manual control, a paused cavebot, AUTO attack off): while the anchor is
-- paused the route waits (`cave.manual`); back on auto it walks on from the nearest
-- route point. Chasers on a paused member never hold the leash.
--
-- run.cave = {
--   mode = "walk" | "pace" | "halt", idx (waypoint), lap, entryIdx (entry walk),
--   progress = Progress { best, at }, still = { pos, since }, visible, load, fullSpent,
--   halt = { pos, center, steps, reached, at, setAt, exclude, repicks, fallback, blockerId }
--     (halt mode only),
--   paceProgress = Progress, lapStartedAt, parked, fought,
--   detour, detourProgress = Progress, fiendishIgnoreUntil, fiendishHp, fiendishHitAt,
--   manual,
-- }

Cavebot = Cavebot or {}
--- File-local helpers shared by the walker files (03a_state .. 03e_anchor_directive).
CAVE_PRIV = CAVE_PRIV or {}

local geo = CombatGeo
local chebyshev, nowMs, signOf, Progress = geo.chebyshev, geo.nowMs, geo.signOf, geo.Progress
local routeOf = Cavebot.routeOf

--- Monsters on screen that send the walk straight to the next hold.
function Cavebot.lureMax(run)
	local lure = math.floor(tonumber(run and run.lure) or 0)
	if lure < 1 then
		local route = routeOf(run)
		lure = route and route.lure or 1
	end
	local lureMax = math.max(1, math.floor(lure * CavebotConfig.LURE_STOP_FACTOR + 0.5))
	return math.min(lureMax, CavebotConfig.LURE_MAX)
end

--- More load on screen than this (summed health fractions) keeps a halt fighting.
local function overResumeLoad(load)
	return (load or 0) > CavebotConfig.LURE_RESUME_LOAD
end

local function setMode(cave, mode)
	if mode == "halt" and cave.mode ~= "halt" then
		cave.paceProgress = nil
		cave.halt = {}
	elseif mode ~= "halt" then
		cave.halt = nil
	end
	cave.mode = mode
end

function Cavebot.start(run)
	local route = routeOf(run)
	if not route then
		logger.error("[Cavebot] run '{}' has no cave route", tostring(run.id or (run.catalog and run.catalog.id)))
		return
	end
	local now = nowMs()
	local cave = {
		mode = "walk",
		idx = 1,
		lap = 0,
		lapStartedAt = now,
		progress = Progress.new(now),
	}
	if #route.entry > 0 then
		cave.entryIdx = 1
	end
	run.cave = cave
	local host = Cavebot.hostOf(run)
	if host.onStart then
		host.onStart(run)
	end
	Cavebot.notify(run)
end

--- Next tile the anchor walks to: a Fiendish detour, the pending entry point, else
--- the current waypoint.
function Cavebot.walkTarget(run)
	local cave, route = run and run.cave, routeOf(run)
	if not cave or not route then
		return nil
	end
	if cave.detour then
		return cave.detour
	end
	if cave.entryIdx and route.entry[cave.entryIdx] then
		return route.entry[cave.entryIdx]
	end
	return route.waypoints[cave.idx]
end

--- Travel direction {fx, fy} from `fromPos` toward the walk target (or the waypoint
--- after it once on the target): the front followers and stances face.
function Cavebot.travelFront(run, fromPos)
	local cave, route = run and run.cave, routeOf(run)
	local target = Cavebot.walkTarget(run)
	if not target or not fromPos then
		return nil
	end
	local fx, fy = signOf(target.x - fromPos.x), signOf(target.y - fromPos.y)
	if fx == 0 and fy == 0 and not cave.entryIdx and #route.waypoints > 1 then
		local nxt = route.waypoints[cave.idx % #route.waypoints + 1]
		fx, fy = signOf(nxt.x - fromPos.x), signOf(nxt.y - fromPos.y)
	end
	if fx == 0 and fy == 0 then
		return nil
	end
	return { fx, fy }
end

--- The anchor is back on auto after manual control: walk on from the route point
--- nearest to where it stands on its floor (pending entry points or waypoints), out
--- of any halt, pace or detour. A parked route drifts back onto its hold.
function Cavebot.resume(run, anchor)
	local cave, route = run and run.cave, routeOf(run)
	if not cave or not route or not anchor then
		return
	end
	local here = anchor:getPosition()
	local now = nowMs()
	cave.manual = nil
	cave.still = nil
	cave.detour = nil
	cave.paceProgress = nil
	cave.progress = Progress.new(now)
	if cave.parked then
		return
	end
	setMode(cave, "walk")
	local bestIdx, bestDist, bestEntry = nil, math.huge, false
	local function consider(points, from, entry)
		for i = from, #points do
			local p = points[i]
			if p.z == here.z then
				local d = chebyshev(here, p)
				if d < bestDist then
					bestIdx, bestDist, bestEntry = i, d, entry
				end
			end
		end
	end
	if cave.entryIdx then
		consider(route.entry, cave.entryIdx, true)
	end
	consider(route.waypoints, 1, false)
	if not bestIdx then
		return
	end
	if bestEntry then
		cave.entryIdx = bestIdx
	else
		cave.entryIdx = nil
		cave.idx = bestIdx
	end
end

function Cavebot.blockerId(run)
	local cave = run and run.cave
	return cave and cave.halt and cave.halt.blockerId or nil
end

function Cavebot.isWalking(run)
	local cave = run and run.cave
	return cave ~= nil and not cave.parked and (cave.mode == "walk" or cave.mode == "pace")
end

local function advance(run, cave, route, now)
	cave.progress = Progress.new(now)
	if cave.entryIdx then
		cave.entryIdx = cave.entryIdx + 1
		if cave.entryIdx > #route.entry then
			cave.entryIdx = nil
		end
		return
	end
	if route.stationary then
		cave.parked = true
		setMode(cave, "halt")
		return
	end
	cave.idx = cave.idx % #route.waypoints + 1
	if cave.idx == 1 then
		cave.lap = cave.lap + 1
		Cavebot.metric(run, "onLap", now - (cave.lapStartedAt or now))
		cave.lapStartedAt = now
	end
end

CAVE_PRIV.setMode = setMode
CAVE_PRIV.overResumeLoad = overResumeLoad
CAVE_PRIV.advance = advance
