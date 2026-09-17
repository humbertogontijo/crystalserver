CreatureInfo = CreatureInfo or {}

CreatureInfo.ByName = CreatureInfo.ByName or {}
CreatureInfo.ByCreatureId = CreatureInfo.ByCreatureId or {}

local function normalizeKey(name)
	if type(name) ~= "string" then
		return ""
	end
	return name:lower()
end

function CreatureInfo.load()
	local path = DATA_DIRECTORY .. "/lib/idleot/creature_info/creatures.generated.json"
	local file = io.open(path, "r")
	if not file then
		logger.error("[CreatureInfo] missing creatures.generated.json at {}", path)
		CreatureInfo.ByName = {}
		CreatureInfo.ByCreatureId = {}
		return false
	end
	local content = file:read("*a")
	file:close()
	local data = JsonParser and JsonParser.decode(content) or json.decode(content)
	if type(data) ~= "table" or type(data.byName) ~= "table" then
		logger.error("[CreatureInfo] creatures.generated.json decode failed")
		CreatureInfo.ByName = {}
		CreatureInfo.ByCreatureId = {}
		return false
	end

	local byName = {}
	local byCreatureId = {}

	for name, entry in pairs(data.byName) do
		entry.name = name
		byName[normalizeKey(name)] = entry
		local id = tonumber(entry.creatureId)
		if id and id > 0 then
			byCreatureId[id] = entry
		end
	end

	-- Prefer explicit byCreatureId index when present. JSON decode yields separate
	-- tables (not aliases of byName), so row==entry never backfills name — copy
	-- the name already set from byName for the same creatureId.
	if type(data.byCreatureId) == "table" then
		for key, entry in pairs(data.byCreatureId) do
			local id = tonumber(key)
			if id and id > 0 and type(entry) == "table" then
				if type(entry.name) ~= "string" or entry.name == "" then
					local prior = byCreatureId[id]
					if prior and type(prior.name) == "string" and prior.name ~= "" then
						entry.name = prior.name
					end
				end
				byCreatureId[id] = entry
			end
		end
	end

	CreatureInfo.ByName = byName
	CreatureInfo.ByCreatureId = byCreatureId

	local count = 0
	for _ in pairs(byName) do
		count = count + 1
	end
	local idCount = 0
	for _ in pairs(byCreatureId) do
		idCount = idCount + 1
	end
	logger.info("[CreatureInfo] loaded {} creatures ({} ids)", count, idCount)
	return true
end

--- Lookup by display name (case-insensitive).
function CreatureInfo.get(name)
	if not name then
		return nil
	end
	return CreatureInfo.ByName[normalizeKey(name)]
end

--- Recommended level from shared CP→level map (raids, solo bosses, world bosses).
function CreatureInfo.recommendedLevel(name)
	local info = CreatureInfo.get(name)
	if not info then
		return nil
	end
	return tonumber(info.recommendedLevel) or tonumber(info.levelMin)
end

CreatureInfo.load()
