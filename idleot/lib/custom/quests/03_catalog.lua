-- Idle Quests & Tasks catalog. Stock storages stay authoritative.
-- Only kill-N / bring-item / report entries (no lever/puzzle/minigame).

QuestsCatalog = QuestsCatalog or {}

local function kitnoBoard(boardKey, taskId, raceName, creatures, killsRequired, opts)
	opts = opts or {}
	return {
		id = string.format("kitno_%s_%d", boardKey:lower(), taskId),
		kind = QuestsConfig.KIND_TASK,
		pack = "Killing in the Name Of",
		name = raceName,
		description = string.format("Hunt %d %s.", killsRequired, raceName),
		handler = "kitno",
		board = boardKey,
		taskId = taskId,
		creatures = creatures,
		killsRequired = killsRequired,
		huntHint = (creatures and creatures[1]) or nil,
		levelMin = opts.levelMin,
		levelMax = opts.levelMax,
		norepeatable = opts.norepeatable,
		bossName = opts.bossName,
	}
end

local function buildKitnoEntries()
	local out = {}
	if not tasks then
		return out
	end

	local function addBoard(boardKey, board)
		if type(board) ~= "table" then
			return
		end
		for taskId, task in pairs(board) do
			if type(taskId) == "number" and type(task) == "table" and task.raceName and task.killsRequired then
				out[#out + 1] = kitnoBoard(boardKey, taskId, task.raceName, task.creatures, task.killsRequired, {
					levelMin = task.level and task.level[1] or nil,
					levelMax = task.level and task.level[2] or nil,
					norepeatable = task.norepeatable,
					bossName = task.bossName,
				})
			end
		end
	end

	addBoard("GrizzlyAdams", tasks.GrizzlyAdams)
	addBoard("DanielSteelsoul", tasks.DanielSteelsoul)
	addBoard("Budrik", tasks.Budrik)
	addBoard("Lugri", tasks.Lugri)
	addBoard("Gabel", tasks.Gabel)
	addBoard("Malor", tasks.Malor)
	addBoard("RaymondStriker", tasks.RaymondStriker)
	addBoard("Extra", tasks.Extra)

	table.sort(out, function(a, b)
		return tostring(a.id) < tostring(b.id)
	end)
	return out
end

local function buildStaticEntries()
	return {
		-- Spike kill layers (credit expedition kills; stock scripts are map-gated).
		{
			id = "spike_upper_kill",
			kind = QuestsConfig.KIND_TASK,
			pack = "Spike Tasks",
			name = "Upper Spike: Demon Skeletons",
			description = "Slay 7 Demon Skeletons (expedition kills count).",
			handler = "spike",
			layer = "upper",
			creatures = { "demon skeleton" },
			killsRequired = 7,
			huntHint = "demon skeleton",
			storageMain = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest.Spike_Upper_Kill_Main or 44320,
			storageDaily = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest.Spike_Upper_Kill_Daily or 44321,
			reportExp = 1000,
		},
		{
			id = "spike_middle_kill",
			kind = QuestsConfig.KIND_TASK,
			pack = "Spike Tasks",
			name = "Middle Spike: Kill Task",
			description = "Complete the middle Spike kill quota (7).",
			handler = "spike",
			layer = "middle",
			creatures = { "demon skeleton", "vampire", "werewolf" },
			killsRequired = 7,
			huntHint = "vampire",
			storageMain = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest.Spike_Middle_Kill_Main or 44328,
			storageDaily = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest.Spike_Middle_Kill_Daily or 44329,
			reportExp = 2000,
		},
		{
			id = "spike_lower_kill",
			kind = QuestsConfig.KIND_TASK,
			pack = "Spike Tasks",
			name = "Lower Spike: Kill Task",
			description = "Complete the lower Spike kill quota (7).",
			handler = "spike",
			layer = "lower",
			creatures = { "hellspawn", "nightmare", "destroyer" },
			killsRequired = 7,
			huntHint = "hellspawn",
			storageMain = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest.Spike_Lower_Kill_Main or 44336,
			storageDaily = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest.Spike_Lower_Kill_Daily or 44337,
			reportExp = 3500,
		},

		-- A Father's Burden deliver missions.
		{
			id = "afb_sinew",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Strong Sinew",
			description = "Deliver Heoni's sinew to Tereban.",
			handler = "afb",
			itemId = 11548,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Sinew or 42954,
			huntHint = "heoni",
			reportExp = 2500,
		},
		{
			id = "afb_wood",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Exquisite Wood",
			description = "Deliver exquisite wood to Tereban.",
			handler = "afb",
			itemId = 11547,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Wood or 42955,
			reportExp = 2500,
		},
		{
			id = "afb_cloth",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Spectral Cloth",
			description = "Deliver spectral cloth to Tereban.",
			handler = "afb",
			itemId = 11546,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Cloth or 42956,
			reportExp = 2500,
		},
		{
			id = "afb_silk",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Exquisite Silk",
			description = "Deliver exquisite silk to Tereban.",
			handler = "afb",
			itemId = 11545,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Silk or 42957,
			huntHint = "spider",
			reportExp = 2500,
		},
		{
			id = "afb_crystal",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Magic Crystal",
			description = "Deliver a magic crystal to Tereban.",
			handler = "afb",
			itemId = 11552,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Crystal or 42958,
			reportExp = 2500,
		},
		{
			id = "afb_root",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Mystic Root",
			description = "Deliver a mystic root to Tereban.",
			handler = "afb",
			itemId = 11551,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Root or 42959,
			reportExp = 2500,
		},
		{
			id = "afb_iron",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Old Iron",
			description = "Deliver old iron to Tereban.",
			handler = "afb",
			itemId = 11549,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Iron or 42960,
			reportExp = 2500,
		},
		{
			id = "afb_scale",
			kind = QuestsConfig.KIND_QUEST,
			pack = "A Father's Burden",
			name = "Flexible Dragon Scale",
			description = "Deliver Glitterscale's scale to Tereban.",
			handler = "afb",
			itemId = 11550,
			itemCount = 1,
			storage = Storage and Storage.Quest and Storage.Quest.U8_6 and Storage.Quest.U8_6.AFathersBurden.Scale or 42961,
			huntHint = "glitterscale",
			reportExp = 2500,
		},

		-- Outfit addons (item hunts only).
		{
			id = "outfit_citizen_backpack",
			kind = QuestsConfig.KIND_QUEST,
			pack = "Outfit Addons",
			name = "Citizen Backpack Addon",
			description = "Bring 100 minotaur leather.",
			handler = "outfit",
			items = { { itemId = 5878, count = 100 } },
			lookTypeMale = 128,
			lookTypeFemale = 136,
			addon = 1,
			storageMission = Storage and Storage.OutfitQuest and Storage.OutfitQuest.Citizen and Storage.OutfitQuest.Citizen.MissionBackpack
				or (Storage and Storage.Quest and Storage.Quest.U7_8 and Storage.Quest.U7_8.CitizenOutfits and Storage.Quest.U7_8.CitizenOutfits.MissionBackpack)
				or 40778,
			huntHint = "minotaur",
		},
		{
			id = "outfit_citizen_hat",
			kind = QuestsConfig.KIND_QUEST,
			pack = "Outfit Addons",
			name = "Citizen Feather Hat Addon",
			description = "Bring a legion helmet, 100 chicken feathers and 50 honeycombs.",
			handler = "outfit",
			items = {
				{ itemId = 3374, count = 1 },
				{ itemId = 5890, count = 100 },
				{ itemId = 5902, count = 50 },
			},
			lookTypeMale = 128,
			lookTypeFemale = 136,
			addon = 2,
			storageMission = Storage and Storage.Quest and Storage.Quest.U7_8 and Storage.Quest.U7_8.CitizenOutfits and Storage.Quest.U7_8.CitizenOutfits.AddonHat or 40777,
			huntHint = "chicken",
		},
		{
			id = "outfit_assassin_addon2",
			kind = QuestsConfig.KIND_QUEST,
			pack = "Outfit Addons",
			name = "Assassin Addon (Atrad)",
			description = "Bring a behemoth claw and a nose ring.",
			handler = "outfit",
			items = {
				{ itemId = 5930, count = 1 },
				{ itemId = 5804, count = 1 },
			},
			lookTypeMale = 152,
			lookTypeFemale = 156,
			addon = 2,
			requiresOutfit = true,
			huntHint = "behemoth",
		},

		-- The Great Dragon Hunt.
		{
			id = "great_dragon_hunt",
			kind = QuestsConfig.KIND_QUEST,
			pack = "Adventurers Guild",
			name = "The Great Dragon Hunt",
			description = "Kill 50 dragons or dragon lords.",
			handler = "dragon_hunt",
			creatures = { "dragon", "dragon lord" },
			killsRequired = 50,
			huntHint = "dragon",
			storageCounter = Storage and Storage.Quest and Storage.Quest.U10_80 and Storage.Quest.U10_80.TheGreatDragonHunt and Storage.Quest.U10_80.TheGreatDragonHunt.DragonCounter or 45181,
			storageAchievement = Storage and Storage.Quest and Storage.Quest.U10_80 and Storage.Quest.U10_80.TheGreatDragonHunt and Storage.Quest.U10_80.TheGreatDragonHunt.Achievement or 45182,
		},
	}
end

function QuestsCatalog.all()
	if QuestsCatalog._cache then
		return QuestsCatalog._cache
	end
	local entries = buildStaticEntries()
	for _, e in ipairs(buildKitnoEntries()) do
		entries[#entries + 1] = e
	end
	QuestsCatalog._byId = {}
	for _, e in ipairs(entries) do
		QuestsCatalog._byId[e.id] = e
	end
	QuestsCatalog._cache = entries
	return entries
end

function QuestsCatalog.get(id)
	QuestsCatalog.all()
	return QuestsCatalog._byId and QuestsCatalog._byId[id] or nil
end

function QuestsCatalog.rebuild()
	QuestsCatalog._cache = nil
	QuestsCatalog._byId = nil
	return QuestsCatalog.all()
end
