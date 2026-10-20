-- IdleMission: mission orchestrator (click-through tracker).
-- Scripts register with IdleMission.register; steps use PlayerController actions.

IdleMission = IdleMission or {}
IdleMission.__index = IdleMission
setmetatable(IdleMission, { __index = IdleOrchestrator })

IdleMission.registry = IdleMission.registry or {} -- key → def
IdleMission.order = IdleMission.order or {} -- registration order
IdleMission.byPlayerId = IdleMission.byPlayerId or {} -- playerId → { key → run }
IdleMission.catalogIndex = IdleMission.catalogIndex or 0

local function findHuntIdForHint(hint)
	if not hint or not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return nil
	end
	local needle = tostring(hint):lower()
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if not entry.exclusiveKitno and not entry.exclusiveArena and entry.kind ~= "quest" then
			local name = tostring(entry.name or ""):lower()
			if name == needle or name:find(needle, 1, true) then
				return entry.id
			end
			if type(entry.creatures) == "table" then
				for _, c in ipairs(entry.creatures) do
					local cname = tostring(c.name or c):lower()
					if cname == needle or cname:find(needle, 1, true) then
						return entry.id
					end
				end
			end
		end
	end
	return nil
end

--- Crystal quest-log line id for a mission (the id the quest tracker sends), not the CIP staticdata id.
function IdleMission.questLineIdFor(def)
	if not def or not Game.getQuestIdByName then
		return nil
	end
	if def.questLineId then
		return def.questLineId
	end
	local names = {}
	if IdleMissionCipLinks then
		for _, link in ipairs(IdleMissionCipLinks) do
			if tonumber(link.cipQuestId) == tonumber(def.cipQuestId) and link.name then
				names[#names + 1] = link.name
			end
		end
	end
	if def.name then
		names[#names + 1] = def.name
	end
	for _, name in ipairs(names) do
		local id = Game.getQuestIdByName(name)
		if id then
			def.questLineId = id
			return id
		end
	end
	local needle = tostring(def.name or ""):lower()
	if #needle >= 8 and Quests then
		for questId = 1, #Quests do
			local quest = Game.getQuest(questId)
			local qn = quest and quest.name and quest.name:lower() or ""
			-- "Spike Tasks" against the quest log's "Spike Task".
			if #qn >= 8 and (needle:sub(1, #qn) == qn or qn:sub(1, #needle) == needle) then
				def.questLineId = questId
				return questId
			end
		end
	end
	return nil
end

--- Register a mission definition.
--- def: key, cipQuestId, name, catalogId?, build(run) → steps[], describe(run) → step payload extras
function IdleMission.register(def)
	if not def or not def.key then
		return
	end
	local key = tostring(def.key)
	if not def.catalogId then
		IdleMission.catalogIndex = IdleMission.catalogIndex + 1
		def.catalogId = IdleMissionConfig.CATALOG_ID_BASE + IdleMission.catalogIndex
	end
	IdleMission.registry[key] = def
	local listed = false
	for _, existing in ipairs(IdleMission.order) do
		if existing == key then
			listed = true
			break
		end
	end
	if not listed then
		IdleMission.order[#IdleMission.order + 1] = key
	end
	IdleMission.questLineIdFor(def)
	ExpeditionQuestMechanics.register(tostring(def.cipQuestId or key), function() end)
	ExpeditionQuestMechanics.register(key, function() end)
end

function IdleMission.get(key)
	return IdleMission.registry[tostring(key or "")]
end

function IdleMission.byCatalogId(catalogId)
	local id = tonumber(catalogId)
	for _, def in pairs(IdleMission.registry) do
		if def.catalogId == id then
			return def
		end
	end
	return nil
end

local function runsOf(playerId)
	local bucket = IdleMission.byPlayerId[playerId]
	if not bucket then
		bucket = {}
		IdleMission.byPlayerId[playerId] = bucket
	end
	return bucket
end

local function runAlive(run)
	if not run then
		return false
	end
	local bucket = IdleMission.byPlayerId[run.playerId]
	return bucket ~= nil and bucket[run.key] == run
end

function IdleMission.runFor(player, key)
	local bucket = player and IdleMission.byPlayerId[player:getId()] or nil
	if not bucket then
		return nil
	end
	if key then
		return bucket[tostring(key)]
	end
	local only = nil
	for _, run in pairs(bucket) do
		if only then
			return nil
		end
		only = run
	end
	return only
end

local function pushTracker(run)
	local player = Player(run.playerId)
	if not player or not ExpeditionProtocol then
		return
	end
	local def = IdleMission.get(run.key)
	if def and def.pushTrackers then
		local ok, err = pcall(def.pushTrackers, run)
		if not ok then
			logger.warn("[IdleMission] pushTrackers {}: {}", tostring(run.key), tostring(err))
		end
		return
	end
	local step = run.steps[run.stepIndex]
	local payload = {
		type = "missionTracker",
		missionKey = run.key,
		catalogId = run.catalogId,
		cipQuestId = run.cipQuestId,
		questLineId = run.questLineId,
		name = run.name,
		stepId = step and step.id or "done",
		title = step and step.title or "Complete",
		detail = step and (step.detail or "") or "",
		cta = step and (step.cta or "Continue") or "",
		state = run.state or "idle",
		progress = run.progress,
		required = run.required,
		done = not step,
	}
	if step and step.describe then
		local ok, extra = pcall(step.describe, run)
		if ok and type(extra) == "table" then
			for k, v in pairs(extra) do
				payload[k] = v
			end
		end
	end
	ExpeditionProtocol.send(player, payload)
end

local function clearKillWatch(run)
	if run._killWatchUnsub then
		run._killWatchUnsub()
		run._killWatchUnsub = nil
	end
	run._killWatch = nil
end

local function stopRun(run, opts)
	opts = opts or {}
	clearKillWatch(run)
	if run._recalling and not opts.keepHunt then
		-- already recalling
	elseif opts.recallHunt then
		local player = Player(run.playerId)
		if player then
			PlayerController.Hunt.recall(player, { endMsg = opts.endMsg })
		end
	end
	local bucket = IdleMission.byPlayerId[run.playerId]
	if bucket then
		bucket[run.key] = nil
		if not next(bucket) then
			IdleMission.byPlayerId[run.playerId] = nil
		end
	end
	local player = Player(run.playerId)
	if player and ExpeditionProtocol then
		ExpeditionProtocol.send(player, {
			type = "missionTracker",
			missionKey = run.key,
			cipQuestId = run.cipQuestId,
			questLineId = run.questLineId,
			done = true,
			cleared = true,
		})
	end
end

--- Resolve current step index from stock (skip already-satisfied steps).
local function resolveStepIndex(run)
	for i, step in ipairs(run.steps) do
		if not step.satisfied or not step.satisfied(run) then
			return i
		end
	end
	return #run.steps + 1
end

local function refreshProgress(run)
	local step = run.steps[run.stepIndex]
	run.progress = nil
	run.required = nil
	if step and step.progress then
		local p, r = step.progress(run)
		run.progress = p
		run.required = r
	end
	if step and step.kind == "waitKills" and run.progress and run.required and run.progress >= run.required then
		run.state = "ready"
	elseif step and step.kind == "waitKills" then
		run.state = "hunting"
	elseif run.state == "recalling" then
		-- keep
	else
		run.state = "idle"
	end
end

local function stepSatisfied(run, step)
	if not step or not step.satisfied then
		return true
	end
	local ok, result = pcall(step.satisfied, run)
	return ok and result == true
end

local function advanceToNext(run)
	local current = run.steps[run.stepIndex]
	if not stepSatisfied(run, current) then
		refreshProgress(run)
		run.state = "idle"
		pushTracker(run)
		return
	end
	run.stepIndex = run.stepIndex + 1
	while run.steps[run.stepIndex] and run.steps[run.stepIndex].satisfied and run.steps[run.stepIndex].satisfied(run) do
		run.stepIndex = run.stepIndex + 1
	end
	clearKillWatch(run)
	if not run.steps[run.stepIndex] then
		run.state = "done"
		pushTracker(run)
		stopRun(run)
		return
	end
	refreshProgress(run)
	local step = run.steps[run.stepIndex]
	if step.kind == "waitKills" and step.onEnter then
		step.onEnter(run)
	end
	pushTracker(run)
end

--- Watch kills; when quota met → recall hunt and flip tracker to next CTA.
local function armKillWatch(run, step)
	clearKillWatch(run)
	run._killWatch = step
	run.state = "hunting"
	refreshProgress(run)
	pushTracker(run)

	local function onQuota()
		if not runAlive(run) then
			return
		end
		refreshProgress(run)
		if not (run.progress and run.required and run.progress >= run.required) then
			pushTracker(run)
			return
		end
		clearKillWatch(run)
		run.state = "recalling"
		pushTracker(run)
		local player = Player(run.playerId)
		if player and ExpeditionManager.isInExpedition(player) then
			run._recalling = true
			PlayerController.Hunt.recall(player, {
				endMsg = step.recallMsg or "Objective complete. Return to report.",
			})
		end
		-- Move to next step (usually return/report) after recall starts.
		addEvent(function()
			if not runAlive(run) then
				return
			end
			run._recalling = false
			run.state = "idle"
			advanceToNext(run)
		end, 500)
	end

	run._killWatchUnsub = IdleEvents.on("monster.died", function()
		onQuota()
	end, "IdleMission." .. tostring(run.playerId))

	-- Immediate check (already satisfied).
	onQuota()
end

function IdleMission.start(player, key)
	local def = IdleMission.get(key)
	if not def then
		return false, "Unknown mission."
	end
	local existing = IdleMission.runFor(player, key)
	if existing then
		pushTracker(existing)
		return true
	end

	local orch = IdleOrchestrator.new({ name = "mission:" .. tostring(key) })
	local run = setmetatable({
		key = tostring(key),
		name = def.name,
		cipQuestId = def.cipQuestId,
		questLineId = IdleMission.questLineIdFor(def),
		catalogId = def.catalogId,
		playerId = player:getId(),
		orch = orch,
		ctrl = orch:controllerFor(player),
		stepIndex = 1,
		state = "idle",
		steps = {},
	}, IdleMission)

	local steps = def.build(run)
	if type(steps) ~= "table" or #steps == 0 then
		return false, "Mission has no steps."
	end
	run.steps = steps
	run.stepIndex = resolveStepIndex(run)
	runsOf(run.playerId)[run.key] = run

	if not run.steps[run.stepIndex] then
		pushTracker(run)
		stopRun(run)
		return true, "Already complete."
	end

	refreshProgress(run)
	local step = run.steps[run.stepIndex]
	if step.kind == "waitKills" then
		armKillWatch(run, step)
	else
		pushTracker(run)
	end
	return true
end

function IdleMission.stop(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	local bucket = IdleMission.byPlayerId[player:getId()]
	if not bucket then
		return
	end
	if opts.missionKey then
		local run = bucket[tostring(opts.missionKey)]
		if run then
			stopRun(run, opts)
		end
		return
	end
	local keys = {}
	for key in pairs(bucket) do
		keys[#keys + 1] = key
	end
	for _, key in ipairs(keys) do
		local run = bucket[key]
		if run then
			stopRun(run, opts)
		end
	end
end

--- CTA click: run only the current step's action. Starts the run when the quest log
--- asks before the line is tracked. `opts.taskEntryId` selects one Paw and Fur task.
function IdleMission.advance(player, key, opts)
	opts = opts or {}
	if key and player and not IdleMission.runFor(player, key) then
		local started, err = IdleMission.start(player, key)
		if not started then
			return false, err
		end
	end
	local run = key and IdleMission.runFor(player, key) or IdleMission.runFor(player)
	if not run then
		return false, "No active mission."
	end
	if opts.taskEntryId then
		run.taskEntryId = opts.taskEntryId
	end
	local step = run.steps[run.stepIndex]
	if not step then
		return false, "Mission complete."
	end
	if run.busy then
		return false, "Already acting."
	end
	if step.kind == "waitKills" then
		-- Start or continue hunt; watch handles completion.
		if step.onAdvance then
			run.busy = true
			local ok, err = step.onAdvance(run, function(success, reason)
				run.busy = false
				if success == false then
					player:sendTextMessage(MESSAGE_FAILURE, reason or "Could not hunt.")
				end
				armKillWatch(run, step)
			end, opts)
			if ok == false then
				run.busy = false
				return false, err
			end
		else
			armKillWatch(run, step)
		end
		return true
	end

	if not step.onAdvance then
		advanceToNext(run)
		return true
	end

	run.busy = true
	run.state = "acting"
	pushTracker(run)
	local function finish(ok, reason)
		run.busy = false
		if not ok then
			run.state = "idle"
			pushTracker(run)
			if reason and reason ~= "manual" and reason ~= "cancelled" then
				player:sendTextMessage(MESSAGE_FAILURE, tostring(reason))
			end
			return
		end
		-- Walking or speaking is not enough: the player's quest storages have
		-- to show this step is done before the tracker moves on.
		if step.persist or not stepSatisfied(run, step) then
			run.state = "idle"
			pushTracker(run)
			if not step.persist and not stepSatisfied(run, step) then
				player:sendTextMessage(MESSAGE_FAILURE, reason or "The quest did not advance.")
			end
			return
		end
		advanceToNext(run)
	end
	local started, err = step.onAdvance(run, finish, opts)
	if started == false then
		finish(false, err or "Failed.")
		return false, err
	end
	return true
end

function IdleMission.findHuntId(hint)
	return findHuntIdForHint(hint)
end

--- Drop leftover mission rows. Quests are tracked in the quest log, not browsed as expeditions.
function IdleMission.registerCatalogRows()
	if not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return
	end
	local kept = {}
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if not entry.idleMission and entry.kind ~= "quest" then
			kept[#kept + 1] = entry
		end
	end
	ExpeditionConfig.Catalog = kept
	if ExpeditionConfig.sortCatalogForDisplay then
		ExpeditionConfig.sortCatalogForDisplay(ExpeditionConfig.Catalog)
	end
end

local function defsForQuestLine(questLineId)
	local defs = {}
	for _, key in ipairs(IdleMission.order) do
		local def = IdleMission.registry[key]
		if def and IdleMission.questLineIdFor(def) == questLineId then
			defs[#defs + 1] = def
		end
	end
	return defs
end

local function currentStepOf(player, def)
	local run = { playerId = player:getId(), key = def.key, cipQuestId = def.cipQuestId }
	local ok, steps = pcall(def.build, run)
	if not ok or type(steps) ~= "table" then
		return nil
	end
	run.steps = steps
	local idx = resolveStepIndex(run)
	return steps[idx]
end

local function pickDef(player, defs)
	local bucket = IdleMission.byPlayerId[player:getId()] or {}
	for _, def in ipairs(defs) do
		if bucket[def.key] then
			return def
		end
	end
	-- Prefer Paw and Fur when the player already has a Grizzly Adams task running.
	for _, def in ipairs(defs) do
		if def.key == "kitno_paw_and_fur" and def.pushTrackers then
			return def
		end
	end
	local first = nil
	for _, def in ipairs(defs) do
		local step = currentStepOf(player, def)
		if step then
			if step.id ~= "talk_accept" and step.id ~= "manage" then
				return def
			end
			first = first or def
		end
	end
	return first
end

--- Start the IdleOT mission for a quest line (quest-log open), even before the line is tracked.
function IdleMission.ensureLine(player, questLineId)
	questLineId = tonumber(questLineId)
	if not player or not questLineId then
		return nil
	end
	local defs = defsForQuestLine(questLineId)
	if #defs == 0 then
		return nil
	end
	local chosen = pickDef(player, defs)
	if not chosen then
		return nil
	end
	IdleMission.start(player, chosen.key)
	return chosen
end

--- Quest-log preview for a Crystal quest line that has a mission, before it is tracked.
function IdleMission.describeLine(player, questLineId)
	questLineId = tonumber(questLineId)
	if not player or not questLineId then
		return nil
	end
	local defs = defsForQuestLine(questLineId)
	if #defs == 0 then
		return nil
	end
	local chosen = pickDef(player, defs)
	if not chosen then
		return nil
	end
	local run = {
		playerId = player:getId(),
		key = chosen.key,
		name = chosen.name,
		cipQuestId = chosen.cipQuestId,
		catalogId = chosen.catalogId,
		questLineId = questLineId,
		state = "idle",
	}
	local ok, steps = pcall(chosen.build, run)
	if not ok or type(steps) ~= "table" then
		return nil
	end
	run.steps = steps
	run.stepIndex = resolveStepIndex(run)
	local step = run.steps[run.stepIndex]
	if not step then
		return nil
	end
	refreshProgress(run)
	local payload = {
		type = "missionOffer",
		missionKey = run.key,
		questLineId = questLineId,
		title = step.title or "",
		detail = step.detail or "",
		cta = step.cta or "Continue",
		progress = run.progress,
		required = run.required,
	}
	if step.describe then
		local described, extra = pcall(step.describe, run)
		if not described then
			return nil
		end
		-- nil / empty cta: per-flag pushTrackers own the buttons (Paw and Fur).
		if extra == nil or (type(extra) == "table" and tostring(extra.cta or "") == "") then
			return nil
		end
		if type(extra) == "table" then
			for k, v in pairs(extra) do
				payload[k] = v
			end
		end
	end
	if tostring(payload.cta or "") == "" then
		return nil
	end
	return payload
end

--- Ensure a run for each tracked quest line that has a mission.
function IdleMission.syncTracked(player)
	if not player or not player.getSavedMissions then
		return
	end
	local lines = {}
	for _, mission in ipairs(player:getSavedMissions() or {}) do
		local questId = tonumber(mission.questId)
		if questId then
			lines[questId] = true
		end
	end
	for questId in pairs(lines) do
		local defs = defsForQuestLine(questId)
		if #defs > 0 then
			local chosen = pickDef(player, defs)
			bucket = IdleMission.byPlayerId[player:getId()] or {}
			for _, def in ipairs(defs) do
				if (not chosen or def.key ~= chosen.key) and bucket[def.key] then
					stopRun(bucket[def.key], { recallHunt = false })
				end
			end
			if chosen then
				IdleMission.start(player, chosen.key)
			end
		end
	end
end

function IdleMission.refreshTracked(player)
	if not player then
		return
	end
	local bucket = IdleMission.byPlayerId[player:getId()]
	if not bucket then
		return
	end
	local keys = {}
	for key in pairs(bucket) do
		keys[#keys + 1] = key
	end
	local completed = false
	for _, key in ipairs(keys) do
		local run = bucket[key]
		if run then
			local idx = resolveStepIndex(run)
			if not run.steps[idx] then
				stopRun(run, { recallHunt = false })
				completed = true
			else
				if idx ~= run.stepIndex then
					run.stepIndex = idx
					clearKillWatch(run)
					if run.steps[idx].kind == "waitKills" then
						armKillWatch(run, run.steps[idx])
					else
						refreshProgress(run)
						pushTracker(run)
					end
				else
					refreshProgress(run)
					pushTracker(run)
				end
			end
		end
	end
	if completed then
		IdleMission.syncTracked(player)
	end
end

--- Quest lines the log can start, including ones CipSoft would hide until the quest storage is set.
local function offerQuestIds(player)
	local ids = {}
	local seen = {}
	for _, key in ipairs(IdleMission.order) do
		local def = IdleMission.registry[key]
		local questId = def and IdleMission.questLineIdFor(def)
		if questId and not seen[questId] and IdleMission.describeLine(player, questId) then
			seen[questId] = true
			ids[questId] = true
		end
	end
	return ids
end

if Player.sendQuestLog and not Player._idleMissionQuestLogWrapped then
	local stockSendQuestLine = Player.sendQuestLine

	function Player.sendQuestLog(self)
		local offers = offerQuestIds(self)
		local ids = {}
		for questId = 1, #Quests do
			if self:questIsStarted(questId) or offers[questId] then
				ids[#ids + 1] = questId
			end
		end
		local msg = NetworkMessage()
		msg:addByte(0xF0)
		msg:addU16(#ids)
		for _, questId in ipairs(ids) do
			msg:addU16(questId)
			msg:addString(Quests[questId].name, "Player.sendQuestLog")
			msg:addByte(self:questIsCompleted(questId) and 0x01 or 0x00)
		end
		msg:sendToPlayer(self)
		msg:delete()
	end

	function Player.sendQuestLine(self, questId)
		if Game.getMissionsCount(self, questId) > 0 then
			return stockSendQuestLine(self, questId)
		end
		local offer = IdleMission.describeLine(self, questId)
		local quest = Game.getQuest(questId)
		local mission = quest and quest.missions and quest.missions[1]
		if not offer or not quest then
			return stockSendQuestLine(self, questId)
		end
		local msg = NetworkMessage()
		msg:addByte(0xF1)
		msg:addU16(questId)
		msg:addByte(1)
		if self:getClient().version >= 1200 then
			msg:addU16(mission and mission.missionId or 0)
		end
		msg:addString(offer.title ~= "" and offer.title or (mission and mission.name) or quest.name, "Player.sendQuestLine - mission.missionName")
		msg:addString(offer.detail or "", "Player.sendQuestLine - mission.missionDesc")
		msg:sendToPlayer(self)
		msg:delete()
	end

	Player._idleMissionQuestLogWrapped = true
end

--- Paw and Fur quest-log rows use storage 65000+taskId; the engine board uses
--- QUESTSTORAGE_BASE+taskId. Treat either as "started" so tracking sticks.
if Player.missionIsStarted and not Player._idleMissionStartedWrapped then
	local stockMissionIsStarted = Player.missionIsStarted
	function Player.missionIsStarted(self, questId, missionIndex)
		if stockMissionIsStarted(self, questId, missionIndex) then
			return true
		end
		local mission = Game.getMission(questId, missionIndex)
		local name = mission and mission.name and tostring(mission.name) or ""
		if not name:find("Paw and Fur:", 1, true) or not tasks or not tasks.GrizzlyAdams then
			return false
		end
		local race = name:match("Paw and Fur:%s*(.+)")
		if not race then
			return false
		end
		for taskId, task in pairs(tasks.GrizzlyAdams) do
			if type(taskId) == "number" and task.raceName and task.raceName:lower() == race:lower() then
				local state = self:getStorageValue(QUESTSTORAGE_BASE + taskId)
				if state > 0 and state < 2 then
					-- Keep the quest-log storage in sync for future stock checks.
					if self:getStorageValue(65000 + taskId) < 0 then
						self:setStorageValue(65000 + taskId, 0)
					end
					return true
				end
			end
		end
		return false
	end
	Player._idleMissionStartedWrapped = true
end

if Player.resetTrackedMissions and not Player._idleMissionResetWrapped then
	local originalReset = Player.resetTrackedMissions
	function Player.resetTrackedMissions(self, received)
		originalReset(self, received)
		IdleMission.syncTracked(self)
	end
	Player._idleMissionResetWrapped = true
end

if Player.sendUpdateTrackedQuest and not Player._idleMissionUpdateWrapped then
	local originalUpdate = Player.sendUpdateTrackedQuest
	function Player.sendUpdateTrackedQuest(self, mission)
		originalUpdate(self, mission)
		IdleMission.refreshTracked(self)
	end
	Player._idleMissionUpdateWrapped = true
end

IdleEvents.on("player.logout", function(player)
	if player then
		IdleMission.stop(player, { recallHunt = false })
	end
end, "IdleMission")
