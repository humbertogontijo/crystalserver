-- Paw and Fur (Grizzly Adams) — CIP quest 39 board mission.
-- A player may hold up to tasksByPlayer (3) Grizzly Adams tasks at once.
-- Each active task gets its own tracker CTA; membership / rank lines never get "Select for lobby".

local NPC = "Grizzly Adams"
local NPC_POS = Position(32693, 32767, 6)
local MAX_TASKS = tonumber(tasksByPlayer) or 3
local MEMBERSHIP_FLAG = 1081 -- "Paw and Fur - Hunting Elite"

local function canTake(player, entry)
	if not player or not player.canStartTask or not tasks or not tasks.GrizzlyAdams then
		return false
	end
	return player:canStartTask(entry.name, tasks.GrizzlyAdams) == true
end

local function listActive(player)
	local out = {}
	if not player or not QuestsCatalog or not QuestsCatalog.all then
		return out
	end
	for _, entry in ipairs(QuestsCatalog.all()) do
		if entry.board == "GrizzlyAdams" then
			local _, _, status = QuestsManager.getProgress(player, entry)
			if status == QuestsConfig.STATUS_ACTIVE or status == QuestsConfig.STATUS_READY then
				out[#out + 1] = entry
			end
		end
	end
	table.sort(out, function(a, b)
		return (a.taskId or 0) < (b.taskId or 0)
	end)
	return out
end

--- Every Grizzly Adams task this level can still start (under the 3-task cap).
local function listAvailable(player)
	local out = {}
	if not player or not QuestsCatalog or not QuestsCatalog.all then
		return out
	end
	if #listActive(player) >= MAX_TASKS then
		return out
	end
	for _, entry in ipairs(QuestsCatalog.all()) do
		if entry.board == "GrizzlyAdams" then
			local _, _, status = QuestsManager.getProgress(player, entry)
			if status == QuestsConfig.STATUS_AVAILABLE and canTake(player, entry) then
				out[#out + 1] = entry
			end
		end
	end
	table.sort(out, function(a, b)
		local amin, bmin = a.levelMin or 0, b.levelMin or 0
		if amin ~= bmin then
			return amin > bmin
		end
		return (a.taskId or 0) < (b.taskId or 0)
	end)
	return out
end

local function pickAvailable(player)
	local list = listAvailable(player)
	return list[1]
end

local function questFlagForTask(entry)
	if not entry or not Game.getQuestIdByName then
		return nil
	end
	local questId = Game.getQuestIdByName("Killing in the Name of...")
	local quest = questId and Game.getQuest(questId)
	if not quest or not quest.missions then
		return nil
	end
	local race = tostring(entry.name or ""):lower()
	if race == "" then
		return nil
	end
	for _, mission in pairs(quest.missions) do
		local name = tostring(mission.name or ""):lower()
		if (name:find("paw and fur:", 1, true) or name:find("paw and fur -", 1, true)) and name:find(race, 1, true) then
			return tonumber(mission.missionId)
		end
	end
	local short = race:match("([%w%s]+)$")
	if short and short ~= race then
		short = short:gsub("^%s+", "")
		for _, mission in pairs(quest.missions) do
			local name = tostring(mission.name or ""):lower()
			if name == "paw and fur: " .. short or name == "paw and fur - " .. short then
				return tonumber(mission.missionId)
			end
		end
	end
	return nil
end

local function syncQuestLogStorage(player, entry)
	if not player or not entry or not entry.taskId then
		return
	end
	local logStor = 65000 + entry.taskId
	if player:getStorageValue(logStor) < 0 then
		player:setStorageValue(logStor, 0)
	end
end

local function refreshQuestUi(player)
	local questId = Game.getQuestIdByName and Game.getQuestIdByName("Killing in the Name of...")
	if not player or not questId then
		return
	end
	if player.sendQuestLine then
		player:sendQuestLine(questId)
	end
	for _, mission in ipairs(player:getSavedMissions() or {}) do
		if tonumber(mission.questId) == questId and mission.missionId then
			local _, _, missionIndex = player:getQuestDataByMissionId(mission.missionId)
			if missionIndex then
				mission.missionName = player:getMissionName(questId, missionIndex)
				mission.missionDesc = player:getMissionDescription(questId, missionIndex)
				if player.sendUpdateTrackedQuest then
					player:sendUpdateTrackedQuest(mission)
				end
			end
		end
	end
	if IdleMission.start then
		IdleMission.start(player, "kitno_paw_and_fur")
	end
end

local function huntHint(entry)
	return entry and (entry.huntHint or (entry.creatures and entry.creatures[1])) or nil
end

local function choiceRows(entries)
	local choices = {}
	for _, entry in ipairs(entries or {}) do
		choices[#choices + 1] = {
			id = entry.id,
			name = entry.name,
			taskId = entry.taskId,
		}
	end
	return choices
end

IdleMission.register({
	key = "kitno_paw_and_fur",
	cipQuestId = 39,
	name = "Paw and Fur",
	city = "Port Hope",
	levelMin = 6,
	recommendedLevel = 20,
	center = { x = NPC_POS.x, y = NPC_POS.y, z = NPC_POS.z },
	creatures = { { name = "Hydra" } },
	pushTrackers = function(run)
		local player = Player(run.playerId)
		if not player or not ExpeditionProtocol then
			return
		end
		local questLineId = run.questLineId or IdleMission.questLineIdFor(IdleMission.get(run.key))
		for flagId in pairs(run._pushedFlags or {}) do
			ExpeditionProtocol.send(player, {
				type = "missionTracker",
				missionKey = run.key,
				questFlagId = flagId,
				questLineId = questLineId,
				cleared = true,
			})
		end
		local active = listActive(player)
		local seenFlags = {}
		for _, entry in ipairs(active) do
			syncQuestLogStorage(player, entry)
			local cur, need, status = QuestsManager.getProgress(player, entry)
			local flagId = questFlagForTask(entry)
			local ready = status == QuestsConfig.STATUS_READY
			local payload = {
				type = "missionTracker",
				missionKey = run.key,
				taskEntryId = entry.id,
				questLineId = questLineId,
				matchName = entry.name,
				name = entry.name,
				title = ready and ("Report " .. entry.name) or ("Hunt " .. entry.name),
				detail = string.format("%s: %d/%d.", entry.name, cur or 0, need or 0),
				cta = ready and "Report to Grizzly Adams" or "Select for lobby",
				progress = cur,
				required = need,
				state = ready and "ready" or "hunting",
			}
			if not ready then
				-- Client opens the expedition browser filtered to this race (may be several hunts).
				payload.browseFilter = huntHint(entry) or entry.name
			end
			if flagId then
				payload.questFlagId = flagId
				seenFlags[flagId] = true
			end
			ExpeditionProtocol.send(player, payload)
		end
		local available = listAvailable(player)
		if #available > 0 then
			local choices = choiceRows(available)
			local first = available[1]
			ExpeditionProtocol.send(player, {
				type = "missionTracker",
				missionKey = run.key,
				taskEntryId = first.id,
				questFlagId = MEMBERSHIP_FLAG,
				questLineId = questLineId,
				matchName = "Hunting Elite",
				name = first.name,
				title = "Accept a Paw and Fur task",
				detail = #choices > 1
						and string.format("Choose an option (%d available), then talk to Grizzly Adams.", #choices)
					or string.format("Talk to Grizzly Adams and take the %s task.", first.name),
				cta = "Talk to Grizzly Adams",
				choices = choices,
				state = "idle",
			})
			seenFlags[MEMBERSHIP_FLAG] = true
		elseif #active == 0 then
			ExpeditionProtocol.send(player, {
				type = "missionTracker",
				missionKey = run.key,
				questLineId = questLineId,
				cleared = true,
			})
		end
		run._pushedFlags = seenFlags
	end,
	build = function(run)
		local ctrl = run.ctrl
		return {
			{
				id = "manage",
				title = "Paw and Fur tasks",
				detail = "Accept, hunt, and report Grizzly Adams tasks (up to three at once).",
				cta = "Continue",
				persist = true,
				satisfied = function()
					return false
				end,
				describe = function()
					local available = listAvailable(Player(run.playerId))
					if #available == 0 then
						return nil
					end
					local choices = choiceRows(available)
					return {
						detail = #choices > 1
								and string.format("Choose an option (%d available), then talk to Grizzly Adams.", #choices)
							or string.format("Talk to Grizzly Adams and take the %s task.", available[1].name),
						cta = "Talk to Grizzly Adams",
						taskEntryId = available[1].id,
						questFlagId = MEMBERSHIP_FLAG,
						matchName = "Hunting Elite",
						choices = choices,
					}
				end,
				onAdvance = function(_, done, opts)
					opts = opts or {}
					local player = Player(run.playerId)
					local entryId = opts.taskEntryId or run.taskEntryId
					local entry = entryId and QuestsCatalog.get(entryId)

					-- Resolve an active task when the client sent a flag id but no entry id.
					if not entry and opts.questFlagId then
						local flagId = tonumber(opts.questFlagId)
						for _, active in ipairs(listActive(player)) do
							if questFlagForTask(active) == flagId then
								entry = active
								break
							end
						end
						-- Membership / "choose a task" flag: require an explicit choice when several exist.
						if not entry and flagId == MEMBERSHIP_FLAG then
							local available = listAvailable(player)
							if #available > 1 and not entryId then
								return done(false, "Choose which Paw and Fur task to take.")
							end
							entry = available[1]
						end
					end

					if entry then
						local _, _, status = QuestsManager.getProgress(player, entry)
						if status == QuestsConfig.STATUS_READY then
							ctrl:talkTo(NPC, { "hi", "report", "yes", "bye" }, {
								position = NPC_POS,
								onDone = function(live, ok, reason)
									if not ok then
										return done(false, reason)
									end
									local reported, msg = QuestsManager.report(live, entry.id)
									refreshQuestUi(live)
									if not reported then
										local _, _, after = QuestsManager.getProgress(live, entry)
										if after == QuestsConfig.STATUS_DONE or after == QuestsConfig.STATUS_AVAILABLE then
											return done(true)
										end
										return done(false, msg)
									end
									done(true)
								end,
							})
							return true
						end
						if status == QuestsConfig.STATUS_ACTIVE then
							-- Client opens the expedition browser with browseFilter; do not auto-pick a lobby hunt.
							return done(false, "Pick a hunt in the expedition browser.")
						end
						if status == QuestsConfig.STATUS_AVAILABLE then
							run.taskEntryId = entry.id
							ctrl:talkTo(NPC, { "hi", "tasks", entry.name:lower(), "yes", "bye" }, {
								position = NPC_POS,
								onDone = function(live, ok, reason)
									if not ok then
										return done(false, reason)
									end
									local _, _, after = QuestsManager.getProgress(live, entry)
									if after == QuestsConfig.STATUS_AVAILABLE then
										local accepted, msg = QuestsManager.accept(live, entry.id)
										if not accepted then
											return done(false, msg)
										end
									elseif after == QuestsConfig.STATUS_LOCKED then
										return done(false, "This quest is locked.")
									end
									refreshQuestUi(live)
									done(true)
								end,
							})
							return true
						end
					end

					local available = listAvailable(player)
					if #available > 1 and not entryId then
						return done(false, "Choose which Paw and Fur task to take.")
					end
					local nextTask = available[1]
					if not nextTask then
						return done(false, "No Paw and Fur task is available for your level.")
					end
					run.taskEntryId = nextTask.id
					ctrl:talkTo(NPC, { "hi", "tasks", nextTask.name:lower(), "yes", "bye" }, {
						position = NPC_POS,
						onDone = function(live, ok, reason)
							if not ok then
								return done(false, reason)
							end
							local chosen = QuestsCatalog.get(run.taskEntryId) or pickAvailable(live)
							if not chosen then
								return done(false, "No Paw and Fur task is available for your level.")
							end
							local _, _, status = QuestsManager.getProgress(live, chosen)
							if status == QuestsConfig.STATUS_AVAILABLE then
								local accepted, msg = QuestsManager.accept(live, chosen.id)
								if not accepted then
									return done(false, msg)
								end
							elseif status == QuestsConfig.STATUS_LOCKED then
								return done(false, "This quest is locked.")
							end
							refreshQuestUi(live)
							done(true)
						end,
					})
				end,
			},
		}
	end,
})
