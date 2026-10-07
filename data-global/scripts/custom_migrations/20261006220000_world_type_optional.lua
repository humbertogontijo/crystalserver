-- IdleOT: the main open world is Optional PvP; PvP-enabled instances override it per
-- instance kind (InstancePvp). The world type is read from `worlds` at boot, before
-- migrations run, so it takes effect on the next restart.
local m = Migration("20261006220000_world_type_optional")
function m:onExecute()
	local worldId = configManager.getNumber(configKeys.WORLD_ID)
	if not db.query(string.format("UPDATE `worlds` SET `type` = 'no-pvp' WHERE `id` = %d", worldId)) then
		logger.error("world_type_optional: failed to update world {}", worldId)
		return false
	end
	logger.info("world_type_optional: world {} set to no-pvp (applies after restart)", worldId)
	return true
end
m:register()
