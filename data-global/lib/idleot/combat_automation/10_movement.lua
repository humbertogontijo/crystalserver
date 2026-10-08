-- Automation movement, directives and the per-tick driver (CombatAutomationMovement.tick).
-- Walk primitives: 06_walk; danger: 07_danger; halt spot: 08_halt_spot; formation:
-- 09_formation. They share file-local helpers through MOVE_PRIV.

local geo = CombatGeo
local nowMs, sameTile, chebyshev, faceToward, walkDestKey = geo.nowMs, geo.sameTile, geo.chebyshev, geo.faceToward, geo.posKey
local settings = CombatAutomationConfig
local isManual = CombatAutomationMovement.isManual
local clearFollowIfAny, clearPendingWalkAction, walkTowardCreature = MOVE_PRIV.clearFollowIfAny, MOVE_PRIV.clearPendingWalkAction, MOVE_PRIV.walkTowardCreature
local driveMember, autoEnabled, applyCreatureStance, haltStep = MOVE_PRIV.driveMember, MOVE_PRIV.autoEnabled, MOVE_PRIV.applyCreatureStance, MOVE_PRIV.haltStep

local FOCUS_GRACE_MS = 1000

--- The expedition anchor this member forms on (follow / anchorStance directive).
function CombatAutomationMovement.directiveAnchor(state)
	local directive = state and state.directive
	if not directive or (directive.kind ~= "anchorStance" and directive.kind ~= "follow") then
		return nil
	end
	return Player(tonumber(directive.targetId) or 0)
end

--- Kiting room past the slot ring around a ranged anchor's fight spot.
local HOME_LEASH_MARGIN = 2

--- A ranged anchor holding a fight spot (`directive.home`) is leashed around it (path
--- search and tile scoring), so kiting does not drag the pack away; cleared otherwise.
local function syncHomeLeash(player, state)
	local directive = state.directive
	local home = directive and directive.kind == "hold" and directive.home and directive.pos or nil
	if home and not CombatAutomationMovement.rangedStance(player) then
		home = nil
	end
	local radius = home and CombatAutomationMovement.memberSlotDistance(player) + HOME_LEASH_MARGIN or nil
	local key = home and (walkDestKey(home) .. ":" .. radius) or nil
	if key == state.homeLeashKey then
		return
	end
	state.homeLeashKey = key
	if home then
		player:setPathLeash(home, radius)
	else
		player:clearPathLeash()
	end
end

function CombatAutomationMovement.setDirective(player, directive)
	local state = CombatAutomation.getState(player)
	if not state then
		return
	end
	local prev = state.directive
	if type(directive) ~= "table" or not directive.kind then
		if prev and prev.kind == "follow" then
			clearFollowIfAny(player)
		end
		state.directive = nil
	else
		if prev and prev.kind == "follow" and directive.kind ~= "follow" then
			clearFollowIfAny(player)
		end
		state.directive = directive
	end
	syncHomeLeash(player, state)
end

function CombatAutomationMovement.clearDirective(player, kind)
	local state = CombatAutomation.getState(player)
	if not state or not state.directive then
		return
	end
	if kind == nil or state.directive.kind == kind then
		if state.directive.kind == "follow" then
			clearFollowIfAny(player)
		end
		state.directive = nil
		syncHomeLeash(player, state)
	end
end

--- Drop a deferred walk-then-act (Use / use-with) so automation can walk again.
function CombatAutomationMovement.clearPendingWalkAction(player)
	clearPendingWalkAction(player)
end

--- Companion beyond the anchor's screen (or CATCH_UP_WALK_SQM) walks back toward it,
--- until within half that distance (hysteresis so fighting near the edge does not flap).
local function driveCatchUp(player, anchor, state)
	if not player or not anchor or not state then
		return false
	end
	local ppos = player:getPosition()
	local apos = anchor:getPosition()
	if not ppos or not apos or ppos.z ~= apos.z then
		state.catchingUp = nil
		return false
	end
	local walkSqm = settings.CATCH_UP_WALK_SQM
	local dist = chebyshev(ppos, apos)
	if state.catchingUp then
		if dist <= math.floor(walkSqm / 2) then
			state.catchingUp = nil
			return false
		end
	elseif dist > walkSqm or not geo.isInViewport(apos, ppos) then
		state.catchingUp = true
	else
		return false
	end
	clearFollowIfAny(player)
	local maxSearch = settings.CATCH_UP_PATH_MAX
	walkTowardCreature(player, anchor, 2, maxSearch)
	return true
end

--- Per-tick positioning: follow → anchorStance → hold → stance vs attack target.
--- Members form up around the anchor only while attacking; otherwise they trail it.
function CombatAutomationMovement.tick(player, config)
	if not player or isManual(player) or PlayerErrand.owns(player) then
		return
	end
	-- Let walk-then-act (Use / use-with) finish without stance/hold stealing the path.
	if player:hasWalkTask() then
		return
	end

	config = config or {}
	local state = CombatAutomation.getState(player)
	local pendingStep = state and state.pendingAreaCast
	if pendingStep then
		clearFollowIfAny(player)
		-- Idle tick: walk already finished. Do not start another step.
		if not pendingStep.idle then
			local ppos = player:getPosition()
			local dest = Position(pendingStep.x, pendingStep.y, pendingStep.z)
			if not ppos or not sameTile(ppos, dest) then
				if nowMs() < (pendingStep.untilMs or 0) then
					CombatAutomationMovement.queueWalkToward(player, dest, true)
				end
			end
		end
		return
	end
	if state and state.skipStanceForAreaCast then
		clearFollowIfAny(player)
		return
	end

	local directive = state and state.directive or nil
	local anchor = CombatAutomationMovement.directiveAnchor(state)

	if anchor then
		if driveCatchUp(player, anchor, state) then
			return
		end
	elseif state then
		state.catchingUp = nil
	end

	-- Luring: trail the anchor (no target, so no formation).
	if directive and directive.kind == "follow" then
		if anchor then
			driveMember(player, anchor, nil, config, state)
		end
		return
	end

	local autoOn = autoEnabled(config)
	local target = player:getTarget()
	local hasFocus = target
		and CombatAutomation.isValidAttackTarget
		and CombatAutomation.isValidAttackTarget(player, target)
		and geo.isInViewport(player:getPosition(), target:getPosition())
	if hasFocus and state then
		state.focusAt = nowMs()
	end
	-- Between kills: stay put rather than stepping back to the trail for one tick.
	local betweenTargets = not hasFocus and state and nowMs() - (state.focusAt or 0) < FOCUS_GRACE_MS

	if directive and directive.kind == "anchorStance" then
		if hasFocus and autoOn then
			applyCreatureStance(player, target, config, anchor)
			return
		end
		if betweenTargets and autoOn then
			return
		end
		-- Halt without a target (pack still arriving): trail, form up once attacking.
		if anchor and autoOn then
			driveMember(player, anchor, nil, config, state)
		elseif not autoOn then
			clearFollowIfAny(player)
		end
		return
	end

	if directive and directive.kind == "hold" then
		local hold = directive.pos
		local relocatePriority = directive.priority == "relocate"
		if hold and directive.luring then
			-- Luring (cave walk / pacing): keep to the route and attack only what is in
			-- range; never chase, so the pack follows the anchor instead.
			clearFollowIfAny(player)
			if relocatePriority then
				CombatAutomationMovement.queueWalkToward(player, hold, false, true, directive.reach, directive.quiet)
			else
				if hasFocus then
					if not (directive.halt and autoOn and haltStep(player, target, config, state)) then
						faceToward(player, target:getPosition())
					end
				elseif type(directive.front) == "table" then
					local ppos = player:getPosition()
					faceToward(player, Position(ppos.x + directive.front[1], ppos.y + directive.front[2], ppos.z))
				end
			end
			return
		end
		if betweenTargets and autoOn and not relocatePriority then
			return
		end
		if hold and (relocatePriority or not hasFocus or not autoOn) then
			clearFollowIfAny(player)
			if autoOn or relocatePriority then
				if not sameTile(player:getPosition(), hold) then
					-- Do not force-repath every tick: queueWalkToward keeps a walk that
					-- already ends there.
					CombatAutomationMovement.queueWalkToward(player, hold, false, relocatePriority, directive.reach, directive.quiet)
				else
					-- Tank waits facing where the pack comes from.
					local front = directive.front
					if not hasFocus and type(front) == "table" then
						faceToward(player, Position(hold.x + front[1], hold.y + front[2], hold.z))
					end
				end
			end
			return
		end
		-- Has combat focus while hold is soft: demote to stance.
		if hasFocus and autoOn and not relocatePriority then
			applyCreatureStance(player, target, config)
			return
		end
	end

	if hasFocus and autoOn then
		applyCreatureStance(player, target, config)
	else
		-- Never keep trailing an old follow target once directives are gone.
		clearFollowIfAny(player)
	end
end

--- Client input took over movement: drop the AI's queued walk and positioning state
--- (a pending walk-then-act is the player's own and stays).
function CombatAutomationMovement.onManualControl(player)
	if not player then
		return
	end
	local state = CombatAutomation.getState(player)
	if state then
		state.pendingAreaCast = nil
		state.catchingUp = nil
		state.retreating = nil
	end
end

function CombatAutomationMovement.onAutoResumed(player)
	if not player then
		return
	end
	clearPendingWalkAction(player)
	clearFollowIfAny(player)
	local state = CombatAutomation.getState(player)
	if state then
		state.pendingAreaCast = nil
		state.skipStanceForAreaCast = nil
		state.areaCastSlotId = nil
		state.areaFace = nil
	end
end
