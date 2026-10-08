-- Cavebot client wire (opcode 113, the combat automation channel).
--
-- S→C { type = "cavebot", state = "on" | "paused" | "stopped", inExpedition,
--   reason (stopped: why it is not running), pauseReason, pausedMs, phase,
--   anchorId, isAnchor, routeSource = "catalog" | "generated", huntName } — on change.
-- C→S { action = "pauseCavebot" } | { action = "resumeAuto" }; the on/off flag rides
--   setAutomation (`autoTarget.cavebot`).

CavebotProtocol = CavebotProtocol or {}

-- playerId -> last encoded frame
local lastSent = {}

local send = IdleUtil.jsonSender(CombatAutomationConfig.OPCODE)

local function phaseOf(run)
	local cave = run.cave
	if not cave then
		return nil
	end
	if cave.manual then
		return "waiting"
	end
	if cave.parked then
		return "parked"
	end
	return cave.mode
end

function CavebotProtocol.stateOf(player)
	local id = player:getId()
	local inExpedition = CavebotStore.inExpedition(player)
	local frame = { type = "cavebot", inExpedition = inExpedition }
	local run = Cavebot.runOfPlayer(player)
	if run then
		local reason = run.pauseReasons and run.pauseReasons[id]
		frame.state = reason and "paused" or "on"
		frame.pauseReason = reason
		frame.phase = phaseOf(run)
		frame.anchorId = run.anchorPlayerId
		frame.isAnchor = run.anchorPlayerId == id
		if run.open then
			frame.routeSource = run.routeSource
			frame.huntName = run.huntName
		else
			frame.routeSource = "catalog"
			frame.huntName = run.catalog and run.catalog.name or nil
		end
	else
		frame.state = "stopped"
		frame.reason = CavebotService.stoppedReason(player) or nil
	end
	local pausedMs = CavebotStore.pausedMs(player)
	if pausedMs > 0 then
		-- Rounded so the dedupe does not resend every tick.
		frame.pausedMs = math.ceil(pausedMs / 1000) * 1000
	end
	return frame
end

function CavebotProtocol.sendState(player, force)
	if not player then
		return false
	end
	local frame = CavebotProtocol.stateOf(player)
	local encoded = JsonParser.encode(frame)
	local id = player:getId()
	if not force and lastSent[id] == encoded then
		return false
	end
	lastSent[id] = encoded
	return send(player, frame)
end

function CavebotProtocol.sendRun(run)
	for _, id in ipairs(Cavebot.memberIds(run)) do
		CavebotProtocol.sendState(Player(id))
	end
end

function CavebotProtocol.forget(player)
	if player then
		lastSent[player:getId()] = nil
	end
end

--- Pause / resume actions. Returns true when consumed.
function CavebotProtocol.handleAction(player, msg)
	local action = msg.action
	if action == "pauseCavebot" then
		CavebotStore.pause(player)
		CavebotProtocol.sendState(player)
		return true
	end
	if action == "resumeAuto" then
		CavebotStore.resume(player)
		CavebotProtocol.sendState(player)
		return true
	end
	return false
end
