-- Cavebot walker, walking: the lure leash (pace), waypoint progress, the Fiendish
-- detour and the lure-full halt.

local geo = CombatGeo
local chebyshev, sameTile, toPosition, Progress = geo.chebyshev, geo.sameTile, geo.toPosition, geo.Progress
local overResumeLoad, advance, enterHalt, findHaltSpot = CAVE_PRIV.overResumeLoad, CAVE_PRIV.advance, CAVE_PRIV.enterHalt, CAVE_PRIV.findHaltSpot

-- ---------------------------------------------------------------------------
-- Walk and pacing
-- ---------------------------------------------------------------------------

--- The lure leash over the chasers (`CavebotPack.chasers`: engaged monsters on any
--- member, not only the anchor): `target` = the largest distance from one to the
--- member it chases (its lock), `anchor` = the largest distance from one to the anchor
--- (the halt box), `laggers` = engaged entries of the chasers outside the resume
--- distances, `adjacent` = chasers next to the anchor. A chaser given up on
--- (`lagStuckUntil`) counts again once it is back inside the resume distances. Only
--- chasers on `members` count (`pack.chasers` holds those of every member).
local function packLag(pack, here, members, now)
	local resumeTarget = CavebotConfig.LURE_LAG_RESUME_SQM
	local resumeAnchor = CavebotConfig.LURE_LEASH_SQM - 2
	local lag = { target = 0, anchor = 0, adjacent = 0, laggers = {} }
	for _, chaser in ipairs(pack.chasers) do
		if members[chaser.target:getId()] then
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
--- waited for are then given up on for PULL_STALL_MS. `cave.paceProgress` tracks
--- the best total lag while waiting.
local function updateLeash(pack, cave, here, now, members)
	local lag = packLag(pack, here, members, now)
	if not leashWants(lag, cave.paceProgress ~= nil) then
		cave.paceProgress = nil
		return false
	end
	local total = lag.target + lag.anchor
	cave.paceProgress = cave.paceProgress or Progress.new(now)
	if Progress.improve(cave.paceProgress, total, now) then
		return true
	end
	if Progress.stalled(cave.paceProgress, now, CavebotConfig.LURE_LAG_STALL_MS) then
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
			cave.progress = Progress.new(now)
		end
		return
	end
	if not fiendish or inSight or cave.entryIdx or now < (cave.fiendishIgnoreUntil or 0) then
		return
	end
	local fpos = fiendish:getPosition()
	if chebyshev(here, fpos) <= CavebotConfig.FIENDISH_DETOUR_SQM then
		cave.detour = { x = fpos.x, y = fpos.y, z = fpos.z }
		cave.detourProgress = Progress.new(now)
	end
end

--- Detour that cannot path or makes no progress for WAYPOINT_STALL_MS is abandoned
--- and the Fiendish ignored for FIENDISH_IGNORE_MS.
local function tickDetour(cave, anchor, here, now)
	local progress = cave.detourProgress
	if Progress.improve(progress, chebyshev(here, cave.detour), now) then
		return
	end
	if CombatAutomationMovement.walkBlocked(anchor, toPosition(cave.detour))
		or Progress.stalled(progress, now, CavebotConfig.WAYPOINT_STALL_MS)
	then
		cave.detour = nil
		cave.fiendishIgnoreUntil = now + CavebotConfig.FIENDISH_IGNORE_MS
		cave.progress = Progress.new(now)
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
	if Progress.improve(progress, dist, now) then
		return
	end
	if visible > 0 then
		progress.at = now
	elseif Progress.stalled(progress, now, CavebotConfig.WAYPOINT_STALL_MS) then
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


CAVE_PRIV.trackStill = trackStill
CAVE_PRIV.trackFiendishHp = trackFiendishHp
CAVE_PRIV.updateDetour = updateDetour
CAVE_PRIV.enterLureFullHalt = enterLureFullHalt
CAVE_PRIV.updateLeash = updateLeash
CAVE_PRIV.tickWalk = tickWalk
