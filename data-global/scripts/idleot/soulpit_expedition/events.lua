-- Soul Pit expedition scripts (opcode multiplexed with expeditions).
-- Logic lives in lib/idleot/soulpit_expedition; this file ensures load order via product scripts.
local startup = GlobalEvent("SoulPitExpeditionStartup")

function startup.onStartup()
	if SoulPitExpedition then
		logger.info("[SoulPitExpedition] ready (join via expedition opcode joinSoulPit)")
	end
	return true
end

startup:register()
