-- Cavebot walker, the per-tick driver (Cavebot.tick / Cavebot.step). State and the
-- walker overview: 03a_state; halt: 03b_halt; walking: 03c_walk. They share
-- file-local helpers through CAVE_PRIV.

local geo = CombatGeo
local nowMs = geo.nowMs
local routeOf = Cavebot.routeOf
local trackStill, tickParked, trackFiendishHp, updateDetour = CAVE_PRIV.trackStill, CAVE_PRIV.tickParked, CAVE_PRIV.trackFiendishHp, CAVE_PRIV.updateDetour
local updateHalt, blockerAhead, enterHalt, enterBlockerHalt = CAVE_PRIV.updateHalt, CAVE_PRIV.blockerAhead, CAVE_PRIV.enterHalt, CAVE_PRIV.enterBlockerHalt
local enterLureFullHalt, setMode, updateLeash, tickWalk = CAVE_PRIV.enterLureFullHalt, CAVE_PRIV.setMode, CAVE_PRIV.updateLeash, CAVE_PRIV.tickWalk
local settleHaltPos = CAVE_PRIV.settleHaltPos

-- ---------------------------------------------------------------------------
-- Tick (Cavebot.step, every TICK_MS)
-- ---------------------------------------------------------------------------

--- One walk tick. `pack`: this tick's CavebotPack.snapshot.
function Cavebot.tick(run, anchor, members, pack)
	local cave, route = run.cave, routeOf(run)
	if not cave or not route then
		return
	end
	local here = anchor:getPosition()
	local now = nowMs()
	local prevMode = cave.mode
	local manual = run.manualIds or {}

	local visible, load = CavebotPack.lureCount(pack, anchor, members)
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
	local host = Cavebot.hostOf(run)
	local fiendish = host.priorityTarget and host.priorityTarget(run) or nil
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
				setMode(cave, updateLeash(pack, cave, here, now, leashMembers) and "pace" or "walk")
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

--- One walker tick of a run (expedition sessions and open-world runs alike): paused
--- members, pack tracking, the route walk (while the host walks it) and the movement
--- directives.
function Cavebot.step(run)
	local host = Cavebot.hostOf(run)
	Cavebot.syncManual(run, host.onPauseChange and function(player, reason, prev)
		host.onPauseChange(run, player, reason, prev)
	end)
	local anchor = Cavebot.anchorOf(run)
	if anchor and run.cave and (not host.walks or host.walks(run)) then
		local members = Cavebot.memberSet(run)
		local pack = CavebotPack.snapshot(run, anchor, members, host.adopt)
		if host.adopt then
			CavebotPack.adoptEngaged(run, members, pack)
		end
		CavebotPack.tickPack(run, anchor:getPosition(), members)
		pack.chasers = CavebotPack.chasers(run, members, anchor:getPosition(), nowMs(), true)
		Cavebot.metric(run, "tick", anchor, Cavebot.memberIds(run))
		Cavebot.tick(run, anchor, members, pack)
	end
	if host.alive and not host.alive(run) then
		return
	end
	Cavebot.syncDirectives(run, host.directives and host.directives(run))
end
