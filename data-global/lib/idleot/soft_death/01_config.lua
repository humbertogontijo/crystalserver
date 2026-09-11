SoftDeathConfig = SoftDeathConfig or {}

-- Free product opcode (125 = ActivityBoost; 126 = loot split).
SoftDeathConfig.OPCODE = 122

SoftDeathConfig.MALE_CORPSE_ID = (ITEM_MALE_CORPSE and ITEM_MALE_CORPSE > 0) and ITEM_MALE_CORPSE or 4240
SoftDeathConfig.FEMALE_CORPSE_ID = (ITEM_FEMALE_CORPSE and ITEM_FEMALE_CORPSE > 0) and ITEM_FEMALE_CORPSE or 4247

SoftDeathConfig.DEFAULT_DURATION_SEC = 10
SoftDeathConfig.DEFAULT_TITLE = "Knocked out"
SoftDeathConfig.DEFAULT_MESSAGE = "Respawning in place..."
