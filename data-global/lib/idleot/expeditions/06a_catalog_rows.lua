-- Expedition catalog rows for the client (opcode 113 catalog pages): what each player
-- may see, slimmed to the fields the hunt finder and boss list draw.

-- Mirrors packages/asset-pipeline/src/expedition/domain/hunt-levels.ts HUNT_BANDS.
local CATALOG_LEVEL_BANDS = {
	{ id = "1-7", lo = 1, hi = 7 },
	{ id = "8-19", lo = 8, hi = 19 },
	{ id = "20-34", lo = 20, hi = 34 },
	{ id = "35-49", lo = 35, hi = 49 },
	{ id = "50-79", lo = 50, hi = 79 },
	{ id = "80-99", lo = 80, hi = 99 },
	{ id = "100-149", lo = 100, hi = 149 },
	{ id = "150-199", lo = 150, hi = 199 },
	{ id = "200-249", lo = 200, hi = 249 },
	{ id = "250-299", lo = 250, hi = 299 },
	{ id = "300-399", lo = 300, hi = 399 },
	{ id = "400-549", lo = 400, hi = 549 },
	{ id = "550-599", lo = 550, hi = 599 },
	{ id = "600+", lo = 600, hi = nil },
}

local function levelBand(entry)
	if type(entry) ~= "table" then
		return ""
	end
	local band = entry.levelBand
	if type(band) == "string" and band ~= "" then
		return band
	end
	local level = tonumber(entry.recommendedLevel) or tonumber(entry.levelMin) or 1
	for _, row in ipairs(CATALOG_LEVEL_BANDS) do
		if level >= row.lo then
			if row.hi == nil or level <= row.hi then
				return row.id
			end
		end
	end
	return ""
end

--- Stable creature mix key: sorted creatureId:percent pairs.
local function creatureSignature(entry)
	if type(entry) ~= "table" then
		return ""
	end
	local sig = entry.creatureSignature
	if type(sig) == "string" and sig ~= "" then
		return sig
	end
	local creatures = entry.creatures
	if type(creatures) ~= "table" or #creatures == 0 then
		local cid = tonumber(entry.creatureId)
		if cid and cid > 0 then
			return tostring(cid) .. ":100"
		end
		return ""
	end
	local parts = {}
	for _, c in ipairs(creatures) do
		local cid = c and tonumber(c.creatureId)
		if cid and cid > 0 then
			parts[#parts + 1] = string.format("%d:%d", cid, math.floor(tonumber(c.percent) or 0))
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function samplePoints(list, cap)
	local out = {}
	local n = #list
	local step = math.max(1, n / cap)
	local i = 1
	while i <= n and #out < cap do
		local p = list[math.floor(i)]
		out[#out + 1] = { x = p.x, y = p.y, z = p.z }
		i = i + step
	end
	return out
end

--- Client minimap preview of a cave route: hold pins and the (closed) walk.
local function cavePreview(route)
	if not route then
		return nil, nil
	end
	local holds = {}
	for _, w in ipairs(route.waypoints) do
		if w.hold then
			holds[#holds + 1] = w
		end
	end
	return samplePoints(holds, 8), samplePoints(route.waypoints, 24)
end

--- Catalog rows `player` may see, slimmed for the client hunt finder / boss list.
function ExpeditionProtocol.catalogRows(player)
	local out = {}
	local now = os.time()
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		local include = true
		if entry.exclusiveKitno then
			include = player
				and QuestsKitnoBoss
				and QuestsKitnoBoss.isUnlocked
				and QuestsKitnoBoss.isUnlocked(player, entry.id)
		elseif entry.exclusiveArena then
			include = player and select(1, QuestArena.canJoin(player, entry))
		end
		if include then
			local role = entry.role
			if role ~= "boss" and role ~= "monster" and role ~= "arena" then
				role = entry.kind == "boss" and "boss" or "monster"
			end
			-- Client hunt UI only knows boss/monster; arena uses monster chrome + wave.
			if role == "arena" then
				role = "monster"
			end
			local row = {
				id = entry.id,
				kind = "hunt",
				role = role,
				name = entry.name,
				levelMin = entry.levelMin,
				recommendedLevel = entry.recommendedLevel,
				creatureId = entry.creatureId,
				floorOffset = tonumber(entry.floorOffset) or 0,
			}
			local combatPower = tonumber(entry.combatPower)
			if combatPower then
				row.combatPower = combatPower
			end
			if entry.exclusiveKitno then
				row.exclusiveKitno = true
			end
			if entry.exclusiveArena then
				row.exclusiveArena = true
				row.encounter = "solo"
				row.maxPlayers = tonumber(entry.maxPlayers) or 1
				row.minPlayers = tonumber(entry.minPlayers) or 1
			end
			local fid = entry.floorFamilyId
			if type(fid) == "string" and fid ~= "" then
				row.floorFamilyId = fid
				row.floorFamilySize = tonumber(entry.floorFamilySize) or 1
				row.floorFamilyIndex = tonumber(entry.floorFamilyIndex) or 0
			end
			local sig = creatureSignature(entry)
			if sig ~= "" then
				row.creatureSignature = sig
			end
			local band = levelBand(entry)
			if band ~= "" then
				row.levelBand = band
			end
			-- Each hunt / floor is its own entry (no floor families or alternates).
			row.displayRepresentative = true
			local creatureIds = entry.creatureIds
			if type(creatureIds) == "table" and #creatureIds > 0 then
				local slim = {}
				local n = math.min(8, #creatureIds)
				for i = 1, n do
					slim[i] = creatureIds[i]
				end
				row.creatureIds = slim
			elseif entry.creatureId then
				row.creatureIds = { entry.creatureId }
			end
			-- Slim creature mix for client hunt-detail looks (id + spawn percent + name).
			-- Names come from CreatureInfo so OTC HuntFinder never falls back to the place title.
			-- Do not copy enrichCreatureMix combat stats; the client uses the hunt-level fields.
			local creatures = entry.creatures
			if type(creatures) == "table" and #creatures > 0 then
				local slimCreatures = {}
				local n = math.min(8, #creatures)
				for i = 1, n do
					local c = creatures[i]
					local cid = c and tonumber(c.creatureId)
					if cid and cid > 0 then
						local crow = {
							creatureId = cid,
							percent = tonumber(c.percent) or 0,
						}
						local amt = tonumber(c.count)
						if amt and amt > 0 then
							crow.count = amt
						end
						local cname = c.name
						if (not cname or cname == "") then
							local info = CreatureInfo.getByCreatureId(cid)
							cname = info and info.name or nil
						end
						if cname and cname ~= "" then
							crow.name = cname
						end
						slimCreatures[#slimCreatures + 1] = crow
					end
				end
				if #slimCreatures > 0 then
					row.creatures = slimCreatures
				end
			end
			if role == "boss" then
				row.bosstiaryClass = entry.bosstiaryClass
				local encounter = ExpeditionConfig.bossEncounter(entry)
				row.encounter = encounter
				local maxPlayers = tonumber(entry.maxPlayers)
				if maxPlayers and maxPlayers > 0 then
					row.maxPlayers = maxPlayers
				elseif encounter == "solo" then
					row.maxPlayers = 1
				else
					row.maxPlayers = 5
				end
				local minPlayers = tonumber(entry.minPlayers)
				if minPlayers and minPlayers > 0 then
					row.minPlayers = minPlayers
				elseif encounter == "solo" then
					row.minPlayers = 1
				end
				local difficultyLever = ExpeditionConfig.bossDifficultyLever(entry)
				if difficultyLever then
					row.bossDifficultyMax = BossDifficulty.max(difficultyLever)
				end
				if type(entry.availability) == "table" and next(entry.availability) ~= nil then
					local available, nextAt = ExpeditionConfig.bossAvailability(entry, now)
					row.availability = entry.availability
					row.available = available
					row.availableAt = nextAt
					if not available then
						row.availabilityLabel = ExpeditionConfig.availabilityLabel(entry, now)
					end
				end
			else
				row.city = entry.city
				local density = tonumber(entry.creatureDensity)
				if density and density > 0 then
					row.creatureDensity = density
				end
				local lureMax = tonumber(entry.lureMax)
				if lureMax and lureMax > 0 then
					row.lureMax = lureMax
				end
			end
			local center = entry.center
			if type(center) == "table" and center.x and center.y then
				row.center = {
					x = tonumber(center.x) or 0,
					y = tonumber(center.y) or 0,
					z = tonumber(center.z) or 7,
				}
			end
			-- Cave route preview for client minimap markers (detail + HUD track).
			if role ~= "boss" then
				row.holds, row.route = cavePreview(ExpeditionConfig.caveRoute(entry))
			end
			out[#out + 1] = row
		end
	end
	return out
end
