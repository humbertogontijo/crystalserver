ActivityBoostSoloBoss = ActivityBoostSoloBoss or {}

local function kv(player)
	if not player or not player.kv then
		return nil
	end
	return player:kv():scoped(ActivityBoostConfig.KV_SCOPE)
end

local function encode(value)
	if ExpeditionJson and ExpeditionJson.encode then
		return ExpeditionJson.encode(value)
	end
	return "{}"
end

local function decode(raw)
	if type(raw) ~= "string" or raw == "" then
		return {}
	end
	if ExpeditionJson and ExpeditionJson.decode then
		local ok, decoded = pcall(ExpeditionJson.decode, raw)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return {}
end

local function soloBossPool()
	local catalog = ExpeditionConfig and ExpeditionConfig.Catalog or {}
	local out = {}
	for _, entry in ipairs(catalog) do
		local role = entry.role or (entry.kind == "boss" and "boss" or "monster")
		if role == "boss" then
			local isSolo = true
			if ExpeditionConfig.isSoloBoss then
				isSolo = ExpeditionConfig.isSoloBoss(entry)
			elseif entry.bosstiaryClass then
				-- Bane = solo; Archfoe/Nemesis = lever.
				isSolo = tostring(entry.bosstiaryClass):lower() == "bane"
			end
			if isSolo then
				out[#out + 1] = entry
			end
		end
	end
	table.sort(out, function(a, b)
		local la = tonumber(a.recommendedLevel) or tonumber(a.levelMin) or 0
		local lb = tonumber(b.recommendedLevel) or tonumber(b.levelMin) or 0
		if la ~= lb then
			return la < lb
		end
		return tostring(a.name or "") < tostring(b.name or "")
	end)
	return out
end

local function pickForPlayer(player)
	local pool = soloBossPool()
	if #pool == 0 then
		return nil
	end
	local level = player:getLevel()
	local best = pool[1]
	local bestDist = math.huge
	for _, entry in ipairs(pool) do
		local rec = tonumber(entry.recommendedLevel) or tonumber(entry.levelMin) or 1
		local dist = math.abs(rec - level)
		if dist < bestDist then
			bestDist = dist
			best = entry
		end
	end
	-- Slight daily rotation among near matches.
	local near = {}
	for _, entry in ipairs(pool) do
		local rec = tonumber(entry.recommendedLevel) or tonumber(entry.levelMin) or 1
		if math.abs(rec - level) <= bestDist + 30 then
			near[#near + 1] = entry
		end
	end
	if #near == 0 then
		near[1] = best
	end
	local idx = ((os.date("%Y%m%d") + 0) + player:getGuid()) % #near + 1
	local pick = near[idx]
	return {
		expeditionId = pick.id,
		name = pick.name,
		creatureId = pick.creatureId or pick.bossRaceId,
		recommendedLevel = pick.recommendedLevel,
		attempted = false,
		cleared = false,
		rank = nil,
		clearSec = nil,
	}
end

function ActivityBoostSoloBoss.resetForNewDay(player)
	local store = kv(player)
	if store then
		store:remove("soloBoss")
	end
end

function ActivityBoostSoloBoss.get(player)
	local store = kv(player)
	if not store then
		return nil
	end
	local data = decode(store:get("soloBoss") or "")
	if type(data) ~= "table" or not data.expeditionId then
		data = pickForPlayer(player)
		if data then
			store:set("soloBoss", encode(data))
		end
	end
	return data
end

local function save(player, data)
	local store = kv(player)
	if store and data then
		store:set("soloBoss", encode(data))
	end
end

function ActivityBoostSoloBoss.rankForClearSec(sec)
	sec = tonumber(sec) or 0
	for _, row in ipairs(ActivityBoostConfig.BOSS_RUSH_RANKS or {}) do
		if row.maxSec == nil or sec <= row.maxSec then
			return row.id
		end
	end
	return "C"
end

function ActivityBoostSoloBoss.markAttempt(player, expeditionId)
	local data = ActivityBoostSoloBoss.get(player)
	if not data then
		return false, "No boss rush assigned."
	end
	if tostring(data.expeditionId) ~= tostring(expeditionId) then
		return false, "That is not today's Boss Rush target."
	end
	if data.attempted and data.cleared then
		return false, "Boss Rush already completed today."
	end
	if data.attempted and not data.cleared then
		return false, "Boss Rush already attempted today."
	end
	data.attempted = true
	save(player, data)
	return true
end

function ActivityBoostSoloBoss.onBossClear(player, expeditionId, clearSec)
	local data = ActivityBoostSoloBoss.get(player)
	if not data then
		return
	end
	if tostring(data.expeditionId) ~= tostring(expeditionId) then
		return
	end
	if data.cleared then
		return
	end
	data.attempted = true
	data.cleared = true
	data.clearSec = math.floor(tonumber(clearSec) or 0)
	data.rank = ActivityBoostSoloBoss.rankForClearSec(data.clearSec)
	save(player, data)
	ActivityBoostActivities.complete(player, "boss_rush")
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("Boss Rush complete! Rank %s (%ds).", data.rank or "C", data.clearSec or 0)
	)
end

function ActivityBoostSoloBoss.canJoin(player, expeditionId)
	local data = ActivityBoostSoloBoss.get(player)
	if not data or tostring(data.expeditionId) ~= tostring(expeditionId) then
		return true -- not a rush attempt gate for other bosses
	end
	if data.attempted then
		return false, "Boss Rush already attempted today. Come back after server save."
	end
	return true
end
