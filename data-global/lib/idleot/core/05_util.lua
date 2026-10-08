-- Small helpers shared by product modules: JSON over extended opcodes, client id lists,
-- day keys. JsonParser (01_json.lua) loads after core, so it is only read at call time.

IdleUtil = IdleUtil or {}

--- Send `payload` as JSON on extended opcode `opcode` (false for a nil player).
function IdleUtil.sendJson(player, opcode, payload)
	if not player then
		return false
	end
	return player:sendExtendedOpcode(opcode, JsonParser.encode(payload))
end

--- `fn(player, payload)` sending JSON on `opcode`.
function IdleUtil.jsonSender(opcode)
	return function(player, payload)
		return IdleUtil.sendJson(player, opcode, payload)
	end
end

--- Decoded JSON object or array (a table passes through); nil for anything else.
function IdleUtil.decodeTable(raw)
	if type(raw) == "table" then
		return raw
	end
	local decoded = JsonParser.decode(raw)
	return type(decoded) == "table" and decoded or nil
end

--- `s` as a quoted, escaped JSON string literal.
function IdleUtil.jsonString(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return '"' .. s .. '"'
end

--- Positive integer item ids from a client list (at most 512).
function IdleUtil.toItemIds(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, value in ipairs(raw) do
		local id = tonumber(value)
		if id and id > 0 then
			out[#out + 1] = math.floor(id)
			if #out >= 512 then
				break
			end
		end
	end
	return out
end

--- Local calendar day "YYYY-MM-DD" (daily counters).
function IdleUtil.dayKey()
	return os.date("%Y-%m-%d")
end
