IdleHooks.install()

local instanceRelease = EventCallback("IdleInstanceOnRelease")

function instanceRelease.instanceOnRelease(instanceKey)
	IdleEvents.emit("instance.released", instanceKey)
end

instanceRelease:register()

local walkEnd = EventCallback("IdlePlayerOnWalkEnd")

-- The engine clears the walk right after this callback, so a walk started from a
-- handler would be dropped: emit on the next dispatcher tick.
function walkEnd.playerOnWalkEnd(player, completed)
	if not IdleEvents.has("player.walkDone") then
		return
	end
	addEvent(function(playerId)
		local p = Player(playerId)
		if p then
			IdleEvents.emit("player.walkDone", p, completed)
		end
	end, 0, player:getId())
end

walkEnd:register()
