local instanceRelease = EventCallback("IdleInstanceOnRelease")

function instanceRelease.instanceOnRelease(instanceKey)
	IdleEvents.emit("instance.released", instanceKey)
end

instanceRelease:register()

local walkEnd = EventCallback("IdlePlayerOnWalkEnd")

-- The engine clears the walk before this callback, so a handler may start the next one.
function walkEnd.playerOnWalkEnd(player, completed, result)
	if IdleEvents.has("player.walkDone") then
		Game.runInInstance(player:getInstanceId(), IdleEvents.emit, "player.walkDone", player, completed, result)
	end
end

walkEnd:register()

-- Product-tracked monsters register "IdleMonsterDeath"; each owner subscribes to "monster.died".
local monsterDeath = CreatureEvent("IdleMonsterDeath")

function monsterDeath.onDeath(creature, corpse, killer, mostDamageKiller)
	IdleEvents.emit("monster.died", creature, corpse, killer, mostDamageKiller)
	return true
end

monsterDeath:register()

local monsterRemove = EventCallback("IdleMonsterOnRemove")

function monsterRemove.monsterOnRemove(monster)
	if IdleEvents.has("monster.removed") then
		IdleEvents.emit("monster.removed", monster)
	end
end

monsterRemove:register()
