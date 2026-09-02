-- Idle Quests & Tasks (opcode 118).

local loginEvent = CreatureEvent("QuestsLogin")

function loginEvent.onLogin(player)
	player:registerEvent("QuestsOpcode")
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("QuestsOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not QuestsConfig or opcode ~= QuestsConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		QuestsProtocol.handle(player, buffer)
	end)
	if not ok then
		logger.error("[Quests] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()

local startup = GlobalEvent("QuestsStartup")

function startup.onStartup()
	if QuestsCatalog and QuestsCatalog.rebuild then
		QuestsCatalog.rebuild()
	end
	if QuestsKitnoBoss and QuestsKitnoBoss.registerExpeditions then
		QuestsKitnoBoss.registerExpeditions()
	end
	if QuestArena and QuestArena.patchStockHelpers then
		QuestArena.patchStockHelpers()
	end
	if QuestArena and QuestArena.registerExpeditions then
		QuestArena.registerExpeditions()
	end
	logger.info("[Quests] idle Quests & Tasks ready (opcode {})", QuestsConfig and QuestsConfig.OPCODE or 118)
	return true
end

startup:register()
