-- Product store offers (GameStore OFFER_TYPE_CUSTOM). Registered into GameStore.Categories
-- at startup by scripts/idleot/globalevents/store_offers.lua.
IdleotStore = IdleotStore or {}

local ids = IdleotStoreConfig.OFFER_IDS
local prices = IdleotStoreConfig.PRICES

local function taskBoostReason(player, boost)
	if (player:getTaskBoardBoost(boost) or 0) > 0 then
		return "This boost is already active."
	end
	return nil
end

local function grantTaskBoost(player, boost)
	if not player:grantTaskBoardBoost(boost) then
		return false, "This boost could not be activated."
	end
	return true
end

--- { categoryName = { offer, ... } } built on demand (GameStore enums are not loaded with libs).
function IdleotStore.buildOffers()
	local custom = GameStore.OfferTypes.OFFER_TYPE_CUSTOM
	return {
		["Boosts"] = {
			{
				icons = { "XP_Boost.png" },
				name = "Lobby XP Boost",
				id = ids.LOBBY_XP_BOOST,
				price = LobbyConfig.XP_BOOST_PRICES[1],
				count = 1,
				type = custom,
				description = string.format(
					"<i>Increases the experience points every member of your lobby gains from hunting by %d%%!</i>\n\n{info} only the lobby host can purchase it\n{info} lasts for %d minutes of hunting time\n{info} can be purchased up to %d times per day\n{info} price increases with every purchase\n{info} cannot be purchased while a lobby XP boost is active",
					LobbyConfig.XP_BOOST_PERCENT,
					math.floor(LobbyConfig.XP_BOOST_DURATION_SEC / 60),
					LobbyConfig.XP_BOOST_MAX_BUYS
				),
				getPrice = function(player)
					local _, price = LobbyBonus.canBuyXpBoost(player)
					return price
				end,
				canBuy = function(player)
					return (LobbyBonus.canBuyXpBoost(player))
				end,
				onBuy = function(player)
					local ok, err = LobbyBonus.applyXpBoost(player)
					local record = ok and LobbyStore.getForPlayer(player)
					if record then
						LobbyProtocol.broadcast(record)
					end
					return ok, err
				end,
			},
			{
				icons = { "Permanent_Hunting_Task_Slot.png" },
				name = "Weekly Double Kill Boost (1H)",
				id = ids.WEEKLY_DOUBLE_KILL,
				price = prices.WEEKLY_DOUBLE_KILL,
				count = 1,
				type = custom,
				description = "<i>Every kill counts twice towards your weekly kill tasks for one hour!</i>\n\n{character}\n{info} lasts for 1 hour\n{info} cannot be purchased while the boost is active",
				canBuy = function(player)
					return taskBoostReason(player, TASK_BOARD_BOOST_WEEKLY_DOUBLE_KILL)
				end,
				onBuy = function(player)
					return grantTaskBoost(player, TASK_BOARD_BOOST_WEEKLY_DOUBLE_KILL)
				end,
			},
			{
				icons = { "Permanent_Hunting_Task_Slot.png" },
				name = "Bounty Double Kill Boost (1H)",
				id = ids.BOUNTY_DOUBLE_KILL,
				price = prices.BOUNTY_DOUBLE_KILL,
				count = 1,
				type = custom,
				description = "<i>Every kill counts twice towards your active bounty task for one hour!</i>\n\n{character}\n{info} lasts for 1 hour\n{info} cannot be purchased while the boost is active",
				canBuy = function(player)
					return taskBoostReason(player, TASK_BOARD_BOOST_BOUNTY_DOUBLE_KILL)
				end,
				onBuy = function(player)
					return grantTaskBoost(player, TASK_BOARD_BOOST_BOUNTY_DOUBLE_KILL)
				end,
			},
		},
		["Useful Things"] = {
			{
				icons = { "Permanent_Hunting_Task_Slot.png" },
				name = "Reduced Weekly Bounty Items",
				id = ids.REDUCED_WEEKLY_ITEMS,
				price = prices.REDUCED_WEEKLY_ITEMS,
				count = 1,
				type = custom,
				description = "<i>Halves the amount of items your weekly delivery tasks require!</i>\n\n{character}\n{info} lasts until the next weekly task reset\n{info} cannot be purchased while the reduction is active",
				canBuy = function(player)
					return taskBoostReason(player, TASK_BOARD_BOOST_WEEKLY_REDUCED_ITEMS)
				end,
				onBuy = function(player)
					return grantTaskBoost(player, TASK_BOARD_BOOST_WEEKLY_REDUCED_ITEMS)
				end,
			},
			{
				icons = { "Charm_Expansion_Offer.png" },
				name = "Charm Points",
				id = ids.CHARM_POINTS,
				price = prices.CHARM_POINTS,
				count = IdleotStoreConfig.CHARM_POINTS_AMOUNT,
				type = custom,
				description = "<i>Unlock and upgrade your Charms faster!</i>\n\n{character}\n{info} added directly to your Charm points",
				onBuy = function(player)
					player:addCharmPoints(IdleotStoreConfig.CHARM_POINTS_AMOUNT)
					return true
				end,
			},
		},
	}
end
