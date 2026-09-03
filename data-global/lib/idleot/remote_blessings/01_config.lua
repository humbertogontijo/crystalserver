RemoteBlessingsConfig = RemoteBlessingsConfig or {}

-- Multiplex with home services on opcode 119 (dedicated blessings+home services).
-- Blessings uses its own opcode to keep topbar simple - 119.
RemoteBlessingsConfig.OPCODE = 119
RemoteBlessingsConfig.KV_AUTO_REBUY = "remote_blessings_auto_rebuy"
