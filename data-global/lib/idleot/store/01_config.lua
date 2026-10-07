IdleotStoreConfig = IdleotStoreConfig or {}

-- Offer ids are mirrored in the client (apps/otclient modules/gamelib/const.lua StoreConst).
IdleotStoreConfig.OFFER_IDS = {
	LOBBY_XP_BOOST = 66101,
	WEEKLY_DOUBLE_KILL = 66102,
	BOUNTY_DOUBLE_KILL = 66103,
	REDUCED_WEEKLY_ITEMS = 66104,
	CHARM_POINTS = 66105,
}

-- Tibia Coin prices (the Lobby XP Boost price comes from LobbyConfig.XP_BOOST_PRICES).
IdleotStoreConfig.PRICES = {
	WEEKLY_DOUBLE_KILL = 40,
	BOUNTY_DOUBLE_KILL = 40,
	REDUCED_WEEKLY_ITEMS = 120,
	CHARM_POINTS = 30,
}

IdleotStoreConfig.CHARM_POINTS_AMOUNT = 100
