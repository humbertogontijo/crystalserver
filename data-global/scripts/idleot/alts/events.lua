local attachCallback = EventCallback("AltsPlayerOnClientAttach")

function attachCallback.playerOnClientAttach(player)
	Alts.onClientAttached(player)
end

attachCallback:register()

local detachCallback = EventCallback("AltsPlayerOnClientDetach")

function detachCallback.playerOnClientDetach(player)
	Alts.onClientDetached(player)
end

detachCallback:register()

local reviveCallback = EventCallback("AltsPlayerOnRevive")

function reviveCallback.playerOnRevive(player)
	Alts.onRevive(player)
end

reviveCallback:register()
