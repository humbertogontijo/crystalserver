LetterConfig = LetterConfig or {}

-- Next free after token services (127).
LetterConfig.OPCODE = 128

-- Reward letters are stock stamped letters tagged with this action id; the
-- template key lives in the item's custom attribute.
LetterConfig.ITEM_ID = 3506
LetterConfig.ACTION_ID = 47110
LetterConfig.TEMPLATE_ATTRIBUTE = "letter"
LetterConfig.KV_SCOPE = "letters"
LetterConfig.DESCRIPTION = "A letter addressed to you. Use it to read it and claim its reward."

-- Delivered once per character on login, in this order.
LetterConfig.AUTO_DELIVER = { "welcome_exercise" }

-- reward.kind: "choice" grants one picked item, "items" grants all of them.
LetterConfig.TEMPLATES = {
	welcome_exercise = {
		subject = "Welcome to IdleOT",
		body = "Welcome, adventurer!\n\n"
			.. "To help you get started, pick one exercise weapon below. "
			.. "It goes to your store inbox and can be used on the exercise dummy in your lobby room to train your skills.\n\n"
			.. "Have a nice game!",
		storage = Storage.PlayerWeaponReward,
		reward = {
			kind = "choice",
			items = {
				{ id = 35279, charges = 64400 }, -- durable exercise sword
				{ id = 35280, charges = 64400 }, -- durable exercise axe
				{ id = 35281, charges = 64400 }, -- durable exercise club
				{ id = 35282, charges = 64400 }, -- durable exercise bow
				{ id = 35283, charges = 64400 }, -- durable exercise rod
				{ id = 35284, charges = 64400 }, -- durable exercise wand
				{ id = 44066, charges = 64400 }, -- durable exercise shield
				{ id = 50294, charges = 64400 }, -- durable exercise wraps
			},
			itemDescription = "You won this exercise weapon as a welcome reward. Use it on an exercise dummy!",
		},
	},
}
