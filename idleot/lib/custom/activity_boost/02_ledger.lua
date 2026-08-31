ActivityBoostLedger = ActivityBoostLedger or {}

local function kv(player)
	if not player or not player.kv then
		return nil
	end
	return player:kv():scoped(ActivityBoostConfig.KV_SCOPE)
end

local function encodeLots(lots)
	if ExpeditionJson and ExpeditionJson.encode then
		return ExpeditionJson.encode(lots or {})
	end
	return "[]"
end

local function decodeLots(raw)
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

local function loadLots(player)
	local store = kv(player)
	if not store then
		return {}
	end
	return decodeLots(store:get("lots") or "")
end

local function saveLots(player, lots)
	local store = kv(player)
	if not store then
		return
	end
	store:set("lots", encodeLots(lots))
end

local function sumLots(lots)
	local total = 0
	for _, lot in ipairs(lots) do
		total = total + math.max(0, math.floor(tonumber(lot.seconds) or 0))
	end
	return total
end

local function soonestExpiry(lots)
	local best = nil
	for _, lot in ipairs(lots) do
		local exp = tonumber(lot.expiresAt)
		if exp and (not best or exp < best) then
			best = exp
		end
	end
	return best
end

function ActivityBoostLedger.syncEngine(player, lots)
	if not player then
		return 0
	end
	lots = lots or loadLots(player)
	local total = sumLots(lots)
	if player.setXpBoostTime then
		player:setXpBoostTime(total)
	end
	if total > 0 then
		if player.setXpBoostPercent then
			player:setXpBoostPercent(ActivityBoostConfig.XP_BOOST_PERCENT or 50)
		end
	else
		if player.setXpBoostPercent then
			player:setXpBoostPercent(0)
		end
	end
	return total
end

--- Drop expired lots; sync engine. Returns remaining seconds.
function ActivityBoostLedger.purgeExpired(player)
	if not player then
		return 0
	end
	local now = os.time()
	local lots = loadLots(player)
	local kept = {}
	for _, lot in ipairs(lots) do
		local exp = tonumber(lot.expiresAt) or 0
		local sec = math.floor(tonumber(lot.seconds) or 0)
		if sec > 0 and exp > now then
			kept[#kept + 1] = { seconds = sec, expiresAt = exp }
		end
	end
	saveLots(player, kept)
	return ActivityBoostLedger.syncEngine(player, kept)
end

function ActivityBoostLedger.getStatus(player)
	local remaining = ActivityBoostLedger.purgeExpired(player)
	local lots = loadLots(player)
	local store = kv(player)
	local earned = store and tonumber(store:get("dailyEarnedSec")) or 0
	return {
		remainingSec = remaining,
		expiresAt = soonestExpiry(lots),
		dailyEarnedSec = earned,
		dailyCapSec = ActivityBoostConfig.DAILY_EARN_CAP_SEC or 0,
		boostPercent = remaining > 0 and (ActivityBoostConfig.XP_BOOST_PERCENT or 50) or 0,
	}
end

function ActivityBoostLedger.getDailyEarned(player)
	local store = kv(player)
	if not store then
		return 0
	end
	return math.max(0, math.floor(tonumber(store:get("dailyEarnedSec")) or 0))
end

function ActivityBoostLedger.resetDailyEarned(player)
	local store = kv(player)
	if store then
		store:set("dailyEarnedSec", 0)
	end
end

--- Credit seconds (capped by remaining daily earn room). Returns credited seconds.
function ActivityBoostLedger.credit(player, seconds, opts)
	opts = opts or {}
	if not player then
		return 0
	end
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	if seconds <= 0 then
		return 0
	end
	ActivityBoostLedger.purgeExpired(player)

	local store = kv(player)
	local earned = ActivityBoostLedger.getDailyEarned(player)
	local cap = ActivityBoostConfig.DAILY_EARN_CAP_SEC or 0
	if not opts.ignoreDailyCap and cap > 0 then
		local room = math.max(0, cap - earned)
		if room <= 0 then
			return 0
		end
		seconds = math.min(seconds, room)
	end

	local lots = loadLots(player)
	local ttl = ActivityBoostConfig.LOT_TTL_SEC or (24 * 60 * 60)
	lots[#lots + 1] = {
		seconds = seconds,
		expiresAt = os.time() + ttl,
	}
	saveLots(player, lots)
	if store and not opts.ignoreDailyCap then
		store:set("dailyEarnedSec", earned + seconds)
	end
	ActivityBoostLedger.syncEngine(player, lots)
	return seconds
end

--- Drain consumed boost from FIFO lots (engine ticks independently; call periodically).
function ActivityBoostLedger.reconcileWithEngine(player)
	if not player or not player.getXpBoostTime then
		return ActivityBoostLedger.purgeExpired(player)
	end
	ActivityBoostLedger.purgeExpired(player)
	local engineLeft = math.max(0, math.floor(tonumber(player:getXpBoostTime()) or 0))
	local lots = loadLots(player)
	local ledgerTotal = sumLots(lots)
	if engineLeft >= ledgerTotal then
		return ActivityBoostLedger.syncEngine(player, lots)
	end
	-- Engine consumed time - shrink FIFO lots to match.
	local need = ledgerTotal - engineLeft
	local kept = {}
	for _, lot in ipairs(lots) do
		if need <= 0 then
			kept[#kept + 1] = lot
		else
			local sec = math.floor(tonumber(lot.seconds) or 0)
			if sec <= need then
				need = need - sec
			else
				kept[#kept + 1] = {
					seconds = sec - need,
					expiresAt = lot.expiresAt,
				}
				need = 0
			end
		end
	end
	saveLots(player, kept)
	return ActivityBoostLedger.syncEngine(player, kept)
end

function ActivityBoostLedger.applyOnExpeditionJoin(player)
	if not player then
		return
	end
	local remaining = ActivityBoostLedger.purgeExpired(player)
	if remaining > 0 and player.setXpBoostPercent then
		player:setXpBoostPercent(ActivityBoostConfig.XP_BOOST_PERCENT or 50)
	end
end
