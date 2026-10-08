-- Faceless Bane (The Dream Courts): at 20% health she heals, summons spectres and turns
-- immortal (creature event facelessHealth) until players step on the arena's iron floors
-- (action id 23108) six times; a used floor goes dark for 10s. While she is immortal the
-- runners (everyone but the anchor, which holds her) walk over lit floors, each to its
-- own. The floor counter is Game storage, kept per instance by InstanceStorage.

local IMMORTAL_EVENT = "facelessHealth"
local WARD_TILE_AID = 23108
local PICK_INTERVAL_MS = 500

local function isWardTile(item)
	return item:getActionId() == WARD_TILE_AID
end

local function litWardAt(position)
	local tile = Tile(position)
	if not tile then
		return false
	end
	local ground = tile:getGround()
	if ground and isWardTile(ground) then
		return true
	end
	for _, item in ipairs(tile:getItems() or {}) do
		if isWardTile(item) then
			return true
		end
	end
	return false
end

local function key(position)
	return position.x .. ":" .. position.y
end

ExpeditionBossMechanics.register("Faceless Bane", function(ctx)
	local wards = ctx:findArenaTiles(isWardTile)
	if #wards == 0 then
		logger.warn("[ExpeditionBossMechanics] Faceless Bane: no ward tiles (aid {}) in the arena", WARD_TILE_AID)
		return
	end
	local claimed = {} -- ward key -> runner id

	local function nextWard(runner)
		local here = runner:getPosition()
		local best, bestDist = nil, nil
		for _, ward in ipairs(wards) do
			local dist = math.max(math.abs(ward.x - here.x), math.abs(ward.y - here.y))
			if dist > 0 and not claimed[key(ward)] and litWardAt(ward) and (not bestDist or dist < bestDist) then
				best, bestDist = ward, dist
			end
		end
		return best
	end

	ctx:whileBossHasEvent(IMMORTAL_EVENT, PICK_INTERVAL_MS, function()
		for _, runner in ipairs(ctx:runners()) do
			local ward = not PlayerErrand.owns(runner) and nextWard(runner)
			if ward then
				claimed[key(ward)] = runner:getId()
				ctx:walkTo(runner, ward, {
					keepGoing = function()
						return litWardAt(ward) and ctx:bossHasEvent(IMMORTAL_EVENT)
					end,
					onDone = function()
						claimed[key(ward)] = nil
					end,
				})
			end
		end
	end)
end)
