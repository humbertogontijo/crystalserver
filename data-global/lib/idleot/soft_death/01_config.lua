SoftDeathConfig = SoftDeathConfig or {}

-- Free product opcode (125 = ActivityBoost; 126 = loot split).
SoftDeathConfig.OPCODE = 122

-- ITEM_MALE_CORPSE / ITEM_FEMALE_CORPSE (utils_definitions.hpp); not exported to Lua.
SoftDeathConfig.MALE_CORPSE_ID = 4240
SoftDeathConfig.FEMALE_CORPSE_ID = 4247

SoftDeathConfig.DEFAULT_DURATION_SEC = 10
SoftDeathConfig.DEFAULT_TITLE = "Knocked out"
SoftDeathConfig.DEFAULT_MESSAGE = "Respawning in place..."
