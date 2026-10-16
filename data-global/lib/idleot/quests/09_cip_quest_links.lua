-- CIP Team Finder quest id links for the expedition generate pipeline.
-- Scanned by packages/asset-pipeline crystal/quest_mechanics_registry.py.

-- Paw and Fur / Meriana Rebels (and other KitNO boards) share CIP quest 39.
IdleMissionCipLinks = IdleMissionCipLinks or {}
IdleMissionCipLinks[#IdleMissionCipLinks + 1] = { cipQuestId = 39, name = "Killing in the Name of..." }
IdleMissionCipLinks[#IdleMissionCipLinks + 1] = { cipQuestId = 81, name = "Adventurers Guild" }
IdleMissionCipLinks[#IdleMissionCipLinks + 1] = { cipQuestId = 87, name = "Spike Tasks" }

-- Explicit fields for the registry scanner (cipQuestId = N).
local cipQuestId = 39 -- Killing in the Name of...
cipQuestId = 81 -- Adventurers Guild
cipQuestId = 87 -- Spike Tasks
