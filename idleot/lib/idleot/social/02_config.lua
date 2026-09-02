SocialConfig = SocialConfig or {}

-- Distinct from expedition (113), team (117), quests (118), blessings (119), remote dialog (120).
SocialConfig.OPCODE = 121

SocialConfig.KV_FRIENDS = "social_friends"
-- Active assemble listing (persists across logout / server restart until Unlist).
SocialConfig.KV_LISTING = "social_team_listing"

SocialConfig.GROUP_CLOSE = "close"
SocialConfig.GROUP_FRIENDS = "friends"
SocialConfig.GROUP_CONTACTS = "contacts"

SocialConfig.MAX_FRIENDS = 200
SocialConfig.MAX_LISTING_SIZE = 4
SocialConfig.LISTING_INVITE_TTL_SEC = 120

SocialConfig.ROLE_MONSTER = "monster"
SocialConfig.ROLE_BOSS = "boss"
SocialConfig.ROLE_RAID = "raid"
SocialConfig.ROLE_OTHER = "other"

SocialConfig.MEMBER_STATUS_ACCEPTED = "accepted"
SocialConfig.MEMBER_STATUS_PENDING = "pending"
SocialConfig.MEMBER_STATUS_DECLINED = "declined"

SocialConfig.VOCATIONS = { "knight", "paladin", "sorcerer", "druid", "monk" }
