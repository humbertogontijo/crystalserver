-- CaveBot walker for map-spawn lure hunts.
-- The anchor walks the hunt's closed cave route (ExpeditionConfig.caveRoute) and
-- attacks on the way; it only fights at holds (generated spawn cluster stands). Once
-- lureMax monsters are on screen it stops waiting for stragglers and, as soon as the
-- next waypoint is a hold, walks straight to the best spot near that hold; reaching a
-- hold with more than LURE_RESUME_LOAD on screen halts there too. A halt fights
-- (without chasing) until the load on screen (summed monster health fractions) drops
-- to LURE_RESUME_LOAD, then walks on. The halt spot is the best tile within
-- HALT_SPOT_STEPS of the hold by the terrain score generation placed the hold with
-- (CombatAutomationMovement.bestAnchorSpot / AnchorSpot), for the actual party; it is
-- picked again when it cannot be reached, and a boss dodge step moves it along. A
-- monster blocking the path halts the walk until it dies.
-- Single-hold routes park on their hold and fight respawns.
--
-- Fiendish Hunt: the forced Fiendish on screen halts the walk until it dies; out of
-- sight within FIENDISH_DETOUR_SQM of the anchor, the anchor detours off the route
-- toward it. An unreachable Fiendish is ignored for FIENDISH_IGNORE_MS.
--
-- session.cave = {
--   mode = "walk" | "pace" | "halt", idx (waypoint), lap, entryIdx (entry walk),
--   progress = { dist, at }, still = { pos, since }, visible, load, haltPos, haltCenter, haltReached,
--   haltAt, haltSetAt, haltExclude, haltRepicks,
--   blockerId, paceUntil, paceCooldownUntil, lapStartedAt, parked, fought,
--   detour, detourProgress = { dist, at }, fiendishIgnoreUntil, fiendishHp, fiendishHitAt,
-- }

ExpeditionCavebot = ExpeditionCavebot or {}

local geo = CombatGeo
local chebyshev, nowMs, sameTile, signOf = geo.chebyshev, geo.nowMs, geo.sameTile, geo.signOf

local function routeOf(session)
	return session and ExpeditionConfig.caveRoute(session.catalog) or nil
end

local function toPosition(p)
	return p and Position(p.x, p.y, p.z) or nil
end

--- Monsters on screen that send the walk straight to the next hold.
function ExpeditionCavebot.lureMax(session)
	local lure = math.floor(tonumber(session and session.lure) or 0)
	if lure < 1 then
		local route = routeOf(session)
		lure = route and route.lure or 1
	end
	local lureMax = math.max(1, math.floor(lure * ExpeditionConfig.LURE_STOP_FACTOR + 0.5))
	return math.min(lureMax, ExpeditionConfig.LURE_MAX)
end

--- More load on screen than this (summed health fractions) keeps a halt fighting.
local function overResumeLoad(load)
	return (load or 0) > ExpeditionConfig.LURE_RESUME_LOAD
end

local function setMode(cave, mode)
	cave.mode = mode
	if mode ~= "halt" then
		cave.haltPos = nil
		cave.haltCenter = nil
		cave.haltReached = nil
		cave.haltSetAt = nil
		cave.haltExclude = nil
		cave.haltRepicks = nil
		cave.blockerId = nil
	end
	if mode ~= "pace" then
		cave.paceUntil = nil
	end
end

function ExpeditionCavebot.start(session)
	local route = routeOf(session)
	if not route then
		logger.error("[Expedition] hunt '{}' has no cave route", tostring(session.catalog and session.catalog.id))
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
	session.cave = cave
	session.state = "hunting"
	ExpeditionManager.broadcastStatus(session)
end

--- Next tile the anchor walks to: a Fiendish detour, the pending entry point, else
--- the current waypoint.
function ExpeditionCavebot.walkTarget(session)
	local cave, route = session and session.cave, routeOf(session)
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
function ExpeditionCavebot.travelFront(session, fromPos)
	local cave, route = session and session.cave, routeOf(session)
	local target = ExpeditionCavebot.walkTarget(session)
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

function ExpeditionCavebot.blockerId(session)
	local cave = session and session.cave
	return cave and cave.blockerId or nil
end

function ExpeditionCavebot.isWalking(session)
	local cave = session and session.cave
	return cave ~= nil and not cave.parked and (cave.mode == "walk" or cave.mode == "pace")
end

local function advance(session, cave, route, now)
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
		ExpeditionMetrics.onLap(session, now - (cave.lapStartedAt or now))
		cave.lapStartedAt = now
	end
end

-- ---------------------------------------------------------------------------
-- Halt (killing box)
-- ---------------------------------------------------------------------------

--- Members other than the anchor with the slot distance each keeps from it.
local function haltTeam(session, anchor)
	local team, anchorId = {}, anchor:getId()
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
		local member = id ~= anchorId and Player(id)
		if member then
			team[#team + 1] = { id = id, slotDist = CombatAutomationMovement.memberSlotDistance(member) }
		end
	end
	return team
end

--- Best fight tile within HALT_SPOT_STEPS of `center` for the session's party.
local function findHaltSpot(session, anchor, center, exclude)
	return CombatAutomationMovement.bestAnchorSpot(anchor, {
		center = center,
		steps = ExpeditionConfig.HALT_SPOT_STEPS,
		exclude = exclude,
		team = haltTeam(session, anchor),
	})
end

local function setHaltPos(cave, spot, now)
	cave.haltPos = toPosition(spot)
	cave.haltReached = nil
	cave.haltSetAt = now
end

--- Halt tile: the best spot near `center` (the hold; default the anchor's tile).
local function chooseHaltPos(session, cave, anchor, now, center)
	cave.haltCenter = toPosition(center) or anchor:getPosition()
	cave.haltExclude = {}
	cave.haltRepicks = 0
	setHaltPos(cave, findHaltSpot(session, anchor, cave.haltCenter) or cave.haltCenter, now)
end

--- `failed`: the halt tile the anchor cannot reach, excluded from now on; the next
--- best near the same centre replaces it. Past HALT_REPICK_MAX picks (or with no
--- other tile) it fights where it stands.
local function repickHaltPos(session, cave, anchor, here, now, failed)
	cave.haltExclude[AnchorSpot.tileKey(failed.x, failed.y)] = true
	local spot
	if cave.haltRepicks < ExpeditionConfig.HALT_REPICK_MAX then
		cave.haltRepicks = cave.haltRepicks + 1
		spot = findHaltSpot(session, anchor, cave.haltCenter, cave.haltExclude)
	end
	if spot then
		setHaltPos(cave, spot, now)
	else
		cave.haltPos = toPosition(here)
		cave.haltReached = true
	end
end

--- Fight at the best spot near `center` (the hold; default where the anchor stands).
local function enterHalt(session, cave, anchor, now, visible, center)
	setMode(cave, "halt")
	cave.haltAt = now
	chooseHaltPos(session, cave, anchor, now, center)
	ExpeditionMetrics.onHalt(session, visible)
end

local function enterBlockerHalt(session, cave, now, blocker)
	setMode(cave, "halt")
	cave.blockerId = blocker:getId()
	cave.haltAt = now
	ExpeditionMetrics.onBlockerHalt(session)
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
	for _, off in ipairs(offsets) do
		local tile = Tile(Position(here.x + off[1], here.y + off[2], here.z))
		local top = tile and tile:getTopCreature()
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
local function haltStuck(session, cave, now)
	local progressAt = math.max(cave.haltAt or now, session.lastKillAt or 0, cave.fiendishHitAt or 0)
	return now - progressAt > ExpeditionConfig.HALT_STUCK_MS
end

--- `fiendishInSight`: the forced Fiendish is on screen, so the halt holds until it dies.
--- A blocker halt walks on once the blocker is dead (to the next hold).
local function updateHalt(session, cave, anchor, here, now, load, fiendishInSight)
	if cave.blockerId then
		if blockerAlive(cave, here) and not haltStuck(session, cave, now) then
			return
		end
		cave.blockerId = nil
		if fiendishInSight then
			chooseHaltPos(session, cave, anchor, now)
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
	if haltStuck(session, cave, now) then
		if fiendishInSight then
			cave.fiendishIgnoreUntil = now + ExpeditionConfig.FIENDISH_IGNORE_MS
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
local function settleHaltPos(session, cave, anchor, here, now)
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
		repickHaltPos(session, cave, anchor, here, now, dest)
	end
end

--- Single-hold route: stay on the hold; each fight until the screen empties counts
--- as one halt.
local function tickParked(session, cave, visible)
	if visible > 0 then
		if not cave.fought then
			ExpeditionMetrics.onHalt(session, visible)
		end
		cave.fought = true
	else
		cave.fought = nil
	end
end

-- ---------------------------------------------------------------------------
-- Walk and pacing
-- ---------------------------------------------------------------------------

--- An engaged monster still chasing the party trails more than LURE_LAG_SQM, and
--- the anchor is not boxed in. One that lost its target or sits sealed on an island
--- never catches up, so it is not waited for.
local function packLagging(session, here, members)
	local lagSqm = ExpeditionConfig.LURE_LAG_SQM
	local engaged, lagging, adjacent = 0, 0, 0
	for mid in pairs(session.engaged) do
		local monster = Monster(mid)
		if monster and monster:getHealth() > 0 then
			engaged = engaged + 1
			local mpos = monster:getPosition()
			local dist = chebyshev(mpos, here)
			if dist <= 1 then
				adjacent = adjacent + 1
			elseif dist > lagSqm and ExpeditionPack.targetsMember(monster, members) and not ExpeditionPack.sealedIn(mpos) then
				lagging = lagging + 1
			end
		end
	end
	if engaged < ExpeditionConfig.LURE_PACE_MIN or adjacent >= ExpeditionConfig.LURE_WAIT_SKIP_ADJACENT then
		return false
	end
	return lagging > 0
end

--- Pacing: wait up to LURE_WAIT_MS for the pack to catch up, then walk at least
--- that long before waiting again.
local function updatePacing(session, cave, here, now, members)
	local waitMs = ExpeditionConfig.LURE_WAIT_MS
	if cave.mode == "pace" then
		if now >= (cave.paceUntil or 0) or not packLagging(session, here, members) then
			setMode(cave, "walk")
			cave.paceCooldownUntil = now + waitMs
		end
		return
	end
	if now >= (cave.paceCooldownUntil or 0) and packLagging(session, here, members) then
		setMode(cave, "pace")
		cave.paceUntil = now + waitMs
	end
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
	if chebyshev(here, fpos) <= ExpeditionConfig.FIENDISH_DETOUR_SQM then
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
		or now - progress.at > ExpeditionConfig.WAYPOINT_STALL_MS
	then
		cave.detour = nil
		cave.fiendishIgnoreUntil = now + ExpeditionConfig.FIENDISH_IGNORE_MS
		cave.progress = { dist = math.huge, at = now }
	end
end

--- Advance on reaching (or failing to path to) the walk target; a waypoint that
--- makes no progress for WAYPOINT_STALL_MS while walking alone is skipped. A hold as
--- the walk target halts at the best spot near it once the lure is full (walking
--- straight there), or on reaching it with more than LURE_RESUME_LOAD on screen.
local function tickWalk(session, cave, route, anchor, here, now, visible, load, lureFull)
	if cave.detour then
		tickDetour(cave, anchor, here, now)
		return
	end
	local target = ExpeditionCavebot.walkTarget(session)
	if not target then
		return
	end
	local dist = chebyshev(here, target)
	local reach = ExpeditionConfig.WAYPOINT_REACH + ExpeditionConfig.WAYPOINT_LOOKAHEAD
	local reached = dist <= reach or CombatAutomationMovement.walkBlocked(anchor, toPosition(target))
	if target.hold and not cave.entryIdx and (lureFull or (reached and overResumeLoad(load))) then
		advance(session, cave, route, now)
		enterHalt(session, cave, anchor, now, visible, target)
		return
	end
	if reached then
		advance(session, cave, route, now)
		return
	end
	local progress = cave.progress
	if dist < progress.dist then
		progress.dist = dist
		progress.at = now
	elseif visible > 0 then
		progress.at = now
	elseif now - progress.at > ExpeditionConfig.WAYPOINT_STALL_MS then
		advance(session, cave, route, now)
	end
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
-- Tick (ExpeditionPack.tickLure, every AI_TICK_MS)
-- ---------------------------------------------------------------------------

function ExpeditionCavebot.tick(session, anchor, members)
	local cave, route = session.cave, routeOf(session)
	if not cave or not route then
		return
	end
	local here = anchor:getPosition()
	local now = nowMs()
	local prevMode = cave.mode
	local stillMs = trackStill(cave, here, now)

	local visible, load = ExpeditionPack.monstersOnScreen(session, anchor)
	cave.visible, cave.load = visible, load
	local fiendish = ExpeditionPack.forcedFiendish(session)
	if cave.parked then
		tickParked(session, cave, visible)
	else
		local fiendishInSight = fiendish ~= nil
			and now >= (cave.fiendishIgnoreUntil or 0)
			and geo.isInViewport(here, fiendish:getPosition())
		trackFiendishHp(cave, fiendish, now)
		updateDetour(cave, here, now, fiendish, fiendishInSight)
		if cave.mode == "halt" then
			updateHalt(session, cave, anchor, here, now, load, fiendishInSight)
		else
			local target = ExpeditionCavebot.walkTarget(session)
			local blocker = target and stillMs >= ExpeditionConfig.BLOCKER_MS and blockerAhead(anchor, here, target)
			local lureFull = visible >= ExpeditionCavebot.lureMax(session)
			if fiendishInSight then
				enterHalt(session, cave, anchor, now, visible)
			elseif blocker then
				enterBlockerHalt(session, cave, now, blocker)
			else
				if lureFull then
					if cave.mode == "pace" then
						setMode(cave, "walk")
					end
				else
					updatePacing(session, cave, here, now, members)
				end
				if cave.mode == "walk" then
					tickWalk(session, cave, route, anchor, here, now, visible, load, lureFull)
				end
			end
		end
		settleHaltPos(session, cave, anchor, here, now)
	end

	if prevMode ~= cave.mode and session.cave == cave then
		ExpeditionManager.broadcastStatus(session)
	end
end

--- Directive for the anchor: walk the route (luring), wait for stragglers, or hold
--- a halt. In a halt it walks straight onto the halt tile and fights from it without chasing
--- while more than LURE_RESUME_LOAD is on screen; below that it fights with its
--- normal stance (follow / positioning). A ranged anchor fights with its stance
--- (distance, kiting, area-spell steps) as soon as it reached the halt tile, or the
--- parked hold, and returns to it between fights. Second value: followers
--- trail in line (true) or take formation (false).
function ExpeditionCavebot.anchorDirective(session, anchor)
	local cave, route = session.cave, routeOf(session)
	local here = anchor:getPosition()
	local front = ExpeditionCavebot.travelFront(session, here)
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
	local target = ExpeditionCavebot.walkTarget(session)
	return {
		kind = "hold",
		pos = toPosition(target or here),
		priority = "relocate",
		reach = ExpeditionConfig.WAYPOINT_REACH,
		front = front,
		luring = true,
	},
		true
end
