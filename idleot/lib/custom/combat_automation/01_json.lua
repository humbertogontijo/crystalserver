-- Minimal JSON encode/decode for combat automation protocol / KV.
CombatAutomationJson = CombatAutomationJson or {}

local function escapeString(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return '"' .. s .. '"'
end

function CombatAutomationJson.encode(value)
	local t = type(value)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return value and "true" or "false"
	elseif t == "number" then
		return tostring(value)
	elseif t == "string" then
		return escapeString(value)
	elseif t == "table" then
		local isArray = true
		local maxIndex = 0
		for k, _ in pairs(value) do
			if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
				isArray = false
				break
			end
			if k > maxIndex then
				maxIndex = k
			end
		end
		if isArray then
			local parts = {}
			for i = 1, maxIndex do
				parts[#parts + 1] = CombatAutomationJson.encode(value[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, v in pairs(value) do
			if type(k) == "string" then
				parts[#parts + 1] = escapeString(k) .. ":" .. CombatAutomationJson.encode(v)
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

local function skipWs(s, i)
	while i <= #s do
		local c = s:sub(i, i)
		if c ~= " " and c ~= "\n" and c ~= "\r" and c ~= "\t" then
			break
		end
		i = i + 1
	end
	return i
end

local decodeValue

local function decodeString(s, i)
	i = i + 1
	local parts = {}
	while i <= #s do
		local c = s:sub(i, i)
		if c == '"' then
			return table.concat(parts), i + 1
		end
		if c == "\\" then
			local n = s:sub(i + 1, i + 1)
			if n == "n" then
				parts[#parts + 1] = "\n"
			elseif n == "r" then
				parts[#parts + 1] = "\r"
			elseif n == "t" then
				parts[#parts + 1] = "\t"
			else
				parts[#parts + 1] = n
			end
			i = i + 2
		else
			parts[#parts + 1] = c
			i = i + 1
		end
	end
	return table.concat(parts), i
end

local function decodeNumber(s, i)
	local j = i
	if s:sub(j, j) == "-" then
		j = j + 1
	end
	while j <= #s and s:sub(j, j):match("[%d%.eE%+%%-]") do
		j = j + 1
	end
	return tonumber(s:sub(i, j - 1)), j
end

local function decodeArray(s, i)
	i = i + 1
	local arr = {}
	i = skipWs(s, i)
	if s:sub(i, i) == "]" then
		return arr, i + 1
	end
	while i <= #s do
		local v
		v, i = decodeValue(s, i)
		arr[#arr + 1] = v
		i = skipWs(s, i)
		local c = s:sub(i, i)
		if c == "]" then
			return arr, i + 1
		end
		if c ~= "," then
			return arr, i
		end
		i = skipWs(s, i + 1)
	end
	return arr, i
end

local function decodeObject(s, i)
	i = i + 1
	local obj = {}
	i = skipWs(s, i)
	if s:sub(i, i) == "}" then
		return obj, i + 1
	end
	while i <= #s do
		local key
		key, i = decodeString(s, i)
		i = skipWs(s, i)
		if s:sub(i, i) ~= ":" then
			return obj, i
		end
		i = skipWs(s, i + 1)
		local val
		val, i = decodeValue(s, i)
		obj[key] = val
		i = skipWs(s, i)
		local c = s:sub(i, i)
		if c == "}" then
			return obj, i + 1
		end
		if c ~= "," then
			return obj, i
		end
		i = skipWs(s, i + 1)
	end
	return obj, i
end

decodeValue = function(s, i)
	i = skipWs(s, i)
	local c = s:sub(i, i)
	if c == '"' then
		return decodeString(s, i)
	elseif c == "{" then
		return decodeObject(s, i)
	elseif c == "[" then
		return decodeArray(s, i)
	elseif c == "t" and s:sub(i, i + 3) == "true" then
		return true, i + 4
	elseif c == "f" and s:sub(i, i + 4) == "false" then
		return false, i + 5
	elseif c == "n" and s:sub(i, i + 3) == "null" then
		return nil, i + 4
	else
		return decodeNumber(s, i)
	end
end

function CombatAutomationJson.decode(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, value = pcall(function()
		local v = decodeValue(raw, 1)
		return v
	end)
	if ok then
		return value
	end
	return nil
end
