-- Meriana Rebels (Raymond Striker / Pirates) — CIP quest 39 board mission.

local NPC = "Raymond Striker"
local NPC_POS = Position(32350, 32588, 7)
local QUEST_ENTRY = "kitno_raymondstriker_1"
local HUNT_HINT = "pirate"

local function entry()
	return QuestsCatalog.get(QUEST_ENTRY)
end

local function progress(player)
	local e = entry()
	if not e then
		return 0, 3000, QuestsConfig.STATUS_LOCKED
	end
	return QuestsManager.getProgress(player, e)
end

IdleMission.register({
	key = "kitno_meriana_rebels",
	cipQuestId = 39,
	name = "Meriana Rebels",
	city = "Meriana",
	levelMin = 1,
	recommendedLevel = 40,
	center = { x = NPC_POS.x, y = NPC_POS.y, z = NPC_POS.z },
	creatures = { { name = "Pirate Marauder" } },
	build = function(run)
		local ctrl = run.ctrl
		return {
			{
				id = "go_raymond",
				title = "Go to Raymond Striker",
				detail = "Travel to Meriana and find Raymond Striker.",
				cta = "Go to Raymond Striker",
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
				title = "Accept the pirate task",
				detail = "Speak with Raymond Striker about hunting pirates.",
				cta = "Talk to Raymond Striker",
				satisfied = function()
					local p = Player(run.playerId)
					local _, _, status = progress(p)
					return status == QuestsConfig.STATUS_ACTIVE
						or status == QuestsConfig.STATUS_READY
						or status == QuestsConfig.STATUS_DONE
				end,
				onAdvance = function(_, done)
					ctrl:talkTo(NPC, { "hi", "task", "pirates", "yes" }, {
						position = NPC_POS,
						onDone = function(player, ok, reason)
							if not ok then
								return done(false, reason)
							end
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
				title = "Hunt Pirates",
				detail = "Slay pirates until the quota is met.",
				cta = "Start hunting",
				recallMsg = "Pirate quota met. Return to Raymond Striker.",
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
						return done(false, "No pirate hunt in the catalog.")
					end
					local ok = ctrl:beginHunt(huntId)
					done(ok, ok and nil or "Could not join hunt.")
				end,
			},
			{
				id = "return_raymond",
				title = "Return to Raymond Striker",
				detail = "Report your kills.",
				cta = "Go to Raymond Striker",
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
				detail = "Talk to Raymond Striker to claim your reward.",
				cta = "Report to Raymond Striker",
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
