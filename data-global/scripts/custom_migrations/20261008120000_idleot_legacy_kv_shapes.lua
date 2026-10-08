-- IdleOT: rewrite player KV left in pre-release shapes so the read side only knows the
-- current ones. Idempotent: every step skips keys that are already in the new shape.
--   * Lobby: the old team keys go away; paid team bonuses become the parked bonuses the
--     player's lobby restores (rosters and listings are not carried over).
--   * Activity boost: banked lots lose their wall-clock expiry (expired ones are dropped);
--     the boolean-completion keys go away.
--   * Combat automation: `expedition_automation` moves to `combat_automation`; slots
--     without a bar group take their priority as the group (step 1).

local LOBBY_KEYS = {
	"account_team_members",
	"account_team_controller_guid",
	"account_squad_members",
	"account_team_bonuses",
	"social_team_listing",
}
local BOOST_DROPPED_KEYS = { "completed", "worldBossFragged", "soloBoss" }

--- Player guids that have the KV key `suffix` (player.<guid>.<suffix>).
local function guidsWithKey(suffix)
	local guids = {}
	local rows = db.storeQuery("SELECT `key_name` FROM `kv_store` WHERE `key_name` LIKE " .. db.escapeString("player.%." .. suffix))
	if rows then
		repeat
			local guid, rest = Result.getString(rows, "key_name"):match("^player%.(%d+)%.(.+)$")
			if guid and rest == suffix then
				guids[#guids + 1] = guid
			end
		until not Result.next(rows)
		Result.free(rows)
	end
	return guids
end

local function playerKv(guid)
	return KV.scoped("player"):scoped(guid)
end

local function decodeTable(raw)
	if type(raw) == "table" then
		return raw
	end
	local decoded = JsonParser.decode(raw)
	return type(decoded) == "table" and decoded or nil
end

local function migrateLobby()
	local seen, players = {}, 0
	for _, key in ipairs(LOBBY_KEYS) do
		for _, guid in ipairs(guidsWithKey(key)) do
			if not seen[guid] then
				seen[guid] = true
				players = players + 1
				local kv = playerKv(guid)
				local bonuses = decodeTable(kv:get("account_team_bonuses"))
				if LobbyBonus.hasActive(bonuses) and kv:get(LobbyConfig.KV_PARKED_BONUSES) == nil then
					kv:set(LobbyConfig.KV_PARKED_BONUSES, JsonParser.encode(LobbyBonus.normalize(bonuses)))
				end
				for _, legacyKey in ipairs(LOBBY_KEYS) do
					kv:remove(legacyKey)
				end
			end
		end
	end
	return players
end

local function migrateActivityBoost()
	local scope = ActivityBoostConfig.KV_SCOPE
	local now = os.time()
	local rewritten = 0
	for _, guid in ipairs(guidsWithKey(scope .. ".lots")) do
		local store = playerKv(guid):scoped(scope)
		local lots = decodeTable(store:get("lots")) or {}
		local kept, changed = {}, false
		for _, lot in ipairs(lots) do
			local seconds = math.floor(tonumber(lot.seconds) or 0)
			local expiresAt = tonumber(lot.expiresAt)
			if lot.expiresAt ~= nil then
				changed = true
			end
			if seconds > 0 and (not expiresAt or expiresAt <= 0 or expiresAt > now) then
				kept[#kept + 1] = { seconds = seconds }
			else
				changed = true
			end
		end
		if changed then
			store:set("lots", JsonParser.encode(kept))
			rewritten = rewritten + 1
		end
	end
	for _, key in ipairs(BOOST_DROPPED_KEYS) do
		for _, guid in ipairs(guidsWithKey(scope .. "." .. key)) do
			playerKv(guid):scoped(scope):remove(key)
		end
	end
	return rewritten
end

--- Slots without a bar group: group = priority (else list index), step 1.
local function groupSlots(list)
	if type(list) ~= "table" then
		return false
	end
	local changed = false
	for index, slot in ipairs(list) do
		if type(slot) == "table" and (tonumber(slot.group) or 0) < 1 then
			slot.group = math.floor(tonumber(slot.priority) or index)
			slot.step = 1
			changed = true
		end
	end
	return changed
end

local function groupPresets(bank)
	if type(bank) ~= "table" or type(bank.presets) ~= "table" then
		return false
	end
	local changed = false
	for _, entries in pairs(bank.presets) do
		changed = groupSlots(entries) or changed
	end
	return changed
end

local function migrateCombatAutomation()
	local key, legacyKey = CombatAutomationConfig.KV_KEY, "expedition_automation"
	local moved, regrouped = 0, 0
	for _, guid in ipairs(guidsWithKey(legacyKey)) do
		local kv = playerKv(guid)
		local current = kv:get(key)
		if type(current) ~= "string" or current == "" then
			kv:set(key, kv:get(legacyKey))
			moved = moved + 1
		end
		kv:remove(legacyKey)
	end
	for _, guid in ipairs(guidsWithKey(key)) do
		local kv = playerKv(guid)
		local config = decodeTable(kv:get(key))
		if config then
			local loadout = type(config.loadout) == "table" and config.loadout or {}
			local changed = groupSlots(config.slots)
			changed = groupSlots(loadout.slots) or changed
			if config.slots == nil and config.loadout == nil then
				changed = groupSlots(config) or changed
			end
			changed = groupPresets(config.attackPresets or config.presets) or changed
			changed = groupPresets(loadout.attackPresets or loadout.presets) or changed
			if changed then
				kv:set(key, JsonParser.encode(config))
				regrouped = regrouped + 1
			end
		end
	end
	return moved, regrouped
end

local m = Migration("20261008120000_idleot_legacy_kv_shapes")
function m:onExecute()
	local lobbies = migrateLobby()
	local lots = migrateActivityBoost()
	local moved, regrouped = migrateCombatAutomation()
	logger.info(
		"idleot_legacy_kv_shapes: {} legacy team(s) parked, {} boost bank(s) rewritten, {} automation config(s) moved, {} regrouped",
		lobbies,
		lots,
		moved,
		regrouped
	)
	return true
end
m:register()
