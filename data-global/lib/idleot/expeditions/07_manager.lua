-- Expedition manager facade: load ordered slices (shared EM_PRIV).
ExpeditionManager = ExpeditionManager or {}
EM_PRIV = EM_PRIV or {}
local base = DATA_DIRECTORY .. "/lib/idleot/expeditions/"
for _, file in ipairs({
	"07a_session.lua",
	"07b_entry.lua",
	"07c_leave.lua",
	"07d_lifecycle.lua",
}) do
	dofile(base .. file)
end
