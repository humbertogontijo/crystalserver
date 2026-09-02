ExpeditionAI = ExpeditionAI or {}

-- Walk-queue dedupe (shared by enablePersistence + pathing helpers).
local lastQueuedWalkById = {}

local function clearQueuedWalk(creature)
	if creature then
		lastQueuedWalkById[creature:getId()] = nil
	end
end

local function memberIds(session)
	if ExpeditionManager and ExpeditionManager.sessionMemberIds then
		return ExpeditionManager.sessionMemberIds(session)
	end
	if session and session.playerId then
		return { session.playerId }
	end
	return {}
end

local function automationFor(session, player)
	if not player or not session then
		return nil
	end
	local id = player:getId()
	if session.memberAutomation and session.memberAutomation[id] then
		return session.memberAutomation[id]
	end
	-- Host-compat field only when this player is the session host.
	if id == session.playerId then
		return session.automation
	end
	return nil
end

local function stanceFor(session, player)
	if not player then
		return "melee"
	end
	local id = player:getId()
	if session and session.memberStance and session.memberStance[id] then
		return session.memberStance[id]
	end
	local auto = automationFor(session, player)
	if auto and auto.autoTarget and auto.autoTarget.stance then
		return auto.autoTarget.stance
	end
	if CombatAutomationStore and CombatAutomationStore.getConfig then
		local config = CombatAutomationStore.getConfig(player)
		if config and config.autoTarget and config.autoTarget.stance then
			return config.autoTarget.stance
		end
	end
	if ExpeditionConfig and ExpeditionConfig.stanceForPlayer then
		return ExpeditionConfig.stanceForPlayer(player)
	end
	if session and session.stance then
		return session.stance
	end
	return "melee"
end

local function rangedDistanceFor(session, player)
	if not player then
		return (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4
	end
	local id = player:getId()
	if session and session.memberRangedDistance and session.memberRangedDistance[id] then
		local n = tonumber(session.memberRangedDistance[id])
		if n == 3 or n == 4 then
			return n
		end
	end
	local auto = automationFor(session, player)
	if auto and auto.autoTarget and auto.autoTarget.rangedDistance then
		local n = tonumber(auto.autoTarget.rangedDistance)
		if n == 3 or n == 4 then
			return n
		end
	end
	if CombatAutomationStore and CombatAutomationStore.getConfig then
		local config = CombatAutomationStore.getConfig(player)
		local n = config and config.autoTarget and tonumber(config.autoTarget.rangedDistance)
		if n == 3 or n == 4 then
			return n
		end
	end
	return (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4
end

--- Chebyshev hold distance for this member (mages may use ranged 4 or 3 from automation).
local function stanceDistance(session, player)
	local role = stanceFor(session, player)
	if ExpeditionConfig and ExpeditionConfig.stanceDistanceFor then
		return ExpeditionConfig.stanceDistanceFor(role, role == "ranged" and rangedDistanceFor(session, player) or nil)
	end
	local map = ExpeditionConfig.STANCE_DISTANCE or ExpeditionConfig.BOSS_STANCE_DISTANCE or {}
	if role == "ranged" then
		return rangedDistanceFor(session, player)
	end
	return map[role] or 1
end

local function syncAttackTarget(session, player, target, force)
	if not session or not player then
		return
	end
	local creatureId = 0
	if target then
		creatureId = target:getId()
	end
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	local pid = player:getId()
	if not force and session.lastSyncedAttackByPlayer[pid] == creatureId then
		return
	end
	session.lastSyncedAttackByPlayer[pid] = creatureId
	-- Compat for older single-player code paths.
	session.lastSyncedAttackCreatureId = creatureId
	ExpeditionProtocol.sendAttackTarget(player, creatureId)
end

--- Force client red-square sync after reconnect (dedupe would otherwise skip).
function ExpeditionAI.resyncAttackTarget(session, player)
	if not session or not player then
		return
	end
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	session.lastSyncedAttackByPlayer[player:getId()] = nil
	session.lastSyncedAttackCreatureId = nil
	syncAttackTarget(session, player, player:getTarget(), true)
end

--- Sync client red square when the server attack target changes (AI or player).
function ExpeditionAI.syncAttackTargetIfChanged(session, player)
	if not session or not player then
		return
	end
	local target = player:getTarget()
	local creatureId = 0
	if target then
		creatureId = target:getId()
	end
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	local pid = player:getId()
	if session.lastSyncedAttackByPlayer[pid] == creatureId then
		return
	end
	syncAttackTarget(session, player, target)
end

-- Idle combat keeps disconnect combat alive; INFIGHT blocks ping-timeout logout.
-- Mid-hunt the client never owns WASD/map: idle combat stays on. Use-with / use from
-- afar approaches via forcePlayerAutoWalk (server path only). AUTO only gates AI
-- attack + creature-chase — it does not unlock free client locomotion.
function ExpeditionAI.enablePersistence(player)
	if not player then
		return
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session and session.state == "ended" then
			return
		end
	end
	-- Idle combat cancels client walk/target; GOD walks the instance freely.
	if PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
		if player.isIdleCombat and player:isIdleCombat() then
			player:setIdleCombat(false)
		end
		return
	end
	if not player:isIdleCombat() then
		player:setIdleCombat(true)
	end
	-- Drop stock IP==0 combat-protection so companions take monster damage in-hunt.
	if player.kv then
		player:kv():remove("combat-protection")
	end
	local condition = Condition(CONDITION_INFIGHT)
	condition:setParameter(CONDITION_PARAM_TICKS, 60000)
	player:addCondition(condition)
end

--- AUTO off→on: drop deferred use-with walkTask + walk dedupe so stance/follow can resume.
--- (Attack resumes via setTarget; positioning stays stuck while hasWalkTask / stale dedupe.)
function ExpeditionAI.onAutoResumed(player)
	if not player then
		return
	end
	clearQueuedWalk(player)
	-- Inline clear-follow (clearFollowIfAny is defined later in this chunk).
	if player.getFollowCreature and player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
	-- setIdleCombat(true) only clears walkTask on false→true; bounce if already idle.
	if player.setIdleCombat then
		if player:isIdleCombat() then
			player:setIdleCombat(false)
		end
		player:setIdleCombat(true)
	elseif player.stopWalk then
		player:stopWalk()
	end
	ExpeditionAI.enablePersistence(player)
end

--- Living monsters tagged with this expedition's private instance id.
--- (Hunt instances no longer create a Zone; do not use zone:getMonsters().)
local function livingInstanceMonsters(session, player)
	local result = {}
	local instance = session and session.instance
	local instanceId = instance and instance.instanceId
	if not instanceId or not Game.getMonsters then
		return result
	end
	for _, monster in ipairs(Game.getMonsters()) do
		if monster and monster:getHealth() > 0 and monster.getInstanceId and monster:getInstanceId() == instanceId then
			if player and CombatAutomation and CombatAutomation.isValidAttackTarget then
				if CombatAutomation.isValidAttackTarget(player, monster) then
					result[#result + 1] = monster
				end
			else
				result[#result + 1] = monster
			end
		end
	end
	return result
end

--- Prefer monsters already in weapon shootRange (Monster::searchTarget / canUseAttack analog).
--- Always nearest-first; attack-order sortMode was removed.
--- If the player already has a valid target (manual click or prior auto pick), keep it -
--- automation only takes the wheel again once they have no target.
local function pickAutoTargetMonster(player, session)
	local monsters = livingInstanceMonsters(session, player)
	local current = player and player:getTarget() or nil
	if current then
		if CombatAutomation and CombatAutomation.isValidAttackTarget then
			if CombatAutomation.isValidAttackTarget(player, current) then
				return current
			end
		elseif current:getHealth() > 0 then
			return current
		end
	end
	if CombatAutomation and CombatAutomation.pickMonsterBySort then
		return CombatAutomation.pickMonsterBySort(player, monsters)
	end
	return nil
end

local CARDINAL_DIRS = {
	{ x = 0, y = -1 }, -- north
	{ x = 0, y = 1 }, -- south
	{ x = -1, y = 0 }, -- west
	{ x = 1, y = 0 }, -- east
}

local function posKey(pos)
	if not pos then
		return nil
	end
	return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
end

local function isCardinalAtDistance(ppos, fpos, d)
	if not ppos or not fpos or ppos.z ~= fpos.z then
		return false
	end
	local dx = math.abs(ppos.x - fpos.x)
	local dy = math.abs(ppos.y - fpos.y)
	return (dx == 0 and dy == d) or (dy == 0 and dx == d)
end

--- True when another creature shares the tile (blocks formation / spawn exclusivity).
local function tileHasOtherCreature(pos, player)
	local tile = Tile(pos)
	if not tile then
		return true
	end
	local instanceId = player and player.getInstanceId and player:getInstanceId() or nil
	local creatures = tile.getCreatures and tile:getCreatures() or nil
	if type(creatures) == "table" then
		for _, creature in ipairs(creatures) do
			if creature and (not player or creature:getId() ~= player:getId()) then
				if not instanceId or not creature.getInstanceId or creature:getInstanceId() == instanceId then
					return true
				end
			end
		end
		return false
	end
	local top = tile:getTopCreature()
	if not top or (player and top:getId() == player:getId()) then
		return false
	end
	return not instanceId or not top.getInstanceId or top:getInstanceId() == instanceId
end

local function isWalkableGround(pos, instanceId)
	local tile = Tile(pos)
	if not tile or not tile:getGround() then
		return false
	end
	if instanceId and tile.hasProperty and CONST_PROP_BLOCKSOLID then
		return not tile:hasProperty(CONST_PROP_BLOCKSOLID, instanceId)
	end
	return not tile:hasFlag(TILESTATE_BLOCKSOLID)
end

local function isTileExclusiveForPlayer(pos, player, reserved)
	if not pos or not isWalkableGround(pos, player and player.getInstanceId and player:getInstanceId()) then
		return false
	end
	local key = posKey(pos)
	if reserved and key and reserved[key] then
		return false
	end
	if tileHasOtherCreature(pos, player) then
		return false
	end
	return true
end

local function reservePos(reserved, pos)
	if reserved and pos then
		local key = posKey(pos)
		if key then
			reserved[key] = true
		end
	end
end

local function unreservePos(reserved, pos)
	if reserved and pos then
		local key = posKey(pos)
		if key then
			reserved[key] = nil
		end
	end
end

local function isOnFocusTile(ppos, focusPos)
	return ppos and focusPos and ppos.x == focusPos.x and ppos.y == focusPos.y and ppos.z == focusPos.z
end

local NEIGHBOR_OFFSETS = {
	{ x = 0, y = -1 },
	{ x = 0, y = 1 },
	{ x = -1, y = 0 },
	{ x = 1, y = 0 },
	{ x = -1, y = -1 },
	{ x = 1, y = -1 },
	{ x = -1, y = 1 },
	{ x = 1, y = 1 },
}

--- Cardinal facing from `fromPos` toward `toPos` (formation is axis-aligned).
local function directionToward(fromPos, toPos)
	if not fromPos or not toPos then
		return nil
	end
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if dx == 0 and dy == 0 then
		return nil
	end
	if math.abs(dx) > math.abs(dy) then
		return dx > 0 and DIRECTION_EAST or DIRECTION_WEST
	end
	if dy ~= 0 then
		return dy > 0 and DIRECTION_SOUTH or DIRECTION_NORTH
	end
	return dx > 0 and DIRECTION_EAST or DIRECTION_WEST
end

local function faceToward(creature, targetPos)
	if not creature or not targetPos then
		return
	end
	local dir = directionToward(creature:getPosition(), targetPos)
	if dir == nil then
		return
	end
	if creature:getDirection() ~= dir then
		creature:setDirection(dir)
	end
end

local function nowMs()
	if type(systemTime) == "function" then
		return math.floor(systemTime())
	end
	return math.floor(os.time() * 1000)
end

-- ---------------------------------------------------------------------------
-- Locomotion: Creature:getPathTo + Creature:autoWalk only (Monster::walkTo analog).
-- Anchor always ignores creatures (FLAG_IGNOREBLOCKCREATURE + thin BFS) so a
-- blocked corridor cannot soft-lock the hold walk. Companions ignore creatures
-- only while trailing the anchor during relocate; once the anchor stands on the
-- hold they form on exclusive tiles (no stacking).
-- ---------------------------------------------------------------------------
local PATH_CARDINALS = {
	{ dir = 0, dx = 0, dy = -1 },
	{ dir = 1, dx = 1, dy = 0 },
	{ dir = 2, dx = 0, dy = 1 },
	{ dir = 3, dx = -1, dy = 0 },
}

local function canPathIgnoreCreatures(creature, pos)
	if not pos then
		return false
	end
	local tile = Tile(pos)
	if not tile or not tile:getGround() then
		return false
	end
	if tile.queryAdd and creature then
		local flags = FLAG_IGNOREBLOCKCREATURE or 0
		if FLAG_PATHFINDING then
			flags = bit.bor(flags, FLAG_PATHFINDING)
		end
		local q = tile:queryAdd(creature, flags)
		return q == RETURNVALUE_NOERROR or q == 0
	end
	local instanceId = creature.getInstanceId and creature:getInstanceId() or nil
	return isWalkableGround(pos, instanceId)
end

--- Cardinal BFS ignoring creatures. Anchor-only (hold / trapped corridors).
local function buildPathIgnoreCreatures(creature, dest, maxNodes)
	if not creature or not dest then
		return nil
	end
	local start = creature:getPosition()
	if not start or start.z ~= dest.z then
		return nil
	end
	if start.x == dest.x and start.y == dest.y then
		return {}
	end
	maxNodes = math.max(64, math.floor(tonumber(maxNodes) or 2048))

	local function key(x, y)
		return x * 65536 + y
	end

	local parentDir = {}
	local parentKey = {}
	local sk = key(start.x, start.y)
	parentDir[sk] = false
	local queue = { { x = start.x, y = start.y } }
	local qh = 1
	local nodes = 0
	local goalKey = key(dest.x, dest.y)

	while queue[qh] and nodes < maxNodes do
		local cur = queue[qh]
		qh = qh + 1
		nodes = nodes + 1
		local ck = key(cur.x, cur.y)

		if ck == goalKey then
			local dirs = {}
			local walk = ck
			while walk and walk ~= sk do
				local dir = parentDir[walk]
				if dir == nil or dir == false then
					return nil
				end
				dirs[#dirs + 1] = dir
				walk = parentKey[walk]
			end
			local out = {}
			for i = #dirs, 1, -1 do
				out[#out + 1] = dirs[i]
			end
			return out
		end

		for _, step in ipairs(PATH_CARDINALS) do
			local nx, ny = cur.x + step.dx, cur.y + step.dy
			local nk = key(nx, ny)
			if parentDir[nk] == nil then
				local npos = Position(nx, ny, start.z)
				local ok = (nx == dest.x and ny == dest.y) or canPathIgnoreCreatures(creature, npos)
				if ok then
					parentDir[nk] = step.dir
					parentKey[nk] = ck
					queue[#queue + 1] = { x = nx, y = ny }
				else
					parentDir[nk] = false
				end
			end
		end
	end
	return nil
end

-- getPathTo returns dest→start; autoWalk expects start→end (then reverses).
local function dirsForAutoWalkFromGetPathTo(path)
	if type(path) ~= "table" or #path == 0 then
		return nil
	end
	local out = {}
	for i = #path, 1, -1 do
		out[#out + 1] = path[i]
	end
	return out
end

local function walkDestKey(pos)
	if not pos then
		return nil
	end
	return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
end

--- Queue a full path via Creature:autoWalk. `force` skips the in-flight dedupe (stall repath).
local function queueWalkToward(creature, dest, ignoreCreatures, force)
	if not creature or not dest or not creature.autoWalk then
		return false
	end
	local ppos = creature:getPosition()
	if not ppos then
		return false
	end
	if ppos.x == dest.x and ppos.y == dest.y and ppos.z == dest.z then
		clearQueuedWalk(creature)
		return true
	end
	local id = creature:getId()
	local key = walkDestKey(dest)
	local prev = lastQueuedWalkById[id]
	local now = nowMs()
	local pkey = posKey(ppos)
	if not force and prev and prev.key == key and prev.ignore == (ignoreCreatures and true or false) then
		local stuckMs = tonumber(ExpeditionConfig.FORMATION_REPATH_MS) or 400
		local stuck = prev.posKey and prev.posKey == pkey and (now - (prev.at or 0)) >= stuckMs
		if not stuck and (now - (prev.at or 0)) < 2500 then
			return true
		end
	end

	local path
	local flags = 0
	if ignoreCreatures then
		local maxSearch = tonumber(ExpeditionConfig.HOLD_PATH_MAX) or 128
		local budget = math.max(512, maxSearch * maxSearch)
		path = buildPathIgnoreCreatures(creature, dest, budget)
		if FLAG_IGNOREBLOCKCREATURE then
			flags = FLAG_IGNOREBLOCKCREATURE
		end
	else
		local maxSearch = tonumber(ExpeditionConfig.HOLD_PATH_MAX) or 128
		if maxSearch < 1 then
			maxSearch = 128
		end
		path = dirsForAutoWalkFromGetPathTo(creature:getPathTo(dest, 0, 0, true, false, maxSearch))
	end
	if type(path) ~= "table" or #path == 0 then
		return false
	end
	if creature:autoWalk(path, flags) == true then
		lastQueuedWalkById[id] = {
			key = key,
			ignore = ignoreCreatures and true or false,
			at = now,
			posKey = pkey,
		}
		return true
	end
	return false
end

--- Hold Chebyshev distance `d` from focus via getPathTo(min=d,max=d) + autoWalk.
local function holdStanceDistance(player, focus, session, d)
	local ppos = player:getPosition()
	local fpos = focus:getPosition()
	if ppos:getDistance(fpos) == d then
		clearQueuedWalk(player)
		return
	end

	local path = dirsForAutoWalkFromGetPathTo(player:getPathTo(fpos, d, d, true, false, 16))
	if type(path) == "table" and #path > 0 then
		local id = player:getId()
		local key = "ring:" .. walkDestKey(fpos) .. ":" .. tostring(d)
		local prev = lastQueuedWalkById[id]
		local now = nowMs()
		if prev and prev.key == key and (now - (prev.at or 0)) < 2500 then
			return
		end
		if player:autoWalk(path, 0) == true then
			lastQueuedWalkById[id] = { key = key, ignore = false, at = now }
			return
		end
	end

	local ring = ExpeditionInstance.randomAttackRangeWalkable(session.instance, fpos, d)
	if ring then
		queueWalkToward(player, ring, false)
	end
end

local function sortByPlayerDistance(list)
	table.sort(list, function(a, b)
		if a.dist ~= b.dist then
			return a.dist < b.dist
		end
		if a.pos.y ~= b.pos.y then
			return a.pos.y < b.pos.y
		end
		return a.pos.x < b.pos.x
	end)
	return list
end

local function collectCardinalCandidates(focusPos, d, player, reserved, ppos)
	local list = {}
	for _, dir in ipairs(CARDINAL_DIRS) do
		local pos = Position(focusPos.x + dir.x * d, focusPos.y + dir.y * d, focusPos.z)
		if isTileExclusiveForPlayer(pos, player, reserved) then
			list[#list + 1] = {
				pos = pos,
				dist = ppos:getDistance(pos),
			}
		end
	end
	return sortByPlayerDistance(list)
end

--- Any exclusive tile on the Chebyshev ring (diagonals included) - used when all
--- cardinal slots at this radius are taken or blocked.
local function collectRingExclusiveCandidates(focusPos, radius, player, reserved, ppos)
	local list = {}
	for dx = -radius, radius do
		for dy = -radius, radius do
			if math.max(math.abs(dx), math.abs(dy)) == radius then
				local pos = Position(focusPos.x + dx, focusPos.y + dy, focusPos.z)
				if isTileExclusiveForPlayer(pos, player, reserved) then
					list[#list + 1] = {
						pos = pos,
						dist = ppos:getDistance(pos),
					}
				end
			end
		end
	end
	return sortByPlayerDistance(list)
end

local function collectIdealCardinalsAtDistance(focusPos, d)
	local ideals = {}
	for _, dir in ipairs(CARDINAL_DIRS) do
		ideals[#ideals + 1] = Position(focusPos.x + dir.x * d, focusPos.y + dir.y * d, focusPos.z)
	end
	return ideals
end

local function minDistanceToIdeals(pos, ideals)
	local best = math.huge
	for _, ideal in ipairs(ideals) do
		local dist = pos:getDistance(ideal)
		if dist < best then
			best = dist
		end
	end
	return best
end

local function anchorDistanceMiss(pos, focusPos, d)
	return math.abs(pos:getDistance(focusPos) - d)
end

local function sortFormationCandidates(list, d, focusPos)
	table.sort(list, function(a, b)
		if a.idealDist ~= b.idealDist then
			return a.idealDist < b.idealDist
		end
		local aMiss = a.radiusMiss or anchorDistanceMiss(a.pos, focusPos, d)
		local bMiss = b.radiusMiss or anchorDistanceMiss(b.pos, focusPos, d)
		if aMiss ~= bMiss then
			return aMiss < bMiss
		end
		if a.dist ~= b.dist then
			return a.dist < b.dist
		end
		if a.pos.y ~= b.pos.y then
			return a.pos.y < b.pos.y
		end
		return a.pos.x < b.pos.x
	end)
	return list
end

--- Closest exclusive tiles around one ideal cardinal (blocked slot near-miss).
local function collectNearIdeal(idealPos, player, reserved, ppos, maxOffset)
	local list = {}
	maxOffset = math.max(1, math.floor(tonumber(maxOffset) or 6))
	for offset = 0, maxOffset do
		for dx = -offset, offset do
			for dy = -offset, offset do
				if math.max(math.abs(dx), math.abs(dy)) == offset then
					local pos = Position(idealPos.x + dx, idealPos.y + dy, idealPos.z)
					if isTileExclusiveForPlayer(pos, player, reserved) then
						list[#list + 1] = {
							pos = pos,
							idealDist = offset,
							dist = ppos:getDistance(pos),
						}
					end
				end
			end
		end
		if list[1] then
			break
		end
	end
	return list
end

--- Formation targets for stance distance `d`: exact cardinal, near blocked cardinal, ring at d, then outward only.
local function collectFormationCandidates(focusPos, d, player, reserved, ppos)
	local candidates = {}

	local exact = collectCardinalCandidates(focusPos, d, player, reserved, ppos)
	for _, entry in ipairs(exact) do
		candidates[#candidates + 1] = {
			pos = entry.pos,
			idealDist = 0,
			radiusMiss = 0,
			dist = entry.dist,
		}
	end
	if candidates[1] then
		return sortFormationCandidates(candidates, d, focusPos)
	end

	for _, ideal in ipairs(collectIdealCardinalsAtDistance(focusPos, d)) do
		local near = collectNearIdeal(ideal, player, reserved, ppos, 6)
		for _, entry in ipairs(near) do
			candidates[#candidates + 1] = {
				pos = entry.pos,
				idealDist = entry.idealDist,
				radiusMiss = anchorDistanceMiss(entry.pos, focusPos, d),
				dist = entry.dist,
			}
		end
	end

	local ring = collectRingExclusiveCandidates(focusPos, d, player, reserved, ppos)
	for _, entry in ipairs(ring) do
		if not isCardinalAtDistance(entry.pos, focusPos, d) then
			candidates[#candidates + 1] = {
				pos = entry.pos,
				idealDist = minDistanceToIdeals(entry.pos, collectIdealCardinalsAtDistance(focusPos, d)),
				radiusMiss = 0,
				dist = entry.dist,
			}
		end
	end
	if candidates[1] then
		return sortFormationCandidates(candidates, d, focusPos)
	end

	for extra = 1, 4 do
		local radius = d + extra
		local outerCardinals = collectCardinalCandidates(focusPos, radius, player, reserved, ppos)
		for _, entry in ipairs(outerCardinals) do
			candidates[#candidates + 1] = {
				pos = entry.pos,
				idealDist = minDistanceToIdeals(entry.pos, collectIdealCardinalsAtDistance(focusPos, d)),
				radiusMiss = extra,
				dist = entry.dist,
			}
		end
		for _, ideal in ipairs(collectIdealCardinalsAtDistance(focusPos, radius)) do
			local near = collectNearIdeal(ideal, player, reserved, ppos, 4)
			for _, entry in ipairs(near) do
				candidates[#candidates + 1] = {
					pos = entry.pos,
					idealDist = entry.idealDist + extra,
					radiusMiss = anchorDistanceMiss(entry.pos, focusPos, d),
					dist = entry.dist,
				}
			end
		end
		if candidates[1] then
			break
		end
	end

	return sortFormationCandidates(candidates, d, focusPos)
end

local function sameTile(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

--- True only when already standing on the best formation tile this tick.
--- Never treat "1 SQM shy of the ideal" as done - that left ranged/close one short
--- and made melee accept the anchor (distance 1 from every d=1 cardinal).
local function isSettledOnBestSlot(ppos, focusPos, d, player, best)
	if tileHasOtherCreature(ppos, player) then
		return false
	end
	-- Exact stance cardinal: always hold if alone (repath only when displaced).
	if isCardinalAtDistance(ppos, focusPos, d) then
		return true
	end
	-- Near-miss / ring fallback: only settle if we are on this tick's best candidate
	-- (best is exact when any exact cardinal is free, so we keep walking until then).
	return best ~= nil and sameTile(ppos, best)
end

--- Last resort: leave a stacked/focus tile via autoWalk toward stance distance.
local function tryStepOffStack(player, reserved, focusPos, d)
	local ppos = player:getPosition()
	local ideals = collectIdealCardinalsAtDistance(focusPos, d)
	local candidates = {}
	for _, off in ipairs(NEIGHBOR_OFFSETS) do
		local pos = Position(ppos.x + off.x, ppos.y + off.y, ppos.z)
		if isTileExclusiveForPlayer(pos, player, reserved) and not isOnFocusTile(pos, focusPos) then
			candidates[#candidates + 1] = {
				pos = pos,
				anchorDist = focusPos:getDistance(pos),
				idealDist = minDistanceToIdeals(pos, ideals),
				radiusMiss = anchorDistanceMiss(pos, focusPos, d),
			}
		end
	end
	table.sort(candidates, function(a, b)
		if a.idealDist ~= b.idealDist then
			return a.idealDist < b.idealDist
		end
		if a.radiusMiss ~= b.radiusMiss then
			return a.radiusMiss < b.radiusMiss
		end
		if a.anchorDist ~= b.anchorDist then
			return a.anchorDist > b.anchorDist
		end
		if a.pos.y ~= b.pos.y then
			return a.pos.y < b.pos.y
		end
		return a.pos.x < b.pos.x
	end)
	for _, entry in ipairs(candidates) do
		reservePos(reserved, entry.pos)
		if queueWalkToward(player, entry.pos) then
			return true
		end
		unreservePos(reserved, entry.pos)
	end
	return false
end

--- Claim a unique cardinal slot and autoWalk toward it.
--- Re-evaluated every AI tick so a push / displacement repaths automatically.
--- When the exact cardinal is blocked, fall back to the closest walkable tile
--- near that ideal slot - never settle one SQM short while the ideal is free.
local function holdCardinalDistance(player, focusPos, d, reserved)
	if not player or not focusPos then
		return
	end
	d = math.max(1, math.floor(tonumber(d) or 1))
	reserved = reserved or {}
	local ppos = player:getPosition()
	local currentKey = posKey(ppos)
	local stacked = tileHasOtherCreature(ppos, player)
	local onFocus = isOnFocusTile(ppos, focusPos)

	local function faceCombatOrFocus()
		local target = player:getTarget()
		if target and target.getPosition and target:getHealth() > 0 then
			faceToward(player, target:getPosition())
		else
			faceToward(player, focusPos)
		end
	end

	-- Always recompute the best slot each tick (handles push / creep / freed tiles).
	local candidates = collectFormationCandidates(focusPos, d, player, reserved, ppos)
	local bestPos = candidates[1] and candidates[1].pos or nil

	if isSettledOnBestSlot(ppos, focusPos, d, player, bestPos) then
		if not (currentKey and reserved[currentKey]) then
			reservePos(reserved, ppos)
		end
		lastQueuedWalkById[player:getId()] = nil
		faceCombatOrFocus()
		return
	end

	if not candidates[1] then
		if stacked or onFocus or not isCardinalAtDistance(ppos, focusPos, d) then
			tryStepOffStack(player, reserved, focusPos, d)
		end
		return
	end

	for _, entry in ipairs(candidates) do
		local dest = entry.pos
		if sameTile(ppos, dest) then
			if not (currentKey and reserved[currentKey]) then
				reservePos(reserved, dest)
			end
			lastQueuedWalkById[player:getId()] = nil
			faceCombatOrFocus()
			return
		end
		reservePos(reserved, dest)
		if queueWalkToward(player, dest) then
			return
		end
		unreservePos(reserved, dest)
	end

	-- Displaced / blocked path: still try to leave a bad tile.
	if stacked or onFocus or not isCardinalAtDistance(ppos, focusPos, d) then
		tryStepOffStack(player, reserved, focusPos, d)
	end
end

local function beginPositionReservations(anchor)
	local reserved = {}
	if anchor then
		reservePos(reserved, anchor:getPosition())
	end
	return reserved
end

local function playerAutoAttackEnabled(player)
	if not player or not CombatAutomationStore or not CombatAutomationStore.getConfig then
		return true
	end
	local config = CombatAutomationStore.getConfig(player)
	return config and config.autoTarget and config.autoTarget.enabled == true
end

local function setAttackTarget(session, player, target)
	-- AUTO off: do not acquire or keep an attack target (taming / manual control).
	if not playerAutoAttackEnabled(player) then
		if player:getTarget() then
			player:setTarget(nil)
		end
		syncAttackTarget(session, player, nil)
		return
	end
	local current = player:getTarget()
	-- Honor a live player target (manual click / client attack packet) even when this
	-- tick's auto-pick was computed before the packet landed.
	if current then
		local keepCurrent = false
		if CombatAutomation and CombatAutomation.isValidAttackTarget then
			keepCurrent = CombatAutomation.isValidAttackTarget(player, current)
		else
			keepCurrent = current:getHealth() > 0
		end
		if keepCurrent and (not target or current:getId() ~= target:getId()) then
			target = current
		end
	end

	current = player:getTarget()
	if current and target and current:getId() == target:getId() and current:getHealth() > 0 then
		faceToward(player, current:getPosition())
		syncAttackTarget(session, player, current)
		return
	end
	-- Switch directly - avoid setTarget(nil) first (CancelTarget clears the client
	-- red square; attack(0) echoes used to wipe the new target again).
	if not player:setTarget(target) then
		ExpeditionAI.enablePersistence(player)
		player:setTarget(target)
	end
	local resolved = player:getTarget() or target
	if resolved then
		faceToward(player, resolved:getPosition())
	end
	syncAttackTarget(session, player, resolved)
end

local function clearFollowIfAny(player)
	-- Player::onFollowCreature(nullptr) calls stopWalk(); never call setFollowCreature(nil)
	-- when already not following or we abort Creature:autoWalk every tick.
	if player and player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
end

-- Familiar-style catch-up: match anchor + soft lag-scaled surplus, teleport at 15 SQM.
-- Anchor walk fires EventCallback playerOnWalk → ExpeditionAI.onPlayerWalk (event-driven yank).
-- AI tick (250ms) re-runs the same logic for teleports / boost cleanup while the anchor stands.
local function clearCatchUpBoost(session, player)
	if not session or not player then
		return
	end
	local boosts = session._catchUpBoost
	if not boosts then
		return
	end
	local pid = player:getId()
	local prev = boosts[pid]
	if type(prev) == "number" and prev ~= 0 and player.changeSpeed then
		player:changeSpeed(-prev)
	end
	boosts[pid] = nil
end

local function clearAllCatchUpBoosts(session)
	if not session or type(session._catchUpBoost) ~= "table" then
		return
	end
	for pid, prev in pairs(session._catchUpBoost) do
		local player = Player(pid)
		if player and type(prev) == "number" and prev ~= 0 and player.changeSpeed then
			player:changeSpeed(-prev)
		end
	end
	session._catchUpBoost = nil
end

local function updateCatchUpSpeed(session, player, anchor)
	if not session or not player or not anchor then
		return
	end
	if player:getId() == anchor:getId() then
		clearCatchUpBoost(session, player)
		return
	end
	if PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
		clearCatchUpBoost(session, player)
		return
	end
	local ppos = player:getPosition()
	local apos = anchor:getPosition()
	if not ppos or not apos then
		return
	end

	local teleportAt = tonumber(ExpeditionConfig.CATCH_UP_TELEPORT_SQM) or 15
	-- Match Creature::checkSummonMove: different floor OR Chebyshev > teleportAt.
	local dist = (ppos.z ~= apos.z) and (teleportAt + 1) or ppos:getDistance(apos)

	-- Familiar: teleport onto master when out of range / different floor.
	if dist > teleportAt then
		clearCatchUpBoost(session, player)
		if player.teleportTo then
			player:teleportTo(apos)
			clearQueuedWalk(player)
		end
		return
	end

	if not player.changeSpeed or not player.getSpeed then
		return
	end

	session._catchUpBoost = session._catchUpBoost or {}
	local pid = player:getId()
	local prevBoost = session._catchUpBoost[pid] or 0
	local desiredBoost = 0
	local stance = stanceDistance(session, player)
	if dist > stance then
		local speedWithoutBoost = player:getSpeed() - prevBoost
		local matchGap = math.max(0, anchor:getSpeed() - speedWithoutBoost)
		-- Soft surplus: ease in with lag so near-stance drift is barely visible.
		local maxBonus = tonumber(ExpeditionConfig.CATCH_UP_SPEED_BONUS) or 60
		local lag = dist - stance
		local maxLag = math.max(1, teleportAt - stance)
		local t = math.min(1, lag / maxLag)
		local surplus = math.floor(maxBonus * t * t)
		desiredBoost = matchGap + surplus
	end
	local delta = desiredBoost - prevBoost
	if delta ~= 0 then
		player:changeSpeed(delta)
		session._catchUpBoost[pid] = desiredBoost ~= 0 and desiredBoost or nil
	end
end

local function tickCatchUp(session)
	if not session then
		return
	end
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	if kind == "raid" then
		return
	end
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if not anchor then
		return
	end
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
			updateCatchUpSpeed(session, player, anchor)
		end
	end
end

--- Called from EventCallback playerOnWalk when the expedition anchor steps (familiar-style).
function ExpeditionAI.onPlayerWalk(player)
	if not player or not ExpeditionConfig then
		return
	end
	-- Cheap reject for everyone not in an expedition (fires on every world walk).
	if player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) ~= 1 then
		return
	end
	if not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or session.state == "ended" then
		return
	end
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	if kind == "raid" then
		return
	end
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if not anchor or player:getId() ~= anchor:getId() then
		return
	end
	tickCatchUp(session)
end

--- Creature-distance stance (Chebyshev ring / follow) vs a focus creature.
--- AUTO off: clear follow / attack so the player is not yanked mid use-with approach;
--- idle combat still blocks free WASD — approach is forcePlayerAutoWalk + walkTask only.
local function applyCreatureStance(session, player, target)
	if not session or not player or not target then
		return
	end
	if not playerAutoAttackEnabled(player) then
		clearFollowIfAny(player)
		setAttackTarget(session, player, nil)
		return
	end
	local stance = stanceFor(session, player)
	if stance == "melee" then
		local follow = player:getFollowCreature()
		if not follow or follow:getId() ~= target:getId() then
			player:setFollowCreature(target)
		end
	else
		clearFollowIfAny(player)
		holdStanceDistance(player, target, session, stanceDistance(session, player))
	end
	setAttackTarget(session, player, target)
end

local function isAnchor(session, player)
	if not session or not player then
		return true
	end
	local anchorId = session.anchorPlayerId
	if not anchorId then
		return player:getId() == session.playerId
	end
	return player:getId() == anchorId
end

local function anchorAtHold(session)
	local hold = session and session.holdPos
	if not hold then
		return true
	end
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if not anchor then
		return false
	end
	local p = anchor:getPosition()
	return p and p.x == hold.x and p.y == hold.y and p.z == hold.z
end

--- Hunt/boss positioning:
--- - Healthy non-anchors: exclusive cardinal formation around the anchor (no monsters needed).
--- - Critical HP (below POSITION_CRITICAL_HP_PERCENT): creature-distance stance vs focus (AUTO on only).
--- - Anchor with a combat focus: creature stance (melee follow / ranged hold) vs that target (AUTO on only).
--- - Anchor with no focus (or relocating): walk to holdPos / stand. Monsters spawn near anchor.
--- Raids never call this - they always use creature stance (still gated on AUTO inside applyCreatureStance).
local function positionForHuntOrBoss(session, player, anchor, reserved, focusCreature)
	if not player then
		return
	end

	local autoOn = playerAutoAttackEnabled(player)
	local critical = ExpeditionConfig.isPositionCritical and ExpeditionConfig.isPositionCritical(player)
	local playerIsAnchor = isAnchor(session, player)

	if critical and autoOn then
		-- Low HP + AUTO on: fall back to creature-distance positioning when a focus exists.
		if focusCreature then
			applyCreatureStance(session, player, focusCreature)
			return
		end
		-- No combat focus yet - still form on anchor so we are not stacked.
	elseif critical and not autoOn then
		-- Low HP + AUTO off: do not chase/hold vs monsters (taming / manual control).
		clearFollowIfAny(player)
	end

	if playerIsAnchor then
		-- Follow/hold the attack target server-side (hunt and boss). Relocate keeps autoWalk to hold.
		if focusCreature and session.state ~= "relocating" and autoOn then
			applyCreatureStance(session, player, focusCreature)
		else
			-- Relocate walk is driven by ExpeditionAI.startRelocateWalk (engine autoWalk).
			-- Do NOT call setFollowCreature(nil) every tick - that clears listWalkDir and aborts autoWalk.
			if session.state ~= "relocating" then
				clearFollowIfAny(player)
				-- AUTO off: do not holdPos-yank (preserves force use-with approach via hasWalkTask).
				if autoOn then
					local hold = session.holdPos
					if hold and not sameTile(player:getPosition(), hold) then
						queueWalkToward(player, hold, true, true)
					end
				end
			else
				clearFollowIfAny(player)
			end
		end
		return
	end

	-- Non-anchor: during relocate, trail the anchor until it stands on the hold,
	-- then switch to formation immediately (driveCompanion in relocate loop).
	if session.state == "relocating" then
		if anchor and anchorAtHold(session) then
			clearFollowIfAny(player)
			holdCardinalDistance(player, anchor:getPosition(), stanceDistance(session, player), reserved)
		else
			clearFollowIfAny(player)
		end
		return
	end

	-- Non-anchor healthy (or critical with no focus): form on the anchor.
	-- hasWalkTask approach walks are preserved by Creature::startAutoWalk (non-forced).
	clearFollowIfAny(player)
	if anchor then
		local d = stanceDistance(session, player)
		-- Only ignore creatures while catching up; otherwise keep formation collision.
		holdCardinalDistance(player, anchor:getPosition(), d, reserved)
	end
end

local function tickHuntMember(session, player, anchor, reserved)
	local tile = Tile(player:getPosition())
	if not tile or not tile:getGround() then
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	-- Formation runs every state (waiting / relocating / idle / hunting), with or without monsters.
	-- Monsters keep engine targeting - no forced selectTarget on the anchor.
	local target = nil
	if session.state == "hunting" then
		target = pickAutoTargetMonster(player, session)
	end

	positionForHuntOrBoss(session, player, anchor, reserved, target)

	if session.state ~= "hunting" then
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	if target then
		-- Critical creature-stance already set the target; re-assert for all members so combat keeps up.
		setAttackTarget(session, player, target)
	else
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
	end
end

--- Shared raid: ALWAYS creature-distance stance (never anchor formation), even with companions.
local function tickRaid(session, player)
	if session.state == "waiting" or session.state == "idle" then
		clearFollowIfAny(player)
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	local tile = Tile(player:getPosition())
	if not tile or not tile:getGround() then
		clearFollowIfAny(player)
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	local focus = nil
	if RaidInstance and RaidInstance.getBoss and session.raidName then
		focus = RaidInstance.getBoss(session.raidName)
	end
	if not focus then
		focus = pickAutoTargetMonster(player, session)
	end
	if not focus then
		clearFollowIfAny(player)
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	applyCreatureStance(session, player, focus)
end

local function tickBossMember(session, player, anchor, reserved)
	local tile = Tile(player:getPosition())
	if not tile or not tile:getGround() then
		clearFollowIfAny(player)
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	local boss = ExpeditionBoss.getBoss(session)
	if not boss then
		boss = pickAutoTargetMonster(player, session)
	end

	-- Formation / stance regardless of boss presence (pre-spawn waiting included).
	positionForHuntOrBoss(session, player, anchor, reserved, boss)

	if not boss then
		player:setTarget(nil)
		syncAttackTarget(session, player, nil)
		return
	end

	-- Player attacks only; boss keeps engine targeting (spawn near party is enough).
	if not isAnchor(session, player) then
		-- Healthy non-anchor: formed on anchor above; keep attacking the boss.
		-- Critical non-anchor: creature stance already set target; re-assert.
		clearFollowIfAny(player)
		setAttackTarget(session, player, boss)
	end
end

local function applyAutoTargetLock(session, player)
	if not player or not CombatAutomationStore or not CombatAutomationStore.applyToRuntime then
		if player and CombatAutomation and CombatAutomation.refreshLoop then
			CombatAutomation.refreshLoop(player)
		end
		return
	end
	local config = CombatAutomationStore.getConfig(player)
	-- Do not copy session slots onto player config (that overwrites the player bar).
	-- Mirror the player's loadout into the session for lobby/stance only.
	if type(config.slots) == "table" and #config.slots > 0 then
		session.memberAutomation = session.memberAutomation or {}
		session.memberAutomation[player:getId()] = { slots = config.slots }
		if player:getId() == session.playerId then
			session.automation = { slots = config.slots }
		end
	end
	-- Default AUTO on at hunt start; remember prior preference to restore on leave.
	-- Player may turn AUTO off mid-hunt (e.g. to tame); do not re-lock it afterward.
	config.autoTarget = config.autoTarget
		or {
			enabled = false,
			stance = ExpeditionConfig.stanceForPlayer(player),
			rangedDistance = (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4,
		}
	session.prevAutoTargetByPlayer = session.prevAutoTargetByPlayer or {}
	local pid = player:getId()
	if session.prevAutoTargetByPlayer[pid] == nil then
		session.prevAutoTargetByPlayer[pid] = config.autoTarget.enabled == true
	end
	if session.prevAutoTargetEnabled == nil and pid == session.playerId then
		session.prevAutoTargetEnabled = config.autoTarget.enabled == true
	end
	config.autoTarget.enabled = true
	CombatAutomationStore.persist(player, config)
	CombatAutomationStore.applyToRuntime(player, config)
	if CombatAutomation and CombatAutomation.setExternalTargeting then
		CombatAutomation.setExternalTargeting(player, true)
	end
	if CombatAutomationProtocol and CombatAutomationProtocol.sendConfig then
		CombatAutomationProtocol.sendConfig(player, config)
	end
end

local function restoreAutoTarget(session, player)
	if not player then
		return
	end
	clearFollowIfAny(player)
	player:setTarget(nil)
	session.lastSyncedAttackByPlayer = session.lastSyncedAttackByPlayer or {}
	session.lastSyncedAttackByPlayer[player:getId()] = nil
	ExpeditionProtocol.sendAttackTarget(player, 0)
	player:setIdleCombat(false)
	player:removeCondition(CONDITION_INFIGHT)
	if CombatAutomation and CombatAutomation.setExternalTargeting then
		CombatAutomation.setExternalTargeting(player, false)
	end
	if CombatAutomationStore and CombatAutomationStore.getConfig then
		local config = CombatAutomationStore.getConfig(player)
		config.autoTarget = config.autoTarget
			or {
				enabled = false,
				stance = ExpeditionConfig.stanceForPlayer(player),
				rangedDistance = (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4,
			}
		local prev = session.prevAutoTargetByPlayer and session.prevAutoTargetByPlayer[player:getId()]
		if prev == nil and player:getId() == session.playerId then
			prev = session.prevAutoTargetEnabled
		end
		if prev ~= nil then
			config.autoTarget.enabled = prev == true
		end
		CombatAutomationStore.persist(player, config)
		CombatAutomationStore.applyToRuntime(player, config)
		if CombatAutomationProtocol and CombatAutomationProtocol.sendConfig then
			CombatAutomationProtocol.sendConfig(player, config)
		end
	elseif CombatAutomation and CombatAutomation.refreshLoop then
		CombatAutomation.refreshLoop(player)
	end
end

function ExpeditionAI.clearCatchUpBoosts(session)
	clearAllCatchUpBoosts(session)
end

function ExpeditionAI.stopPlayer(session, player)
	if not session or not player then
		return
	end
	clearCatchUpBoost(session, player)
	restoreAutoTarget(session, player)
end

--- Continuous hold walk for relocating: anchor autoWalks to the hold; companions
--- trail the live anchor at their stance distance (melee/close/ranged cardinals).
function ExpeditionAI.startRelocateWalk(session)
	if not session then
		return
	end
	if session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	-- Keep occupancy-safe catalog route from advanceHold (do not clear relocatePath).
	if session.relocatePath and not session.relocatePathIndex then
		session.relocatePathIndex = 1
	end
	session._relocateMember = {}
	session._relocateDestsAssigned = nil
	session._relocateFollowReady = nil
	for _, id in ipairs(memberIds(session)) do
		lastQueuedWalkById[id] = nil
	end
	local key = session.key
	local STALL_REQUEUE_MS = tonumber(ExpeditionConfig.FORMATION_REPATH_MS) or 400
	local POLL_MS = ExpeditionConfig.AI_TICK_MS or 250

	local function posKeyOf(pos)
		if not pos then
			return nil
		end
		return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
	end

	local function memberState(s, playerId)
		s._relocateMember = s._relocateMember or {}
		local st = s._relocateMember[playerId]
		if not st then
			st = { queued = false, lastPos = nil, stallMs = 0, dest = nil, ox = nil, oy = nil, dist = nil }
			s._relocateMember[playerId] = st
		end
		return st
	end

	local function atDest(ppos, dest)
		return ppos and dest and ppos.x == dest.x and ppos.y == dest.y and ppos.z == dest.z
	end

	local function trackStall(st, ppos)
		local pk = posKeyOf(ppos)
		if st.lastPos == pk then
			st.stallMs = (st.stallMs or 0) + POLL_MS
		else
			st.lastPos = pk
			st.stallMs = 0
		end
		return (st.stallMs or 0) >= STALL_REQUEUE_MS
	end

	--- Assign each companion a fixed cardinal offset at their stance distance.
	local function assignCompanionSlots(s, anchor)
		local apos = anchor:getPosition()
		if not apos then
			return
		end
		local reserved = {}
		reservePos(reserved, apos)
		local anchorId = anchor:getId()
		local ids = memberIds(s)
		table.sort(ids, function(a, b)
			return a < b
		end)
		for _, id in ipairs(ids) do
			if id ~= anchorId then
				local player = Player(id)
				if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
					local st = memberState(s, id)
					local d = stanceDistance(s, player)
					local ppos = player:getPosition()
					local candidates = collectFormationCandidates(apos, d, player, reserved, ppos)
					local dest = candidates[1] and candidates[1].pos or nil
					if not dest then
						for _, dir in ipairs(CARDINAL_DIRS) do
							local pos = Position(apos.x + dir.x * d, apos.y + dir.y * d, apos.z)
							local instanceId = player.getInstanceId and player:getInstanceId() or nil
							if isWalkableGround(pos, instanceId) and not reserved[posKey(pos)] then
								dest = pos
								break
							end
						end
					end
					if dest then
						st.ox = dest.x - apos.x
						st.oy = dest.y - apos.y
						st.dist = d
						reservePos(reserved, dest)
					else
						st.ox = 0
						st.oy = -d
						st.dist = d
					end
					st.queued = false
					st.stallMs = 0
					st.lastPos = nil
					st.queuedDestKey = nil
				end
			end
		end
	end

	local function slotDest(apos, st, player)
		if not apos or not st or st.ox == nil or st.oy == nil then
			return nil
		end
		local dest = Position(apos.x + st.ox, apos.y + st.oy, apos.z)
		local instanceId = player and player.getInstanceId and player:getInstanceId() or nil
		if isWalkableGround(dest, instanceId) then
			return dest
		end
		-- Slot blocked (wall): pick a fresh exclusive cardinal at stance distance.
		local d = st.dist or 1
		local reserved = {}
		reservePos(reserved, apos)
		local candidates = collectFormationCandidates(apos, d, player, reserved, player:getPosition())
		local alt = candidates[1] and candidates[1].pos or nil
		if alt then
			st.ox = alt.x - apos.x
			st.oy = alt.y - apos.y
			return Position(alt.x, alt.y, alt.z)
		end
		return dest
	end

	local function routeIndexAt(path, ppos, startIdx)
		local idx = math.max(1, math.floor(tonumber(startIdx) or 1))
		if not ppos or type(path) ~= "table" then
			return idx
		end
		while idx <= #path do
			local wp = path[idx]
			if wp and wp.x == ppos.x and wp.y == ppos.y and (not wp.z or wp.z == ppos.z) then
				idx = idx + 1
			else
				break
			end
		end
		return idx
	end

	local function stepToDirection(dx, dy)
		if dx == 0 and dy == -1 then
			return DIRECTION_NORTH
		elseif dx == 1 and dy == 0 then
			return DIRECTION_EAST
		elseif dx == 0 and dy == 1 then
			return DIRECTION_SOUTH
		elseif dx == -1 and dy == 0 then
			return DIRECTION_WEST
		elseif dx == 1 and dy == -1 then
			return DIRECTION_NORTHEAST
		elseif dx == 1 and dy == 1 then
			return DIRECTION_SOUTHEAST
		elseif dx == -1 and dy == 1 then
			return DIRECTION_SOUTHWEST
		elseif dx == -1 and dy == -1 then
			return DIRECTION_NORTHWEST
		end
		return nil
	end

	--- Walk the precomputed occupancy route (tile list) via explicit dirs - avoids
	--- async A* paths that leave the hunt mask and soft-lock relocate.
	--- Queues the full remaining leg in one autoWalk (catalog routes are short).
	local function queueRouteWalk(creature, path, startIdx)
		if not creature or not creature.autoWalk or type(path) ~= "table" or #path == 0 then
			return false, startIdx
		end
		local ppos = creature:getPosition()
		if not ppos then
			return false, startIdx
		end
		local idx = routeIndexAt(path, ppos, startIdx)
		if idx > #path then
			local last = path[#path]
			if last and ppos.x == last.x and ppos.y == last.y and (not last.z or last.z == ppos.z) then
				clearQueuedWalk(creature)
				return true, idx
			end
			return false, math.min(idx, #path)
		end
		local dirs = {}
		local x, y = ppos.x, ppos.y
		local endIdx = idx
		for j = idx, #path do
			local wp = path[j]
			if not wp or (wp.z and wp.z ~= ppos.z) then
				break
			end
			local dx, dy = wp.x - x, wp.y - y
			if math.abs(dx) > 1 or math.abs(dy) > 1 or (dx == 0 and dy == 0) then
				break
			end
			local dir = stepToDirection(dx, dy)
			if not dir then
				break
			end
			dirs[#dirs + 1] = dir
			x, y = wp.x, wp.y
			endIdx = j
		end
		if #dirs == 0 then
			return false, idx
		end
		local flags = FLAG_IGNOREBLOCKCREATURE or 0
		if creature:autoWalk(dirs, flags) == true then
			local id = creature:getId()
			lastQueuedWalkById[id] = {
				key = "route:" .. tostring(idx) .. ":" .. tostring(endIdx),
				ignore = true,
				at = nowMs(),
			}
			return true, endIdx + 1
		end
		return false, idx
	end

	local function driveAnchor(s, player, hold)
		if not player or not hold then
			return true
		end
		local st = memberState(s, player:getId())
		local ppos = player:getPosition()
		if atDest(ppos, hold) then
			return true
		end
		local stalled = trackStall(st, ppos)
		local path = s.relocatePath
		if type(path) == "table" and #path > 0 then
			local idx = routeIndexAt(path, ppos, s.relocatePathIndex or 1)
			s.relocatePathIndex = idx
			-- Finished the last queued leg but not at hold yet - extend without waiting for stall.
			if st.queued and st.routeQueueEndIdx and idx >= st.routeQueueEndIdx and not atDest(ppos, hold) then
				st.queued = false
			end
			if stalled or not st.queued then
				local ok, nextIdx = queueRouteWalk(player, path, idx)
				s.relocatePathIndex = nextIdx
				if ok then
					st.queued = true
					st.routeQueueEndIdx = nextIdx
					st.stallMs = 0
				else
					-- Route gap / diagonal mismatch / blocked: pathfind to hold immediately.
					st.dest = Position(hold.x, hold.y, hold.z)
					if queueWalkToward(player, st.dest, true, true) then
						st.queued = true
						st.routeQueueEndIdx = nil
						st.stallMs = 0
					end
				end
			end
			return false
		end
		st.dest = st.dest or Position(hold.x, hold.y, hold.z)
		local dest = st.dest
		if (not st.queued) or stalled then
			if queueWalkToward(player, dest, true, stalled) then
				st.queued = true
				st.stallMs = 0
			end
		end
		return false
	end

	--- Trail live anchor at assigned stance offset. Finish each autoWalk leg before
	--- repathing to the updated slot so we do not abort mid-walk every tile.
	local function driveCompanion(s, player, apos)
		if not player or not apos then
			return true
		end
		local st = memberState(s, player:getId())
		local dest = slotDest(apos, st, player)
		if not dest then
			return true
		end
		st.dest = dest
		local ppos = player:getPosition()
		local d = st.dist or 1
		local dist = ppos:getDistance(apos)
		if atDest(ppos, dest) or (isCardinalAtDistance(ppos, apos, d) and dist == d) then
			st.queued = false
			st.queuedDestKey = posKeyOf(dest)
			return true
		end
		-- Finished the previous leg: allow a fresh queue to the new slot.
		if st.queuedDestKey and posKeyOf(ppos) == st.queuedDestKey then
			st.queued = false
		end
		local destKey = posKeyOf(dest)
		local stalled = trackStall(st, ppos)
		local tooFar = dist > (d + 1)
		local tooClose = dist < d
		local needQueue = (not st.queued)
			or stalled
			or ((tooFar or tooClose) and st.queuedDestKey ~= destKey)
		if needQueue then
			-- Stack through party members while trailing; exclusive tiles only after hold.
			if queueWalkToward(player, dest, true, stalled) then
				st.queued = true
				st.queuedDestKey = destKey
				st.stallMs = 0
			end
		end
		return false
	end

	local function loop()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state ~= "relocating" then
			if s then
				s.relocateWalkEvent = nil
			end
			return
		end
		local hold = s.holdPos
		if not hold then
			s.relocateWalkEvent = addEvent(loop, POLL_MS)
			return
		end

		local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(s)
		if not anchor then
			s.relocateWalkEvent = addEvent(loop, POLL_MS)
			return
		end

		if anchor:getFollowCreature() then
			anchor:setFollowCreature(nil)
		end

		if not s._relocateDestsAssigned then
			local st = memberState(s, anchor:getId())
			st.dest = Position(hold.x, hold.y, hold.z)
			st.queued = false
			st.stallMs = 0
			st.lastPos = nil
			assignCompanionSlots(s, anchor)
			s._relocateDestsAssigned = true
		end

		local apos = anchor:getPosition()
		local anchorDone = driveAnchor(s, anchor, hold)
		local anchorId = anchor:getId()
		local reserved = beginPositionReservations(anchor)
		for _, id in ipairs(memberIds(s)) do
			if id ~= anchorId then
				local player = Player(id)
				if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
					if player:getFollowCreature() then
						player:setFollowCreature(nil)
					end
					if anchorDone then
						holdCardinalDistance(player, apos, stanceDistance(s, player), reserved)
					else
						driveCompanion(s, player, apos)
					end
				end
			end
		end

		-- Spawn / hunt-formation unlock as soon as the anchor stands on the hold.
		if anchorDone then
			s._relocateFollowReady = true
			s.relocateWalkEvent = nil
			if ExpeditionWaves and ExpeditionWaves.onRelocatePartySettled then
				ExpeditionWaves.onRelocatePartySettled(s)
			end
			-- Same-tick formation after state leaves relocating (no 250ms+ companion pause).
			if ExpeditionAI.tick then
				ExpeditionAI.tick(s)
			end
			return
		end

		s.relocateWalkEvent = addEvent(loop, POLL_MS)
	end

	session.relocateWalkEvent = addEvent(loop, 0)
end

function ExpeditionAI.tick(session)
	if not session then
		return
	end
	if session.state == "ended" or session.endedByDeath then
		return
	end
	if session.companionIds and ExpeditionManager and ExpeditionManager.notifyHuntMemberDeath then
		for companionId in pairs(session.companionIds) do
			local companion = Player(companionId)
			if not companion or (companion.getHealth and companion:getHealth() <= 0) then
				ExpeditionManager.notifyHuntMemberDeath(companion or companionId, nil)
				return
			end
		end
	end
	local ids = memberIds(session)
	if #ids == 0 then
		if ExpeditionManager.endIfNoPlayers then
			ExpeditionManager.endIfNoPlayers(session, { immediate = true })
		end
		return
	end

	local anyOnline = false
	for _, id in ipairs(ids) do
		if Player(id) then
			anyOnline = true
			break
		end
	end
	if not anyOnline then
		if ExpeditionManager.endIfNoPlayers then
			ExpeditionManager.endIfNoPlayers(session, { immediate = true })
		end
		return
	end

	if ExpeditionManager.endIfNoPlayers and ExpeditionManager.endIfNoPlayers(session) then
		return
	end

	-- Content role drives AI; kind only distinguishes catalog hunt vs shared raid instance.
	local role = session.role or (session.catalog and session.catalog.role) or "monster"
	local kind = session.kind or (session.catalog and session.catalog.kind) or "hunt"
	local anchor = nil
	if kind ~= "raid" then
		anchor = ExpeditionConfig.getAnchorPlayer(session)
	end

	-- Boss kill-gates (immunity / prepareDeath) can re-attach mid-fight via THINK;
	-- clear only when those events are present (no-op most ticks).
	if role == "boss" and ExpeditionBoss and ExpeditionBoss.ensureKillableSession then
		ExpeditionBoss.ensureKillableSession(session)
	end

	-- Shared per-tick tile claims so companions never path to / stand on the same SQM.
	local reserved = beginPositionReservations(anchor)

	-- Stable order (id asc) so exclusive slot assignment is deterministic.
	local ordered = {}
	for _, id in ipairs(ids) do
		ordered[#ordered + 1] = id
	end
	table.sort(ordered, function(a, b)
		return a < b
	end)

	for _, id in ipairs(ordered) do
		local player = Player(id)
		if player then
			if ExpeditionManager.reconcilePresence and not ExpeditionManager.reconcilePresence(player) then
				-- Member left the area; continue remaining members.
			elseif PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
				-- GOD spectates and walks; skip hunt/boss pathing.
			else
				ExpeditionAI.enablePersistence(player)
				if anchor and kind ~= "raid" then
					updateCatchUpSpeed(session, player, anchor)
				end
				if role == "boss" or role == "arena" then
					if kind == "raid" then
						tickRaid(session, player)
					else
						tickBossMember(session, player, anchor, reserved)
					end
				else
					tickHuntMember(session, player, anchor, reserved)
				end
			end
		end
	end

end

function ExpeditionAI.start(session)
	if not session then
		return
	end
	if session.state == "ended" then
		return
	end
	if session.aiEvent then
		stopEvent(session.aiEvent)
	end
	for _, id in ipairs(memberIds(session)) do
		ExpeditionAI.enablePersistence(Player(id))
	end
	local key = session.key
	local function loop()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state == "ended" then
			return
		end
		ExpeditionAI.tick(s)
		s = ExpeditionManager.getSessionByKey(key)
		if s and s.state ~= "ended" then
			s.aiEvent = addEvent(loop, ExpeditionConfig.AI_TICK_MS)
		end
	end
	session.aiEvent = addEvent(loop, ExpeditionConfig.AI_TICK_MS)

	-- Slot automation runs via CombatAutomation's shared 250ms loop.
	for _, id in ipairs(memberIds(session)) do
		local player = Player(id)
		if player and not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
			applyAutoTargetLock(session, player)
		end
	end
end

function ExpeditionAI.stop(session)
	if not session then
		return
	end
	if session.aiEvent then
		stopEvent(session.aiEvent)
		session.aiEvent = nil
	end
	if session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	session.relocatePath = nil
	session.relocatePathIndex = nil
	session._relocateMember = nil
	session._relocateDestsAssigned = nil
	session._relocateFollowReady = nil
	clearAllCatchUpBoosts(session)
	for _, id in ipairs(memberIds(session)) do
		lastQueuedWalkById[id] = nil
		local player = Player(id)
		if player then
			restoreAutoTarget(session, player)
		end
	end
	session.lastSyncedAttackCreatureId = nil
end
