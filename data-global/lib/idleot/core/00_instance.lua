-- Instance identity helpers. The engine handle is the key string
-- "kind:subareaId:channel" (creature:getInstanceId(), Game.allocateInstance, ...);
-- "world:0:0" is the shared map-template layer. Keys compare with == and work as table keys.
-- Parsing, building and liveness all come from the engine (Game.parseInstance,
-- Game.instanceKey, Game.isInstanceLive); this file only adds conveniences on top.

Instance = Instance or {}

Instance.WORLD = INSTANCE_WORLD
-- The Adventurers' hub (InstanceFenceRegistry::HUB_ADVENTURERS), channel 0.
Instance.HUB = INSTANCE_HUB

-- Kinds the subarea partition assigns to open-world regions.
Instance.OPEN_WORLD_KINDS = {
	city = true,
	house = true,
	wild = true,
	hunt = true,
	connector = true,
}

local WORLD_RECORD = { kind = "world", subareaId = 0, channel = 0, key = Instance.WORLD }

-- Parsed keys never change meaning, so memoize them (bounded: rebuilt when it grows too large).
local PARSE_CACHE_LIMIT = 4096
local parseCache, parseCacheSize = {}, 0

--- Key for {kind, subareaId, channel}; nil (never a guessed key) for an unknown kind.
function Instance.key(kind, subareaId, channel)
	return Game.instanceKey(tostring(kind), math.floor(tonumber(subareaId) or 0), math.floor(tonumber(channel) or 0))
end

--- {kind, subareaId, channel, key} for a key string, instance table or 0/nil (world). nil when unparsable.
function Instance.parse(id)
	if id == nil or id == 0 then
		return WORLD_RECORD
	end
	if type(id) == "table" then
		if id.key then
			return Instance.parse(id.key)
		end
		if id.kind then
			local key = Instance.key(id.kind, id.subareaId, id.channel)
			return key and Instance.parse(key) or nil
		end
		return nil
	end
	if type(id) ~= "string" then
		return nil
	end
	local cached = parseCache[id]
	if cached then
		return cached
	end
	local parsed = Game.parseInstance(id)
	if not parsed then
		return nil
	end
	if parseCacheSize >= PARSE_CACHE_LIMIT then
		parseCache, parseCacheSize = {}, 0
	end
	parseCache[id] = parsed
	parseCacheSize = parseCacheSize + 1
	return parsed
end

--- Canonical key string; world for nil / 0. Unparsable input is a caller bug: nil.
function Instance.normalize(id)
	local parsed = Instance.parse(id)
	return parsed and parsed.key or nil
end

--- Key of a creature or item (world when it has none). The engine key is already canonical.
function Instance.of(thing)
	if thing and thing.getInstanceId then
		return thing:getInstanceId() or Instance.WORLD
	end
	return Instance.WORLD
end

function Instance.isWorld(id)
	return Instance.normalize(id) == Instance.WORLD
end

function Instance.kind(id)
	local parsed = Instance.parse(id)
	return parsed and parsed.kind or nil
end

function Instance.subareaId(id)
	local parsed = Instance.parse(id)
	return parsed and parsed.subareaId or nil
end

function Instance.channel(id)
	local parsed = Instance.parse(id)
	return parsed and parsed.channel or nil
end

--- Same {kind, subareaId} on another channel; nil for world or unparsable input.
function Instance.withChannel(id, channel)
	local parsed = Instance.parse(id)
	if not parsed or parsed.kind == "world" then
		return nil
	end
	return Instance.key(parsed.kind, parsed.subareaId, channel)
end

--- Reserved channel (expedition, lobby room, raid, ...) or a private-only kind.
function Instance.isPrivate(id)
	local key = Instance.normalize(id)
	if not key or key == Instance.WORLD then
		return false
	end
	return Game.isPrivateInstance(key) == true
end

--- Engine registry: the instance exists and is not closing (and is owned by `owner` when given).
--- Callbacks that captured a key must check this before acting on it.
function Instance.isLive(id, owner)
	local key = Instance.normalize(id)
	if not key then
		return false
	end
	return Game.isInstanceLive(key, owner) == true
end

function Instance.isOpenWorld(id)
	local parsed = Instance.parse(id)
	return parsed ~= nil and Instance.OPEN_WORLD_KINDS[parsed.kind] == true and Game.isPrivateInstance(parsed.key) ~= true
end

function Instance.sameSubarea(a, b)
	local pa, pb = Instance.parse(a), Instance.parse(b)
	return pa ~= nil and pb ~= nil and pa.kind == pb.kind and pa.subareaId == pb.subareaId
end
