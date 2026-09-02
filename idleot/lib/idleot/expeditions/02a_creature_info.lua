-- Overlay shared creature_info stats onto expedition catalog + raid levels.
-- Hunt entries use viewport pack levels (Σ creatureCP × count^densityExp).

local function catalogRole(entry)
	if type(entry) ~= "table" then
		return "monster"
	end
	local role = entry.role
	if role == "boss" or role == "monster" then
		return role
	end
	return entry.kind == "boss" and "boss" or "monster"
end

function ExpeditionConfig.enrichCatalogEntry(entry)
	if not CreatureInfo or type(entry) ~= "table" then
		return entry
	end

	local role = catalogRole(entry)
	if role == "boss" then
		local levels = CreatureInfo.levelsForBoss(entry.creatureId, entry.name)
		if levels then
			entry.combatPower = levels.combatPower
			entry.levelMin = levels.levelMin
			entry.recommendedLevel = levels.recommendedLevel
			if (not entry.creatureId or entry.creatureId <= 0) and levels.creatureId then
				entry.creatureId = levels.creatureId
			end
		end
		return entry
	end

	if type(entry.creatures) == "table" and #entry.creatures > 0 then
		entry.creatures = CreatureInfo.enrichCreatureMix(entry.creatures)
		local pack = CreatureInfo.levelsForHuntPack(
			entry.creatures,
			entry.creatureDensity
		)
		if pack then
			entry.combatPower = pack.combatPower
			entry.levelMin = pack.levelMin
			entry.recommendedLevel = pack.recommendedLevel
		end
	elseif entry.creatureId then
		local info = CreatureInfo.getByCreatureId(entry.creatureId)
		if info then
			entry.combatPower = tonumber(info.combatPower) or entry.combatPower
			entry.levelMin = tonumber(info.huntLevelMin) or entry.levelMin
			entry.recommendedLevel = tonumber(info.huntRecommendedLevel) or entry.recommendedLevel
		end
	end

	return entry
end

function ExpeditionConfig.enrichCatalogFromCreatureInfo()
	if not CreatureInfo or not CreatureInfo.ByCreatureId then
		logger.warn("[Expedition] CreatureInfo unavailable - catalog levels unchanged")
		return
	end
	for _, entry in ipairs(ExpeditionConfig.Catalog or {}) do
		ExpeditionConfig.enrichCatalogEntry(entry)
	end
	if ExpeditionConfig.sortCatalogForDisplay then
		ExpeditionConfig.sortCatalogForDisplay(ExpeditionConfig.Catalog)
	end
	if ExpeditionConfig.buildCatalogDisplayMetadata then
		ExpeditionConfig.buildCatalogDisplayMetadata()
	end
end

function ExpeditionConfig.enrichRaidLevelsFromCreatureInfo()
	if not CreatureInfo or not CreatureInfo.ByCreatureId then
		return
	end
	for _, row in pairs(ExpeditionConfig.RaidLevels or {}) do
		if type(row) == "table" then
			local levels = CreatureInfo.levelsForBoss(row.creatureId, row.name)
			if not levels and row.creatureId then
				levels = CreatureInfo.levelsForBoss(row.creatureId, nil)
			end
			if levels then
				row.combatPower = levels.combatPower
				row.levelMin = levels.levelMin
				row.recommendedLevel = levels.recommendedLevel
				if (not row.creatureId or row.creatureId <= 0) and levels.creatureId then
					row.creatureId = levels.creatureId
				end
			end
		end
	end
end

function ExpeditionConfig.applyCreatureInfoOverlays()
	ExpeditionConfig.enrichCatalogFromCreatureInfo()
	ExpeditionConfig.enrichRaidLevelsFromCreatureInfo()
end

ExpeditionConfig.applyCreatureInfoOverlays()
