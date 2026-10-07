-- Starter gear is granted by scripts/idleot/starter_kit (product kits).
-- Core overlay replaces stock send_first_items.lua.

local sendFirstItems = CreatureEvent("SendFirstItems")

function sendFirstItems.onLogin(_player)
	return true
end

sendFirstItems:register()
