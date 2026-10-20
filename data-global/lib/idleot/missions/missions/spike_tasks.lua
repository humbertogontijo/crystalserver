-- Spike Tasks — CIP quest 87 (Upper Spike kill layer as the first idle loop).

local NPC = "Gnomilly"
local NPC_POS = Position(32242, 32599, 9)
local QUEST_ENTRY = "spike_upper_kill"
local HUNT_HINT = "demon skeleton"

local function entry()
	return QuestsCatalog.get(QUEST_ENTRY)
end

local function progress(player)
	local e = entry()
	if not e then
		return 0, 7, QuestsConfig.STATUS_LOCKED
	end
	return QuestsManager.getProgress(player, e)
end

IdleMission.register({
	key = "spike_tasks",
	cipQuestId = 87,
	name = "Spike Tasks",
	city = "Kazordoon",
	levelMin = 1,
	recommendedLevel = 50,
	center = { x = NPC_POS.x, y = NPC_POS.y, z = NPC_POS.z },
	creatures = { { name = "Demon Skeleton" } },
	build = function(run)
		local ctrl = run.ctrl
		return {
			{
				id = "talk_accept",
				title = "Accept the Upper Spike task",
				detail = "Go to Gnomilly in the Spike and take the demon skeleton task.",
				cta = "Talk to Gnomilly",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_ACTIVE
						or status == QuestsConfig.STATUS_READY
						or status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:talkTo(NPC, { "hi", "task", "yes", "bye" }, {
						position = NPC_POS,
						onDone = function(player, ok, reason)
							if not ok then
								return done(false, reason)
							end
							local _, _, status = progress(player)
							if status ~= QuestsConfig.STATUS_ACTIVE and status ~= QuestsConfig.STATUS_READY then
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
				title = "Slay Demon Skeletons",
				detail = "Kill 7 demon skeletons (expedition kills count).",
				cta = "Select for lobby",
				recallMsg = "Spike quota met. Return to Gnomilly.",
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
						return done(false, "No demon skeleton hunt in the catalog.")
					end
					local ok, err = PlayerController.Hunt.selectForLobby(Player(run.playerId), huntId)
					done(ok == true, ok and nil or (err or "Could not select the expedition."))
				end,
			},
			{
				id = "talk_report",
				title = "Report the Spike task",
				detail = "Return to Gnomilly for fame and experience.",
				cta = "Report to Gnomilly",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_DONE
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
