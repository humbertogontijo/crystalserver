QuestsConfig = QuestsConfig or {}

-- Next free product opcode after team (117).
QuestsConfig.OPCODE = 118

-- Entry kinds shown in the client.
QuestsConfig.KIND_TASK = "task"
QuestsConfig.KIND_QUEST = "quest"

-- Status strings sent to the client.
QuestsConfig.STATUS_AVAILABLE = "available"
QuestsConfig.STATUS_ACTIVE = "active"
QuestsConfig.STATUS_READY = "ready"
QuestsConfig.STATUS_DONE = "done"
QuestsConfig.STATUS_LOCKED = "locked"
