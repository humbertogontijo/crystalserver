IdleHooks.install()

local instanceRelease = EventCallback("IdleInstanceOnRelease")

function instanceRelease.instanceOnRelease(instanceKey)
	IdleEvents.emit("instance.released", instanceKey)
end

instanceRelease:register()

local walkEnd = EventCallback("IdlePlayerOnWalkEnd")

-- The engine clears the walk right after this callback, so a walk started from a
-- handler would be dropped: emit on the next dispatcher tick, in the player's instance.
function walkEnd.playerOnWalkEnd(player, completed)
	if not IdleEvents.has("player.walkDone") then
		return
	end
	addEvent(function(playerId)
		local p = Player(playerId)
		if p then
			Game.runInInstance(p:getInstanceId(), IdleEvents.emit, "player.walkDone", p, completed)
		end
	end, 0, player:getId())
end

walkEnd:register()

local itemAdded = EventCallback("IdleZoneOnItemAdded")

function itemAdded.zoneOnItemAdded(zone, item)
	if IdleEvents.has("zone.itemAdded") then
		IdleEvents.emit("zone.itemAdded", zone, item)
	end
end

itemAdded:register()

local itemRemoved = EventCallback("IdleZoneOnItemRemoved")

function itemRemoved.zoneOnItemRemoved(zone, item)
	if IdleEvents.has("zone.itemRemoved") then
		IdleEvents.emit("zone.itemRemoved", zone, item)
	end
end

itemRemoved:register()
