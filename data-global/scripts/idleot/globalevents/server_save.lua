-- Product server-save hooks, called once from stock global_server_save.lua ServerSave()
-- before it closes or shuts the server down. Not GlobalEvent "save": that one also fires
-- on every saveServer() (save interval, /save, /reload).

IdleotServerSave = IdleotServerSave or {}

--- Stamp the new server-save epoch (boost lots read it), then run the product hooks.
function IdleotServerSave.run()
	UpdateDailyRewardGlobalStorage(DailyReward.storages.lastServerSave, os.time())
	IdleSafe.call("ActivityBoostActivities.onServerSave", ActivityBoostActivities.onServerSave)
	IdleSafe.call("ActivityBoostWorldBoss.onServerSave", ActivityBoostWorldBoss.onServerSave)
	IdleSafe.call("ExpeditionManager.onServerSave", ExpeditionManager.onServerSave)
	IdleSafe.call("DiscoverySystem.onServerSave", DiscoverySystem.onServerSave)
	IdleSafe.call("EchoWarden.onServerSave", EchoWarden.onServerSave)
end
