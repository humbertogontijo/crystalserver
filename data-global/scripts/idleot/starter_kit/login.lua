-- Starter kit: equips the vocation gear + backpack on a character's first login.
-- The portal inserts bare player rows (no item copy); this is the only grant.

local BACKPACK_ID = 2854

-- Mainland vocation kits only. VOCATION_NONE / Newhaven use Newhaven.giveStarterItems
-- after the in-town vocation pick (see quests/newhaven/on_login_newhaven.lua).
local KITS = {
	[VOCATION.BASE_ID.SORCERER] = {
		equipped = {
			{ CONST_SLOT_HEAD, 7992 }, -- mage hat
			{ CONST_SLOT_NECKLACE, 3572 }, -- scarf
			{ CONST_SLOT_ARMOR, 7991 }, -- magician's robe
			{ CONST_SLOT_RIGHT, 3059 }, -- spellbook
			{ CONST_SLOT_LEFT, 3074 }, -- wand of vortex
			{ CONST_SLOT_LEGS, 3362 }, -- studded legs
			{ CONST_SLOT_FEET, 3552 }, -- leather boots
		},
		container = {
			{ 3003, 1 }, -- rope
			{ 5710, 1 }, -- light shovel
			{ 268, 10 }, -- mana potion
		},
	},
	[VOCATION.BASE_ID.DRUID] = {
		equipped = {
			{ CONST_SLOT_HEAD, 7992 }, -- mage hat
			{ CONST_SLOT_NECKLACE, 3572 }, -- scarf
			{ CONST_SLOT_ARMOR, 7991 }, -- magician's robe
			{ CONST_SLOT_RIGHT, 3059 }, -- spellbook
			{ CONST_SLOT_LEFT, 3066 }, -- snakebite rod
			{ CONST_SLOT_LEGS, 3362 }, -- studded legs
			{ CONST_SLOT_FEET, 3552 }, -- leather boots
		},
		container = {
			{ 3003, 1 }, -- rope
			{ 5710, 1 }, -- light shovel
			{ 268, 10 }, -- mana potion
		},
	},
	[VOCATION.BASE_ID.PALADIN] = {
		equipped = {
			{ CONST_SLOT_HEAD, 3374 }, -- legion helmet
			{ CONST_SLOT_NECKLACE, 3572 }, -- scarf
			{ CONST_SLOT_ARMOR, 3571 }, -- ranger's cloak
			{ CONST_SLOT_LEFT, 3350 }, -- bow (before the quiver: two-handed)
			{ CONST_SLOT_RIGHT, 35562, { { 3447, 50 } } }, -- quiver with arrows
			{ CONST_SLOT_LEGS, 8095 }, -- ranger legs
			{ CONST_SLOT_FEET, 3552 }, -- leather boots
		},
		container = {
			{ 3003, 1 }, -- rope
			{ 5710, 1 }, -- light shovel
			{ 266, 10 }, -- health potion
			{ 3277, 1 }, -- spear
			{ 3425, 1 }, -- dwarven shield
		},
	},
	[VOCATION.BASE_ID.KNIGHT] = {
		equipped = {
			{ CONST_SLOT_HEAD, 3354 }, -- brass helmet
			{ CONST_SLOT_NECKLACE, 3572 }, -- scarf
			{ CONST_SLOT_ARMOR, 3359 }, -- brass armor
			{ CONST_SLOT_RIGHT, 3425 }, -- dwarven shield
			{ CONST_SLOT_LEFT, 7773 }, -- steel axe
			{ CONST_SLOT_LEGS, 3372 }, -- brass legs
			{ CONST_SLOT_FEET, 3552 }, -- leather boots
		},
		container = {
			{ 7774, 1 }, -- jagged sword
			{ 3327, 1 }, -- daramanian mace
			{ 3003, 1 }, -- rope
			{ 5710, 1 }, -- light shovel
			{ 266, 10 }, -- health potion
		},
	},
	[VOCATION.BASE_ID.MONK] = {
		equipped = {
			{ CONST_SLOT_HEAD, 3354 }, -- brass helmet
			{ CONST_SLOT_NECKLACE, 3572 }, -- scarf
			{ CONST_SLOT_ARMOR, 3359 }, -- brass armor
			{ CONST_SLOT_LEFT, 50171 }, -- jo staff
			{ CONST_SLOT_LEGS, 3372 }, -- brass legs
			{ CONST_SLOT_FEET, 3552 }, -- leather boots
		},
		container = {
			{ 3425, 1 }, -- dwarven shield
			{ 3003, 1 }, -- rope
			{ 5710, 1 }, -- light shovel
			{ 266, 10 }, -- health potion
		},
	},
}

local function fill(container, contents)
	for _, entry in ipairs(contents or {}) do
		container:addItem(entry[1], entry[2])
	end
end

local function grant(player, kit)
	local backpack = player:addItem(BACKPACK_ID, 1, false, 1, CONST_SLOT_BACKPACK)
	for _, entry in ipairs(kit.equipped or {}) do
		local slot, itemId, contents = entry[1], entry[2], entry[3]
		local item = player:addItem(itemId, 1, false, 1, slot) or player:addItem(itemId, 1)
		if item and contents then
			fill(item, contents)
		end
	end
	if backpack then
		fill(backpack, kit.container)
	end
end

-- Same name as the stock event: the datapack registration replaces data/.../send_first_items.lua.
local starterKit = CreatureEvent("SendFirstItems")

function starterKit.onLogin(player)
	if player:getLastLoginSaved() ~= 0 then
		return true
	end
	-- No mainland kit on Newhaven / no-voc first login.
	if player:getVocation():getId() == VOCATION_NONE then
		return true
	end
	local town = player:getTown()
	if town and town:getId() == TOWNS_LIST.NEWHAVEN then
		return true
	end
	local kit = KITS[player:getVocation():getBaseId()]
	if kit then
		grant(player, kit)
	end
	return true
end

starterKit:register()
