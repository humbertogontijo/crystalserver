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

local function ensureDay(player)
	local store = kv(player)
	if not store then
		return nil
	end
	local today = dayKey()
	local saved = store:get("activityDay")
	if saved ~= today then
		store:set("activityDay", today)
		store:set("completed", "{}")
		ActivityBoostLedger.resetDailyEarned(player)
		if ActivityBoostSoloBoss and ActivityBoostSoloBoss.resetForNewDay then
			ActivityBoostSoloBoss.resetForNewDay(player)
		end
		store:remove("worldBossFragged")
	end
	return store
end

local function decodeCompleted(raw)
	if type(raw) ~= "string" or raw == "" or raw == "{}" then
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

local function encodeCompleted(map)
	if ExpeditionJson and ExpeditionJson.encode then
		return ExpeditionJson.encode(map or {})
	end
	return "{}"
end

function ActivityBoostActivities.isComplete(player, activityId)
	local store = ensureDay(player)
	if not store then
		return false
	end
	local completed = decodeCompleted(store:get("completed") or "{}")
	return completed[tostring(activityId)] == true
end

function ActivityBoostActivities.list(player)
	ensureDay(player)
	local out = {}
	for _, def in ipairs(ActivityBoostConfig.ACTIVITIES or {}) do
		out[#out + 1] = {
			id = def.id,
			name = def.name,
			description = def.description,
			rewardSec = def.rewardSec,
			destination = def.destination,
			destinationLabel = def.destinationLabel,
			complete = ActivityBoostActivities.isComplete(player, def.id),
		}
	end
	return out
end

--- Mark complete and credit boost (once per day). Returns credited seconds or 0.
function ActivityBoostActivities.complete(player, activityId, opts)
	opts = opts or {}
	if not player or not activityId then
		return 0
	end
	local store = ensureDay(player)
	if not store then
		return 0
	end
	local def = nil
	for _, entry in ipairs(ActivityBoostConfig.ACTIVITIES or {}) do
		if entry.id == activityId then
			def = entry
			break
		end
	end
	if not def then
		return 0
	end
	if ActivityBoostActivities.isComplete(player, activityId) then
		return 0
	end
	local completed = decodeCompleted(store:get("completed") or "{}")
	completed[tostring(activityId)] = true
	store:set("completed", encodeCompleted(completed))

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
	if ActivityBoostProtocol and ActivityBoostProtocol.sendState then
		ActivityBoostProtocol.sendState(player)
	end
	return credited
end

function ActivityBoostActivities.onServerSave()
	for _, player in ipairs(Game.getPlayers()) do
		ensureDay(player)
		ActivityBoostLedger.purgeExpired(player)
	end
end

function ActivityBoostActivities.onLogin(player)
	ensureDay(player)
	ActivityBoostLedger.purgeExpired(player)
end

--- Track hunt session time for Morning Hunt.
function ActivityBoostActivities.noteHuntProgress(player, session)
	if not player or not session then
		return
	end
	if session.kind == "raid" or session.kind == "soulpit" or session.kind == "worldboss" then
		return
	end
	local contentRole = session.role or (session.catalog and session.catalog.role)
	if contentRole == "boss" then
		return
	end
	local started = tonumber(session.startedAt) or 0
	if started <= 0 then
		return
	end
	local elapsed = os.time() - started
	local need = ActivityBoostConfig.MORNING_HUNT_SEC or (10 * 60)
	if elapsed >= need then
		ActivityBoostActivities.complete(player, "morning_hunt")
	end
end

function ActivityBoostActivities.onBossExpeditionVictory(player)
	ActivityBoostActivities.complete(player, "boss_slayer")
end

--- Task Board daily bounty claim (hooked from CrystalServer game.cpp).
function ActivityBoostActivities.onBountyTaskClaimed(player)
	ActivityBoostActivities.complete(player, "bounty_hunter")
end
