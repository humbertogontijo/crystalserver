////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "io/io_friend.hpp"

#include "config/configmanager.hpp"
#include "creatures/creatures_definitions.hpp"
#include "creatures/players/player.hpp"
#include "creatures/players/vocations/vocation.hpp"
#include "database/database.hpp"
#include "game/game.hpp"
#include "io/iologindata.hpp"
#include "utils/tools.hpp"

#include <nlohmann/json.hpp>

namespace {
std::string worldDisplayName() {
	const auto &world = g_game().worlds().getCurrentWorld();
	if (world && !world->name.empty()) {
		return world->name;
	}
	return g_configManager().getString(SERVER_NAME);
}

std::string vocationNameFromId(uint16_t vocId) {
	const auto &voc = g_vocations().getVocation(vocId);
	if (!voc) {
		return {};
	}
	return voc->getVocName();
}

Outfit_t outfitFromDbRow(const DBResult_ptr &result) {
	Outfit_t outfit;
	outfit.lookType = result->getNumber<uint16_t>("looktype");
	outfit.lookHead = result->getNumber<uint16_t>("lookhead");
	outfit.lookBody = result->getNumber<uint16_t>("lookbody");
	outfit.lookLegs = result->getNumber<uint16_t>("looklegs");
	outfit.lookFeet = result->getNumber<uint16_t>("lookfeet");
	outfit.lookAddons = result->getNumber<uint16_t>("lookaddons");
	return outfit;
}

std::shared_ptr<Player> findOnlinePlayerOnAccount(uint32_t accountId) {
	for (const auto &[_, online] : g_game().getPlayers()) {
		if (online && online->getAccountId() == accountId) {
			return online;
		}
	}
	return nullptr;
}

std::string displayNameForAccount(uint32_t accountId) {
	if (const auto &online = findOnlinePlayerOnAccount(accountId)) {
		return online->getName();
	}
	Database &db = Database::getInstance();
	const auto worldId = g_game().worlds().getCurrentWorld()->id;
	const std::string query = fmt::format(
		"SELECT `name` FROM `players` WHERE `account_id` = {} AND `world_id` = {} AND `deletion` = 0 ORDER BY `level` DESC, `name` ASC LIMIT 1",
		accountId, worldId
	);
	if (const DBResult_ptr result = db.storeQuery(query)) {
		return result->getString("name");
	}
	return fmt::format("#{}", accountId);
}

void fillRowFromPlayer(const std::shared_ptr<Player> &player, FriendSystemFriendRow &row) {
	row.guid = player->getGUID();
	row.name = player->getName();
	row.level = player->getLevel();
	if (const auto &voc = player->getVocation()) {
		row.vocation = voc->getVocName();
	}
	row.online = true;
	row.outfit = player->getCurrentOutfit();
}

bool fillRowFromDb(uint32_t accountId, FriendSystemFriendRow &row) {
	Database &db = Database::getInstance();
	const auto worldId = g_game().worlds().getCurrentWorld()->id;
	const std::string query = fmt::format(
		"SELECT `id`, `name`, `level`, `vocation`, `looktype`, `lookhead`, `lookbody`, `looklegs`, `lookfeet`, `lookaddons` "
		"FROM `players` WHERE `account_id` = {} AND `world_id` = {} AND `deletion` = 0 ORDER BY `level` DESC, `name` ASC LIMIT 1",
		accountId, worldId
	);
	const DBResult_ptr result = db.storeQuery(query);
	if (!result) {
		row.guid = accountId;
		row.name = fmt::format("#{}", accountId);
		return false;
	}
	row.guid = result->getNumber<uint32_t>("id");
	row.name = result->getString("name");
	row.level = result->getNumber<uint16_t>("level");
	row.vocation = vocationNameFromId(result->getNumber<uint16_t>("vocation"));
	row.online = false;
	row.outfit = outfitFromDbRow(result);
	return true;
}
} // namespace

FriendActionTarget IOFriend::parseActionPayload(const std::string &payload) {
	FriendActionTarget target;
	if (payload.empty()) {
		return target;
	}
	if (payload.front() == '{' || payload.front() == '[') {
		try {
			const auto json = nlohmann::json::parse(payload);
			if (json.contains("accountId")) {
				target.accountId = json["accountId"].get<uint32_t>();
			}
			if (json.contains("guid")) {
				target.guid = json["guid"].get<uint32_t>();
			}
			if (json.contains("name")) {
				target.name = json["name"].get<std::string>();
			}
			if (json.contains("group")) {
				if (json["group"].is_string()) {
					target.group = normalizeGroupByte(json["group"].get<std::string>());
				} else {
					target.group = normalizeGroupByte(json["group"].get<uint8_t>());
				}
			}
			if (json.contains("settingType")) {
				target.settingType = json["settingType"].get<uint8_t>();
			}
			if (json.contains("showCharacterInfo")) {
				target.showCharacter = json["showCharacterInfo"].get<bool>();
			} else if (json.contains("showCharacter")) {
				target.showCharacter = json["showCharacter"].get<bool>();
			}
			if (json.contains("showAccountInfo")) {
				target.showAccount = json["showAccountInfo"].get<bool>();
			} else if (json.contains("showAccount")) {
				target.showAccount = json["showAccount"].get<bool>();
			}
			if (json.contains("allowInspect")) {
				target.allowInspect = json["allowInspect"].get<bool>();
			}
		} catch (const nlohmann::json::exception &) {
			target.name = payload;
		}
	} else {
		target.name = payload;
	}
	trimString(target.name);
	return target;
}

uint8_t IOFriend::normalizeGroupByte(const std::string &group) {
	const std::string lower = asLowerCaseString(group);
	if (lower == "close" || lower == "close friends" || lower == "closefriends") {
		return 3;
	}
	if (lower == "contacts" || lower == "contact") {
		return 1;
	}
	return 2;
}

uint8_t IOFriend::normalizeGroupByte(uint8_t group) {
	if (group == 3 || group == 1) {
		return group;
	}
	return 2;
}

uint32_t IOFriend::getAccountIdByPlayerGuid(uint32_t playerGuid) {
	if (playerGuid == 0) {
		return 0;
	}
	if (const auto &online = g_game().getPlayerByID(playerGuid)) {
		return online->getAccountId();
	}
	Database &db = Database::getInstance();
	const auto worldId = g_game().worlds().getCurrentWorld()->id;
	const std::string query = fmt::format(
		"SELECT `account_id` FROM `players` WHERE `id` = {} AND `world_id` = {} AND `deletion` = 0 LIMIT 1",
		playerGuid, worldId
	);
	const DBResult_ptr result = db.storeQuery(query);
	if (!result) {
		return 0;
	}
	return result->getNumber<uint32_t>("account_id");
}

uint32_t IOFriend::getAccountIdByPlayerName(const std::string &name) {
	if (name.empty()) {
		return 0;
	}
	if (const auto &online = g_game().getPlayerByName(name)) {
		return online->getAccountId();
	}
	Database &db = Database::getInstance();
	const auto worldId = g_game().worlds().getCurrentWorld()->id;
	const std::string query = fmt::format(
		"SELECT `account_id` FROM `players` WHERE `name` = {} AND `world_id` = {} AND `deletion` = 0 LIMIT 1",
		db.escapeString(name), worldId
	);
	const DBResult_ptr result = db.storeQuery(query);
	if (!result) {
		return 0;
	}
	return result->getNumber<uint32_t>("account_id");
}

bool IOFriend::isAccountPremium(uint32_t accountId) {
	const std::string query = fmt::format("SELECT `premdays`, `lastday` FROM `accounts` WHERE `id` = {}", accountId);
	const DBResult_ptr result = Database::getInstance().storeQuery(query);
	if (!result) {
		return false;
	}
	const auto premDays = result->getNumber<uint32_t>("premdays");
	const auto lastDay = result->getNumber<time_t>("lastday");
	return premDays > 0 || lastDay > getTimeNow();
}

bool IOFriend::isAccountOnline(uint32_t accountId) {
	return findOnlinePlayerOnAccount(accountId) != nullptr;
}

bool IOFriend::isSameAccount(uint32_t accountId, uint32_t otherAccountId) {
	return accountId != 0 && accountId == otherAccountId;
}

bool IOFriend::enrichFriendRow(uint32_t friendAccountId, uint8_t group, FriendSystemFriendRow &row) {
	row.group = normalizeGroupByte(group);
	if (const auto &online = findOnlinePlayerOnAccount(friendAccountId)) {
		fillRowFromPlayer(online, row);
		return true;
	}
	fillRowFromDb(friendAccountId, row);
	row.group = normalizeGroupByte(group);
	return true;
}

std::vector<FriendSystemFriendRow> IOFriend::loadFriendList(uint32_t accountId) {
	std::vector<FriendSystemFriendRow> rows;
	const std::string query = fmt::format(
		"SELECT `friend_account_id`, `group` FROM `account_friends` WHERE `account_id` = {} ORDER BY `created` ASC",
		accountId
	);
	const DBResult_ptr result = Database::getInstance().storeQuery(query);
	if (!result) {
		return rows;
	}
	do {
		FriendSystemFriendRow row;
		const uint32_t friendAccountId = result->getNumber<uint32_t>("friend_account_id");
		const uint8_t group = result->getNumber<uint16_t>("group");
		enrichFriendRow(friendAccountId, group, row);
		rows.emplace_back(std::move(row));
	} while (result->next());
	return rows;
}

void IOFriend::loadInviteLists(uint32_t accountId, std::vector<FriendSystemInviteRow> &received, std::vector<FriendSystemInviteRow> &sent) {
	received.clear();
	sent.clear();

	const std::string recvQuery = fmt::format(
		"SELECT `from_account_id`, `created` FROM `account_friend_invites` WHERE `to_account_id` = {} ORDER BY `created` ASC",
		accountId
	);
	if (const DBResult_ptr result = Database::getInstance().storeQuery(recvQuery)) {
		do {
			const uint32_t fromAccountId = result->getNumber<uint32_t>("from_account_id");
			received.push_back({
				.guid = fromAccountId,
				.name = displayNameForAccount(fromAccountId),
				.created = result->getNumber<uint32_t>("created"),
			});
		} while (result->next());
	}

	const std::string sentQuery = fmt::format(
		"SELECT `to_account_id`, `created` FROM `account_friend_invites` WHERE `from_account_id` = {} ORDER BY `created` ASC",
		accountId
	);
	if (const DBResult_ptr result = Database::getInstance().storeQuery(sentQuery)) {
		do {
			const uint32_t toAccountId = result->getNumber<uint32_t>("to_account_id");
			sent.push_back({
				.guid = toAccountId,
				.name = displayNameForAccount(toAccountId),
				.created = result->getNumber<uint32_t>("created"),
			});
		} while (result->next());
	}
}

std::vector<FriendSystemInviteRow> IOFriend::loadBlacklist(uint32_t accountId) {
	std::vector<FriendSystemInviteRow> rows;
	const std::string query = fmt::format(
		"SELECT `blocked_account_id`, `created` FROM `account_friend_blacklist` WHERE `account_id` = {} ORDER BY `created` ASC",
		accountId
	);
	const DBResult_ptr result = Database::getInstance().storeQuery(query);
	if (!result) {
		return rows;
	}
	do {
		const uint32_t blockedId = result->getNumber<uint32_t>("blocked_account_id");
		rows.push_back({
			.guid = blockedId,
			.name = displayNameForAccount(blockedId),
			.created = result->getNumber<uint32_t>("created"),
		});
	} while (result->next());
	return rows;
}

std::vector<FriendSystemSettingRow> IOFriend::loadSettings(uint32_t accountId) {
	std::vector<FriendSystemSettingRow> rows;
	const std::string query = fmt::format(
		"SELECT `setting_type`, `show_character`, `show_account`, `allow_inspect`, `enable_character`, `enable_account`, `enable_inspect` "
		"FROM `account_friend_settings` WHERE `account_id` = {} ORDER BY `setting_type` ASC",
		accountId
	);
	const DBResult_ptr result = Database::getInstance().storeQuery(query);
	if (result) {
		do {
			rows.push_back({
				.settingType = static_cast<uint8_t>(result->getNumber<uint16_t>("setting_type")),
				.showCharacter = result->getNumber<uint16_t>("show_character") != 0,
				.showAccount = result->getNumber<uint16_t>("show_account") != 0,
				.allowInspect = result->getNumber<uint16_t>("allow_inspect") != 0,
				.enableCharacter = result->getNumber<uint16_t>("enable_character") != 0,
				.enableAccount = result->getNumber<uint16_t>("enable_account") != 0,
				.enableInspect = result->getNumber<uint16_t>("enable_inspect") != 0,
			});
		} while (result->next());
	}
	if (rows.empty()) {
		for (uint8_t settingType = 0; settingType < 4; ++settingType) {
			rows.push_back({ .settingType = settingType });
		}
	}
	return rows;
}

bool IOFriend::sendInvite(uint32_t fromAccountId, uint32_t toAccountId) {
	const auto now = static_cast<uint32_t>(getTimeNow());
	const std::string query = fmt::format(
		"INSERT INTO `account_friend_invites` (`from_account_id`, `to_account_id`, `created`) VALUES ({}, {}, {}) "
		"ON DUPLICATE KEY UPDATE `created` = VALUES(`created`)",
		fromAccountId, toAccountId, now
	);
	return Database::getInstance().executeQuery(query);
}

bool IOFriend::acceptInvite(uint32_t accepterAccountId, uint32_t fromAccountId) {
	Database &db = Database::getInstance();
	const auto now = static_cast<uint32_t>(getTimeNow());
	if (!db.executeQuery(fmt::format(
			"DELETE FROM `account_friend_invites` WHERE `from_account_id` = {} AND `to_account_id` = {}",
			fromAccountId, accepterAccountId
		))) {
		return false;
	}
	db.executeQuery(fmt::format(
		"DELETE FROM `account_friend_invites` WHERE `from_account_id` = {} AND `to_account_id` = {}",
		accepterAccountId, fromAccountId
	));
	const std::string insert = fmt::format(
		"INSERT IGNORE INTO `account_friends` (`account_id`, `friend_account_id`, `group`, `created`) VALUES "
		"({}, {}, 2, {}), ({}, {}, 2, {})",
		accepterAccountId, fromAccountId, now, fromAccountId, accepterAccountId, now
	);
	return db.executeQuery(insert);
}

bool IOFriend::declineInvite(uint32_t declinerAccountId, uint32_t fromAccountId) {
	return Database::getInstance().executeQuery(fmt::format(
		"DELETE FROM `account_friend_invites` WHERE `from_account_id` = {} AND `to_account_id` = {}",
		fromAccountId, declinerAccountId
	));
}

bool IOFriend::cancelInvite(uint32_t senderAccountId, uint32_t toAccountId) {
	return Database::getInstance().executeQuery(fmt::format(
		"DELETE FROM `account_friend_invites` WHERE `from_account_id` = {} AND `to_account_id` = {}",
		senderAccountId, toAccountId
	));
}

bool IOFriend::removeFriend(uint32_t accountId, uint32_t friendAccountId) {
	Database &db = Database::getInstance();
	db.executeQuery(fmt::format(
		"DELETE FROM `account_friends` WHERE `account_id` = {} AND `friend_account_id` = {}",
		accountId, friendAccountId
	));
	db.executeQuery(fmt::format(
		"DELETE FROM `account_friends` WHERE `account_id` = {} AND `friend_account_id` = {}",
		friendAccountId, accountId
	));
	return true;
}

bool IOFriend::changeFriendGroup(uint32_t accountId, uint32_t friendAccountId, uint8_t group) {
	return Database::getInstance().executeQuery(fmt::format(
		"UPDATE `account_friends` SET `group` = {} WHERE `account_id` = {} AND `friend_account_id` = {}",
		normalizeGroupByte(group), accountId, friendAccountId
	));
}

bool IOFriend::addBlacklist(uint32_t accountId, uint32_t blockedAccountId) {
	const auto now = static_cast<uint32_t>(getTimeNow());
	return Database::getInstance().executeQuery(fmt::format(
		"INSERT IGNORE INTO `account_friend_blacklist` (`account_id`, `blocked_account_id`, `created`) VALUES ({}, {}, {})",
		accountId, blockedAccountId, now
	));
}

bool IOFriend::removeBlacklist(uint32_t accountId, uint32_t blockedAccountId) {
	return Database::getInstance().executeQuery(fmt::format(
		"DELETE FROM `account_friend_blacklist` WHERE `account_id` = {} AND `blocked_account_id` = {}",
		accountId, blockedAccountId
	));
}

bool IOFriend::saveSetting(uint32_t accountId, const FriendActionTarget &target) {
	return Database::getInstance().executeQuery(fmt::format(
		"INSERT INTO `account_friend_settings` (`account_id`, `setting_type`, `show_character`, `show_account`, `allow_inspect`, "
		"`enable_character`, `enable_account`, `enable_inspect`) VALUES ({}, {}, {}, {}, {}, 1, 1, 1) "
		"ON DUPLICATE KEY UPDATE `show_character` = VALUES(`show_character`), `show_account` = VALUES(`show_account`), "
		"`allow_inspect` = VALUES(`allow_inspect`)",
		accountId,
		target.settingType,
		target.showCharacter ? 1 : 0,
		target.showAccount ? 1 : 0,
		target.allowInspect ? 1 : 0
	));
}

bool IOFriend::searchAccountByCharacterName(const std::string &characterName, FriendSystemSearchResult &result) {
	const uint32_t accountId = getAccountIdByPlayerName(characterName);
	if (accountId == 0) {
		return false;
	}

	result.accountId = accountId;
	result.premium = isAccountPremium(accountId);
	result.online = isAccountOnline(accountId);
	result.lastLogin = 0;
	result.characters.clear();

	Database &db = Database::getInstance();
	const auto worldId = g_game().worlds().getCurrentWorld()->id;
	const std::string query = fmt::format(
		"SELECT `id`, `name`, `level`, `vocation`, `looktype`, `lookhead`, `lookbody`, `looklegs`, `lookfeet`, `lookaddons`, `lastlogin` "
		"FROM `players` WHERE `account_id` = {} AND `world_id` = {} AND `deletion` = 0 ORDER BY `level` DESC, `name` ASC",
		accountId, worldId
	);
	const DBResult_ptr dbResult = db.storeQuery(query);
	if (!dbResult) {
		return false;
	}
	const std::string world = worldDisplayName();
	do {
		FriendSystemSearchCharacterRow row;
		row.guid = dbResult->getNumber<uint32_t>("id");
		row.name = dbResult->getString("name");
		row.level = dbResult->getNumber<uint16_t>("level");
		row.vocation = vocationNameFromId(dbResult->getNumber<uint16_t>("vocation"));
		row.world = world;
		row.outfit = outfitFromDbRow(dbResult);
		const auto login = dbResult->getNumber<uint32_t>("lastlogin");
		if (login > result.lastLogin) {
			result.lastLogin = login;
		}
		if (const auto &online = g_game().getPlayerByName(row.name)) {
			row.online = true;
			row.creatureId = online->getID();
			row.outfit = online->getCurrentOutfit();
			row.level = online->getLevel();
			if (const auto &voc = online->getVocation()) {
				row.vocation = voc->getVocName();
			}
		}
		result.characters.emplace_back(std::move(row));
	} while (dbResult->next());
	return !result.characters.empty();
}

bool IOFriend::isFriend(uint32_t accountId, uint32_t friendAccountId) {
	const std::string query = fmt::format(
		"SELECT 1 FROM `account_friends` WHERE `account_id` = {} AND `friend_account_id` = {} LIMIT 1",
		accountId, friendAccountId
	);
	return Database::getInstance().storeQuery(query) != nullptr;
}

bool IOFriend::isBlacklisted(uint32_t accountId, uint32_t blockedAccountId) {
	const std::string query = fmt::format(
		"SELECT 1 FROM `account_friend_blacklist` WHERE `account_id` = {} AND `blocked_account_id` = {} LIMIT 1",
		accountId, blockedAccountId
	);
	return Database::getInstance().storeQuery(query) != nullptr;
}
