-- ============================================================================
-- Echo Warden subarea scheduler — CIP-like ~30 min arms on instance 0.
-- ============================================================================

local startup = GlobalEvent("EchoWardenSubareaStartup")

function startup.onStartup()
	addEvent(function()
		EchoWarden.startSubareaScheduler()
	end, 15000)
	return true
end

startup:register()
