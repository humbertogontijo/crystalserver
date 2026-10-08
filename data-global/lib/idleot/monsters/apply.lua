-- Merge one override node (overrides.generated.lua) into a stock monster table.
-- Pure Lua: the asset pipeline runs this file through lupa to verify the table it emits.
--
-- Node format (written by packages/asset-pipeline features.monsters.emit_overrides):
--   key = value              scalar (or new table) replaces the stock value
--   key = { ...node }        nested patch when the stock value is a table
--   _unset = { "key", ... }  keys the product removed
--   _list = { op, ... }      edits of the array part; entries are matched by their
--                            id/name/type/text fields and nth occurrence in the stock list:
--     { match = {...}, nth = 2, patch = {...node} }
--     { match = {...}, remove = true }
--     { insert = i, value = {...} }   final 1-based position, ascending

MonsterOverrides = MonsterOverrides or {}

local IDENTITY_FIELDS = { "id", "name", "type", "text" }

local function identity(entry)
	if type(entry) ~= "table" then
		return "=" .. tostring(entry)
	end
	local parts = {}
	for _, field in ipairs(IDENTITY_FIELDS) do
		local value = entry[field]
		if value ~= nil then
			parts[#parts + 1] = field .. "=" .. tostring(value)
		end
	end
	return table.concat(parts, ";")
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local applyNode

local function applyList(list, ops, warn)
	local indexByKey, seen = {}, {}
	for index = 1, #list do
		local key = identity(list[index])
		seen[key] = (seen[key] or 0) + 1
		indexByKey[key .. "#" .. seen[key]] = index
	end

	local removed, inserts = {}, {}
	for _, op in ipairs(ops) do
		if op.insert then
			inserts[#inserts + 1] = op
		else
			local key = identity(op.match) .. "#" .. (op.nth or 1)
			local index = indexByKey[key]
			if not index then
				warn("no stock entry " .. key)
			elseif op.remove then
				removed[index] = true
			elseif op.patch and type(list[index]) == "table" then
				applyNode(list[index], op.patch, warn)
			end
		end
	end

	local result = {}
	for index = 1, #list do
		if not removed[index] then
			result[#result + 1] = list[index]
		end
	end
	for _, op in ipairs(inserts) do
		table.insert(result, math.min(op.insert, #result + 1), copy(op.value))
	end
	for index = #list, 1, -1 do
		list[index] = nil
	end
	for index = 1, #result do
		list[index] = result[index]
	end
end

applyNode = function(target, node, warn)
	for key, value in pairs(node) do
		if key == "_list" then
			applyList(target, value, warn)
		elseif key == "_unset" then
			for _, name in ipairs(value) do
				target[name] = nil
			end
		elseif type(value) == "table" and type(target[key]) == "table" then
			applyNode(target[key], value, warn)
		else
			target[key] = copy(value)
		end
	end
end

-- Mutates `mask`; `warn(message)` reports stock entries an override no longer finds.
function MonsterOverrides.apply(mask, node, warn)
	applyNode(mask, node, warn or function() end)
	return mask
end
