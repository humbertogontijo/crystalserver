-- Open-world cavebot: players with the cavebot on (CavebotStore.isEnabled) on a public
-- hunt / wild layer walk a cave route (CavebotRoutes) together. A run is a party (or a
-- solo player) on one layer; its anchor is elected among the members (every member has
-- the cavebot on: a stopped one leaves the run) and kept while it stays a member, so a
-- paused anchor is never replaced. Members get idle combat (250 ms think cadence,
-- manual-control detection) while they are in a run; a disconnected member leaves it.
-- Monsters are tracked only once they target a member (CavebotPack.adoptEngaged).

CavebotService = CavebotService or {}

-- playerId -> true: cavebot flag and AUTO attack on (checked for a layer every tick)
local enrolled = {}
-- runId -> run
local runs = {}
-- playerId -> runId
local runOf = {}
-- playerId -> true: idle combat turned on by the service
local idleOwned = {}
local tickEvent = nil

local function groupLeaderId(player)
	local party = player:getParty()
	local leader = party and party:getLeader()
	return leader and leader:getId() or player:getId()
end

--- Layer key the player may run the cavebot on, or nil and why not.
local function eligibleLayer(player)
	if player:getHealth() <= 0 then
		return nil, "dead"
	end
	if PzTeleport.isGod(player) then
		return nil, "god"
	end
	if CavebotStore.inExpedition(player) then
		return nil, "expedition"
	end
	if player:isHeadless() then
		return nil, "offline"
	end
	if not CavebotStore.isEnabled(player) then
		return nil, CavebotStore.flagOn(player) and "attack" or "off"
	end
	local key = player:getInstanceId()
	local kind = Instance.kind(key)
	if not kind or not CavebotConfig.OPEN_KINDS[kind] or Instance.isPrivate(key) then
		return nil, "area"
	end
	return key
end

local function ownIdleCombat(player)
	if not player:isIdleCombat() then
		player:setIdleCombat(true)
		idleOwned[player:getId()] = true
	end
end

local function releaseMember(id)
	runOf[id] = nil
	local player = Player(id)
	if not player then
		idleOwned[id] = nil
		return
	end
	CombatAutomationMovement.clearDirective(player)
	CombatAutomationMovement.clearWalkDedupe(player)
	if player.clearPathLeash then
		player:clearPathLeash()
	end
	if idleOwned[id] then
		idleOwned[id] = nil
		if not CavebotStore.inExpedition(player) and player:isIdleCombat() then
			player:setIdleCombat(false)
		end
	end
	CavebotProtocol.sendState(player)
end

local function newRun(runId, instanceKey)
	local run = {
		open = true,
		id = runId,
		instanceId = instanceKey,
		ids = {},
		tracked = {},
		engaged = {},
		releasedUntil = {},
		kills = 0,
	}
	runs[runId] = run
	return run
end

local function closeRun(run)
	runs[run.id] = nil
	CavebotPack.clearOwners(run.id)
end

local function resetWalk(run)
	run.cave = nil
	run.engaged = {}
	run.releasedUntil = {}
end

--- Keep the anchor while it is a living member; else elect (Cavebot.bestAnchor).
local function electAnchor(run, members)
	local current = run.anchorPlayerId and members[run.anchorPlayerId] and Player(run.anchorPlayerId)
	if current and current:getHealth() > 0 then
		return current
	end
	local candidates = {}
	for _, id in ipairs(run.ids) do
		local player = Player(id)
		if player and player:getHealth() > 0 then
			candidates[#candidates + 1] = player
		end
	end
	if #candidates == 0 then
		run.anchorPlayerId = nil
		return nil
	end
	local anchor = Cavebot.bestAnchor(candidates)
	run.anchorPlayerId = anchor:getId()
	if run.cave then
		Cavebot.resume(run, anchor)
	end
	Cavebot.notify(run)
	return anchor
end

--- Route on the anchor's floor: re-resolved when the anchor changes floor or none was found.
local function ensureRoute(run, anchor)
	local pos = anchor:getPosition()
	if run.route and run.routeZ == pos.z then
		return true
	end
	if run.routeRetryAt and CombatGeo.nowMs() < run.routeRetryAt and run.routeZ == pos.z then
		return false
	end
	local route, source, name = CavebotRoutes.resolve(anchor, run.instanceId)
	run.routeZ = pos.z
	if route ~= run.route then
		resetWalk(run)
	end
	run.route, run.routeSource, run.huntName = route, source, name
	run.routeRetryAt = not route and CombatGeo.nowMs() + 5000 or nil
	Cavebot.notify(run)
	return route ~= nil
end

local function tickRun(run)
	local members = Cavebot.memberSet(run)
	for _, id in ipairs(run.ids) do
		local player = Player(id)
		if player then
			ownIdleCombat(player)
		end
	end
	local anchor = electAnchor(run, members)
	if not anchor or not ensureRoute(run, anchor) then
		for _, id in ipairs(run.ids) do
			local player = Player(id)
			if player then
				CombatAutomationMovement.clearDirective(player)
			end
		end
		return
	end
	if not run.cave then
		Cavebot.start(run)
		Cavebot.resume(run, anchor)
	end
	Cavebot.syncManual(run)
	CavebotPack.adoptEngaged(run, members)
	CavebotPack.tickPack(run, anchor:getPosition(), members)
	Cavebot.tick(run, anchor, members)
	Cavebot.syncDirectives(run)
end

local schedule

local function tick()
	tickEvent = nil
	local groups = {}
	for id in pairs(enrolled) do
		local player = Player(id)
		if not player then
			enrolled[id] = nil
		else
			local key = eligibleLayer(player)
			if key then
				local runId = string.format("%s|%d", key, groupLeaderId(player))
				local group = groups[runId]
				if not group then
					group = { key = key, ids = {}, set = {} }
					groups[runId] = group
				end
				group.ids[#group.ids + 1] = id
				group.set[id] = true
			end
		end
	end
	for id, runId in pairs(runOf) do
		local group = groups[runId]
		if not group or not group.set[id] then
			releaseMember(id)
		end
	end
	for runId, run in pairs(runs) do
		if not groups[runId] then
			closeRun(run)
		end
	end
	for runId, group in pairs(groups) do
		table.sort(group.ids)
		local run = runs[runId] or newRun(runId, group.key)
		run.ids = group.ids
		for _, id in ipairs(group.ids) do
			if not runOf[id] then
				runOf[id] = runId
				CavebotProtocol.sendState(Player(id))
			end
		end
		tickRun(run)
	end
	schedule()
end

schedule = function()
	if not tickEvent and next(enrolled) then
		tickEvent = addEvent(tick, CavebotConfig.TICK_MS)
	end
end

function CavebotService.getRun(runId)
	return runs[runId]
end

--- The player's open-world run, once it walks a route.
function CavebotService.runOfPlayer(player)
	local runId = player and runOf[player:getId()]
	local run = runId and runs[runId]
	return run and run.cave and run or nil
end

--- Why the cavebot is not running for `player` (frame `reason`).
function CavebotService.stoppedReason(player)
	local key, reason = eligibleLayer(player)
	if not key then
		return reason
	end
	local runId = runOf[player:getId()]
	local run = runId and runs[runId]
	if run and not run.route then
		return "noRoute"
	end
	return "starting"
end

--- The cavebot flag or AUTO attack changed (CavebotStore.onConfigChanged).
function CavebotService.refresh(player)
	if not player then
		return
	end
	local id = player:getId()
	if CavebotStore.isEnabled(player) then
		enrolled[id] = true
		schedule()
	else
		enrolled[id] = nil
		if runOf[id] then
			releaseMember(id)
		end
	end
	CavebotProtocol.sendState(player)
end

function CavebotService.onLogout(player)
	local id = player:getId()
	enrolled[id] = nil
	if runOf[id] then
		releaseMember(id)
	end
	idleOwned[id] = nil
	CavebotStore.forget(player)
	CavebotProtocol.forget(player)
end
