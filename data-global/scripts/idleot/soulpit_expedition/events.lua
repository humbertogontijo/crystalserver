-- Soul Pit expedition scripts (opcode multiplexed with expeditions).
-- Logic lives in lib/idleot/soulpit_expedition; this file ensures load order via product scripts.
local startup = GlobalEvent("SoulPitExpeditionStartup")

function startup.onStartup()
	logger.info("[SoulPitExpedition] ready (join via expedition opcode joinSoulPit)")
	return true
end

startup:register()
