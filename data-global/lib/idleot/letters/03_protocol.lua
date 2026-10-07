-- Opcode 128. Client: { "action": "claim", "choice": <1-based index> } | { "action": "status" }
-- Server: letter{subject, body, reward} | claimed{items} | status{has} | error{message}

function Letters.handleOpcode(player, buffer)
	if type(buffer) ~= "string" or buffer == "" then
		return
	end
	local payload = JsonParser.decode(buffer)
	if type(payload) ~= "table" then
		return
	end
	if payload.action == "claim" then
		Letters.claim(player, payload.choice)
	elseif payload.action == "status" then
		Letters.sendStatus(player)
	end
end
