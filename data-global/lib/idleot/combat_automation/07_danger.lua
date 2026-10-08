-- Automation movement, danger: wave / beam lines and boss fronts members keep out of.

local geo = CombatGeo
local nowMs, chebyshev, tileFree, fartherFromLeash = geo.nowMs, geo.chebyshev, geo.tileFree, geo.fartherFromLeash
local throttled, ADJUST_THROTTLE_MS, stepTo = MOVE_PRIV.throttled, MOVE_PRIV.ADJUST_THROTTLE_MS, MOVE_PRIV.stepTo

-- ---------------------------------------------------------------------------
-- Wave / beam lines: members keep out of the directional attacks of monsters on
-- screen (any monster; bosses also have their own, far stronger front rule below).
-- ---------------------------------------------------------------------------

--- Attacks of unknown shape (scripted monster spells) count as a cone this long.
local LINE_FALLBACK_RANGE = 5
local CARDINAL_DIRS = { DIRECTION_NORTH, DIRECTION_EAST, DIRECTION_SOUTH, DIRECTION_WEST }

local function offsetKey(dx, dy)
	return (dx + 128) * 256 + (dy + 128)
end

--- Union of a monster type's directional attacks (waves / beams), cached per name:
--- nil when it casts none, else per facing { list = { { dx, dy }, ... }, set =
--- { [offsetKey] = true } } with offsets from the caster.
local shapeByName = {}
local function directionalShape(monster)
	local mType = monster.getType and monster:getType()
	if not mType or not mType.getAttackList then
		return nil
	end
	local name = mType:name()
	local cached = shapeByName[name]
	if cached == nil then
		local north, any = {}, false
		local function add(dx, dy)
			if dx ~= 0 or dy ~= 0 then
				north[offsetKey(dx, dy)] = { dx, dy }
			end
		end
		for _, attack in ipairs(mType:getAttackList() or {}) do
			if attack.needDirection then
				any = true
				if type(attack.area) == "table" and #attack.area > 0 then
					for _, off in ipairs(attack.area) do
						add(off.x, off.y)
					end
				else
					for f = 1, LINE_FALLBACK_RANGE do
						for l = 1 - f, f - 1 do
							add(l, -f)
						end
					end
				end
			end
		end
		cached = false
		if any then
			cached = {}
			for _, dir in ipairs(CARDINAL_DIRS) do
				local list, set = {}, {}
				for _, off in pairs(north) do
					local dx, dy = geo.rotateOffset(off[1], off[2], dir)
					list[#list + 1] = { dx, dy }
					set[offsetKey(dx, dy)] = true
				end
				cached[dir] = { list = list, set = set }
			end
		end
		shapeByName[name] = cached
	end
	return cached or nil
end

--- Directional casters fighting on `player`'s screen: `tiles` counts per tile the
--- casters fighting someone else whose line covers it (as they face now); `mine`
--- lists the casters targeting `player`, which turn toward it wherever it stands.
--- Nil when there are none.
local function lineDanger(player)
	local monsters = CombatAutomation.visibleMonsters and CombatAutomation.visibleMonsters(player) or {}
	local tiles, mine, any = {}, {}, false
	local myId = player:getId()
	local z = player:getPosition().z
	for _, monster in ipairs(monsters) do
		local target = monster:getTarget()
		local shape = target and directionalShape(monster)
		local mpos = shape and monster:getPosition()
		if mpos and mpos.z == z then
			any = true
			if target:getId() == myId then
				mine[#mine + 1] = { pos = mpos, shape = shape }
			else
				local facing = shape[monster:getDirection()]
				for _, off in ipairs(facing and facing.list or {}) do
					local key = geo.tileKey(mpos.x + off[1], mpos.y + off[2])
					tiles[key] = (tiles[key] or 0) + 1
				end
			end
		end
	end
	return any and { tiles = tiles, mine = mine } or nil
end

--- Casters whose line covers `pos` (exact diagonals of a caster turning toward it
--- stay clear).
local function linesCovering(lines, pos)
	local count = lines.tiles[geo.tileKey(pos.x, pos.y)] or 0
	for _, caster in ipairs(lines.mine) do
		local dx, dy = pos.x - caster.pos.x, pos.y - caster.pos.y
		local adx, ady = math.abs(dx), math.abs(dy)
		if adx ~= ady then
			local dir
			if adx > ady then
				dir = dx > 0 and DIRECTION_EAST or DIRECTION_WEST
			else
				dir = dy > 0 and DIRECTION_SOUTH or DIRECTION_NORTH
			end
			if caster.shape[dir].set[offsetKey(dx, dy)] then
				count = count + 1
			end
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Boss fronts: every stance and role keeps out of the cone in front of a boss
-- (reward or bosstiary boss; regular monsters do not count).
-- ---------------------------------------------------------------------------

--- Cone reach (wave / beam length).
local BOSS_CONE_RANGE = 7
--- A tile in a boss front loses this much (above every other positioning term).
local BOSS_FRONT_PENALTY = 10 * AnchorSpot.RING_TILE

local bossByName = {}
local function isBoss(monster)
	local mType = monster.getType and monster:getType()
	if not mType then
		return false
	end
	local name = mType:name()
	local cached = bossByName[name]
	if cached == nil then
		cached = (mType.isRewardBoss and mType:isRewardBoss())
			or (mType.bossRaceId and (tonumber(mType:bossRaceId()) or 0) > 0)
			or false
		bossByName[name] = cached
	end
	return cached
end

--- Bosses on `player`'s screen: { pos, dir, targetId }.
local function bossFronts(player)
	local out = {}
	local monsters = CombatAutomation.visibleMonsters and CombatAutomation.visibleMonsters(player) or {}
	for _, monster in ipairs(monsters) do
		if isBoss(monster) then
			local target = monster:getTarget()
			out[#out + 1] = { pos = monster:getPosition(), dir = monster:getDirection(), targetId = target and target:getId() or nil }
		end
	end
	return out
end

--- `pos` is in front of a boss for `player`: a boss attacking `player` turns to face
--- it wherever it stands (only exact diagonals stay clear); others keep their facing.
local function inBossFront(player, pos, fronts)
	local myId = player:getId()
	for _, front in ipairs(fronts) do
		local dir = front.targetId ~= myId and front.dir or nil
		if geo.inFrontCone(front.pos, dir, pos, BOSS_CONE_RANGE) then
			return true
		end
	end
	return false
end

--- Melee in front of a boss: step to a free neighbour out of every boss front that
--- keeps its target adjacent (a diagonal when the boss attacks it). The step is kept
--- on the state (`anchorAdoptPos`, `anchorAdoptAt`) so a cavebot halt moves along.
--- True while a dodge owns movement.
local function dodgeBossFront(player, target, state)
	local fronts = bossFronts(player)
	local ppos = player:getPosition()
	if #fronts == 0 or not inBossFront(player, ppos, fronts) then
		return false
	end
	if throttled(state, "bossDodgeAt", ADJUST_THROTTLE_MS) then
		return true
	end
	local tpos = target:getPosition()
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		local pos = Position(ppos.x + off[1], ppos.y + off[2], ppos.z)
		if chebyshev(pos, tpos) == 1 and tileFree(pos, player) and not fartherFromLeash(player, ppos, pos)
			and not inBossFront(player, pos, fronts)
			and stepTo(player, pos)
		then
			if state then
				state.anchorAdoptPos = pos
				state.anchorAdoptAt = nowMs()
				local directive = state.directive
				if directive and directive.kind == "hold" then
					directive.pos = pos
				end
			end
			return true
		end
	end
	return false
end


MOVE_PRIV.bossFronts = bossFronts
MOVE_PRIV.inBossFront = inBossFront
MOVE_PRIV.BOSS_FRONT_PENALTY = BOSS_FRONT_PENALTY
MOVE_PRIV.dodgeBossFront = dodgeBossFront
MOVE_PRIV.linesCovering = linesCovering
MOVE_PRIV.lineDanger = lineDanger
MOVE_PRIV.directionalShape = directionalShape
