-- Register Crystal XML raids (data-global/raids/**) as Lua Raid objects so
-- RaidInstance can provision them. C++ Game.startRaid stays disabled.

XmlRaids = XmlRaids or {}

local ALL_DAYS = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }

local function readFile(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local source = file:read("*a")
	file:close()
	if type(source) ~= "string" then
		return nil
	end
	return source:gsub("\r\n", "\n"):gsub("\n", " ")
end

local function xmlAttr(attrs, name)
	if type(attrs) ~= "string" then
		return nil
	end
	-- Require a word frontier so short names (y, x, z) do not match suffixes
	-- of longer attrs (delay="…" → spurious y="…").
	local value = attrs:match("%f[%w_]" .. name .. '%s*=%s*"([^"]*)"')
		or attrs:match("%f[%w_]" .. name .. "%s*=%s*'([^']*)'")
	if value then
		return value
	end
	return attrs:match("%f[%w_]" .. name .. "%s*=%s*([%w%.%-]+)")
end

local function xmlNumber(attrs, name)
	local raw = xmlAttr(attrs, name)
	local n = tonumber(raw)
	if n then
		return n
	end
	return nil
end

local function parseIndex(source)
	local out = {}
	if type(source) ~= "string" then
		return out
	end
	for attrs in source:gmatch("<raid%s+([^>]+)/?>") do
		local name = xmlAttr(attrs, "name")
		local file = xmlAttr(attrs, "file")
		if name and file then
			out[#out + 1] = {
				name = name,
				file = file,
				interval2 = xmlNumber(attrs, "interval2") or 1440,
				margin = xmlNumber(attrs, "margin") or 180,
			}
		end
	end
	return out
end

local function addPoint(points, x, y, z)
	if not x or not y or not z then
		return
	end
	points[#points + 1] = { x = x, y = y, z = z }
end

local function parseRaidBody(source)
	local events = {}
	if type(source) ~= "string" then
		return events
	end

	for attrs in source:gmatch("<announce%s+([^>]+)/?>") do
		local message = xmlAttr(attrs, "message")
		if message and message ~= "" then
			events[#events + 1] = {
				kind = "announce",
				delay = xmlNumber(attrs, "delay") or 0,
				message = message:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""),
			}
		end
	end

	for attrs in source:gmatch("<singlespawn%s+([^>]+)/?>") do
		local name = xmlAttr(attrs, "name")
		local x, y, z = xmlNumber(attrs, "x"), xmlNumber(attrs, "y"), xmlNumber(attrs, "z")
		if name and x and y and z then
			events[#events + 1] = {
				kind = "singlespawn",
				delay = xmlNumber(attrs, "delay") or 0,
				name = name,
				x = x,
				y = y,
				z = z,
			}
		end
	end

	for attrs, body in source:gmatch("<areaspawn%s+([^>]*)>(.-)</areaspawn%s*>") do
		local delay = xmlNumber(attrs, "delay") or 0
		local fromX = xmlNumber(attrs, "fromx")
		local fromY = xmlNumber(attrs, "fromy")
		local fromZ = xmlNumber(attrs, "fromz")
		local toX = xmlNumber(attrs, "tox")
		local toY = xmlNumber(attrs, "toy")
		local toZ = xmlNumber(attrs, "toz")
		local monsters = {}
		for mattrs in body:gmatch("<monster%s+([^>]+)/?>") do
			local name = xmlAttr(mattrs, "name")
			if name then
				monsters[#monsters + 1] = {
					name = name,
					amount = math.max(1, math.floor(xmlNumber(mattrs, "amount") or 1)),
				}
			end
		end
		if #monsters > 0 then
			events[#events + 1] = {
				kind = "areaspawn",
				delay = delay,
				fromX = fromX,
				fromY = fromY,
				fromZ = fromZ,
				toX = toX,
				toY = toY,
				toZ = toZ,
				monsters = monsters,
			}
		end
	end

	table.sort(events, function(a, b)
		if a.delay ~= b.delay then
			return a.delay < b.delay
		end
		if a.kind == b.kind then
			return false
		end
		return a.kind == "announce"
	end)
	return events
end

local function spawnCenter(events)
	local points = {}
	for _, event in ipairs(events) do
		if event.kind == "singlespawn" then
			addPoint(points, event.x, event.y, event.z)
		elseif event.kind == "areaspawn" then
			local x1, x2 = event.fromX, event.toX
			local y1, y2 = event.fromY, event.toY
			local z = event.fromZ or event.toZ
			if x1 and x2 and y1 and y2 and z then
				addPoint(points, math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2), z)
			end
		end
	end
	if #points == 0 then
		return nil
	end
	local sx, sy, sz = 0, 0, points[1].z
	for _, p in ipairs(points) do
		sx = sx + p.x
		sy = sy + p.y
	end
	return {
		x = math.floor(sx / #points),
		y = math.floor(sy / #points),
		z = sz,
	}
end

local function groupByDelay(events)
	local groups = {}
	local byDelay = {}
	for _, event in ipairs(events) do
		local delay = event.delay or 0
		local group = byDelay[delay]
		if not group then
			group = { delay = delay, announces = {}, spawns = {} }
			byDelay[delay] = group
			groups[#groups + 1] = group
		end
		if event.kind == "announce" then
			group.announces[#group.announces + 1] = event.message
		elseif event.kind == "singlespawn" then
			group.spawns[#group.spawns + 1] = {
				name = event.name,
				amount = 1,
				position = Position(event.x, event.y, event.z),
			}
		elseif event.kind == "areaspawn" then
			for _, monster in ipairs(event.monsters or {}) do
				local cap = ExpeditionConfig.RAID_XML_MAX_AMOUNT or 8
				group.spawns[#group.spawns + 1] = {
					name = monster.name,
					amount = math.min(monster.amount, cap),
				}
			end
		end
	end
	table.sort(groups, function(a, b)
		return a.delay < b.delay
	end)
	return groups
end

local function capSpawnTotal(spawns)
	local maxTotal = ExpeditionConfig.RAID_XML_MAX_TOTAL or 32
	local total = 0
	for _, spawn in ipairs(spawns) do
		total = total + (tonumber(spawn.amount) or 0)
	end
	if total <= maxTotal then
		return
	end
	local scale = maxTotal / total
	for _, spawn in ipairs(spawns) do
		spawn.amount = math.max(1, math.floor((tonumber(spawn.amount) or 1) * scale))
	end
end

local function addRaidStages(raid, groups)
	local prevDelay = 0
	for i, group in ipairs(groups) do
		local wait = (group.delay or 0) - prevDelay
		if wait > 0 then
			raid:addIntermission(wait)
		end
		capSpawnTotal(group.spawns)
		local isLast = i == #groups
		local announces = group.announces
		local spawns = group.spawns
		local stage = raid:addStage({
			start = function()
				for _, message in ipairs(announces) do
					raid:broadcast(MESSAGE_EVENT_ADVANCE, message)
				end
				for _, config in ipairs(spawns) do
					raid:spawnMonsters(config)
				end
			end,
		})
		if stage and stage.autoAdvance then
			if isLast then
				-- Keep last stage open; RaidInstance watcher owns teardown after clear/despawn.
				stage:autoAdvance("24h")
			else
				-- Encounter:enterStage cancelEvents() drops pending spawnMonsters timers.
				-- Advance only after the default spawn flash so wave monsters actually appear.
				local spawnMs = tonumber(raid.timeToSpawnMonsters) or ParseDuration("3s") or 3000
				stage:autoAdvance(math.max(100, spawnMs + 200))
			end
		end
		prevDelay = group.delay or prevDelay
	end
end

local function registerOne(entry, raidsRoot)
	if not Raid or Raid.registry[entry.name] then
		return false
	end
	local source = readFile(raidsRoot .. "/" .. entry.file)
	if not source then
		logger.warn("[XmlRaids] missing {}", entry.file)
		return false
	end
	if source:find("<script%s", 1, false) then
		logger.warn("[XmlRaids] skip scripted raid {}", entry.name)
		return false
	end
	local events = parseRaidBody(source)
	local groups = groupByDelay(events)
	local hasSpawn = false
	for _, group in ipairs(groups) do
		if group.spawns[1] then
			hasSpawn = true
			break
		end
	end
	if not hasSpawn then
		logger.warn("[XmlRaids] skip {} (no spawns)", entry.name)
		return false
	end

	local center = spawnCenter(events)
	if not center then
		logger.warn("[XmlRaids] skip {} (no spawn center)", entry.name)
		return false
	end

	local zone = Zone("raid.xml." .. entry.name)
	zone:addArea(Position(center.x - 1, center.y - 1, center.z), Position(center.x + 1, center.y + 1, center.z))

	local interval2 = math.max(1, math.floor(entry.interval2 or 1440))
	local marginMin = math.max(1, math.floor(entry.margin or 180))
	local chancePerDay = 1440 / interval2
	if chancePerDay < 1 then
		chancePerDay = 1
	end

	local raid = Raid(entry.name, {
		zone = zone,
		allowedDays = ALL_DAYS,
		minActivePlayers = 1,
		initialChance = ExpeditionConfig.RAID_XML_INITIAL_CHANCE or 0.12,
		targetChancePerDay = chancePerDay,
		maxChancePerCheck = ExpeditionConfig.RAID_XML_MAX_CHANCE_PER_CHECK or 0.08,
		minGapBetween = tostring(marginMin) .. "m",
	})
	raid._raidSpawnCenter = center
	addRaidStages(raid, groups)
	raid:register()
	return true
end

function XmlRaids.register()
	if not Raid or not Encounter then
		logger.warn("[XmlRaids] Raid/Encounter not loaded; skip XML import")
		return 0
	end
	local raidsRoot = DATA_DIRECTORY .. "/raids"
	local index = readFile(raidsRoot .. "/raids.xml")
	if not index then
		logger.warn("[XmlRaids] missing {}/raids.xml", raidsRoot)
		return 0
	end
	local registered = 0
	for _, entry in ipairs(parseIndex(index)) do
		local ok, err = pcall(registerOne, entry, raidsRoot)
		if ok and err then
			registered = registered + 1
		elseif not ok then
			logger.error("[XmlRaids] failed {}: {}", entry.name, err)
		end
	end
	logger.info("[XmlRaids] registered {} Crystal XML raids as Lua Raid objects", registered)
	return registered
end
