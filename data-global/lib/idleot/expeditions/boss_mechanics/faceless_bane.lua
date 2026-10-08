-- Faceless Bane (The Dream Courts): at 20% health she heals, summons spectres and turns
-- immortal (creature event facelessHealth) until players step on the arena's iron floors
-- (action id 23108) six times; a used floor goes dark (action id cleared) for 10s. While
-- she is immortal the runners (everyone but the anchor, which holds her) walk over lit
-- floors, each to its own. The floor counter is Game storage, kept per instance by
-- InstanceStorage.
--
-- Runners are sent when she turns immortal, when one of them finishes a floor, and when a
-- member is handed back to the AI. Floors change only their action id (no item event), so a
-- runner left without a lit floor waits for the earliest known relight.

local IMMORTAL_EVENT = "facelessHealth"
local WARD_TILE_AID = 23108
local WARD_DARK_MS = 10000 -- stock: a used floor relights after 10s
local RELIGHT_RETRY_MS = 1000 -- floors darkened by someone else relight at an unknown time

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
	local claimed, darkUntil, walking = {}, {}, {} -- ward key -> runner id / relight ms; runner id -> true

	local function immortal()
		return ctx:bossHasEvent(IMMORTAL_EVENT)
	end

	local function nextWard(runner)
		local here = runner:getPosition()
		local best, bestDist = nil, nil
		for _, ward in ipairs(wards) do
			local dist = CombatGeo.chebyshev(ward, here)
			if dist > 0 and dist ~= math.huge and not claimed[key(ward)] and litWardAt(ward) and (not bestDist or dist < bestDist) then
				best, bestDist = ward, dist
			end
		end
		return best
	end

	local dispatch

	local function waitForRelight()
		local now, soonest = CombatGeo.nowMs(), nil
		for _, ward in ipairs(wards) do
			local relight = darkUntil[key(ward)]
			if relight and relight > now and (not soonest or relight < soonest) then
				soonest = relight
			end
		end
		ctx.scope:timer("relight", soonest and (soonest - now) or RELIGHT_RETRY_MS, dispatch)
	end

	dispatch = function()
		if not immortal() then
			return
		end
		local waiting = false
		for _, runner in ipairs(ctx:runners()) do
			local id = runner:getId()
			if not walking[id] then
				local ward = not PlayerErrand.owns(runner) and nextWard(runner)
				if ward then
					local wardKey = key(ward)
					claimed[wardKey], walking[id] = id, true
					local started = ctx:walkTo(runner, ward, {
						keepGoing = function()
							return litWardAt(ward) and immortal()
						end,
						onDone = function(_, ok)
							claimed[wardKey], walking[id] = nil, nil
							if ok then
								darkUntil[wardKey] = CombatGeo.nowMs() + WARD_DARK_MS
							end
							ctx:after(0, dispatch)
						end,
					})
					if not started then
						claimed[wardKey], walking[id] = nil, nil
					end
				else
					waiting = true
				end
			end
		end
		if waiting then
			waitForRelight()
		end
	end

	ctx:onBossEvent(IMMORTAL_EVENT, dispatch, function()
		ctx.scope:cancel("relight")
	end)
	ctx:on("member.resumed", function(session)
		if session == ctx.session then
			dispatch()
		end
	end)
end, { immunity = { IMMORTAL_EVENT } })
