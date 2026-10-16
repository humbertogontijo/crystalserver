-- Paw and Fur (Grizzly Adams) — CIP quest 39 board mission.

local NPC = "Grizzly Adams"
local NPC_POS = Position(32693, 32767, 6)
local QUEST_ENTRY = "kitno_grizzlyadams_1" -- Crocodiles; stock storages shared with open world
local HUNT_HINT = "crocodile"

local function entry()
	return QuestsCatalog.get(QUEST_ENTRY)
end

local function progress(player)
	local e = entry()
	if not e then
		return 0, 300, QuestsConfig.STATUS_LOCKED
	end
	return QuestsManager.getProgress(player, e)
end

IdleMission.register({
	key = "kitno_paw_and_fur",
	cipQuestId = 39,
	name = "Paw and Fur",
	city = "Port Hope",
	levelMin = 6,
	recommendedLevel = 20,
	center = { x = NPC_POS.x, y = NPC_POS.y, z = NPC_POS.z },
	creatures = { { name = "Crocodile" } },
	build = function(run)
		local ctrl = run.ctrl
		return {
			{
				id = "go_grizzly",
				title = "Go to Grizzly Adams",
				detail = "Travel to the Paw and Fur Society in Port Hope.",
				cta = "Go to Grizzly Adams",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_ACTIVE
						or status == QuestsConfig.STATUS_READY
						or status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:goTo(NPC_POS, {
						reach = 2,
						onDone = function(_, ok, reason)
							done(ok, reason)
						end,
					})
				end,
			},
			{
				id = "talk_accept",
				title = "Accept a Paw and Fur task",
				detail = "Speak with Grizzly Adams and take the Crocodiles task.",
				cta = "Talk to Grizzly Adams",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_ACTIVE
						or status == QuestsConfig.STATUS_READY
						or status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:talkTo(NPC, { "hi", "tasks", "crocodiles", "yes" }, {
						position = NPC_POS,
						onDone = function(player, ok, reason)
							if not ok then
								return done(false, reason)
							end
							-- Stock NPC may already set storage; ensure via manager.
							local _, _, status = progress(player)
							if status == QuestsConfig.STATUS_AVAILABLE or status == QuestsConfig.STATUS_LOCKED then
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
				title = "Hunt Crocodiles",
				detail = "Slay crocodiles until the task quota is met.",
				cta = "Start hunting",
				recallMsg = "Crocodile quota met. Return to Grizzly Adams.",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_READY or status == QuestsConfig.STATUS_DONE
				end,
				progress = function()
					local p = Player(run.playerId)
					local cur, need = progress(p)
					return cur, need
				end,
				describe = function()
					local p = Player(run.playerId)
					local cur, need = progress(p)
					return { progress = cur, required = need, detail = string.format("Kills %d/%d.", cur or 0, need or 0) }
				end,
				onAdvance = function(_, done)
					local huntId = IdleMission.findHuntId(HUNT_HINT)
					if not huntId then
						return done(false, "No crocodile hunt in the catalog.")
					end
					local ok = ctrl:beginHunt(huntId)
					done(ok, ok and nil or "Could not join hunt.")
				end,
			},
			{
				id = "return_grizzly",
				title = "Return to Grizzly Adams",
				detail = "Report your kills to Grizzly Adams.",
				cta = "Go to Grizzly Adams",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:goTo(NPC_POS, {
						reach = 2,
						onDone = function(_, ok, reason)
							done(ok, reason)
						end,
					})
				end,
			},
			{
				id = "talk_report",
				title = "Report the task",
				detail = "Talk to Grizzly Adams to claim your reward.",
				cta = "Report to Grizzly Adams",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:talkTo(NPC, { "hi", "report", "yes" }, {
						position = NPC_POS,
						onDone = function(player, ok, reason)
							if not ok then
								return done(false, reason)
							end
							local reported, msg = QuestsManager.report(player, QUEST_ENTRY)
							if not reported then
								-- May already be done via NPC dialogue.
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
