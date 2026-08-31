-- Minimal JSON encode/decode for social wire format (same pattern as team/expeditions).
SocialJson = SocialJson or {}

local function escapeStr(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return '"' .. s .. '"'
end

local function encodeValue(v, depth)
	depth = depth or 0
	if depth > 12 then
		return "null"
	end
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		return tostring(v)
	elseif t == "string" then
		return escapeStr(v)
	elseif t == "table" then
		local isArray = true
		local n = 0
		for k, _ in pairs(v) do
			if type(k) ~= "number" then
				isArray = false
				break
			end
			if k > n then
				n = k
			end
		end
		if isArray then
			local parts = {}
			for i = 1, n do
				parts[#parts + 1] = encodeValue(v[i], depth + 1)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = escapeStr(tostring(k)) .. ":" .. encodeValue(val, depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

function SocialJson.encode(value)
	return encodeValue(value, 0)
end

local function skipWs(s, i)
	local _, j = s:find("^[ \t\r\n]*", i)
	return (j or i - 1) + 1
end

local function parseValue(s, i)
	i = skipWs(s, i)
	local c = s:sub(i, i)
	if c == '"' then
		local out = {}
		i = i + 1
		while i <= #s do
			local ch = s:sub(i, i)
			if ch == "\\" then
				local n = s:sub(i + 1, i + 1)
				if n == "n" then
					out[#out + 1] = "\n"
				elseif n == "r" then
					out[#out + 1] = "\r"
				elseif n == "t" then
					out[#out + 1] = "\t"
				else
					out[#out + 1] = n
				end
				i = i + 2
			elseif ch == '"' then
				return table.concat(out), i + 1
			else
				out[#out + 1] = ch
				i = i + 1
			end
		end
		return nil, i
	elseif c == "{" then
		local obj = {}
		i = i + 1
		i = skipWs(s, i)
		if s:sub(i, i) == "}" then
			return obj, i + 1
		end
		while i <= #s do
			i = skipWs(s, i)
			local key
			key, i = parseValue(s, i)
			if type(key) ~= "string" then
				return nil, i
			end
			i = skipWs(s, i)
			if s:sub(i, i) ~= ":" then
				return nil, i
			end
			i = i + 1
			local val
			val, i = parseValue(s, i)
			obj[key] = val
			i = skipWs(s, i)
			local sep = s:sub(i, i)
			if sep == "}" then
				return obj, i + 1
			elseif sep == "," then
				i = i + 1
			else
				return nil, i
			end
		end
		return nil, i
	elseif c == "[" then
		local arr = {}
		i = i + 1
		i = skipWs(s, i)
		if s:sub(i, i) == "]" then
			return arr, i + 1
		end
		while i <= #s do
			local val
			val, i = parseValue(s, i)
			arr[#arr + 1] = val
			i = skipWs(s, i)
			local sep = s:sub(i, i)
			if sep == "]" then
				return arr, i + 1
			elseif sep == "," then
				i = i + 1
			else
				return nil, i
			end
		end
		return nil, i
	elseif s:sub(i, i + 3) == "null" then
		return nil, i + 4
	elseif s:sub(i, i + 3) == "true" then
		return true, i + 4
	elseif s:sub(i, i + 4) == "false" then
		return false, i + 5
	else
		local num, j = s:match("^(-?%d+%.?%d*[eE]?[+-]?%d*)()", i)
		if num then
			return tonumber(num), j
		end
	end
	return nil, i
end

function SocialJson.decode(str)
	if type(str) ~= "string" or str == "" then
		return nil
	end
	local value, i = parseValue(str, 1)
	return value
end
