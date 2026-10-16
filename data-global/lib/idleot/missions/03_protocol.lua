-- Mission start / advance on expedition opcode 113.

function IdleMission.handleAction(player, msg)
	if not player or type(msg) ~= "table" then
		return false
	end
	local action = msg.action
	if action == "missionStart" then
		local key = msg.missionKey or msg.key
		if not key and msg.id then
			local def = IdleMission.byCatalogId(msg.id)
			key = def and def.key
		end
		local ok, err = IdleMission.start(player, key)
		if not ok then
			ExpeditionProtocol.sendError(player, err or "Could not start mission.")
		end
		return true
	end
	if action == "missionAdvance" then
		local ok, err = IdleMission.advance(player)
		if not ok then
			ExpeditionProtocol.sendError(player, err or "Could not advance mission.")
		end
		return true
	end
	if action == "missionStop" then
		IdleMission.stop(player, { recallHunt = true })
		return true
	end
	if action == "missionStatus" then
		local run = IdleMission.runFor(player)
		if run then
			-- Re-push tracker.
			local step = run.steps[run.stepIndex]
			ExpeditionProtocol.send(player, {
				type = "missionTracker",
				missionKey = run.key,
				catalogId = run.catalogId,
				cipQuestId = run.cipQuestId,
				name = run.name,
				stepId = step and step.id or "done",
				title = step and step.title or "Complete",
				detail = step and (step.detail or "") or "",
				cta = step and (step.cta or "Continue") or "",
				state = run.state or "idle",
				progress = run.progress,
				required = run.required,
				done = not step,
			})
		else
			ExpeditionProtocol.send(player, { type = "missionTracker", cleared = true, done = true })
		end
		return true
	end
	return false
end
