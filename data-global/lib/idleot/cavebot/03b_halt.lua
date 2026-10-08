-- Cavebot walker, halt (killing box): the halt tile, blocker halts and when a halt ends.

local geo = CombatGeo
local chebyshev, sameTile, signOf, toPosition = geo.chebyshev, geo.sameTile, geo.signOf, geo.toPosition
local setMode, overResumeLoad = CAVE_PRIV.setMode, CAVE_PRIV.overResumeLoad

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
	local halt = cave.halt
	halt.pos = toPosition(spot)
	halt.reached = nil
	halt.setAt = now
end

--- Halt tile: the best spot within `steps` (default HALT_SPOT_STEPS) of `center` (the
--- hold; default the anchor's tile).
local function chooseHaltPos(run, cave, anchor, now, center, steps)
	local halt = cave.halt
	halt.center = toPosition(center) or anchor:getPosition()
	halt.steps = steps or CavebotConfig.HALT_SPOT_STEPS
	halt.exclude = {}
	halt.repicks = 0
	setHaltPos(cave, findHaltSpot(run, anchor, halt.center, halt.steps) or halt.center, now)
end

--- `failed`: the halt tile the anchor cannot reach, excluded from now on; the next
--- best near the same centre replaces it. Past HALT_REPICK_MAX picks (or with no
--- other tile) it takes the most open free tile next to it once, then fights where
--- it stands.
local function repickHaltPos(run, cave, anchor, here, now, failed)
	local halt = cave.halt
	halt.exclude[CombatGeo.tileKey(failed.x, failed.y)] = true
	local spot
	if halt.repicks < CavebotConfig.HALT_REPICK_MAX then
		halt.repicks = halt.repicks + 1
		spot = findHaltSpot(run, anchor, halt.center, halt.steps, halt.exclude)
	end
	if not spot and not halt.fallback then
		halt.fallback = true
		spot = findHaltSpot(run, anchor, here, 1, halt.exclude)
		if spot and sameTile(spot, here) then
			spot = nil
		end
	end
	if spot then
		setHaltPos(cave, spot, now)
	else
		halt.pos = toPosition(here)
		halt.reached = true
	end
end

--- Fight at the best spot within `steps` of `center` (the hold; default where the
--- anchor stands).
local function enterHalt(run, cave, anchor, now, visible, center, steps)
	setMode(cave, "halt")
	cave.halt.at = now
	chooseHaltPos(run, cave, anchor, now, center, steps)
	Cavebot.metric(run, "onHalt", visible)
end

local function enterBlockerHalt(run, cave, now, blocker)
	setMode(cave, "halt")
	local halt = cave.halt
	halt.blockerId = blocker:getId()
	halt.at = now
	Cavebot.metric(run, "onBlockerHalt")
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
	local halt = cave.halt
	local monster = halt.blockerId and Monster(halt.blockerId)
	return monster ~= nil and monster:getHealth() > 0 and chebyshev(monster:getPosition(), here) <= 1
end

--- No kill or Fiendish hit for HALT_STUCK_MS since the halt began.
local function haltStuck(run, cave, now)
	local progressAt = math.max(cave.halt.at or now, run.lastKillAt or 0, cave.fiendishHitAt or 0)
	return now - progressAt > CavebotConfig.HALT_STUCK_MS
end

--- `fiendishInSight`: the forced Fiendish is on screen, so the halt holds until it dies.
--- A blocker halt walks on once the blocker is dead (to the next hold).
local function updateHalt(run, cave, anchor, here, now, load, fiendishInSight)
	local halt = cave.halt
	if halt.blockerId then
		if blockerAlive(cave, here) and not haltStuck(run, cave, now) then
			return
		end
		halt.blockerId = nil
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
local function anchorStep(anchor, halt)
	local state = CombatAutomation.getState(anchor)
	local step = state and state.anchorAdoptPos
	if not step or (state.anchorAdoptAt or 0) < (halt.setAt or 0) then
		return nil
	end
	state.anchorAdoptPos = nil
	return step
end

--- Off the halt tile with no path there: pick again near the same centre. The
--- anchor's boss dodge step becomes the halt tile.
local function settleHaltPos(run, cave, anchor, here, now)
	local halt = cave.halt
	if not (halt and halt.pos) then
		return
	end
	local step = anchorStep(anchor, halt)
	if step and step.z == halt.pos.z then
		halt.pos = toPosition(step)
	end
	local dest = halt.pos
	if sameTile(here, dest) then
		halt.reached = true
	elseif halt.reached and CombatAutomationMovement.rangedStance(anchor) then
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
			Cavebot.metric(run, "onHalt", visible)
		end
		cave.fought = true
	else
		cave.fought = nil
	end
end


CAVE_PRIV.enterHalt = enterHalt
CAVE_PRIV.findHaltSpot = findHaltSpot
CAVE_PRIV.tickParked = tickParked
CAVE_PRIV.updateHalt = updateHalt
CAVE_PRIV.blockerAhead = blockerAhead
CAVE_PRIV.enterBlockerHalt = enterBlockerHalt
CAVE_PRIV.settleHaltPos = settleHaltPos
