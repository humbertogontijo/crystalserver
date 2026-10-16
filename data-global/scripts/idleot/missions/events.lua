-- Idle mission catalog refresh after KitNO/arena append their exclusive rows.

local startup = GlobalEvent("IdleMissionStartup")

function startup.onStartup()
	if IdleMission and IdleMission.registerCatalogRows then
		IdleMission.registerCatalogRows()
		logger.info("[IdleMission] registered {} missions", (function()
			local n = 0
			for _ in pairs(IdleMission.registry or {}) do
				n = n + 1
			end
			return n
		end)())
	end
	return true
end

startup:register()
