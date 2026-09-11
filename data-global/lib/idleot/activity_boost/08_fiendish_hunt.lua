-- Daily Fiendish Hunt: roll a level-gated hunt, join with maxWaves=1 + forced Fiendish.
ActivityBoostFiendishHunt = ActivityBoostFiendishHunt or {}

local KV_KEY = "fiendishHunt"

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

local function fiendishHpMult()
	return tonumber(ActivityBoostConfig.FIENDISH_HP_MULT) or 3.6
end

--- Combat power of a creature as if it were Fiendish (HP × fiendish mult).
function ActivityBoostFiendishHunt.fiendishCombatPower(creatureIdOrInfo)
	local info = creatureIdOrInfo
	if type(creatureIdOrInfo) ~= "table" then
		info = CreatureInfo and CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(creatureIdOrInfo)
	end
	if type(info) ~= "table" then
		return 0
	end
	local baseCp = tonumber(info.combatPower) or 0
	local hp = tonumber(info.hp) or 0
	local expectedDps = tonumber(info.expectedDps) or 0
	if expectedDps > 0 and hp > 0 and CreatureInfo and CreatureInfo.computeCombatPower then
		local traits = {
			hp = hp * fiendishHpMult(),
			health = hp * fiendishHpMult(),
			expectedDps = expectedDps,
			expectedHealDps = tonumber(info.expectedHealDps) or 0,
			armor = tonumber(info.armor) or 0,
			defense = tonumber(info.defense) or 0,
			mitigation = tonumber(info.mitigation) or 0,
			meanElementPercent = tonumber(info.meanElementPercent) or 0,
			speed = tonumber(info.speed) or 0,
		}
		return tonumber(CreatureInfo.computeCombatPower(traits)) or 0
	end
	-- w.health default is 1 → CP scales with sqrt(hp).
	if baseCp > 0 then
		return baseCp * math.sqrt(fiendishHpMult())
	end
	return 0
end

function ActivityBoostFiendishHunt.fiendishRecommendedLevel(creatureIdOrInfo)
	local cp = ActivityBoostFiendishHunt.fiendishCombatPower(creatureIdOrInfo)
	if cp <= 0 then
		return 1
	end
	if CreatureInfo and CreatureInfo.levelsFromCombatPower then
		local levels = CreatureInfo.levelsFromCombatPower(cp, true)
		return tonumber(levels and levels.recommendedLevel) or 1
	end
	return 1
end

local function creatureNameForId(creatureId)
	local info = CreatureInfo and CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(creatureId)
	if info and info.name then
		return tostring(info.name)
	end
	return "Fiendish creature"
end

local function eligibleCreaturesForHunt(hunt, playerLevel)
	local out = {}
	local creatures = hunt and hunt.creatures or {}
	for _, row in ipairs(creatures) do
		local creatureId = tonumber(row.creatureId) or tonumber(row.raceId)
		if creatureId and creatureId > 0 then
			local info = CreatureInfo and CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(creatureId)
			if info and not info.isBoss then
				local rec = ActivityBoostFiendishHunt.fiendishRecommendedLevel(info)
				if rec <= playerLevel then
					out[#out + 1] = {
						creatureId = creatureId,
						name = creatureNameForId(creatureId),
						recommendedLevel = rec,
						percent = tonumber(row.percent) or 0,
					}
				end
			end
		end
	end
	-- Fallback: primary creatureId on hunt row.
	if #out == 0 then
		local creatureId = tonumber(hunt.creatureId)
		if creatureId and creatureId > 0 then
			local info = CreatureInfo and CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(creatureId)
			if info and not info.isBoss then
				local rec = ActivityBoostFiendishHunt.fiendishRecommendedLevel(info)
				if rec <= playerLevel then
					out[#out + 1] = {
						creatureId = creatureId,
						name = creatureNameForId(creatureId),
						recommendedLevel = rec,
						percent = 100,
					}
				end
			end
		end
	end
	return out
end

local function buildEligibleOffers(player)
	local catalog = ExpeditionConfig and ExpeditionConfig.Catalog or {}
	local level = player:getLevel()
	local offers = {}
	for _, entry in ipairs(catalog) do
		local role = entry.role or (entry.kind == "boss" and "boss" or "monster")
		if role == "monster" and not entry.exclusiveArena and not entry.exclusiveKitno and not entry.soulPit then
			-- Must be joinable at the player's level (catalog gate used by ExpeditionManager.join).
			local huntLevelMin = tonumber(entry.levelMin) or 1
			if huntLevelMin <= level then
				local creatures = eligibleCreaturesForHunt(entry, level)
				if #creatures > 0 then
					-- Prefer higher-percent spawns for the Fiendish pick.
					table.sort(creatures, function(a, b)
						if a.percent ~= b.percent then
							return a.percent > b.percent
						end
						return a.creatureId < b.creatureId
					end)
					offers[#offers + 1] = {
						hunt = entry,
						creatures = creatures,
					}
				end
			end
		end
	end
	return offers
end

local function offerStillValid(player, data)
	if type(data) ~= "table" or not data.expeditionId then
		return false
	end
	local level = player:getLevel()
	local hunt = nil
	if ExpeditionConfig and ExpeditionConfig.getById then
		hunt = ExpeditionConfig.getById(data.expeditionId, "monster")
	end
	if not hunt then
		return false
	end
	if (tonumber(hunt.levelMin) or 1) > level then
		return false
	end
	local creatureId = tonumber(data.creatureId)
	if not creatureId or creatureId <= 0 then
		return false
	end
	local rec = ActivityBoostFiendishHunt.fiendishRecommendedLevel(creatureId)
	if rec > level then
		return false
	end
	return true
end

local function pickOffer(player)
	local pool = buildEligibleOffers(player)
	if #pool == 0 then
		return nil
	end
	local pick = pool[math.random(1, #pool)]
	local creature = pick.creatures[math.random(1, math.min(3, #pick.creatures))]
	local hunt = pick.hunt
	return {
		expeditionId = hunt.id,
		huntName = hunt.name,
		creatureId = creature.creatureId,
		creatureName = creature.name,
	}
end

local function save(player, data)
	local store = kv(player)
	if store then
		if data then
			store:set(KV_KEY, encode(data))
		else
			store:remove(KV_KEY)
		end
	end
end

function ActivityBoostFiendishHunt.resetForNewDay(player)
	local store = kv(player)
	if store then
		store:remove(KV_KEY)
	end
end

function ActivityBoostFiendishHunt.get(player)
	local store = kv(player)
	if not store then
		return nil
	end
	if ActivityBoostActivities and ActivityBoostActivities.isComplete
		and ActivityBoostActivities.isComplete(player, "fiendish_hunt") then
		local data = decode(store:get(KV_KEY) or "")
		if type(data) == "table" and data.expeditionId then
			data.complete = true
			return data
		end
		return { complete = true }
	end
	local data = decode(store:get(KV_KEY) or "")
	if type(data) ~= "table" or not data.expeditionId or not offerStillValid(player, data) then
		data = pickOffer(player)
		if data then
			save(player, data)
		else
			save(player, nil)
		end
	end
	return data
end

function ActivityBoostFiendishHunt.reroll(player)
	local data = pickOffer(player)
	save(player, data)
	return data
end

function ActivityBoostFiendishHunt.canJoin(player)
	if not player then
		return false, "Invalid player."
	end
	if ActivityBoostActivities and ActivityBoostActivities.isComplete
		and ActivityBoostActivities.isComplete(player, "fiendish_hunt") then
		return false, "Fiendish Hunt already completed today."
	end
	local data = ActivityBoostFiendishHunt.get(player)
	if not data or not data.expeditionId then
		return false, "No Fiendish Hunt available for your level."
	end
	return true, data
end

function ActivityBoostFiendishHunt.join(player)
	local can, dataOrErr = ActivityBoostFiendishHunt.canJoin(player)
	if not can then
		return false, dataOrErr
	end
	local data = dataOrErr
	if not ExpeditionManager or not ExpeditionManager.join then
		return false, "Expeditions unavailable."
	end
	-- Options (maxWaves / forceFiendish / lure) are injected in ExpeditionManager.join
	-- when the catalog id matches today's offer.
	ExpeditionManager.join(player, data.expeditionId, "monster")
	local session = ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	local catalogId = session and session.catalog and session.catalog.id
	if not session or tostring(catalogId) ~= tostring(data.expeditionId) or not session.forceFiendishCreatureId then
		return false, "Could not start Fiendish Hunt."
	end
	return true, data
end

--- Called when a maxWaves-limited hunt finishes (per member).
function ActivityBoostFiendishHunt.onClear(player, session)
	if not player then
		return
	end
	local data = ActivityBoostFiendishHunt.get(player)
	local catalogId = session and session.catalog and session.catalog.id
	if data and catalogId and tostring(data.expeditionId) ~= tostring(catalogId) then
		-- Not today's Fiendish offer (generic maxWaves hunt).
		return
	end
	if not data or not data.expeditionId then
		return
	end
	-- Only the forced-Fiendish sessions from this activity.
	if not (session and session.forceFiendishCreatureId and session.skipOpenWorldForge) then
		return
	end
	if ActivityBoostActivities and ActivityBoostActivities.addProgress then
		ActivityBoostActivities.addProgress(player, "fiendish_hunt", 1)
	end
	if ActivityBoostActivities and ActivityBoostActivities.isComplete
		and ActivityBoostActivities.isComplete(player, "fiendish_hunt") then
		save(player, nil)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Fiendish Hunt: daily goal reached.")
		return
	end
	local nextOffer = ActivityBoostFiendishHunt.reroll(player)
	if nextOffer then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"Fiendish Hunt cleared! Next: %s (%s).",
				nextOffer.huntName or "hunt",
				nextOffer.creatureName or "Fiendish"
			)
		)
	else
		save(player, nil)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Fiendish Hunt cleared!")
	end
	-- addProgress already sendState; reroll needs a fresh push of the next offer.
	if ActivityBoostProtocol and ActivityBoostProtocol.sendState then
		ActivityBoostProtocol.sendState(player)
	end
end
