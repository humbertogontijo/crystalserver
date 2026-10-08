-- Cavebot toggle state. The on/off flag is `autoTarget.cavebot` in the combat
-- automation config (persisted with it, off by default) and needs AUTO attack on. A
-- pause (`pauseCavebot`, the client toggle inside an expedition) lasts
-- CombatAutomationConfig.MANUAL_CONTROL_MS and is runtime only. Inside an expedition the
-- cavebot cannot be stopped: turning it off pauses it.

CavebotStore = CavebotStore or {}

-- playerId -> pausedUntil (ms); cleared by the pause's own timer (pauseEvents)
local pausedUntil = {}
local pauseEvents = {}

local function endPause(id)
	pausedUntil[id] = nil
	if pauseEvents[id] then
		stopEvent(pauseEvents[id])
		pauseEvents[id] = nil
	end
end

local function autoTargetOf(player)
	if not player then
		return nil
	end
	local config = CombatAutomation.getState(player).config or CombatAutomationStore.getConfig(player)
	return config and type(config.autoTarget) == "table" and config.autoTarget or nil
end

local function inExpedition(player)
	local session = ExpeditionManager.getSessionByPlayer(player)
	return session ~= nil and session.state ~= "ended"
end
CavebotStore.inExpedition = inExpedition

function CavebotStore.attackOn(player)
	local at = autoTargetOf(player)
	return at ~= nil and at.enabled == true
end

function CavebotStore.flagOn(player)
	local at = autoTargetOf(player)
	return at ~= nil and at.cavebot == true
end

--- Open world: the player asked for the cavebot (flag and AUTO attack on).
function CavebotStore.isEnabled(player)
	return CavebotStore.flagOn(player) and CavebotStore.attackOn(player)
end

function CavebotStore.pauseMs()
	return CombatAutomationConfig.MANUAL_CONTROL_MS
end

function CavebotStore.pause(player)
	if not player then
		return
	end
	local id, ms = player:getId(), CavebotStore.pauseMs()
	endPause(id)
	pausedUntil[id] = CombatGeo.nowMs() + ms
	pauseEvents[id] = addEvent(function()
		pauseEvents[id] = nil
		pausedUntil[id] = nil
	end, ms)
end

--- Milliseconds left on the player's pause (0 when not paused).
function CavebotStore.pausedMs(player)
	local untilMs = player and pausedUntil[player:getId()]
	return untilMs and math.max(0, untilMs - CombatGeo.nowMs()) or 0
end

--- Hand the player's movement back to the AI now: ends a pause and manual control.
function CavebotStore.resume(player)
	if not player then
		return
	end
	endPause(player:getId())
	player:clearManualControl()
end

function CavebotStore.forget(player)
	if player then
		endPause(player:getId())
	end
end

--- Why the walker leaves this member alone, or nil: "manual" (their own walk / follow
--- input), "pause" (paused cavebot), "attack" (AUTO attack off; open-world runs drop
--- such members instead).
function CavebotStore.pauseReason(player, _run)
	if CombatAutomationMovement.isManual(player) then
		return "manual"
	end
	if pausedUntil[player:getId()] then
		return "pause"
	end
	if not CavebotStore.attackOn(player) then
		return "attack"
	end
	return nil
end

--- setConfig hook (before persist): inside an expedition turning the cavebot off pauses
--- it and keeps the flag.
function CavebotStore.filterConfig(player, config, existing)
	local at, prev = config.autoTarget, existing and existing.autoTarget
	if type(at) ~= "table" or type(prev) ~= "table" then
		return
	end
	if prev.cavebot == true and at.cavebot ~= true and inExpedition(player) then
		at.cavebot = true
		if at.enabled == true then
			CavebotStore.pause(player)
		end
	end
end

--- applyToRuntime hook: the flag or AUTO attack may have changed.
function CavebotStore.onConfigChanged(player)
	CavebotService.refresh(player)
end
