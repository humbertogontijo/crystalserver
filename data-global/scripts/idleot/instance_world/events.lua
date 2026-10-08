local startup = GlobalEvent("InstanceWorldStartup")

function startup.onStartup()
	local ok, err = pcall(InstanceWorld.onStartup)
	if not ok then
		logger.error("[InstanceWorld] onStartup failed: {}", err)
	end
	return true
end

startup:register()

local bindCallback = EventCallback("InstanceWorldPlayerOnInstanceBind")

function bindCallback.playerOnInstanceBind(player, position)
	InstanceWorld.bindLogin(player, position)
end

bindCallback:register()

local travelCallback = EventCallback("InstanceWorldCreatureOnInstanceTravel")

function travelCallback.creatureOnInstanceTravel(creature, destination)
	return InstanceWorld.onEngineTravel(creature, destination)
end

travelCallback:register()

local changeCallback = EventCallback("InstanceWorldPlayerOnChangeInstance")

function changeCallback.playerOnChangeInstance(player, _fromKey, _toKey)
	InstanceWorld.onChangeInstance(player)
end

changeCallback:register()

-- A reattached client never saw the bind, so identity is pushed whenever a client is ready.
local clientReadyCallback = EventCallback("InstanceWorldPlayerOnClientReady")

function clientReadyCallback.playerOnClientReady(player)
	InstanceWorld.sendBounds(player, true)
end

clientReadyCallback:register()

local loginEvent = CreatureEvent("InstanceWorldLogin")

function loginEvent.onLogin(player)
	local ok, err = pcall(function()
		InstanceWorld.rescueIfStranded(player)
		local pid = player:getId()
		for _, delay in ipairs({ 100, 750 }) do
			addEvent(function()
				local p = Player(pid)
				if p then
					InstanceWorld.rescueIfStranded(p)
				end
			end, delay)
		end
	end)
	if not ok then
		logger.error("[InstanceWorld] onLogin failed for {}: {}", player:getName(), err)
	end
	return true
end

loginEvent:register()

local kindsLogin = CreatureEvent("InstanceKindsLogin")

function kindsLogin.onLogin(player)
	player:registerEvent("InstanceKindsHealth")
	player:registerEvent("InstanceKindsPrepareDeath")
	return true
end

kindsLogin:register()

local kindsHealth = CreatureEvent("InstanceKindsHealth")

function kindsHealth.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	return InstanceKinds.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
end

kindsHealth:register()

local kindsPrepareDeath = CreatureEvent("InstanceKindsPrepareDeath")

function kindsPrepareDeath.onPrepareDeath(creature, killer)
	local player = creature and creature:getPlayer()
	if player then
		return InstanceKinds.onPrepareDeath(player)
	end
	return true
end

kindsPrepareDeath:register()

local moveCreatureCallback = EventCallback("InstanceWorldPlayerOnMoveCreature")

function moveCreatureCallback.playerOnMoveCreature(player, creature, fromPosition, toPosition)
	if InstanceWorld.canMoveCreature(player, creature, fromPosition, toPosition) then
		return true
	end
	if player then
		player:sendCancelMessage(RETURNVALUE_NOTPOSSIBLE)
	end
	return false
end

moveCreatureCallback:register()

local moveItemCallback = EventCallback("InstanceWorldPlayerOnMoveItem")

function moveItemCallback.playerOnMoveItem(player, _item, _count, fromPosition, toPosition)
	-- Inventory / open containers use 0xFFFF — not map tiles; occupancy does not apply.
	-- (Without this skip, ground→backpack always fails with "Sorry, not possible.")
	if toPosition and toPosition.x ~= 0xFFFF and not InstanceWorld.canWalk(player, toPosition) then
		player:sendCancelMessage(RETURNVALUE_NOTPOSSIBLE)
		return false
	end
	-- Map pickup/push: ground tile must stay inside occupancy (no walking out to drag).
	if fromPosition and fromPosition.x ~= 0xFFFF and not InstanceWorld.canWalk(player, fromPosition) then
		player:sendCancelMessage(RETURNVALUE_NOTPOSSIBLE)
		return false
	end
	return true
end

moveItemCallback:register()

-- Open-world subarea layers spawn on first player: roll forge per spawn at world density
-- (the engine's global quota would all land on the few occupied layers).
local openWorldSpawnCallback = EventCallback("InstanceWorldMonsterOnSpawn")

function openWorldSpawnCallback.monsterOnSpawn(monster, _position)
	if Instance.isOpenWorld(monster:getInstanceId()) then
		InstanceWorld.applyOpenWorldForge(monster)
	end
end

openWorldSpawnCallback:register()
