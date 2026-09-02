-- Starter gear is seeded on Sample characters at DB migrate time and copied at
-- character create (SlenderAAC). Core overlay replaces stock send_first_items.lua.

local sendFirstItems = CreatureEvent("SendFirstItems")

function sendFirstItems.onLogin(_player)
	return true
end

sendFirstItems:register()
