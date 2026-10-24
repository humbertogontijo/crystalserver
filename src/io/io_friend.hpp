////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////
#pragma once

#include "creatures/creatures_definitions.hpp"

struct FriendSystemFriendRow {
	uint32_t guid = 0;
	std::string name;
	uint8_t group = 2;
	uint16_t level = 0;
	std::string vocation;
	bool online = false;
	Outfit_t outfit {};
};

struct FriendSystemInviteRow {
	uint32_t guid = 0;
	std::string name;
	uint32_t created = 0;
};

struct FriendSystemSearchCharacterRow {
	uint32_t guid = 0;
	uint32_t creatureId = 0;
	std::string name;
	uint16_t level = 0;
	std::string vocation;
	std::string world;
	bool online = false;
	Outfit_t outfit {};
};

struct FriendSystemSearchResult {
	uint32_t accountId = 0;
	bool online = false;
	bool premium = false;
	uint32_t lastLogin = 0;
	std::vector<FriendSystemSearchCharacterRow> characters;
};

struct FriendSystemSettingRow {
	uint8_t settingType = 0;
	bool showCharacter = true;
	bool showAccount = true;
	bool allowInspect = true;
	bool enableCharacter = true;
	bool enableAccount = true;
	bool enableInspect = true;
};

struct FriendActionTarget {
	uint32_t accountId = 0;
	uint32_t guid = 0;
	std::string name;
	uint8_t group = 2;
	uint8_t settingType = 0;
	bool showCharacter = true;
	bool showAccount = true;
	bool allowInspect = true;
};

class IOFriend {
public:
	static constexpr uint16_t MAX_FRIENDS = 200;

	static FriendActionTarget parseActionPayload(const std::string &payload);
	static uint8_t normalizeGroupByte(const std::string &group);
	static uint8_t normalizeGroupByte(uint8_t group);

	static uint32_t getAccountIdByPlayerName(const std::string &name);
	static uint32_t getAccountIdByPlayerGuid(uint32_t playerGuid);
	static bool isAccountPremium(uint32_t accountId);
	static bool isAccountOnline(uint32_t accountId);
	static bool isSameAccount(uint32_t accountId, uint32_t otherAccountId);

	static bool enrichFriendRow(uint32_t friendAccountId, uint8_t group, FriendSystemFriendRow &row);

	static std::vector<FriendSystemFriendRow> loadFriendList(uint32_t accountId);
	static void loadInviteLists(uint32_t accountId, std::vector<FriendSystemInviteRow> &received, std::vector<FriendSystemInviteRow> &sent);
	static std::vector<FriendSystemInviteRow> loadBlacklist(uint32_t accountId);
	static std::vector<FriendSystemSettingRow> loadSettings(uint32_t accountId);

	static bool sendInvite(uint32_t fromAccountId, uint32_t toAccountId);
	static bool acceptInvite(uint32_t accepterAccountId, uint32_t fromAccountId);
	static bool declineInvite(uint32_t declinerAccountId, uint32_t fromAccountId);
	static bool cancelInvite(uint32_t senderAccountId, uint32_t toAccountId);
	static bool removeFriend(uint32_t accountId, uint32_t friendAccountId);
	static bool changeFriendGroup(uint32_t accountId, uint32_t friendAccountId, uint8_t group);
	static bool addBlacklist(uint32_t accountId, uint32_t blockedAccountId);
	static bool removeBlacklist(uint32_t accountId, uint32_t blockedAccountId);
	static bool saveSetting(uint32_t accountId, const FriendActionTarget &target);

	static bool searchAccountByCharacterName(const std::string &characterName, FriendSystemSearchResult &result);

	static bool isFriend(uint32_t accountId, uint32_t friendAccountId);
	static bool isBlacklisted(uint32_t accountId, uint32_t blockedAccountId);
};
