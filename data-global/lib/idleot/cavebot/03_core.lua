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
--   progress = { dist, at }, still = { pos, since }, visible, load, fullSpent,
--   haltPos, haltCenter, haltSteps, haltReached, haltAt, haltSetAt, haltExclude, haltRepicks, haltFallback,
--   blockerId, paceProgress = { lag, at }, lapStartedAt, parked, fought,
--   detour, detourProgress = { dist, at }, fiendishIgnoreUntil, fiendishHp, fiendishHitAt,
--   manual,
-- }

Cavebot = Cavebot or {}

local geo = CombatGeo
local chebyshev, nowMs, sameTile, signOf = geo.chebyshev, geo.nowMs, geo.sameTile, geo.signOf

local routeOf = Cavebot.routeOf

local function toPosition(p)
	return p and Position(p.x, p.y, p.z) or nil
end

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
	end
	cave.mode = mode
	if mode ~= "halt" then
		cave.haltPos = nil
		cave.haltCenter = nil
		cave.haltSteps = nil
		cave.haltReached = nil
		cave.haltSetAt = nil
		cave.haltExclude = nil
		cave.haltRepicks = nil
		cave.haltFallback = nil
		cave.blockerId = nil
	end
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
		progress = { dist = math.huge, at = now },
	}
	if #route.entry > 0 then
		cave.entryIdx = 1
	end
	run.cave = cave
	if not Cavebot.isOpen(run) then
		run.state = "hunting"
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
	cave.progress = { dist = math.huge, at = now }
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
	return cave and cave.blockerId or nil
end

function Cavebot.isWalking(run)
	local cave = run and run.cave
	return cave ~= nil and not cave.parked and (cave.mode == "walk" or cave.mode == "pace")
end

local function advance(run, cave, route, now)
	cave.progress = { dist = math.huge, at = now }
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
		ExpeditionMetrics.onLap(run, now - (cave.lapStartedAt or now))
		cave.lapStartedAt = now
	end
end

-- ---------------------------------------------------------------------------
-- Halt (killing box)
-- ---------------------------------------------------------------------------

--- Members other than the anchor with the slot distance each keeps from it.
local function haltTeam(run, anchor)
	local team, anchorId = {}, anchor:getId()
	for _, id in ipairs(Cavebot.memberIds(run)) do
		local member = id ~= anchorId and Player(id)
		if member then
			team[#team + 1] = { id = id, slotDist = CombatAutomationMovement.memberSlotDistance(member) }
		end
	end
	return team
end

--- Best fight tile within `steps` walking steps of `center` for the run's party,
--- around the monsters already there. Returns pos, score, ring, unserved.
local function findHaltSpot(run, anchor, center, steps, exclude)
	return CombatAutomationMovement.bestAnchorSpot(anchor, {
		center = center,
		steps = steps,
		exclude = exclude,
		team = haltTeam(run, anchor),
		avoidMonsters = true,
	})
end

local function setHaltPos(cave, spot, now)
	cave.haltPos = toPosition(spot)
	cave.haltReached = nil
	cave.haltSetAt = now
end

--- Halt tile: the best spot within `steps` (default HALT_SPOT_STEPS) of `center` (the
--- hold; default the anchor's tile).
local function chooseHaltPos(run, cave, anchor, now, center, steps)
	cave.haltCenter = toPosition(center) or anchor:getPosition()
	cave.haltSteps = steps or CavebotConfig.HALT_SPOT_STEPS
	cave.haltExclude = {}
	cave.haltRepicks = 0
	setHaltPos(cave, findHaltSpot(run, anchor, cave.haltCenter, cave.haltSteps) or cave.haltCenter, now)
end

--- `failed`: the halt tile the anchor cannot reach, excluded from now on; the next
--- best near the same centre replaces it. Past HALT_REPICK_MAX picks (or with no
--- other tile) it takes the most open free tile next to it once, then fights where
--- it stands.
local function repickHaltPos(run, cave, anchor, here, now, failed)
	cave.haltExclude[AnchorSpot.tileKey(failed.x, failed.y)] = true
	local spot
	if cave.haltRepicks < CavebotConfig.HALT_REPICK_MAX then
		cave.haltRepicks = cave.haltRepicks + 1
		spot = findHaltSpot(run, anchor, cave.haltCenter, cave.haltSteps, cave.haltExclude)
	end
	if not spot and not cave.haltFallback then
		cave.haltFallback = true
		spot = findHaltSpot(run, anchor, here, 1, cave.haltExclude)
		if spot and sameTile(spot, here) then
			spot = nil
		end
	end
	if spot then
		setHaltPos(cave, spot, now)
	else
		cave.haltPos = toPosition(here)
		cave.haltReached = true
	end
end

--- Fight at the best spot within `steps` of `center` (the hold; default where the
--- anchor stands).
local function enterHalt(run, cave, anchor, now, visible, center, steps)
	setMode(cave, "halt")
	cave.haltAt = now
	chooseHaltPos(run, cave, anchor, now, center, steps)
	ExpeditionMetrics.onHalt(run, visible)
end

local function enterBlockerHalt(run, cave, now, blocker)
	setMode(cave, "halt")
	cave.blockerId = blocker:getId()
	cave.haltAt = now
	ExpeditionMetrics.onBlockerHalt(run)
end

--- An attackable monster on a tile next to the anchor in the travel direction.
local function blockerAhead(anchor, here, target)
	local fx, fy = signOf(target.x - here.x), signOf(target.y - here.y)
	if fx == 0 and fy == 0 then
		return nil
	end
	local offsets = { { fx, fy } }
	if fx ~= 0 and fy ~= 0 then
		offsets[2] = { fx, 0 }
		offsets[3] = { 0, fy }
	end
	local instanceId = anchor:getInstanceId()
	for _, off in ipairs(offsets) do
		local tile = Tile(Position(here.x + off[1], here.y + off[2], here.z))
		local top = tile and tile:getTopCreature(instanceId)
		if top and top:isMonster() and CombatAutomation.isValidAttackTarget(anchor, top) then
			return top
		end
	end
	return nil
end

local function blockerAlive(cave, here)
	local monster = cave.blockerId and Monster(cave.blockerId)
	return monster ~= nil and monster:getHealth() > 0 and chebyshev(monster:getPosition(), here) <= 1
end

--- No kill or Fiendish hit for HALT_STUCK_MS since the halt began.
local function haltStuck(run, cave, now)
	local progressAt = math.max(cave.haltAt or now, run.lastKillAt or 0, cave.fiendishHitAt or 0)
	return now - progressAt > CavebotConfig.HALT_STUCK_MS
end

--- `fiendishInSight`: the forced Fiendish is on screen, so the halt holds until it dies.
--- A blocker halt walks on once the blocker is dead (to the next hold).
local function updateHalt(run, cave, anchor, here, now, load, fiendishInSight)
	if cave.blockerId then
		if blockerAlive(cave, here) and not haltStuck(run, cave, now) then
			return
		end
		cave.blockerId = nil
		if fiendishInSight then
			chooseHaltPos(run, cave, anchor, now)
		else
			setMode(cave, "walk")
		end
		return
	end
	if not overResumeLoad(load) and not fiendishInSight then
		setMode(cave, "walk")
		return
	end
	-- Visible monsters out of reach: walk on.
	if haltStuck(run, cave, now) then
		if fiendishInSight then
			cave.fiendishIgnoreUntil = now + CavebotConfig.FIENDISH_IGNORE_MS
		end
		setMode(cave, "walk")
	end
end

--- The anchor's boss dodge step since the halt tile was set (`dodgeBossFront`).
local function anchorStep(anchor, cave)
	local state = CombatAutomation.getState(anchor)
	local step = state and state.anchorAdoptPos
	if not step or (state.anchorAdoptAt or 0) < (cave.haltSetAt or 0) then
		return nil
	end
	state.anchorAdoptPos = nil
	return step
end

--- Off the halt tile with no path there: pick again near the same centre. The
--- anchor's boss dodge step becomes the halt tile.
local function settleHaltPos(run, cave, anchor, here, now)
	local step = cave.haltPos and anchorStep(anchor, cave)
	if step and step.z == cave.haltPos.z then
		cave.haltPos = toPosition(step)
	end
	local dest = cave.haltPos
	if not dest then
		return
	end
	if sameTile(here, dest) then
		cave.haltReached = true
	elseif cave.haltReached and CombatAutomationMovement.rangedStance(anchor) then
		-- A ranged anchor fights by stance around the halt tile once there.
		return
	elseif CombatAutomationMovement.walkBlocked(anchor, dest) then
		repickHaltPos(run, cave, anchor, here, now, dest)
	end
end

--- Single-hold route: stay on the hold; each fight until the screen empties counts
--- as one halt.
local function tickParked(run, cave, visible)
	if visible > 0 then
		if not cave.fought then
			ExpeditionMetrics.onHalt(run, visible)
		end
		cave.fought = true
	else
		cave.fought = nil
	end
end

-- ---------------------------------------------------------------------------
-- Walk and pacing
-- ---------------------------------------------------------------------------

--- The lure leash over the chasers (`CavebotPack.chasers`: engaged monsters on any
--- member, not only the anchor): `target` = the largest distance from one to the
--- member it chases (its lock), `anchor` = the largest distance from one to the anchor
--- (the halt box), `laggers` = engaged entries of the chasers outside the resume
--- distances, `adjacent` = chasers next to the anchor. A chaser given up on
--- (`lagStuckUntil`) counts again once it is back inside the resume distances.
local function packLag(run, here, members, now)
	local resumeTarget = CavebotConfig.LURE_LAG_RESUME_SQM
	local resumeAnchor = CavebotConfig.LURE_LEASH_SQM - 2
	local lag = { target = 0, anchor = 0, adjacent = 0, laggers = {} }
	for _, chaser in ipairs(CavebotPack.chasers(run, members, here, now, true)) do
		local mpos = chaser.monster:getPosition()
		local toTarget = chebyshev(mpos, chaser.target:getPosition())
		local toAnchor = chebyshev(mpos, here)
		local inside = toTarget <= resumeTarget and toAnchor <= resumeAnchor
		local state = chaser.state
		if inside then
			state.lagStuckUntil = nil
		end
		if toAnchor <= 1 then
			lag.adjacent = lag.adjacent + 1
		end
		if (state.lagStuckUntil or 0) <= now then
			lag.target = math.max(lag.target, toTarget)
			lag.anchor = math.max(lag.anchor, toAnchor)
			if not inside then
				lag.laggers[#lag.laggers + 1] = state
			end
		end
	end
	return lag
end

--- Start waiting once a chaser trails its target by more than LURE_LAG_SQM or the
--- anchor by more than LURE_LEASH_SQM; keep waiting (`waiting`) until every chaser is
--- back inside the resume distances. Never while LURE_WAIT_SKIP_ADJACENT box the anchor.
local function leashWants(lag, waiting)
	if lag.adjacent >= CavebotConfig.LURE_WAIT_SKIP_ADJACENT then
		return false
	end
	if waiting then
		return #lag.laggers > 0
	end
	return lag.target > CavebotConfig.LURE_LAG_SQM or lag.anchor > CavebotConfig.LURE_LEASH_SQM
end

--- True while the anchor stands still for the pack. No time cap: a wait ends when the
--- pack is in, or when the lag has not shrunk for LURE_LAG_STALL_MS — the chasers it
--- waited for are then given up on for PULL_STALL_MS. `cave.paceProgress` = { lag, at }
--- while waiting.
local function updateLeash(run, cave, here, now, members)
	local lag = packLag(run, here, members, now)
	if not leashWants(lag, cave.paceProgress ~= nil) then
		cave.paceProgress = nil
		return false
	end
	local total = lag.target + lag.anchor
	local progress = cave.paceProgress
	if not progress or total < progress.lag then
		cave.paceProgress = { lag = total, at = now }
	elseif now - progress.at > CavebotConfig.LURE_LAG_STALL_MS then
		local untilMs = now + CavebotConfig.PULL_STALL_MS
		for _, state in ipairs(lag.laggers) do
			state.lagStuckUntil = untilMs
		end
		cave.paceProgress = nil
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Fiendish Hunt
-- ---------------------------------------------------------------------------

--- Note damage on the Fiendish (halt progress while it takes a while to kill).
local function trackFiendishHp(cave, fiendish, now)
	if not fiendish then
		cave.fiendishHp = nil
		return
	end
	local hp = fiendish:getHealth()
	if hp < (cave.fiendishHp or hp) then
		cave.fiendishHitAt = now
	end
	cave.fiendishHp = hp
end

--- Start a detour toward the Fiendish when it is near but off screen; drop it once
--- the Fiendish is on screen or gone. Out of sight it idles, so its tile is fixed.
local function updateDetour(cave, here, now, fiendish, inSight)
	if cave.detour then
		if not fiendish or inSight then
			cave.detour = nil
			cave.progress = { dist = math.huge, at = now }
		end
		return
	end
	if not fiendish or inSight or cave.entryIdx or now < (cave.fiendishIgnoreUntil or 0) then
		return
	end
	local fpos = fiendish:getPosition()
	if chebyshev(here, fpos) <= CavebotConfig.FIENDISH_DETOUR_SQM then
		cave.detour = { x = fpos.x, y = fpos.y, z = fpos.z }
		cave.detourProgress = { dist = math.huge, at = now }
	end
end

--- Detour that cannot path or makes no progress for WAYPOINT_STALL_MS is abandoned
--- and the Fiendish ignored for FIENDISH_IGNORE_MS.
local function tickDetour(cave, anchor, here, now)
	local progress = cave.detourProgress
	local dist = chebyshev(here, cave.detour)
	if dist < progress.dist then
		progress.dist = dist
		progress.at = now
	elseif CombatAutomationMovement.walkBlocked(anchor, toPosition(cave.detour))
		or now - progress.at > CavebotConfig.WAYPOINT_STALL_MS
	then
		cave.detour = nil
		cave.fiendishIgnoreUntil = now + CavebotConfig.FIENDISH_IGNORE_MS
		cave.progress = { dist = math.huge, at = now }
	end
end

--- Advance on reaching (or failing to path to) the walk target; a waypoint that
--- makes no progress for WAYPOINT_STALL_MS while walking alone is skipped. Reaching a
--- hold with more than LURE_RESUME_LOAD in the lure halts at the best spot near it.
local function tickWalk(run, cave, route, anchor, here, now, visible, load)
	if cave.detour then
		tickDetour(cave, anchor, here, now)
		return
	end
	local target = Cavebot.walkTarget(run)
	if not target then
		return
	end
	local dist = chebyshev(here, target)
	local reach = CavebotConfig.WAYPOINT_REACH + CavebotConfig.WAYPOINT_LOOKAHEAD
	local reached = dist <= reach or CombatAutomationMovement.walkBlocked(anchor, toPosition(target))
	if target.hold and not cave.entryIdx and reached and overResumeLoad(load) then
		advance(run, cave, route, now)
		enterHalt(run, cave, anchor, now, visible, target)
		return
	end
	if reached then
		advance(run, cave, route, now)
		return
	end
	local progress = cave.progress
	if dist < progress.dist then
		progress.dist = dist
		progress.at = now
	elseif visible > 0 then
		progress.at = now
	elseif now - progress.at > CavebotConfig.WAYPOINT_STALL_MS then
		advance(run, cave, route, now)
	end
end

--- Lure full: fight at the next hold when it is already on screen (consuming it), else
--- at the best spot within LURE_FULL_SPOT_STEPS of the anchor, so the pack stays in
--- sight; the walk then resumes toward the same waypoint. Arms again only once the
--- lure drops below lureMax (`cave.fullSpent`), so a halt that ends with the lure still
--- full walks on instead of halting again on the spot.
--- Next hold waypoint at or after the current one (same floor), or nil.
local function nextHold(cave, route, here)
	if cave.entryIdx or cave.detour then
		return nil
	end
	local n = #route.waypoints
	for k = 0, n - 1 do
		local wp = route.waypoints[(cave.idx - 1 + k) % n + 1]
		if wp.hold then
			return wp.z == here.z and wp or nil
		end
	end
	return nil
end

local function enterLureFullHalt(run, cave, route, anchor, here, now, visible)
	cave.fullSpent = true
	local target = Cavebot.walkTarget(run)
	if target and target.hold and not cave.detour and not cave.entryIdx and geo.isInViewport(here, target) then
		advance(run, cave, route, now)
		enterHalt(run, cave, anchor, now, visible, target)
		return
	end
	-- Cramped spot (corridor) with the next hold close: walk on and fight there.
	local _, _, ring = findHaltSpot(run, anchor, here, CavebotConfig.LURE_FULL_SPOT_STEPS)
	local hold = nextHold(cave, route, here)
	if (ring or 0) < CavebotConfig.HALT_OPEN_RING and hold and chebyshev(here, hold) <= CavebotConfig.LURE_FULL_HOLD_SQM then
		return
	end
	enterHalt(run, cave, anchor, now, visible, nil, CavebotConfig.LURE_FULL_SPOT_STEPS)
end

local function trackStill(cave, here, now)
	local still = cave.still
	if not still or not sameTile(still.pos, here) then
		cave.still = { pos = { x = here.x, y = here.y, z = here.z }, since = now }
		return 0
	end
	return now - still.since
end

-- ---------------------------------------------------------------------------
-- Tick (ExpeditionPack.tickLure / CavebotService, every TICK_MS)
-- ---------------------------------------------------------------------------

function Cavebot.tick(run, anchor, members)
	local cave, route = run.cave, routeOf(run)
	if not cave or not route then
		return
	end
	local here = anchor:getPosition()
	local now = nowMs()
	local prevMode = cave.mode
	local manual = run.manualIds or {}

	local visible, load = CavebotPack.lureCount(run, anchor, members)
	cave.visible, cave.load = visible, load
	-- The anchor's player leads: the route waits for Cavebot.resume.
	if manual[anchor:getId()] then
		if not cave.manual then
			cave.manual = true
			Cavebot.notify(run)
		end
		return
	end
	local stillMs = trackStill(cave, here, now)
	-- Members walking themselves drag their chasers off on purpose: never wait for those.
	local leashMembers = members
	if next(manual) then
		leashMembers = {}
		for id in pairs(members) do
			if not manual[id] then
				leashMembers[id] = true
			end
		end
	end
	local lureFull = visible >= Cavebot.lureMax(run)
	if not lureFull then
		cave.fullSpent = nil
	end
	local fiendish = not Cavebot.isOpen(run) and ExpeditionPack.forcedFiendish(run) or nil
	if cave.parked then
		tickParked(run, cave, visible)
	else
		local fiendishInSight = fiendish ~= nil
			and now >= (cave.fiendishIgnoreUntil or 0)
			and geo.isInViewport(here, fiendish:getPosition())
		trackFiendishHp(cave, fiendish, now)
		updateDetour(cave, here, now, fiendish, fiendishInSight)
		if cave.mode == "halt" then
			updateHalt(run, cave, anchor, here, now, load, fiendishInSight)
		else
			local target = Cavebot.walkTarget(run)
			local blocker = target and stillMs >= CavebotConfig.BLOCKER_MS and blockerAhead(anchor, here, target)
			if fiendishInSight then
				enterHalt(run, cave, anchor, now, visible)
			elseif blocker then
				enterBlockerHalt(run, cave, now, blocker)
			elseif lureFull and not cave.fullSpent then
				enterLureFullHalt(run, cave, route, anchor, here, now, visible)
			else
				setMode(cave, updateLeash(run, cave, here, now, leashMembers) and "pace" or "walk")
				if cave.mode == "walk" then
					tickWalk(run, cave, route, anchor, here, now, visible, load)
				end
			end
		end
		settleHaltPos(run, cave, anchor, here, now)
	end

	if prevMode ~= cave.mode and run.cave == cave then
		Cavebot.notify(run)
	end
end

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
	local tile = cave.parked and route.waypoints[1] or (cave.mode == "halt" and cave.haltPos) or nil
	if cave.parked or cave.mode == "halt" then
		local visible = cave.visible or 0
		if tile and overResumeLoad(cave.load) then
			if (cave.parked or cave.haltReached) and CombatAutomationMovement.rangedStance(anchor) then
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
