-- Exclusive solo-boss expeditions unlocked by Paw & Fur (kitno) task reports.
-- Replaces achievement rewards: report unlocks a private solo fight against that boss.

QuestsKitnoBoss = QuestsKitnoBoss or {}

QuestsKitnoBoss.ID_BASE = 910000
QuestsKitnoBoss.KV_SCOPE = "quests-kitno-boss"

local registered = false

local function kv(player)
	if not player or not player.kv then
		return nil
	end
	return player:kv():scoped(QuestsKitnoBoss.KV_SCOPE)
end

function QuestsKitnoBoss.expeditionIdForTaskId(taskId)
	taskId = tonumber(taskId)
	if not taskId then
		return nil
	end
	return QuestsKitnoBoss.ID_BASE + taskId
end

function QuestsKitnoBoss.resolveMonsterName(bossName)
	if type(bossName) ~= "string" or bossName == "" then
		return nil
	end
	local stripped = bossName:gsub("^[Tt]he%s+", "")
	local raw = {
		bossName,
		"The " .. stripped,
		stripped,
	}
	-- Deduplicate (case-insensitive) while preserving order.
	local seen, candidates = {}, {}
	for i = 1, #raw do
		local name = raw[i]
		local key = name:lower()
		if name ~= "" and not seen[key] then
			seen[key] = true
			candidates[#candidates + 1] = name
		end
	end
	-- Prefer CreatureInfo (silent) so short kitno aliases like "Snapper" /
	-- "Many" resolve to "The Snapper" / "The Many" without getMonsterType errors.
	if CreatureInfo and CreatureInfo.get then
		for i = 1, #candidates do
			local info = CreatureInfo.get(candidates[i])
			if info and type(info.name) == "string" and info.name ~= "" then
				local mType = MonsterType and MonsterType(info.name)
				if mType and mType.name then
					local resolved = mType:name()
					if type(resolved) == "string" and resolved ~= "" then
						return resolved
					end
				end
				return info.name
			end
		end
	end
	for i = 1, #candidates do
		local name = candidates[i]
		local mType = MonsterType and MonsterType(name)
		if mType and mType.name then
			local resolved = mType:name()
			if type(resolved) == "string" and resolved ~= "" then
				return resolved
			end
		end
	end
	return nil
end

local function templateSoloArena()
	if not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return nil
	end
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		local role = entry.role or (entry.kind == "boss" and "boss" or "monster")
		if role == "boss" and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(entry) then
			if type(entry.center) == "table" and entry.center.x then
				return entry
			end
		end
	end
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		local role = entry.role or (entry.kind == "boss" and "boss" or "monster")
		if role == "boss" and type(entry.center) == "table" and entry.center.x then
			return entry
		end
	end
	return nil
end

local function alreadyInCatalog(id)
	if not ExpeditionConfig or not ExpeditionConfig.getById then
		return false
	end
	return ExpeditionConfig.getById(id, "boss") ~= nil
end

function QuestsKitnoBoss.registerExpeditions()
	if registered then
		return true
	end
	if not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return false
	end
	local template = templateSoloArena()
	if not template or not template.center then
		logger.warn("[QuestsKitnoBoss] no solo boss arena template — skip exclusive registration")
		return false
	end

	local count = 0
	if not tasks or not tasks.GrizzlyAdams then
		return false
	end
	for taskId, task in pairs(tasks.GrizzlyAdams) do
		if type(taskId) == "number" and type(task) == "table" and task.bossName then
			local monsterName = QuestsKitnoBoss.resolveMonsterName(task.bossName)
			if monsterName then
				local id = QuestsKitnoBoss.expeditionIdForTaskId(taskId)
				if id and not alreadyInCatalog(id) then
					local levelMin = task.level and task.level[1] or 1
					local info = CreatureInfo and CreatureInfo.get and CreatureInfo.get(monsterName)
					local creatureId = info and tonumber(info.creatureId) or nil
					local center = {
						x = template.center.x,
						y = template.center.y,
						z = template.center.z,
					}
					local entry = {
						id = id,
						kind = "hunt",
						role = "boss",
						name = monsterName,
						bosstiaryClass = "Bane",
						encounter = "solo",
						exclusiveKitno = true,
						kitnoTaskId = taskId,
						kitnoBossKey = tostring(task.bossName),
						levelMin = levelMin,
						recommendedLevel = (info and tonumber(info.recommendedLevel)) or levelMin,
						creatureId = creatureId,
						creatureIds = creatureId and { creatureId } or nil,
						center = center,
						floors = { center.z },
						maxPlayers = 1,
						minPlayers = 1,
						score = 2000,
					}
					ExpeditionConfig.Catalog[#ExpeditionConfig.Catalog + 1] = entry
					count = count + 1
				end
			else
				logger.warn("[QuestsKitnoBoss] no MonsterType for boss {}", tostring(task.bossName))
			end
		end
	end
	registered = true
	logger.info("[QuestsKitnoBoss] registered {} exclusive solo boss expeditions", count)
	return true
end

function QuestsKitnoBoss.isUnlocked(player, expeditionId)
	local store = kv(player)
	if not store then
		return false
	end
	local id = tonumber(expeditionId)
	if not id then
		return false
	end
	return store:get("unlock:" .. tostring(id)) == true
		or store:get("unlock:" .. tostring(id)) == 1
		or tostring(store:get("unlock:" .. tostring(id)) or "") == "1"
end

function QuestsKitnoBoss.unlock(player, taskId)
	local id = QuestsKitnoBoss.expeditionIdForTaskId(taskId)
	if not id then
		return nil
	end
	QuestsKitnoBoss.registerExpeditions()
	local store = kv(player)
	if store then
		store:set("unlock:" .. tostring(id), true)
	end
	return id
end

function QuestsKitnoBoss.canJoin(player, catalog)
	if not catalog or not catalog.exclusiveKitno then
		return true
	end
	if QuestsKitnoBoss.isUnlocked(player, catalog.id) then
		return true
	end
	return false, "Complete the matching Paw & Fur task and report it to unlock this boss."
end
