-- IdleMission: mission orchestrator (click-through tracker).
-- Scripts register with IdleMission.register; steps use PlayerController actions.

IdleMission = IdleMission or {}
IdleMission.__index = IdleMission
setmetatable(IdleMission, { __index = IdleOrchestrator })

IdleMission.registry = IdleMission.registry or {} -- key → def
IdleMission.byPlayerId = IdleMission.byPlayerId or {} -- playerId → run
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

function IdleMission.runFor(player)
	return player and IdleMission.byPlayerId[player:getId()] or nil
end

local function pushTracker(run)
	local player = Player(run.playerId)
	if not player or not ExpeditionProtocol then
		return
	end
	local step = run.steps[run.stepIndex]
	local payload = {
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
	IdleMission.byPlayerId[run.playerId] = nil
	local player = Player(run.playerId)
	if player and ExpeditionProtocol then
		ExpeditionProtocol.send(player, {
			type = "missionTracker",
			missionKey = run.key,
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

local function advanceToNext(run)
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
		if IdleMission.byPlayerId[run.playerId] ~= run then
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
			if IdleMission.byPlayerId[run.playerId] ~= run then
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
	local existing = IdleMission.runFor(player)
	if existing then
		if existing.key == key then
			pushTracker(existing)
			return true
		end
		stopRun(existing, { recallHunt = true })
	end

	local orch = IdleOrchestrator.new({ name = "mission:" .. key })
	local run = setmetatable({
		key = key,
		name = def.name,
		cipQuestId = def.cipQuestId,
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
	IdleMission.byPlayerId[run.playerId] = run

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
	local run = IdleMission.runFor(player)
	if run then
		stopRun(run, opts or { recallHunt = true })
	end
end

--- CTA click: run only the current step's action.
function IdleMission.advance(player)
	local run = IdleMission.runFor(player)
	if not run then
		return false, "No active mission."
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
			end)
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
			if reason and reason ~= "manual" then
				player:sendTextMessage(MESSAGE_FAILURE, tostring(reason))
			end
			return
		end
		advanceToNext(run)
	end
	local started, err = step.onAdvance(run, finish)
	if started == false then
		finish(false, err or "Failed.")
		return false, err
	end
	return true
end

function IdleMission.findHuntId(hint)
	return findHuntIdForHint(hint)
end

--- Append mission rows into ExpeditionConfig.Catalog (runtime, like arena/kitno).
function IdleMission.registerCatalogRows()
	if not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return
	end
	-- Drop previous mission rows.
	local kept = {}
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if not entry.idleMission then
			kept[#kept + 1] = entry
		end
	end
	ExpeditionConfig.Catalog = kept
	for _, def in pairs(IdleMission.registry) do
		ExpeditionConfig.Catalog[#ExpeditionConfig.Catalog + 1] = {
			id = def.catalogId,
			kind = "quest",
			role = "monster",
			name = def.name,
			cipQuestId = def.cipQuestId,
			idleMission = def.key,
			missionKey = def.key,
			levelMin = def.levelMin or 1,
			recommendedLevel = def.recommendedLevel or def.levelMin or 1,
			creatures = def.creatures or {},
			center = def.center,
			city = def.city,
		}
	end
	if ExpeditionConfig.sortCatalogForDisplay then
		ExpeditionConfig.sortCatalogForDisplay(ExpeditionConfig.Catalog)
	end
end

IdleEvents.on("player.logout", function(player)
	if player then
		IdleMission.stop(player, { recallHunt = false })
	end
end, "IdleMission")
