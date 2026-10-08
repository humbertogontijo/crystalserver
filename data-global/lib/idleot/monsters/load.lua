-- Product stat / loot / attack values for stock monsters. Stock files under
-- data-global/monster stay byte-identical to upstream; overrides.generated.lua
-- (packages/asset-pipeline features.monsters) is merged into each monster table
-- when its file calls mType:register(monster).

dofile(DATA_DIRECTORY .. "/lib/idleot/monsters/apply.lua")

MonsterOverrides.byName = dofile(DATA_DIRECTORY .. "/lib/idleot/monsters/overrides.generated.lua")
MonsterOverrides.applied = setmetatable({}, { __mode = "k" })

local function registerWithOverrides(stockRegister, mtype, mask)
	local name = mtype:name()
	local node = MonsterOverrides.byName[name]
	if node and type(mask) == "table" and not MonsterOverrides.applied[mask] then
		MonsterOverrides.applied[mask] = true
		MonsterOverrides.apply(mask, node, function(message)
			logger.warn("[idleot/monsters] {}: override {}", name, message)
		end)
	end
	return stockRegister(mtype, mask)
end

-- data/scripts/lib/register_monster_type.lua assigns MonsterType.register after
-- this lib and again on every /reload monsters. The key is kept out of the raw
-- table so each assignment lands in __newindex and stays wrapped.
local methods = getmetatable(MonsterType)
if not methods.idleotOverrides then
	local stockRegister = rawget(MonsterType, "register")
	rawset(MonsterType, "register", nil)
	local function register(mtype, mask)
		return registerWithOverrides(stockRegister, mtype, mask)
	end
	methods.__index = function(_, key)
		if key == "register" and stockRegister then
			return register
		end
	end
	methods.__newindex = function(self, key, value)
		if key == "register" then
			stockRegister = value
		else
			rawset(self, key, value)
		end
	end
	methods.idleotOverrides = true
end
