-- GOD test hook for the client's server dialogs: /dialogtest modal | text | letter | stamped
local dialogTest = TalkAction("/dialogtest")

function dialogTest.onSay(player, words, param)
	logCommand(player, words, param)

	if param == "modal" then
		local window = ModalWindow({
			title = "Dialog test",
			message = "Pick a choice.",
		})
		for _, name in ipairs({ "First", "Second", "Third" }) do
			window:addChoice(name, function(target, button, choice)
				target:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Dialog test: %s / %s", tostring(button.name), tostring(choice.text)))
			end)
		end
		window:addButton("Ok")
		window:addButton("Close")
		-- Button ids are 1-based (modal_window_helper.lua).
		window:setDefaultEnterButton(1)
		window:setDefaultEscapeButton(2)
		window:sendToPlayer(player)
	elseif param == "text" then
		player:showTextDialog(2817, "Read-only dialog test text.", false)
	elseif param == "letter" then
		player:showTextDialog(3505, "", true, 200)
	elseif param == "stamped" then
		-- Stamped letter (3506) with writer: CIP showItemText shows the author-warning strip
		-- when author is set and the item is a stamped letter.
		-- Use addItem so the item is born in the player's instance (Game.createItem without
		-- a position/instance returns nil under instanceStrict).
		local item = player:addItem(3506, 1)
		if not item then
			player:sendCancelMessage("Could not create stamped letter.")
			return true
		end
		item:setAttribute(ITEM_ATTRIBUTE_TEXT, "Meeting at the depot tomorrow.")
		item:setAttribute(ITEM_ATTRIBUTE_WRITER, "Sample Writer")
		player:showTextDialog(item, item:getAttribute(ITEM_ATTRIBUTE_TEXT), false)
	else
		player:sendCancelMessage("Usage: /dialogtest modal | text | letter | stamped")
	end
	return true
end

dialogTest:separator(" ")
dialogTest:groupType("god")
dialogTest:register()
