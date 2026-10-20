-- Adventurers Guild / Great Dragon Hunt — CIP quest 81.

local NPC = "Theodore Loveless"
local NPC_POS = Position(32362, 32787, 6)
local QUEST_ENTRY = "great_dragon_hunt"
local HUNT_HINT = "dragon"

local function entry()
	return QuestsCatalog.get(QUEST_ENTRY)
end

local function progress(player)
	local e = entry()
	if not e then
		return 0, 50, QuestsConfig.STATUS_LOCKED
	end
	return QuestsManager.getProgress(player, e)
end

IdleMission.register({
	key = "adventurers_guild",
	cipQuestId = 81,
	name = "Adventurers Guild",
	city = "Liberty Bay",
	levelMin = 1,
	recommendedLevel = 40,
	center = { x = NPC_POS.x, y = NPC_POS.y, z = NPC_POS.z },
	creatures = { { name = "Dragon" } },
	build = function(run)
		local ctrl = run.ctrl
		return {
			{
				id = "talk_accept",
				title = "Begin the Great Dragon Hunt",
				detail = "Talk to Theodore Loveless in Liberty Bay and take the hunt.",
				cta = "Talk to Theodore Loveless",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_ACTIVE
						or status == QuestsConfig.STATUS_READY
						or status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:talkTo(NPC, { "hi", "dragon", "hunt", "yes", "bye" }, {
						position = NPC_POS,
						onDone = function(player, ok, reason)
							if not ok then
								return done(false, reason)
							end
							local _, _, status = progress(player)
							if status ~= QuestsConfig.STATUS_ACTIVE and status ~= QuestsConfig.STATUS_READY and status ~= QuestsConfig.STATUS_DONE then
								local accepted, msg = QuestsManager.accept(player, QUEST_ENTRY)
								if not accepted then
									return done(false, msg)
								end
							end
							done(true)
						end,
					})
				end,
			},
			{
				id = "hunt_kills",
				kind = "waitKills",
				title = "Hunt Dragons",
				detail = "Slay dragons and dragon lords (50).",
				cta = "Select for lobby",
				recallMsg = "Dragon quota met. Return to report.",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_READY or status == QuestsConfig.STATUS_DONE
				end,
				progress = function()
					local p = Player(run.playerId)
					return progress(p)
				end,
				describe = function()
					local p = Player(run.playerId)
					local cur, need = progress(p)
					return { progress = cur, required = need, detail = string.format("Kills %d/%d.", cur or 0, need or 0) }
				end,
				onAdvance = function(_, done)
					local huntId = IdleMission.findHuntId(HUNT_HINT)
					if not huntId then
						return done(false, "No dragon hunt in the catalog.")
					end
					local ok, err = PlayerController.Hunt.selectForLobby(Player(run.playerId), huntId)
					done(ok == true, ok and nil or (err or "Could not select the expedition."))
				end,
			},
			{
				id = "talk_report",
				title = "Claim the dragon hoard",
				detail = "Return to Theodore Loveless and claim the reward.",
				cta = "Report to Theodore Loveless",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					if status == QuestsConfig.STATUS_DONE then
						return true
					end
					-- Repeatable: a claim increments the achievement and resets
					-- the counter to an active hunt. Still on the quota means
					-- this step is the current one.
					local e = entry()
					local claimed = e and math.max(0, p:getStorageValue(e.storageAchievement)) or 0
					return claimed > 0 and status ~= QuestsConfig.STATUS_READY and status ~= QuestsConfig.STATUS_AVAILABLE
				end,
				onAdvance = function(_, done)
					ctrl:talkTo(NPC, { "hi", "report", "yes", "bye" }, {
						position = NPC_POS,
						onDone = function(player, ok, reason)
							if not ok then
								return done(false, reason)
							end
							local reported, msg = QuestsManager.report(player, QUEST_ENTRY)
							if not reported then
								local _, _, status = progress(player)
								if status == QuestsConfig.STATUS_DONE then
									return done(true)
								end
								return done(false, msg)
							end
							done(true)
						end,
					})
				end,
			},
		}
	end,
})
