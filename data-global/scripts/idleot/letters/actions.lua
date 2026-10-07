-- Using a reward letter opens the client letter window instead of the stock text window.

local letterUse = Action()

function letterUse.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	return Letters.open(player, item)
end

letterUse:aid(LetterConfig.ACTION_ID)
letterUse:register()
