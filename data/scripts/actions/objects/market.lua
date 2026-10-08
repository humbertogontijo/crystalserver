local market = Action()

function market.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if not configManager.getBoolean(configKeys.ENABLE_MARKET) then
		player:sendCancelMessage("Market is disabled.")
		return true
	end

	-- Player::sendMarketEnter no-ops until a locker sets lastDepotId; depot
	-- boxes are shared across locker ids, so pin one before opening.
	player:getDepotChest(1, true)
	player:openMarket()
	return true
end

market:id(12903)
market:register()
