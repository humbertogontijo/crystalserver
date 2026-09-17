CreatureInfo = CreatureInfo or {}

--- Lookup by bosstiary / bestiary race id.
--- Ensures ``name`` is present (byCreatureId JSON rows often omit it; load()
--- usually backfills from byName, but defend here for raceId-only callers).
function CreatureInfo.getByCreatureId(creatureId)
	local id = tonumber(creatureId)
	if not id or id <= 0 then
		return nil
	end
	local info = CreatureInfo.ByCreatureId and CreatureInfo.ByCreatureId[id] or nil
	if not info then
		return nil
	end
	if type(info.name) ~= "string" or info.name == "" then
		if CreatureInfo.ByName then
			for _, entry in pairs(CreatureInfo.ByName) do
				if tonumber(entry.creatureId) == id and type(entry.name) == "string" and entry.name ~= "" then
					info.name = entry.name
					break
				end
			end
		end
	end
	if type(info.name) ~= "string" or info.name == "" then
		return nil
	end
	return info
end

--- Spawn-weighted mean of generated creature combatPower (density not applied).
function CreatureInfo.compositionCombatPower(creatures)
	local weighted, weightSum = 0, 0
	if type(creatures) ~= "table" then
		return 0
	end
	for _, row in ipairs(creatures) do
		local id = row and tonumber(row.creatureId)
		local pct = row and tonumber(row.percent) or 0
		local power = 0
		if id and pct > 0 then
			local info = CreatureInfo.getByCreatureId(id)
			power = info and tonumber(info.combatPower) or tonumber(row.combatPower) or 0
		end
		if power > 0 and pct > 0 then
			local w = pct / 100
			weighted = weighted + w * power
			weightSum = weightSum + w
		end
	end
	if weightSum <= 0 then
		return 0
	end
	return weighted / weightSum
end

--- Density-free composition of generated creature combatPower.
function CreatureInfo.packCombatPower(creatures)
	return CreatureInfo.compositionCombatPower(creatures)
end

--- Σ creatureCP_i × n_i^densityExp. n_i is viewport count when set,
--- otherwise density × share_i.
function CreatureInfo.huntCombatPowerFromMix(creatures, creatureDensity)
	if type(creatures) ~= "table" then
		return 0
	end
	local dens = tonumber(creatureDensity) or 1
	if dens < 0 then
		dens = 0
	end
	local exp = 0.5
	if CreatureInfo.huntDensityExp then
		exp = tonumber(CreatureInfo.huntDensityExp()) or 0.5
	end
	local countSum = 0
	local parts = {}
	for _, row in ipairs(creatures) do
		local id = row and tonumber(row.creatureId)
		local pct = row and tonumber(row.percent) or 0
		local n = row and tonumber(row.count)
		local power = tonumber(row and row.combatPower) or 0
		if power <= 0 and id and (pct > 0 or (n and n > 0)) then
			local info = CreatureInfo.getByCreatureId(id)
			power = info and tonumber(info.combatPower) or 0
		end
		if power > 0 then
			if n and n > 0 then
				countSum = countSum + n
				parts[#parts + 1] = { n = n, power = power }
			elseif pct > 0 then
				parts[#parts + 1] = { w = pct / 100, power = power }
			end
		end
	end
	if #parts == 0 then
		return 0
	end
	local pack = 0
	if countSum > 0 then
		for _, part in ipairs(parts) do
			if part.n and part.n > 0 then
				pack = pack + part.power * (part.n ^ exp)
			end
		end
		return pack
	end
	if dens <= 0 then
		return 0
	end
	local weightSum = 0
	for _, part in ipairs(parts) do
		if part.w then
			weightSum = weightSum + part.w
		end
	end
	if weightSum <= 0 then
		return 0
	end
	for _, part in ipairs(parts) do
		if part.w then
			local n = dens * (part.w / weightSum)
			if n > 0 then
				pack = pack + part.power * (n ^ exp)
			end
		end
	end
	return pack
end

--- Attach base stats from creatures.generated.json; keeps hunt percent overlay.
function CreatureInfo.enrichCreatureMix(creatures)
	if type(creatures) ~= "table" then
		return creatures
	end
	local out = {}
	for i, row in ipairs(creatures) do
		local id = row and tonumber(row.creatureId)
		local pct = row and tonumber(row.percent) or 0
		local enriched = {
			creatureId = id,
			percent = pct,
		}
		local amt = tonumber(row.count)
		if amt and amt > 0 then
			enriched.count = amt
		end
		if id and id > 0 then
			local info = CreatureInfo.getByCreatureId(id)
			if info then
				enriched.name = info.name
				enriched.combatPower = tonumber(info.combatPower) or 0
				enriched.levelMin = tonumber(info.levelMin) or 1
				enriched.recommendedLevel = tonumber(info.recommendedLevel) or 1
				enriched.hp = tonumber(info.hp) or 0
				enriched.exp = tonumber(info.exp) or 0
				enriched.expectedDps = tonumber(info.expectedDps) or 0
				enriched.expectedHealDps = tonumber(info.expectedHealDps) or 0
				enriched.armor = tonumber(info.armor) or 0
				enriched.defense = tonumber(info.defense) or 0
				enriched.mitigation = tonumber(info.mitigation) or 0
				enriched.meanElementPercent = tonumber(info.meanElementPercent) or 0
				enriched.speed = tonumber(info.speed) or 0
			end
		end
		out[i] = enriched
	end
	return out
end

--- Hunt levels from Σ creature combatPower × n_i^densityExp.
function CreatureInfo.levelsForHuntPack(creatures, creatureDensity)
	local packCp = CreatureInfo.huntCombatPowerFromMix(creatures, creatureDensity)
	if packCp <= 0 then
		return nil
	end
	local levels = CreatureInfo.huntLevelsFromPackCombatPower(packCp)
	levels.combatPower = packCp
	return levels
end

--- Boss / raid levels for a single creature (same CP→level pair as hunts).
function CreatureInfo.levelsForBoss(creatureId, name)
	local info = CreatureInfo.getByCreatureId(creatureId) or (name and CreatureInfo.get(name))
	if not info then
		return nil
	end
	return {
		combatPower = tonumber(info.combatPower) or 0,
		levelMin = tonumber(info.levelMin) or 1,
		recommendedLevel = tonumber(info.recommendedLevel) or 1,
		creatureId = info.creatureId,
		name = info.name,
	}
end
