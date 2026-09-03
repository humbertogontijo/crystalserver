local market = Action()

function market.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if not configManager.getBoolean(configKeys.ENABLE_MARKET) then
		player:sendCancelMessage("Market is disabled.")
		return true
	end

	-- CrystalServer Player::sendMarketEnter no-ops when lastDepotId is 0
	-- (default for lockers whose OTBM depot attribute was never set). Depot
	-- boxes are shared across locker ids, so pin a non-zero id before open.
	player:getDepotChest(1, true)
	player:openMarket()
	return true
end

market:id(12903)
market:register()
