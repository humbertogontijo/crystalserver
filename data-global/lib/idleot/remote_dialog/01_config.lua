-- Reusable remote NPC dialog (opcode 120).
-- Opens a client dialog and optionally forwards player lines to a real NPC as
-- TALKTYPE_PRIVATE_PN (same path as in-range private NPC chat, without spectators).
-- NPC replies use engine TALKTYPE_PRIVATE_NP (cross-instance private speak).

RemoteDialogConfig = RemoteDialogConfig or {}
RemoteDialogConfig.OPCODE = 120
