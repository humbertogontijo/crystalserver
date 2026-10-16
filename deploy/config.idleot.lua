
-- IdleOT overrides, appended to config.lua.dist when config.lua is generated
-- (Makefile server-start, Dockerfile). Later assignments win.

-- World
worldType = "no-pvp"
removeBeginningWeaponAmmunition = false

-- Connection
-- Browser OTC: native WebSocket game port (0 = disabled).
websocketGamePort = 7174
maxPacketsPerSecond = 50
maxPlayersOnlinePerAccount = 4
maxPlayersOutsidePZPerAccount = 4

-- Bestiary
bestiaryKillMultiplier = 2
showLootsInBestiary = true
-- Player KV scopes written by product Lua: Echo Warden first kills show the
-- bestiary mastery marker; discovery keeps the Cyclopedia map percent.
bestiaryMasteryMarkerScope = "echo_warden"
cyclopediaMapPercentScope = "discovery"

-- Task board: store-bought double-kill boosts last this long.
taskBoardDoubleKillSeconds = 60 * 60

-- Loot and bank
autoLoot = true
autoBank = true
toggleGoldPouchQuickLootOnly = true

-- Database (make infra)
mysqlUser = "crystal"
mysqlPass = "crystal"

-- Session auth (portal issues game sessions)
authType = "session"

-- Misc
freePremium = true
disableLegacyRaids = true
coinImagesURL = "http://127.0.0.1:5173/images/store/"

-- Rates (stages in data/stages.lua)
-- rateGoldLoot multiplies dropped gold/platinum/crystal coins and the drop
-- chance of creature products (on top of rateLoot).
rateUseStages = true
rateLoot = 2
rateGoldLoot = 1.0

-- Stamina
-- staminaGreenThreshold: minutes above which the green (happy hour) band starts.
-- staminaPenaltyThreshold: at or below this many minutes XP is halved (0 = only when empty).
staminaGreenThreshold = 36 * 60
staminaPenaltyThreshold = 0
timeToRegenMinuteStamina = 1.5 * 60
timeToRegenMinutePremiumStamina = 3 * 60
staminaTrainer = true
staminaTrainerDelay = 1
staminaPz = true
staminaGreenDelay = 3

-- VIP
vipSystemEnabled = true
-- Flat VIP experience is off. Shared parties add 10% per distinct VIP account, up to 40%.
vipBonusExp = 0
vipStayOnline = true

-- Engine
useAnyDatapackFolder = false
generateLuaApiDocs = false
-- Each subarea (regions.generated.json) is its own instance; players switch instance when crossing borders.
openWorldSubareaInstances = true
-- Empty public channels > 0 (overflow layers) are torn down after this many seconds.
instanceChannelIdleSeconds = 120
