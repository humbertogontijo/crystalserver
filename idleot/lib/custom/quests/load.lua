-- Quests & Tasks library loader.
--
-- Stock Player.addFamePoint / getFamePoints / removeFamePoints index
-- Storage.Quest.U10_20.SpikeTaskQuest.Constants.Spike_Fame_Points, but the
-- datapack flattens those keys onto SpikeTaskQuest. Move the key under
-- Constants (do not keep both) so fame helpers work and Storage duplicate
-- checks stay clean.
local spike = Storage and Storage.Quest and Storage.Quest.U10_20 and Storage.Quest.U10_20.SpikeTaskQuest
if spike and not spike.Constants then
	local fame = spike.Spike_Fame_Points or 44313
	spike.Constants = {
		Spike_Fame_Points = fame,
	}
	spike.Spike_Fame_Points = nil
end

local base = DATA_DIRECTORY .. "/lib/custom/quests/"
local files = {
	"01_json.lua",
	"02_config.lua",
	"03_catalog.lua",
	"04_manager.lua",
	"05_protocol.lua",
	"06_kitno_boss.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
