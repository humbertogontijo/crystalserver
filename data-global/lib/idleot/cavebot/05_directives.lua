-- Paused members and movement directives for a cave run (expedition or open world).

local function resumable(reason)
	return reason == "manual" or reason == "pause"
end
Cavebot.isResumablePause = resumable

--- Members the walker leaves alone (`run.manualIds`: id -> true, `run.pauseReasons`:
--- id -> CavebotStore.pauseReason). Pausing drops the AI's queued walk; resuming
--- resets positioning and, for the anchor, picks the route up from where it stands.
--- A paused member keeps its anchor role (no re-election). `onChange(player, reason,
--- prevReason)` runs for each member whose reason changed.
function Cavebot.syncManual(run, onChange)
	local before = run.pauseReasons or {}
	local manual, reasons, changed = {}, {}, false
	for _, id in ipairs(Cavebot.memberIds(run)) do
		local player = Player(id)
		local reason = player and CavebotStore.pauseReason(player, run) or nil
		if reason then
			manual[id] = true
			reasons[id] = reason
			if not before[id] then
				CombatAutomationMovement.onManualControl(player)
			end
		end
		if player and reason ~= before[id] then
			changed = true
			if onChange then
				onChange(player, reason, before[id])
			end
		end
	end
	run.manualIds = manual
	run.pauseReasons = reasons
	local anchor = Cavebot.anchorOf(run)
	for id in pairs(before) do
		local player = not manual[id] and Player(id)
		if player then
			changed = true
			CombatAutomationMovement.onAutoResumed(player)
			if anchor and anchor:getId() == id and run.cave then
				Cavebot.resume(run, anchor)
			end
		end
	end
	if changed and CavebotProtocol then
		CavebotProtocol.sendRun(run)
	end
end

--- Movement directives: the anchor walks the cave route or holds `opts.holdPos` (boss /
--- arena / before the walk starts); the others trail loosely behind it and take
--- formation around it only while attacking. Paused members get none; while the anchor
--- is paused, the others form on it wherever it stands. `opts.noAnchor`: no anchor at
--- all (raids), every member fights by its own stance.
function Cavebot.syncDirectives(run, opts)
	if not run or not CombatAutomationMovement then
		return
	end
	opts = opts or {}
	local move = CombatAutomationMovement
	local anchor = Cavebot.anchorOf(run)
	local anchorId = anchor and anchor:getId() or run.anchorPlayerId
	local manual = run.manualIds or {}

	local anchorDirective, walking = nil, false
	if not opts.noAnchor and anchor then
		if manual[anchorId] then
			anchorDirective = { kind = "hold", pos = anchor:getPosition(), priority = "soft" }
		elseif run.cave then
			anchorDirective, walking = Cavebot.anchorDirective(run, anchor)
		elseif opts.holdPos then
			local hold = opts.holdPos
			anchorDirective = { kind = "hold", pos = Position(hold.x, hold.y, hold.z), priority = "soft", home = true }
		end
	end

	for _, id in ipairs(Cavebot.memberIds(run)) do
		local player = Player(id)
		if player and not PzTeleport.isGod(player) then
			if opts.noAnchor or manual[id] then
				move.clearDirective(player)
			elseif id == anchorId then
				if anchorDirective then
					move.setDirective(player, anchorDirective)
				else
					move.clearDirective(player)
				end
			elseif anchorId and anchorDirective then
				if walking then
					move.setDirective(player, { kind = "follow", targetId = anchorId, front = anchorDirective.front })
				else
					move.setDirective(player, { kind = "anchorStance", targetId = anchorId, front = anchorDirective.front })
				end
			else
				move.clearDirective(player)
			end
		end
	end
end
