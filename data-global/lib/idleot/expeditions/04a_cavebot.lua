-- CaveBot walker for map-spawn lure hunts.
-- The anchor walks the hunt's closed cave route (ExpeditionConfig.caveRoute) and
-- attacks on the way; it halts once lureMax monsters are on screen and a good halt
-- tile is in reach (else it keeps luring for up to HALT_DEFER_MS). Reaching a hold
-- (a generated spawn cluster stand) halts too when more than LURE_RESUME_LOAD is on
-- screen. Either halt fights (without chasing) until the load on screen (summed
-- monster health fractions) drops to LURE_RESUME_LOAD, then walks on. A halt fights
-- from the best reachable tile on screen (CombatAutomationMovement.bestAnchorSpot:
-- room for a monster ring and ranged lanes; the hold wins ties), picking again when
-- that tile cannot be reached or turns out poor. A monster blocking the path halts the
-- walk until it dies, or until the pack catches up (then it is a lure halt).
-- Single-hold routes park on their hold and fight respawns.
--
-- Fiendish Hunt: the forced Fiendish on screen halts the walk until it dies; out of
-- sight within FIENDISH_DETOUR_SQM of the anchor, the anchor detours off the route
-- toward it. An unreachable Fiendish is ignored for FIENDISH_IGNORE_MS.
--
-- session.cave = {
--   mode = "walk" | "pace" | "halt", idx (waypoint), lap, entryIdx (entry walk),
--   progress = { dist, at }, still = { pos, since }, visible, load, haltPos, haltReached, haltAt, haltWalkUntil,
--   haltGood, haltExclude, haltRepicks, haltCheckAt, haltDeferSince, haltDeferCheckAt,
--   packHalt, blockerId, paceUntil, paceCooldownUntil, lapStartedAt, parked, fought,
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

--- Monsters on screen that halt the walk.
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
	if mode == "halt" then
		cave.haltDeferSince = nil
		cave.haltDeferCheckAt = nil
	else
		cave.haltPos = nil
		cave.haltReached = nil
		cave.haltGood = nil
		cave.haltExclude = nil
		cave.haltRepicks = nil
		cave.haltCheckAt = nil
		cave.packHalt = nil
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

--- Farthest cardinal slot a ranged member holds from the anchor (nil: no ranged).
local function teamLaneDistance(session)
	local laneDist
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
		local d = CombatAutomationMovement.rangedSlotDistance(Player(id))
		if d and (not laneDist or d > laneDist) then
			laneDist = d
		end
	end
	return laneDist
end

local function goodHaltSpot(ring, lanes)
	return (ring or 0) >= ExpeditionConfig.HALT_MIN_RING and (lanes or 0) >= ExpeditionConfig.HALT_MIN_LANES
end

--- Best reachable fight tile (room for a monster ring and lanes out to the ranged
--- slots): pos, score, ring, lanes.
local function findHaltSpot(session, anchor, prefer, exclude)
	return CombatAutomationMovement.bestAnchorSpot(anchor, prefer and toPosition(prefer), teamLaneDistance(session), exclude)
end

--- Walk to `spot`; the walk may take longer the farther it is.
local function setHaltPos(cave, here, spot, ring, lanes, now)
	cave.haltPos = toPosition(spot)
	cave.haltGood = goodHaltSpot(ring, lanes)
	cave.haltReached = nil
	cave.haltWalkUntil = now + ExpeditionConfig.LURE_WAIT_MS * 2 + chebyshev(here, spot) * ExpeditionConfig.HALT_WALK_MS_PER_SQM
	cave.haltCheckAt = now + ExpeditionConfig.HALT_RECHECK_MS
end

--- Halt tile: the hold / current tile when already good, else the best reachable
--- fight tile a few steps away.
local function chooseHaltPos(session, cave, anchor, now, prefer)
	local here = anchor:getPosition()
	cave.haltExclude = {}
	cave.haltRepicks = 0
	local spot, _, ring, lanes = findHaltSpot(session, anchor, prefer)
	setHaltPos(cave, here, spot or here, ring, lanes, now)
end

--- Look again from where the anchor stands. `failed`: the halt tile it cannot reach,
--- excluded from now on; the best reachable tile replaces it. Otherwise (halted on a
--- poor tile) it only moves to a good one. Past HALT_REPICK_MAX moves it stays put.
local function repickHaltPos(session, cave, anchor, here, now, failed)
	cave.haltCheckAt = now + ExpeditionConfig.HALT_RECHECK_MS
	if failed then
		cave.haltExclude[failed.x * 65536 + failed.y] = true
	end
	local spot, _, ring, lanes
	if cave.haltRepicks < ExpeditionConfig.HALT_REPICK_MAX then
		spot, _, ring, lanes = findHaltSpot(session, anchor, nil, cave.haltExclude)
	end
	if spot and not sameTile(spot, here) and (failed or goodHaltSpot(ring, lanes)) then
		cave.haltRepicks = cave.haltRepicks + 1
		setHaltPos(cave, here, spot, ring, lanes, now)
	elseif failed then
		cave.haltPos = toPosition(here)
		cave.haltReached = true
		cave.haltGood = spot ~= nil and sameTile(spot, here) and goodHaltSpot(ring, lanes)
	end
end

--- Lure halt off a hold: fight from the best tile on screen.
local function beginPackHalt(session, cave, anchor, now)
	cave.packHalt = true
	cave.haltAt = now
	chooseHaltPos(session, cave, anchor, now)
end

--- Enter a lure halt. `prefer` (a hold reached with more than LURE_RESUME_LOAD on
--- screen) wins ties for the fight tile, so a leg into a thin area still ends in a fight.
local function enterHalt(session, cave, anchor, now, visible, prefer)
	setMode(cave, "halt")
	cave.packHalt = true
	cave.haltAt = now
	chooseHaltPos(session, cave, anchor, now, prefer)
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
local function updateHalt(session, cave, anchor, here, now, visible, load, fiendishInSight)
	if cave.blockerId and not blockerAlive(cave, here) then
		cave.blockerId = nil
		if not cave.packHalt then
			if visible < ExpeditionCavebot.lureMax(session) and not fiendishInSight then
				setMode(cave, "walk")
				return
			end
			beginPackHalt(session, cave, anchor, now)
		end
	end
	if not cave.packHalt then
		-- The pack caught up while killing the blocker: fight it from a proper tile.
		if visible >= ExpeditionCavebot.lureMax(session) then
			beginPackHalt(session, cave, anchor, now)
		elseif haltStuck(session, cave, now) then
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

--- Off the halt tile and unable to get there (blocked, e.g. a monster took it after
--- the anchor stepped off, or not reached by `haltWalkUntil`): pick the best tile
--- reachable from here instead. Halted on a poor tile: keep looking for a good one.
local function settleHaltPos(session, cave, anchor, here, now)
	local dest = cave.haltPos
	if not dest then
		return
	end
	if sameTile(here, dest) then
		cave.haltReached = true
	elseif CombatAutomationMovement.walkBlocked(anchor, dest) or (not cave.haltReached and now > (cave.haltWalkUntil or 0)) then
		repickHaltPos(session, cave, anchor, here, now, dest)
		return
	end
	if cave.haltReached and not cave.haltGood and now >= (cave.haltCheckAt or 0) then
		repickHaltPos(session, cave, anchor, here, now)
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
--- makes no progress for WAYPOINT_STALL_MS while walking alone is skipped.
local function tickWalk(session, cave, route, anchor, here, now, visible, load)
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
	if dist <= reach or CombatAutomationMovement.walkBlocked(anchor, toPosition(target)) then
		local fightHere = target.hold and not cave.entryIdx and overResumeLoad(load)
		advance(session, cave, route, now)
		if fightHere then
			enterHalt(session, cave, anchor, now, visible, target)
		end
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

local function adjacentEngaged(session, here)
	local n = 0
	for mid in pairs(session.engaged) do
		local monster = Monster(mid)
		if monster and monster:getHealth() > 0 and chebyshev(monster:getPosition(), here) <= 1 then
			n = n + 1
		end
	end
	return n
end

local HALT_DEFER_CHECK_MS = 500

--- Lure full but no good halt tile on screen: keep walking the route (no pacing) for
--- up to HALT_DEFER_MS, unless LURE_WAIT_SKIP_ADJACENT monsters already box the anchor.
local function haltDeferred(session, cave, anchor, here, now)
	cave.haltDeferSince = cave.haltDeferSince or now
	if now - cave.haltDeferSince > ExpeditionConfig.HALT_DEFER_MS
		or adjacentEngaged(session, here) >= ExpeditionConfig.LURE_WAIT_SKIP_ADJACENT
	then
		return false
	end
	if now < (cave.haltDeferCheckAt or 0) then
		return true
	end
	cave.haltDeferCheckAt = now + HALT_DEFER_CHECK_MS
	local _, _, ring, lanes = findHaltSpot(session, anchor)
	return not goodHaltSpot(ring, lanes)
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
			updateHalt(session, cave, anchor, here, now, visible, load, fiendishInSight)
		else
			local target = ExpeditionCavebot.walkTarget(session)
			local blocker = target and stillMs >= ExpeditionConfig.BLOCKER_MS and blockerAhead(anchor, here, target)
			local lureFull = visible >= ExpeditionCavebot.lureMax(session)
			if fiendishInSight or (lureFull and not haltDeferred(session, cave, anchor, here, now)) then
				enterHalt(session, cave, anchor, now, visible)
			elseif blocker then
				enterBlockerHalt(session, cave, now, blocker)
			else
				if lureFull then
					if cave.mode == "pace" then
						setMode(cave, "walk")
					end
				else
					cave.haltDeferSince = nil
					updatePacing(session, cave, here, now, members)
				end
				if cave.mode == "walk" then
					tickWalk(session, cave, route, anchor, here, now, visible, load)
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
--- a halt. In a halt it walks onto the halt tile and fights from it without chasing
--- while more than LURE_RESUME_LOAD is on screen; below that it fights with its
--- normal stance (follow / positioning). Second value: followers
--- trail in line (true) or take formation (false).
function ExpeditionCavebot.anchorDirective(session, anchor)
	local cave, route = session.cave, routeOf(session)
	local here = anchor:getPosition()
	local front = ExpeditionCavebot.travelFront(session, here)
	local tile = cave.parked and route.waypoints[1] or (cave.mode == "halt" and cave.haltPos) or nil
	if cave.parked or cave.mode == "halt" then
		local visible = cave.visible or 0
		if tile and overResumeLoad(cave.load) then
			local priority = sameTile(here, tile) and "soft" or "relocate"
			return { kind = "hold", pos = toPosition(tile), priority = priority, reach = 0, front = front, luring = true }, false
		end
		-- Parked with an empty screen: drift back onto the hold.
		local rest = (tile and visible == 0) and tile or here
		return { kind = "hold", pos = toPosition(rest), priority = "soft", front = front }, false
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
