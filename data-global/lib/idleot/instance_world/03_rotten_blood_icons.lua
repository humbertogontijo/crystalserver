-- Instance-hunt rotten blood icons (Darklight Core, Putrefactory, etc.).
--
-- Upstream monster_onthink_area_icons.lua gates white-cross / hazard stacks on fixed
-- world rectangles (x <= 33941). Expedition hunts use the same map tiles but often sit
-- outside those boxes (e.g. Darklight Core center x=34102), so open-world area checks
-- never fire. Private instances apply the same icon mechanics to players near rotten-blood
-- monsters without changing open-world quest behavior.

RottenBloodInstanceIcons = RottenBloodInstanceIcons or {}

local partyTaintCache = setmetatable({}, { __mode = "v" })
local processedPlayers = setmetatable({}, { __mode = "k" })
local lastMonsterThink = setmetatable({}, { __mode = "k" })
local lastCacheReset = os.time()
local KV_SCOPE = "rotten-blood-area-icons"

local function getPartyMinTaintLevel(player)
	local party = player:getParty()
	if not party then
		local kv = player:kv():scoped("rotten-blood-quest")
		local currentTaintKV = kv:get("taints") or 0
		local currentTaintCondition = 0
		local taintCondition = player:getCondition(CONDITION_BAKRAGORE, CONDITIONID_DEFAULT)
		if taintCondition then
			currentTaintCondition = taintCondition:getParameter(CONDITION_PARAM_SUBID) or 0
		end
		return math.max(currentTaintKV, currentTaintCondition)
	end

	local leader = party:getLeader()
	if not leader then
		return 0
	end

	local leaderId = leader:getId()
	local currentTime = os.time()

	if partyTaintCache[leaderId] and currentTime - partyTaintCache[leaderId].timestamp < 10 then
		return partyTaintCache[leaderId].minTaint
	end

	local members = party:getMembers()
	local minTaint = 9999

	local kv = leader:kv():scoped("rotten-blood-quest")
	local leaderTaint = kv:get("taints") or 0
	local taintCondition = leader:getCondition(CONDITION_BAKRAGORE, CONDITIONID_DEFAULT)
	if taintCondition then
		leaderTaint = math.max(leaderTaint, taintCondition:getParameter(CONDITION_PARAM_SUBID) or 0)
	end
	minTaint = math.min(minTaint, leaderTaint)

	for _, member in ipairs(members) do
		if member and member:isPlayer() then
			local memberKv = member:kv():scoped("rotten-blood-quest")
			local memberTaint = memberKv:get("taints") or 0
			local memberCondition = member:getCondition(CONDITION_BAKRAGORE, CONDITIONID_DEFAULT)
			if memberCondition then
				memberTaint = math.max(memberTaint, memberCondition:getParameter(CONDITION_PARAM_SUBID) or 0)
			end
			minTaint = math.min(minTaint, memberTaint)
		end
	end

	if minTaint == 9999 then
		minTaint = 0
	end

	partyTaintCache[leaderId] = {
		minTaint = minTaint,
		timestamp = currentTime,
	}

	return minTaint
end

local function updateHazardIcon(player)
	local taintLevel = getPartyMinTaintLevel(player)

	if taintLevel > 0 then
		local iconLevel = 0
		if taintLevel >= 1 and taintLevel <= 4 then
			iconLevel = taintLevel
		elseif taintLevel == 5 then
			iconLevel = 0
		elseif taintLevel >= 6 and taintLevel <= 9 then
			iconLevel = taintLevel - 5
		end

		if iconLevel > 0 then
			player:setIcon("rotten-hazard", CreatureIconCategory_Quests, CreatureIconQuests_Hazard, iconLevel)
		else
			player:removeIcon("rotten-hazard")
		end
	else
		player:removeIcon("rotten-hazard")
	end
end

local function handleLowerLeftIcon(player)
	local currentTime = os.time()
	local kv = player:kv():scoped(KV_SCOPE)
	local lastUpdate = kv:get("lastLowerLeftUpdate") or 0

	if currentTime - lastUpdate >= 1 then
		local currentIcon = player:getIcon("white-cross")
		if not currentIcon or currentIcon.category ~= CreatureIconCategory_Quests or currentIcon.icon ~= CreatureIconQuests_RedCross then
			player:setIcon("white-cross", CreatureIconCategory_Quests, CreatureIconQuests_RedCross, 1)
		else
			local newCount = math.min(currentIcon.count + 1, 111)
			player:setIcon("white-cross", CreatureIconCategory_Quests, CreatureIconQuests_RedCross, newCount)

			if newCount >= 111 then
				local damage = math.random(1300, 1500)
				player:setIcon("white-cross", CreatureIconCategory_Quests, CreatureIconQuests_RedCross, 0)

				if player:getHealth() > 0 then
					doTargetCombatHealth(0, player, COMBAT_ENERGYDAMAGE, -damage, -damage, CONST_ME_ENERGYHIT)
				end
			end
		end
		kv:set("lastLowerLeftUpdate", currentTime)
	end
end

local function processPlayerInInstance(player)
	if processedPlayers[player] then
		return
	end
	processedPlayers[player] = true

	local currentTime = os.time()
	local kv = player:kv():scoped(KV_SCOPE)

	local lastHazardUpdate = kv:get("lastHazardUpdate") or 0
	if currentTime - lastHazardUpdate >= 8 then
		updateHazardIcon(player)
		kv:set("lastHazardUpdate", currentTime)
	end

	-- Expedition hunts on rotten-blood monsters: always stack white-cross while nearby.
	handleLowerLeftIcon(player)
end

function RottenBloodInstanceIcons.onMonsterThink(monster)
	if not monster or not monster.isMonster or not monster:isMonster() then
		return
	end

	local currentTime = os.time()
	if currentTime - lastCacheReset >= 1 then
		processedPlayers = setmetatable({}, { __mode = "k" })
		lastMonsterThink = setmetatable({}, { __mode = "k" })
		lastCacheReset = currentTime
	end

	-- At most one spectator scan per monster per second (icons tick on 1s cadence).
	if lastMonsterThink[monster] == currentTime then
		return
	end
	lastMonsterThink[monster] = currentTime

	-- Engine Spectators with creature instanceId (Creature:getPlayersInRange).
	local spectators
	if monster.getPlayersInRange then
		spectators = monster:getPlayersInRange(15)
	else
		local monsterPos = monster:getPosition()
		if not monsterPos then
			return
		end
		local instanceId = monster.getInstanceId and monster:getInstanceId() or nil
		if instanceId ~= nil then
			spectators = Game.getSpectators(monsterPos, false, true, 15, 15, 15, 15, instanceId)
		else
			spectators = Game.getSpectators(monsterPos, false, true, 15, 15, 15, 15)
		end
	end

	for _, player in ipairs(spectators or {}) do
		if player and player:isPlayer() then
			processPlayerInInstance(player)
		end
	end
end
