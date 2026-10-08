-- Product server-save hooks. Stock global_server_save.lua is left untouched.
--
-- Default config (globalServerSaveShutdown = true) calls Game.setGameState(SHUTDOWN)
-- before bumping lastServerSave, which fires GlobalEvent type "save" first.
-- We bump lastServerSave here so boost lots stamp the new epoch, then run hooks.
-- If shutdown/close are both off, the UpdateDailyRewardGlobalStorage wrapper
-- (installed on startup) still runs the hooks after the stock bump.

IdleotServerSave = IdleotServerSave or {}

local lastHookEpoch = 0

function IdleotServerSave.runHooks()
	local epoch = os.time()
	if lastHookEpoch ~= 0 and epoch - lastHookEpoch < 5 then
		return
	end
	lastHookEpoch = epoch

	IdleSafe.call("ActivityBoostActivities.onServerSave", ActivityBoostActivities.onServerSave)
	IdleSafe.call("ActivityBoostWorldBoss.onServerSave", ActivityBoostWorldBoss.onServerSave)
	IdleSafe.call("ExpeditionManager.onServerSave", ExpeditionManager.onServerSave)
	if DiscoverySystem and DiscoverySystem.onServerSave then
		IdleSafe.call("DiscoverySystem.onServerSave", DiscoverySystem.onServerSave)
	end
	if EchoWarden and EchoWarden.onServerSave then
		IdleSafe.call("EchoWarden.onServerSave", EchoWarden.onServerSave)
	end
end

local saveEvent = GlobalEvent("IdleotServerSave")

function saveEvent.onSave()
	if DailyReward and DailyReward.storages and DailyReward.storages.lastServerSave then
		UpdateDailyRewardGlobalStorage(DailyReward.storages.lastServerSave, os.time())
	end
	IdleotServerSave.runHooks()
	return true
end

saveEvent:type("save")
saveEvent:register()

local startup = GlobalEvent("IdleotServerSaveWrap")

function startup.onStartup()
	if type(UpdateDailyRewardGlobalStorage) ~= "function" then
		return true
	end
	if IdleotServerSave._wrapped then
		return true
	end
	local orig = UpdateDailyRewardGlobalStorage
	UpdateDailyRewardGlobalStorage = function(key, value)
		orig(key, value)
		if DailyReward and DailyReward.storages and key == DailyReward.storages.lastServerSave then
			IdleotServerSave.runHooks()
		end
	end
	IdleotServerSave._wrapped = true
	return true
end

startup:register()
