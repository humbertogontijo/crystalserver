-- Global storage per private instance.
--
-- Stock boss scripts keep fight state in Game global storage (Faceless Bane's ward tile
-- counter, boss timers, ...), which is server-wide. Code running for a private instance
-- (its creatures' events, Game.runInInstance) reads and writes that instance's own layer:
-- a write stays in the instance, a read falls back to the world value until the instance
-- writes the key, and the layer is dropped when the instance is released. World code is
-- unchanged.
--
-- Game.getStorageValue/setStorageValue are defined in data/libs (loaded after product
-- libs), so install() runs from scripts/idleot.

InstanceStorage = InstanceStorage or { layers = {} }

local UNSET = {}

local function privateScope()
	local id = Game.getInstanceScope()
	if id and Instance.isPrivate(id) then
		return id
	end
	return nil
end

function InstanceStorage.clear(instanceId)
	local id = Instance.normalize(instanceId)
	if id then
		InstanceStorage.layers[id] = nil
	end
end

function InstanceStorage.install()
	if InstanceStorage.installed then
		return
	end
	InstanceStorage.installed = true
	local layers = InstanceStorage.layers
	local getWorld, setWorld = Game.getStorageValue, Game.setStorageValue

	function Game.getStorageValue(key)
		local id = privateScope()
		local layer = id and layers[id]
		local value = layer and layer[key]
		if value == nil then
			return getWorld(key)
		end
		return value == UNSET and -1 or value
	end

	function Game.setStorageValue(key, value)
		local id = privateScope()
		if not id or key == nil then
			return setWorld(key, value)
		end
		layers[id] = layers[id] or {}
		layers[id][key] = (value == -1 or value == nil) and UNSET or value
	end

	local release = Game.releaseInstance
	function Game.releaseInstance(instanceId, ...)
		InstanceStorage.clear(instanceId)
		return release(instanceId, ...)
	end
end
