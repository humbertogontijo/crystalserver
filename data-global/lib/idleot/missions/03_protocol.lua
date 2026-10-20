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
		local ok, err = IdleMission.advance(player, msg.missionKey or msg.key, {
			taskEntryId = msg.taskEntryId or msg.entryId,
			questFlagId = tonumber(msg.questFlagId),
		})
		if not ok then
			ExpeditionProtocol.sendError(player, err or "Could not advance mission.")
		end
		return true
	end
	if action == "missionStop" then
		IdleMission.stop(player, { missionKey = msg.missionKey or msg.key, recallHunt = false })
		return true
	end
	if action == "missionLookup" then
		local questLineId = tonumber(msg.questLineId)
		-- Start the line's mission and push per-flag CTAs (Paw and Fur tasks, etc.)
		-- even when nothing is on the quest tracker yet.
		if IdleMission.ensureLine then
			IdleMission.ensureLine(player, questLineId)
		elseif IdleMission.syncTracked then
			IdleMission.syncTracked(player)
		end
		local offer = IdleMission.describeLine and IdleMission.describeLine(player, questLineId)
		if offer and tostring(offer.cta or "") ~= "" then
			ExpeditionProtocol.send(player, offer)
		else
			-- Flag CTAs from pushTrackers are enough; do not wipe with an empty offer.
			ExpeditionProtocol.send(player, { type = "missionOffer", questLineId = questLineId, cleared = true })
		end
		return true
	end
	if action == "missionStatus" then
		if IdleMission.refreshTracked then
			IdleMission.refreshTracked(player)
		end
		return true
	end
	return false
end
