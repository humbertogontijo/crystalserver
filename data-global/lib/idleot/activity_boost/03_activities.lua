ActivityBoostActivities = ActivityBoostActivities or {}

local function kv(player)
	if not player or not player.kv then
		return nil
	end
	return player:kv():scoped(ActivityBoostConfig.KV_SCOPE)
end

local function dayKey()
	return os.date("%Y-%m-%d")
end

local function decodeMap(raw)
	if type(raw) ~= "string" or raw == "" or raw == "{}" then
		return {}
	end
	if JsonParser and JsonParser.decode then
		local ok, decoded = pcall(JsonParser.decode, raw)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return {}
end

local function encodeMap(map)
	if JsonParser and JsonParser.encode then
		return JsonParser.encode(map or {})
	end
	return "{}"
end

--- Boost bookkeeping day rollover (XP bank). Counts live in C++ DailyActivityData.
local function ensureBoostDay(player)
	local store = kv(player)
	if not store then
		return nil
	end
	local today = dayKey()
	local saved = store:get("activityDay")
	if saved ~= today then
		store:set("activityDay", today)
		store:set("credited", "{}")
		-- Drop legacy keys from the previous boolean-completion design.
		store:remove("completed")
		store:remove("worldBossFragged")
		ActivityBoostLedger.resetDailyEarned(player)
		if ActivityBoostSoloBoss and ActivityBoostSoloBoss.resetForNewDay then
			ActivityBoostSoloBoss.resetForNewDay(player)
		end
		if ActivityBoostFiendishHunt and ActivityBoostFiendishHunt.resetForNewDay then
			ActivityBoostFiendishHunt.resetForNewDay(player)
		end
	end
	return store
end

local function findDef(activityId)
	for _, entry in ipairs(ActivityBoostConfig.ACTIVITIES or {}) do
		if entry.id == activityId then
			return entry
		end
	end
	return nil
end

local function getCurrent(player, activityId)
	if not player or not player.getDailyActivityStat then
		return 0
	end
	return tonumber(player:getDailyActivityStat(tostring(activityId))) or 0
end

local function isCredited(player, activityId)
	local store = ensureBoostDay(player)
	if not store then
		return false
	end
	local credited = decodeMap(store:get("credited") or "{}")
	return credited[tostring(activityId)] == true
end

local function markCredited(player, activityId)
	local store = ensureBoostDay(player)
	if not store then
		return
	end
	local credited = decodeMap(store:get("credited") or "{}")
	credited[tostring(activityId)] = true
	store:set("credited", encodeMap(credited))
end

function ActivityBoostActivities.isComplete(player, activityId)
	local def = findDef(activityId)
	if not def then
		return false
	end
	local goal = tonumber(def.goal) or 1
	return getCurrent(player, activityId) >= goal
end

--- Credit XP boost once when today's count reaches the goal.
function ActivityBoostActivities.evaluateCredit(player, activityId)
	if not player or not activityId then
		return 0
	end
	local def = findDef(activityId)
	if not def then
		return 0
	end
	ensureBoostDay(player)
	local goal = tonumber(def.goal) or 1
	local current = getCurrent(player, activityId)
	if current < goal then
		return 0
	end
	if isCredited(player, activityId) then
		return 0
	end
	markCredited(player, activityId)
	local credited = ActivityBoostLedger.credit(player, def.rewardSec or 0)
	if credited > 0 then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"Activity complete: %s (+%d min XP boost).",
				def.name or activityId,
				math.floor(credited / 60)
			)
		)
	end
	return credited
end

function ActivityBoostActivities.list(player, opts)
	ensureBoostDay(player)
	opts = opts or {}
	local out = {}
	for _, def in ipairs(ActivityBoostConfig.ACTIVITIES or {}) do
		local goal = tonumber(def.goal) or 1
		local current = math.min(getCurrent(player, def.id), goal)
		local percent = 0
		if goal > 0 then
			percent = math.min(100, math.floor((current / goal) * 100 + 0.5))
		end
		local description = def.description
		if def.id == "fiendish_hunt" then
			local offer = opts.fiendishHunt
			if offer == nil and ActivityBoostFiendishHunt and ActivityBoostFiendishHunt.get then
				offer = ActivityBoostFiendishHunt.get(player)
			end
			if offer and offer.huntName and not offer.complete then
				description = string.format(
					"Clear %s — Fiendish %s (%d/%d).",
					offer.huntName,
					offer.creatureName or "creature",
					current,
					goal
				)
			end
		end
		out[#out + 1] = {
			id = def.id,
			name = def.name,
			description = description,
			rewardSec = def.rewardSec,
			destination = def.destination,
			destinationLabel = def.destinationLabel,
			goal = goal,
			current = current,
			percent = percent,
			complete = current >= goal,
		}
	end
	return out
end

--- Increment a daily activity counter and evaluate XP credit.
function ActivityBoostActivities.addProgress(player, activityId, delta)
	delta = tonumber(delta) or 1
	if not player or not activityId or delta <= 0 then
		return 0
	end
	if not player.addDailyActivityStat then
		return 0
	end
	ensureBoostDay(player)
	local current = player:addDailyActivityStat(tostring(activityId), delta)
	ActivityBoostActivities.evaluateCredit(player, activityId)
	if ActivityBoostProtocol and ActivityBoostProtocol.sendState then
		ActivityBoostProtocol.sendState(player)
	end
	return current
end

--- Called from C++ after daily_hunt kill increments (throttled).
function ActivityBoostActivities.onStatChanged(player, activityId)
	if not player then
		return
	end
	ensureBoostDay(player)
	ActivityBoostActivities.evaluateCredit(player, activityId)
	if ActivityBoostProtocol and ActivityBoostProtocol.sendState then
		ActivityBoostProtocol.sendState(player)
	end
end

function ActivityBoostActivities.onServerSave()
	-- GlobalServerSave already bumped DailyReward lastServerSave; drop banked boost.
	for _, player in ipairs(Game.getPlayers()) do
		ensureBoostDay(player)
		ActivityBoostLedger.clear(player)
		if ActivityBoostProtocol and ActivityBoostProtocol.sendState then
			pcall(ActivityBoostProtocol.sendState, player)
		end
	end
end

function ActivityBoostActivities.onLogin(player)
	ensureBoostDay(player)
	-- Offline players: clear lots stamped before the latest server save.
	ActivityBoostLedger.purgeExpired(player)
end

function ActivityBoostActivities.onBossExpeditionVictory(player, session)
	if not player then
		return
	end
	local catalog = session and session.catalog
	if not catalog then
		return
	end
	if ExpeditionConfig and ExpeditionConfig.isSoloBoss then
		if not ExpeditionConfig.isSoloBoss(catalog) then
			return
		end
	end
	ActivityBoostActivities.addProgress(player, "solo_boss", 1)
end

--- Task Board daily bounty claim (hooked from CrystalServer game.cpp).
function ActivityBoostActivities.onBountyTaskClaimed(player)
	ActivityBoostActivities.addProgress(player, "bounty_hunter", 1)
end

function ActivityBoostActivities.getWorldBossFragsToday(player)
	return getCurrent(player, "world_boss")
end

function ActivityBoostActivities.worldBossCapReached(player)
	local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
	return getCurrent(player, "world_boss") >= cap
end
