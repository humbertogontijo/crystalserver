-- Remote hireling economy (cooldown / tax / auto-sell). Overlay only.

RemoteHirelingConfig = RemoteHirelingConfig or {}

RemoteHirelingConfig.OPCODE = 115
RemoteHirelingConfig.KV_SCOPE = "remote_hireling"
RemoteHirelingConfig.KV_COOLDOWN_UNTIL = "cooldownUntil"
RemoteHirelingConfig.KV_AUTO_SELL = "autoSell"
RemoteHirelingConfig.KV_SELL_ON_NO_GOLD = "sellOnNoGold"
RemoteHirelingConfig.KV_SELL_ON_NO_CAP = "sellOnNoCap"
RemoteHirelingConfig.KV_ACCEPT_TAX_ON_COOLDOWN = "acceptTaxOnCooldown"
RemoteHirelingConfig.KV_SELL_FILTER_MODE = "sellFilterMode"
RemoteHirelingConfig.KV_SELL_FILTER_IDS = "sellFilterIds"

-- 1 hour free-sell cooldown; 20% tax while remaining.
RemoteHirelingConfig.COOLDOWN_SECONDS = 60 * 60
RemoteHirelingConfig.TAX_PERCENT = 20

-- Avoid re-selling every combat tick when gold/cap is still insufficient.
RemoteHirelingConfig.EMERGENCY_SELL_COOLDOWN_SECONDS = 5

RemoteHirelingConfig.MAX_FILTER_IDS = 512
