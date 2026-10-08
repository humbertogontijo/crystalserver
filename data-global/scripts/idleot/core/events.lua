IdleHooks.install()

local instanceRelease = EventCallback("IdleInstanceOnRelease")

function instanceRelease.instanceOnRelease(instanceKey)
	IdleEvents.emit("instance.released", instanceKey)
end

instanceRelease:register()
