////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
////////////////////////////////////////////////////////////////////////

#include "lua/functions/core/game/game_functions.hpp"

#include "core.hpp"
#include <cstdint>
#include <limits>
#include "creatures/monsters/monster.hpp"
#include "creatures/monsters/monsters.hpp"
#include "creatures/npcs/npc.hpp"
#include "creatures/players/achievement/player_achievement.hpp"
#include "creatures/players/player.hpp"
#include "game/functions/game_reload.hpp"
#include "game/game.hpp"
#include "game/instance_fence.hpp"
#include "game/scheduling/dispatcher.hpp"
#include "creatures/monsters/monsters.hpp"
#ifdef IDLEOT_HAS_OCCUPANCY
#include "occupancy_mask.hpp"
#endif
#include "io/io_bosstiary.hpp"
#include "io/iobestiary.hpp"
#include "io/iologindata.hpp"
#include "items/item.hpp"
#include "lua/callbacks/event_callback.hpp"
#include "lua/callbacks/events_callbacks.hpp"
#include "lua/creature/events.hpp"
#include "lua/creature/talkaction.hpp"
#include "lua/functions/creatures/npc/npc_type_functions.hpp"
#include "lua/functions/events/event_callback_functions.hpp"
#include "lua/scripts/lua_environment.hpp"
#include "map/spectators.hpp"
#include "lua/functions/lua_functions_loader.hpp"
#include "lib/thread/thread_pool.hpp"

#include <atomic>
#include <memory>
#include <vector>

namespace {

bool placeHeadlessPlayer(const std::shared_ptr<Player> &player, Position position, bool hasPosition, uint32_t instanceId = 0) {
	if (!player) {
		return false;
	}
	player->setID();
	if (!hasPosition) {
		position = player->getLoginPosition();
	}
	// Bind before placeCreature (same pattern as Game.createMonster) so login hooks and
	// spectators see the private hunt/raid id immediately — no post-place enterInstance race.
	if (instanceId != 0) {
		player->setInstanceId(instanceId);
	}
	// Forced place so headless players can stack near the controller / temple.
	// onPlacedCreature → playerLogin must see the DB lastLoginSaved — same order as ProtocolGame.
	if (!g_game().placeCreature(player, position, false, true)
		&& !g_game().placeCreature(player, player->getTemplePosition(), false, true)) {
		return false;
	}
	player->stampLoginTimestamps();
	g_game().addCreatureCheck(player);
	player->setOnline(true);
	player->setHeadless(true);
	g_game().inheritAccountQuickLootFilter(player);
	return true;
}

void reclaimHeadlessPlayer(const std::shared_ptr<Player> &player, Position position, bool hasPosition, uint32_t instanceId) {
	if (!player) {
		return;
	}
	player->setHeadless(true);
	// Prefer bind+move together (same pattern as creature:teleportTo(..., instanceId)).
	// Same-tile setInstanceId alone is what leaves client ghosts.
	const auto &tile = player->getTile();
	const bool onMap = tile && !player->isRemoved();
	if (hasPosition && onMap && player->getPosition() != position) {
		if (instanceId != 0) {
			player->setInstanceId(instanceId);
		}
		g_game().internalTeleport(player, position, true);
	} else if (hasPosition && !onMap) {
		if (instanceId != 0) {
			player->setInstanceId(instanceId);
		}
		g_game().internalTeleport(player, position, true);
	} else if (instanceId != 0 && (!onMap || player->getInstanceId() == 0)) {
		player->setInstanceId(instanceId);
	} else if (instanceId != 0 && onMap && player->getInstanceId() != instanceId) {
		g_logger().warn(
			"[Game.headlessLogin] refusing same-tile instance rebind for '{}' ({} → {}); pass a distinct position",
			player->getName(),
			player->getInstanceId(),
			instanceId
		);
	}
	g_game().inheritAccountQuickLootFilter(player);
}

struct HeadlessBatchSlot {
	enum class Kind : uint8_t { Name, Guid };
	Kind kind = Kind::Name;
	std::string name;
	uint32_t guid = 0;
	std::shared_ptr<Player> existing;
};

struct HeadlessBatchLoadResult {
	size_t index = 0;
	std::shared_ptr<Player> player;
	bool ok = false;
	std::string error;
};

} // namespace

void GameFunctions::init(lua_State* L) {
	Lua::registerTable(L, "Game");

	Lua::registerMethod(L, "Game", "createNpcType", GameFunctions::luaGameCreateNpcType);
	Lua::registerMethod(L, "Game", "createMonsterType", GameFunctions::luaGameCreateMonsterType);

	Lua::registerMethod(L, "Game", "getSpectators", GameFunctions::luaGameGetSpectators);

	Lua::registerMethod(L, "Game", "getBoostedCreature", GameFunctions::luaGameGetBoostedCreature);
	Lua::registerMethod(L, "Game", "getBestiaryList", GameFunctions::luaGameGetBestiaryList);

	Lua::registerMethod(L, "Game", "getPlayers", GameFunctions::luaGameGetPlayers);
	Lua::registerMethod(L, "Game", "loadMap", GameFunctions::luaGameLoadMap);
	Lua::registerMethod(L, "Game", "loadMapChunk", GameFunctions::luaGameloadMapChunk);
	Lua::registerMethod(L, "Game", "copyMapRegion", GameFunctions::luaGameCopyMapRegion);
#ifdef IDLEOT_HAS_OCCUPANCY
	Lua::registerMethod(L, "Game", "loadOccupancyMask", GameFunctions::luaGameLoadOccupancyMask);
#endif
	Lua::registerMethod(L, "Game", "allocateInstance", GameFunctions::luaGameAllocateInstance);
	Lua::registerMethod(L, "Game", "releaseInstance", GameFunctions::luaGameReleaseInstance);
	Lua::registerMethod(L, "Game", "setInstanceHubFence", GameFunctions::luaGameSetInstanceHubFence);
	Lua::registerMethod(L, "Game", "setInstanceAreaFence", GameFunctions::luaGameSetInstanceAreaFence);
	Lua::registerMethod(L, "Game", "setInstancePrivateFence", GameFunctions::luaGameSetInstancePrivateFence);
	Lua::registerMethod(L, "Game", "clearInstancePrivateFence", GameFunctions::luaGameClearInstancePrivateFence);
	Lua::registerMethod(L, "Game", "setInstanceFloors", GameFunctions::luaGameSetInstanceFloors);
	Lua::registerMethod(L, "Game", "canWalkInstance", GameFunctions::luaGameCanWalkInstance);
	Lua::registerMethod(L, "Game", "computeCombatPowerFromTraits", GameFunctions::luaGameComputeCombatPowerFromTraits);
	Lua::registerMethod(L, "Game", "disableWorldSpawns", GameFunctions::luaGameDisableWorldSpawns);
	Lua::registerMethod(L, "Game", "getNpcs", GameFunctions::luaGameGetNpcs);
	Lua::registerMethod(L, "Game", "getMonsters", GameFunctions::luaGameGetMonsters);

	Lua::registerMethod(L, "Game", "getExperienceForLevel", GameFunctions::luaGameGetExperienceForLevel);
	Lua::registerMethod(L, "Game", "getMonsterCount", GameFunctions::luaGameGetMonsterCount);
	Lua::registerMethod(L, "Game", "getPlayerCount", GameFunctions::luaGameGetPlayerCount);
	Lua::registerMethod(L, "Game", "getNpcCount", GameFunctions::luaGameGetNpcCount);
	Lua::registerMethod(L, "Game", "getMonsterTypes", GameFunctions::luaGameGetMonsterTypes);

	Lua::registerMethod(L, "Game", "getTowns", GameFunctions::luaGameGetTowns);
	Lua::registerMethod(L, "Game", "getHouses", GameFunctions::luaGameGetHouses);
	Lua::registerMethod(L, "Game", "createHouse", GameFunctions::luaGameCreateHouse);

	Lua::registerMethod(L, "Game", "getGameState", GameFunctions::luaGameGetGameState);
	Lua::registerMethod(L, "Game", "setGameState", GameFunctions::luaGameSetGameState);

	Lua::registerMethod(L, "Game", "getWorldType", GameFunctions::luaGameGetWorldType);

	Lua::registerMethod(L, "Game", "getReturnMessage", GameFunctions::luaGameGetReturnMessage);

	Lua::registerMethod(L, "Game", "createItem", GameFunctions::luaGameCreateItem);
	Lua::registerMethod(L, "Game", "createContainer", GameFunctions::luaGameCreateContainer);
	Lua::registerMethod(L, "Game", "createMonster", GameFunctions::luaGameCreateMonster);
	Lua::registerMethod(L, "Game", "createSoulPitMonster", GameFunctions::luaGameCreateSoulPitMonster);
	Lua::registerMethod(L, "Game", "createNpc", GameFunctions::luaGameCreateNpc);
	Lua::registerMethod(L, "Game", "generateNpc", GameFunctions::luaGameGenerateNpc);
	Lua::registerMethod(L, "Game", "createTile", GameFunctions::luaGameCreateTile);
	Lua::registerMethod(L, "Game", "createBestiaryCharm", GameFunctions::luaGameCreateBestiaryCharm);

	Lua::registerMethod(L, "Game", "createItemClassification", GameFunctions::luaGameCreateItemClassification);

	Lua::registerMethod(L, "Game", "getBestiaryCharm", GameFunctions::luaGameGetBestiaryCharm);

	Lua::registerMethod(L, "Game", "startRaid", GameFunctions::luaGameStartRaid);

	Lua::registerMethod(L, "Game", "getClientVersion", GameFunctions::luaGameGetClientVersion);
	Lua::registerMethod(L, "Game", "setImprovedRespawnZones", GameFunctions::luaGameSetImprovedRespawnZones);

	Lua::registerMethod(L, "Game", "reload", GameFunctions::luaGameReload);

	Lua::registerMethod(L, "Game", "hasDistanceEffect", GameFunctions::luaGameHasDistanceEffect);
	Lua::registerMethod(L, "Game", "hasEffect", GameFunctions::luaGameHasEffect);
	Lua::registerMethod(L, "Game", "getOfflinePlayer", GameFunctions::luaGameGetOfflinePlayer);
	Lua::registerMethod(L, "Game", "headlessLogin", GameFunctions::luaGameHeadlessLogin);
	Lua::registerMethod(L, "Game", "headlessLoginBatch", GameFunctions::luaGameHeadlessLoginBatch);
	Lua::registerMethod(L, "Game", "headlessLogout", GameFunctions::luaGameHeadlessLogout);
	Lua::registerMethod(L, "Game", "deliverCompanionFeatureUI", GameFunctions::luaGameDeliverCompanionFeatureUI);
	Lua::registerMethod(L, "Game", "getNormalizedPlayerName", GameFunctions::luaGameGetNormalizedPlayerName);
	Lua::registerMethod(L, "Game", "getNormalizedGuildName", GameFunctions::luaGameGetNormalizedGuildName);

	Lua::registerMethod(L, "Game", "addInfluencedMonster", GameFunctions::luaGameAddInfluencedMonster);
	Lua::registerMethod(L, "Game", "removeInfluencedMonster", GameFunctions::luaGameRemoveInfluencedMonster);
	Lua::registerMethod(L, "Game", "getInfluencedMonsters", GameFunctions::luaGameGetInfluencedMonsters);
	Lua::registerMethod(L, "Game", "makeFiendishMonster", GameFunctions::luaGameMakeFiendishMonster);
	Lua::registerMethod(L, "Game", "removeFiendishMonster", GameFunctions::luaGameRemoveFiendishMonster);
	Lua::registerMethod(L, "Game", "getFiendishMonsters", GameFunctions::luaGameGetFiendishMonsters);
	Lua::registerMethod(L, "Game", "getBoostedBoss", GameFunctions::luaGameGetBoostedBoss);

	Lua::registerMethod(L, "Game", "getLadderIds", GameFunctions::luaGameGetLadderIds);
	Lua::registerMethod(L, "Game", "getDummies", GameFunctions::luaGameGetDummies);

	Lua::registerMethod(L, "Game", "getTalkActions", GameFunctions::luaGameGetTalkActions);
	Lua::registerMethod(L, "Game", "getEventCallbacks", GameFunctions::luaGameGetEventCallbacks);

	Lua::registerMethod(L, "Game", "registerAchievement", GameFunctions::luaGameRegisterAchievement);
	Lua::registerMethod(L, "Game", "getAchievementInfoById", GameFunctions::luaGameGetAchievementInfoById);
	Lua::registerMethod(L, "Game", "getAchievementInfoByName", GameFunctions::luaGameGetAchievementInfoByName);
	Lua::registerMethod(L, "Game", "getSecretAchievements", GameFunctions::luaGameGetSecretAchievements);
	Lua::registerMethod(L, "Game", "getPublicAchievements", GameFunctions::luaGameGetPublicAchievements);
	Lua::registerMethod(L, "Game", "getAchievements", GameFunctions::luaGameGetAchievements);

	Lua::registerMethod(L, "Game", "getSoulCoreItems", GameFunctions::luaGameGetSoulCoreItems);
	Lua::registerMethod(L, "Game", "getMonstersByRace", GameFunctions::luaGameGetMonstersByRace);
	Lua::registerMethod(L, "Game", "getMonstersByBestiaryStars", GameFunctions::luaGameGetMonstersByBestiaryStars);
	Lua::registerMethod(L, "Game", "getTitleByName", GameFunctions::luaGameGetTitleByName);

	Lua::registerMethod(L, "Game", "getHouseCountByAccount", GameFunctions::luaHouseGetHouseCountByAccount);

	Lua::registerMethod(L, "Game", "setGuildMotd", GameFunctions::luaGameSetGuildMotd);

	// Guild management functions
	Lua::registerMethod(L, "Game", "disbandGuild", GameFunctions::luaGameDisbandGuild);
	Lua::registerMethod(L, "Game", "invitePlayerToGuild", GameFunctions::luaGameInvitePlayerToGuild);
	Lua::registerMethod(L, "Game", "removePlayerFromGuild", GameFunctions::luaGameRemovePlayerFromGuild);
	Lua::registerMethod(L, "Game", "promotePlayer", GameFunctions::luaGamePromotePlayer);
	Lua::registerMethod(L, "Game", "demotePlayer", GameFunctions::luaGameDemotePlayer);
	Lua::registerMethod(L, "Game", "passLeadership", GameFunctions::luaGamePassLeadership);
	Lua::registerMethod(L, "Game", "setPlayerGuildNick", GameFunctions::luaGameSetPlayerGuildNick);
	Lua::registerMethod(L, "Game", "setRankName", GameFunctions::luaGameSetRankName);
	Lua::registerMethod(L, "Game", "createGuild", GameFunctions::luaGameCreateGuild);
	Lua::registerMethod(L, "Game", "joinGuild", GameFunctions::luaGameJoinGuild);
}

// Game
int GameFunctions::luaGameCreateMonsterType(lua_State* L) {
	// Game.createMonsterType(name[, variant = ""[, alternateName = ""]])
	if (Lua::isString(L, 1)) {
		const auto name = Lua::getString(L, 1);
		std::string uniqueName = name;
		auto variant = Lua::getString(L, 2, "");
		const auto alternateName = Lua::getString(L, 3, "");
		std::set<std::string> names;

		// if variant starts with !, then it's the only variant for this monster, so we register it with both names
		if (variant.starts_with("!")) {
			names.insert(name);
			variant = variant.substr(1);
		}
		if (!variant.empty()) {
			uniqueName = variant + "|" + name;
		}
		names.insert(uniqueName);

		if (!alternateName.empty()) {
			names.insert(alternateName);
		}

		for (const auto &checkName : names) {
			if (g_monsters().getMonsterType(checkName, true)) {
				lua_pushnil(L);
				lua_pushstring(L, fmt::format("The monster with name {} already registered", checkName).c_str());
				return 2;
			}
		}

		const auto monsterType = std::make_shared<MonsterType>(name);
		if (!monsterType) {
			lua_pushnil(L);
			lua_pushstring(L, "MonsterType is nullptr");
			return 2;
		}

		monsterType->name = name;
		if (!alternateName.empty()) {
			monsterType->name = alternateName;
		}

		monsterType->variantName = variant;
		monsterType->nameDescription = "a " + name;

		for (const auto &registerName : names) {
			if (!g_monsters().tryAddMonsterType(registerName, monsterType)) {
				lua_pushnil(L);
				lua_pushstring(L, fmt::format("The monster with name {} already registered", registerName).c_str());
				return 2;
			}
		}

		Lua::pushUserdata<MonsterType>(L, monsterType);
		Lua::setMetatable(L, -1, "MonsterType");
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameCreateNpcType(lua_State* L) {
	return NpcTypeFunctions::luaNpcTypeCreate(L);
}

int GameFunctions::luaGameGetSpectators(lua_State* L) {
	// Game.getSpectators(position[, multifloor = false[, onlyPlayer = false[, minRangeX = 0[, maxRangeX = 0[, minRangeY = 0[, maxRangeY = 0[, instanceId]]]]]]])
	const Position &position = Lua::getPosition(L, 1);
	const bool multifloor = Lua::getBoolean(L, 2, false);
	const bool onlyPlayers = Lua::getBoolean(L, 3, false);
	const auto minRangeX = Lua::getNumber<int32_t>(L, 4, 0);
	const auto maxRangeX = Lua::getNumber<int32_t>(L, 5, 0);
	const auto minRangeY = Lua::getNumber<int32_t>(L, 6, 0);
	const auto maxRangeY = Lua::getNumber<int32_t>(L, 7, 0);
	uint32_t instanceId = std::numeric_limits<uint32_t>::max();
	if (lua_gettop(L) >= 8 && !lua_isnil(L, 8)) {
		instanceId = Lua::getNumber<uint32_t>(L, 8);
	}

	Spectators spectators;

	if (onlyPlayers) {
		spectators.find<Player>(position, multifloor, minRangeX, maxRangeX, minRangeY, maxRangeY, true, instanceId);
	} else {
		spectators.find<Creature>(position, multifloor, minRangeX, maxRangeX, minRangeY, maxRangeY, true, instanceId);
	}

	lua_createtable(L, spectators.size(), 0);

	int index = 0;
	for (const auto &creature : spectators) {
		Lua::pushUserdata<Creature>(L, creature);
		Lua::setCreatureMetatable(L, -1, creature);
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetBoostedCreature(lua_State* L) {
	// Game.getBoostedCreature()
	Lua::pushString(L, g_game().getBoostedMonsterName());
	return 1;
}

int GameFunctions::luaGameGetBestiaryList(lua_State* L) {
	// Game.getBestiaryList([bool[string or BestiaryType_t]])
	lua_newtable(L);
	int index = 0;
	const bool name = Lua::getBoolean(L, 2, false);

	if (lua_gettop(L) <= 2) {
		const std::map<uint16_t, std::string> &mtype_list = g_game().getBestiaryList();
		for (const auto &ita : mtype_list) {
			if (name) {
				Lua::pushString(L, ita.second);
			} else {
				lua_pushnumber(L, ita.first);
			}
			lua_rawseti(L, -2, ++index);
		}
	} else {
		if (Lua::isNumber(L, 2)) {
			const std::map<uint16_t, std::string> tmplist = g_iobestiary().findRaceByName("CRYSTAL", false, Lua::getNumber<BestiaryType_t>(L, 2));
			for (const auto &itb : tmplist) {
				if (name) {
					Lua::pushString(L, itb.second);
				} else {
					lua_pushnumber(L, itb.first);
				}
				lua_rawseti(L, -2, ++index);
			}
		} else {
			const std::map<uint16_t, std::string> tmplist = g_iobestiary().findRaceByName(Lua::getString(L, 2));
			for (const auto &itc : tmplist) {
				if (name) {
					Lua::pushString(L, itc.second);
				} else {
					lua_pushnumber(L, itc.first);
				}
				lua_rawseti(L, -2, ++index);
			}
		}
	}
	return 1;
}

int GameFunctions::luaGameCreateSoulPitMonster(lua_State* L) {
	// Game.createSoulPitMonster(monsterName, position, [stack = 1, [, extended = false[, force = false[, master = nil[, instanceId = 0]]]]])
	const auto &monster = Monster::createMonster(Lua::getString(L, 1));
	if (!monster) {
		lua_pushnil(L);
		return 1;
	}

	bool isSummon = false;
	if (lua_gettop(L) >= 6 && lua_type(L, 6) != LUA_TNIL) {
		if (const auto &master = Lua::getCreature(L, 6)) {
			monster->setMaster(master, true);
			isSummon = true;
		}
	}
	if (lua_gettop(L) >= 7) {
		monster->setInstanceId(Lua::getNumber<uint32_t>(L, 7, 0));
	}

	const Position &position = Lua::getPosition(L, 2);
	const uint8_t stack = Lua::getNumber<uint8_t>(L, 3, 1);
	const bool extended = Lua::getBoolean(L, 4, false);
	const bool force = Lua::getBoolean(L, 5, false);
	if (g_game().placeCreature(monster, position, extended, force)) {
		monster->setSoulPitStack(stack);
		monster->onSpawn(position);

		Lua::pushUserdata<Monster>(L, monster);
		Lua::setMetatable(L, -1, "Monster");
	} else {
		if (isSummon) {
			monster->setMaster(nullptr);
		}
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameGetSoulCoreItems(lua_State* L) {
	// Game.getSoulCoreItems()
	std::vector<const ItemType*> soulCoreItems;
	for (const auto &itemType : Item::items.getItems()) {
		if (itemType.m_primaryType == "SoulCores" || itemType.type == ITEM_TYPE_SOULCORES) {
			soulCoreItems.emplace_back(&itemType);
		}
	}
	lua_createtable(L, soulCoreItems.size(), 0);
	int index = 0;
	for (const auto* itemType : soulCoreItems) {
		Lua::pushUserdata<const ItemType>(L, itemType);
		Lua::setMetatable(L, -1, "ItemType");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetMonstersByRace(lua_State* L) {
	// Game.getMonstersByRace(race)
	const BestiaryType_t race = Lua::getNumber<BestiaryType_t>(L, 1);
	const auto monstersByRace = g_monsters().getMonstersByRace(race);
	lua_createtable(L, monstersByRace.size(), 0);
	int index = 0;
	for (const auto &monsterType : monstersByRace) {
		Lua::pushUserdata<MonsterType>(L, monsterType);
		Lua::setMetatable(L, -1, "MonsterType");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetMonstersByBestiaryStars(lua_State* L) {
	// Game.getMonstersByBestiaryStars(stars)
	const uint8_t stars = Lua::getNumber<uint8_t>(L, 1);
	const auto monstersByStars = g_monsters().getMonstersByBestiaryStars(stars);
	lua_createtable(L, monstersByStars.size(), 0);
	int index = 0;
	for (const auto &monsterType : monstersByStars) {
		Lua::pushUserdata<MonsterType>(L, monsterType);
		Lua::setMetatable(L, -1, "MonsterType");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetPlayers(lua_State* L) {
	// Game.getPlayers()
	lua_createtable(L, g_game().getPlayersOnline(), 0);

	int index = 0;
	for (const auto &playerEntry : g_game().getPlayers()) {
		Lua::pushUserdata<Player>(L, playerEntry.second);
		Lua::setMetatable(L, -1, "Player");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameLoadMap(lua_State* L) {
	// Game.loadMap(path)
	const std::string &path = Lua::getString(L, 1);
	g_dispatcher().addEvent([path]() { g_game().loadMap(path); }, __FUNCTION__);
	return 0;
}

int GameFunctions::luaGameloadMapChunk(lua_State* L) {
	// Game.loadMapChunk(path, position, remove)
	const std::string &path = Lua::getString(L, 1);
	const Position &position = Lua::getPosition(L, 2);
	g_dispatcher().addEvent([path, position]() { g_game().loadMap(path, position); }, __FUNCTION__);
	return 0;
}

int GameFunctions::luaGameCopyMapRegion(lua_State* L) {
	// Game.copyMapRegion(sourceFrom, sourceTo, dest)
	const Position &sourceFrom = Lua::getPosition(L, 1);
	const Position &sourceTo = Lua::getPosition(L, 2);
	const Position &dest = Lua::getPosition(L, 3);
	lua_pushnumber(L, g_game().copyMapRegion(sourceFrom, sourceTo, dest));
	return 1;
}

#ifdef IDLEOT_HAS_OCCUPANCY
namespace {
	int luaOccupancyMaskContains(lua_State* L) {
		// occupancy:contains(worldX, worldY)
		lua_getfield(L, 1, "originX");
		const auto originX = Lua::getNumber<int32_t>(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 1, "originY");
		const auto originY = Lua::getNumber<int32_t>(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 1, "width");
		const auto width = Lua::getNumber<int32_t>(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 1, "height");
		const auto height = Lua::getNumber<int32_t>(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 1, "bits");
		size_t bitsLen = 0;
		const char* bits = lua_tolstring(L, -1, &bitsLen);
		lua_pop(L, 1);

		const auto worldX = Lua::getNumber<int32_t>(L, 2);
		const auto worldY = Lua::getNumber<int32_t>(L, 3);
		const int32_t lx = worldX - originX;
		const int32_t ly = worldY - originY;
		if (bits == nullptr || width <= 0 || height <= 0 || lx < 0 || ly < 0 || lx >= width || ly >= height) {
			lua_pushboolean(L, 0);
			return 1;
		}
		const size_t i = static_cast<size_t>(ly) * static_cast<size_t>(width) + static_cast<size_t>(lx);
		const size_t byteIndex = i >> 3;
		if (byteIndex >= bitsLen) {
			lua_pushboolean(L, 0);
			return 1;
		}
		lua_pushboolean(L, (static_cast<uint8_t>(bits[byteIndex]) & (1u << (i & 7))) != 0);
		return 1;
	}
}

int GameFunctions::luaGameLoadOccupancyMask(lua_State* L) {
	// Game.loadOccupancyMask(path, originX, originY)
	const auto path = Lua::getString(L, 1);
	const auto originX = Lua::getNumber<int32_t>(L, 2);
	const auto originY = Lua::getNumber<int32_t>(L, 3);
	OccupancyMask occ;
	if (!loadOccupancyMaskFile(path, originX, originY, occ)) {
		lua_pushnil(L);
		return 1;
	}
	lua_createtable(L, 0, 7);
	Lua::setField(L, "originX", occ.originX);
	Lua::setField(L, "originY", occ.originY);
	Lua::setField(L, "width", occ.width);
	Lua::setField(L, "height", occ.height);
	Lua::setField(L, "tiles", occ.tiles);
	lua_pushlstring(L, reinterpret_cast<const char*>(occ.bits.data()), occ.bits.size());
	lua_setfield(L, -2, "bits");
	lua_pushcfunction(L, luaOccupancyMaskContains);
	lua_setfield(L, -2, "contains");
	return 1;
}
#endif

int GameFunctions::luaGameAllocateInstance(lua_State* L) {
	// Game.allocateInstance()
	const uint32_t id = g_game().allocateInstanceId();
	if (id == 0) {
		lua_pushnil(L);
		return 1;
	}
	lua_pushnumber(L, id);
	return 1;
}

int GameFunctions::luaGameReleaseInstance(lua_State* L) {
	// Game.releaseInstance(id)
	g_game().releaseInstanceId(Lua::getNumber<uint32_t>(L, 1));
	Lua::pushBoolean(L, true);
	return 1;
}

namespace {
	std::vector<uint8_t> readFloorList(lua_State* L, int index) {
		std::vector<uint8_t> floors;
		if (!lua_istable(L, index)) {
			return floors;
		}
		const int absIndex = index > 0 ? index : lua_gettop(L) + index + 1;
		lua_pushnil(L);
		while (lua_next(L, absIndex) != 0) {
			int z = -1;
			if (lua_isnumber(L, -1)) {
				z = static_cast<int>(lua_tonumber(L, -1));
			} else if (lua_isnumber(L, -2) && lua_toboolean(L, -1)) {
				z = static_cast<int>(lua_tonumber(L, -2));
			}
			if (z >= 0 && z <= 15) {
				floors.push_back(static_cast<uint8_t>(z));
			}
			lua_pop(L, 1);
		}
		return floors;
	}

	bool readOccupancyFromTable(lua_State* L, int index, InstanceFenceRegistry::Occupancy &out) {
		if (!lua_istable(L, index)) {
			return false;
		}
		const int absIndex = index > 0 ? index : lua_gettop(L) + index + 1;
		lua_getfield(L, absIndex, "originX");
		lua_getfield(L, absIndex, "originY");
		lua_getfield(L, absIndex, "width");
		lua_getfield(L, absIndex, "height");
		lua_getfield(L, absIndex, "bits");
		if (!lua_isnumber(L, -5) || !lua_isnumber(L, -4) || !lua_isnumber(L, -3) || !lua_isnumber(L, -2) || !lua_isstring(L, -1)) {
			lua_pop(L, 5);
			return false;
		}
		out.originX = static_cast<int32_t>(lua_tonumber(L, -5));
		out.originY = static_cast<int32_t>(lua_tonumber(L, -4));
		out.width = static_cast<int32_t>(lua_tonumber(L, -3));
		out.height = static_cast<int32_t>(lua_tonumber(L, -2));
		size_t len = 0;
		const char* bits = lua_tolstring(L, -1, &len);
		out.bits.assign(bits, bits + len);
		lua_pop(L, 5);
		return out.width > 0 && out.height > 0 && !out.bits.empty();
	}

	InstanceFenceRegistry::Fence makeFenceFromLua(lua_State* L, int occIndex, int aabbIndex, int floorsIndex, bool allFloors) {
		InstanceFenceRegistry::Fence fence;
		fence.allFloors = allFloors;
		if (floorsIndex != 0) {
			fence.floors = readFloorList(L, floorsIndex);
			if (!fence.floors.empty()) {
				fence.allFloors = false;
			}
		}
		InstanceFenceRegistry::Occupancy occ;
		if (occIndex != 0 && readOccupancyFromTable(L, occIndex, occ)) {
			fence.occupancy = std::move(occ);
		} else if (aabbIndex != 0 && lua_istable(L, aabbIndex)) {
			const int absAabb = aabbIndex > 0 ? aabbIndex : lua_gettop(L) + aabbIndex + 1;
			lua_getfield(L, absAabb, "x");
			lua_getfield(L, absAabb, "y");
			lua_getfield(L, absAabb, "w");
			lua_getfield(L, absAabb, "h");
			if (lua_isnumber(L, -4) && lua_isnumber(L, -3) && lua_isnumber(L, -2) && lua_isnumber(L, -1)) {
				InstanceFenceRegistry::Aabb box;
				box.x = static_cast<int32_t>(lua_tonumber(L, -4));
				box.y = static_cast<int32_t>(lua_tonumber(L, -3));
				box.w = static_cast<int32_t>(lua_tonumber(L, -2));
				box.h = static_cast<int32_t>(lua_tonumber(L, -1));
				if (box.w > 0 && box.h > 0) {
					fence.aabb = box;
				}
			}
			lua_pop(L, 4);
		}
		return fence;
	}
} // namespace

int GameFunctions::luaGameSetInstanceHubFence(lua_State* L) {
	// Game.setInstanceHubFence(centerX, centerY[, radius = 40[, floors]])
	const auto cx = Lua::getNumber<int32_t>(L, 1);
	const auto cy = Lua::getNumber<int32_t>(L, 2);
	const auto radius = Lua::getNumber<int32_t>(L, 3, InstanceFenceRegistry::DEFAULT_HUB_WALK_RADIUS);
	std::vector<uint8_t> floors;
	if (lua_gettop(L) >= 4) {
		floors = readFloorList(L, 4);
	}
	g_instanceFences().setHub(cx, cy, radius, floors);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameSetInstanceAreaFence(lua_State* L) {
	// Game.setInstanceAreaFence(areaId, occupancyTable[, boundaryTable])
	// Cities/settlements: all floors. occupancyTable from Game.loadOccupancyMask.
	const auto areaId = Lua::getNumber<uint32_t>(L, 1);
	auto fence = makeFenceFromLua(L, 2, lua_gettop(L) >= 3 ? 3 : 0, 0, true);
	g_instanceFences().setAreaFence(areaId, std::move(fence));
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameSetInstancePrivateFence(lua_State* L) {
	// Game.setInstancePrivateFence(instanceId, occupancyTable[, boundaryTable[, floors]])
	const auto instanceId = Lua::getNumber<uint32_t>(L, 1);
	const int top = lua_gettop(L);
	auto fence = makeFenceFromLua(L, 2, top >= 3 ? 3 : 0, top >= 4 ? 4 : 0, false);
	g_instanceFences().setPrivateFence(instanceId, std::move(fence));
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameClearInstancePrivateFence(lua_State* L) {
	// Game.clearInstancePrivateFence(instanceId)
	g_instanceFences().clearPrivateFence(Lua::getNumber<uint32_t>(L, 1));
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameSetInstanceFloors(lua_State* L) {
	// Game.setInstanceFloors(instanceId, floorsTable|nil)
	const auto instanceId = Lua::getNumber<uint32_t>(L, 1);
	if (lua_isnoneornil(L, 2)) {
		g_instanceFences().setFloors(instanceId, {}, true);
	} else {
		auto floors = readFloorList(L, 2);
		g_instanceFences().setFloors(instanceId, floors, floors.empty());
	}
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameCanWalkInstance(lua_State* L) {
	// Game.canWalkInstance(creature, position)
	const auto &creature = Lua::getUserdataShared<Creature>(L, 1);
	if (!creature) {
		Lua::pushBoolean(L, true);
		return 1;
	}
	const Position &pos = Lua::getPosition(L, 2);
	Lua::pushBoolean(L, g_game().canWalkInstance(creature, pos));
	return 1;
}

int GameFunctions::luaGameComputeCombatPowerFromTraits(lua_State* L) {
	// Game.computeCombatPowerFromTraits(traitsTable)
	// Keys: health|hp, expectedDps, expectedHealDps, armor, defense, mitigation,
	//       meanElementPercent, speed
	if (!lua_istable(L, 1)) {
		lua_pushnumber(L, 0);
		return 1;
	}
	auto read = [L](const char* a, const char* b = nullptr) {
		lua_getfield(L, 1, a);
		if (lua_isnil(L, -1) && b) {
			lua_pop(L, 1);
			lua_getfield(L, 1, b);
		}
		const double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 0.0;
		lua_pop(L, 1);
		return v;
	};
	const double health = read("health", "hp");
	const double expectedDps = read("expectedDps", "expected_dps");
	const double expectedHealDps = read("expectedHealDps", "expected_heal_dps");
	const double armor = read("armor");
	const double defense = read("defense");
	const double mitigation = read("mitigation");
	const double meanElement = read("meanElementPercent", "mean_element_percent");
	const double speed = read("speed");
	lua_pushnumber(L, computeCombatPowerFromTraits(health, expectedDps, expectedHealDps, armor, defense, mitigation, meanElement, speed));
	return 1;
}

int GameFunctions::luaGameDisableWorldSpawns(lua_State* L) {
	// Game.disableWorldSpawns()
	g_game().disableWorldSpawns();
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameGetNpcs(lua_State* L) {
	// Game.getNpcs()
	lua_createtable(L, static_cast<int>(g_game().getNpcs().size()), 0);
	int index = 0;
	for (const auto &[id, npc] : g_game().getNpcs()) {
		Lua::pushUserdata<Npc>(L, npc);
		Lua::setMetatable(L, -1, "Npc");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetMonsters(lua_State* L) {
	// Game.getMonsters()
	lua_createtable(L, static_cast<int>(g_game().getMonsters().size()), 0);
	int index = 0;
	for (const auto &[id, monster] : g_game().getMonsters()) {
		Lua::pushUserdata<Monster>(L, monster);
		Lua::setMetatable(L, -1, "Monster");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetExperienceForLevel(lua_State* L) {
	// Game.getExperienceForLevel(level)
	const uint32_t level = Lua::getNumber<uint32_t>(L, 1);
	if (level == 0) {
		Lua::reportErrorFunc("Level must be greater than 0.");
	} else {
		lua_pushnumber(L, Player::getExpForLevel(level));
	}
	return 1;
}

int GameFunctions::luaGameGetMonsterCount(lua_State* L) {
	// Game.getMonsterCount()
	lua_pushnumber(L, g_game().getMonstersOnline());
	return 1;
}

int GameFunctions::luaGameGetPlayerCount(lua_State* L) {
	// Game.getPlayerCount()
	lua_pushnumber(L, g_game().getPlayersOnline());
	return 1;
}

int GameFunctions::luaGameGetNpcCount(lua_State* L) {
	// Game.getNpcCount()
	lua_pushnumber(L, g_game().getNpcsOnline());
	return 1;
}

int GameFunctions::luaGameGetMonsterTypes(lua_State* L) {
	// Game.getMonsterTypes()
	const auto type = g_monsters().monsters;
	lua_createtable(L, type.size(), 0);

	for (const auto &[typeName, mType] : type) {
		Lua::pushUserdata<MonsterType>(L, mType);
		Lua::setMetatable(L, -1, "MonsterType");
		lua_setfield(L, -2, typeName.c_str());
	}
	return 1;
}

int GameFunctions::luaGameGetTowns(lua_State* L) {
	// Game.getTowns()
	const auto towns = g_game().map.towns.getTowns();
	lua_createtable(L, towns.size(), 0);

	int index = 0;
	for (const auto &townEntry : towns) {
		Lua::pushUserdata<Town>(L, townEntry.second);
		Lua::setMetatable(L, -1, "Town");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetHouses(lua_State* L) {
	// Game.getHouses()
	const auto houses = g_game().map.houses.getHouses();
	lua_createtable(L, houses.size(), 0);

	int index = 0;
	for (const auto &houseEntry : houses) {
		if (houseEntry.second->isEphemeral()) {
			continue;
		}
		Lua::pushUserdata<House>(L, houseEntry.second);
		Lua::setMetatable(L, -1, "House");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameCreateHouse(lua_State* L) {
	// Game.createHouse(houseId)
	const uint32_t houseId = Lua::getNumber<uint32_t>(L, 1);
	const auto &house = g_game().map.houses.addHouse(houseId);
	Lua::pushUserdata<House>(L, house);
	Lua::setMetatable(L, -1, "House");
	return 1;
}

int GameFunctions::luaGameGetGameState(lua_State* L) {
	// Game.getGameState()
	lua_pushnumber(L, g_game().getGameState());
	return 1;
}

int GameFunctions::luaGameSetGameState(lua_State* L) {
	// Game.setGameState(state)
	const GameState_t state = Lua::getNumber<GameState_t>(L, 1);
	g_game().setGameState(state);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameGetWorldType(lua_State* L) {
	// Game.getWorldType()
	lua_pushnumber(L, g_game().worlds().getCurrentWorld()->type);
	return 1;
}

int GameFunctions::luaGameGetReturnMessage(lua_State* L) {
	// Game.getReturnMessage(value)
	const ReturnValue value = Lua::getNumber<ReturnValue>(L, 1);
	Lua::pushString(L, getReturnMessage(value));
	return 1;
}

int GameFunctions::luaGameCreateItem(lua_State* L) {
	// Game.createItem(itemId or name[, count[, position]])
	uint16_t itemId;
	if (Lua::isNumber(L, 1)) {
		itemId = Lua::getNumber<uint16_t>(L, 1);
	} else {
		itemId = Item::items.getItemIdByName(Lua::getString(L, 1));
		if (itemId == 0) {
			lua_pushnil(L);
			return 1;
		}
	}

	const auto count = Lua::getNumber<int32_t>(L, 2, 1);
	int32_t itemCount = 1;
	int32_t subType = 1;

	const ItemType &it = Item::items[itemId];
	if (it.hasSubType()) {
		if (it.stackable) {
			itemCount = std::ceil(count / static_cast<float_t>(it.stackSize));
		}

		subType = count;
	} else {
		itemCount = std::max<int32_t>(1, count);
	}

	Position position;
	if (lua_gettop(L) >= 3) {
		position = Lua::getPosition(L, 3);
	}

	const bool hasTable = itemCount > 1;
	if (hasTable) {
		lua_newtable(L);
	} else if (itemCount == 0) {
		lua_pushnil(L);
		return 1;
	}

	for (int32_t i = 1; i <= itemCount; ++i) {
		int32_t stackCount = subType;
		if (it.stackable) {
			stackCount = std::min<int32_t>(stackCount, it.stackSize);
			subType -= stackCount;
		}

		const auto &item = Item::CreateItem(itemId, stackCount);
		if (!item) {
			if (!hasTable) {
				lua_pushnil(L);
			}
			return 1;
		}

		if (position.x != 0) {
			const auto &tile = g_game().map.getTile(position);
			if (!tile) {
				if (!hasTable) {
					lua_pushnil(L);
				}
				return 1;
			}

			ReturnValue ret = g_game().internalAddItem(tile, item, INDEX_WHEREEVER, FLAG_NOLIMIT);
			if (ret != RETURNVALUE_NOERROR) {
				if (!hasTable) {
					lua_pushnil(L);
				}
				return 1;
			}
		} else {
			Lua::getScriptEnv()->addTempItem(item);
			item->setParent(VirtualCylinder::virtualCylinder);
		}

		if (hasTable) {
			lua_pushnumber(L, i);
			Lua::pushUserdata<Item>(L, item);
			Lua::setItemMetatable(L, -1, item);
			lua_settable(L, -3);
		} else {
			Lua::pushUserdata<Item>(L, item);
			Lua::setItemMetatable(L, -1, item);
		}
	}

	return 1;
}

int GameFunctions::luaGameCreateContainer(lua_State* L) {
	// Game.createContainer(itemId, size[, position])
	const uint16_t size = Lua::getNumber<uint16_t>(L, 2);
	uint16_t id;
	if (Lua::isNumber(L, 1)) {
		id = Lua::getNumber<uint16_t>(L, 1);
	} else {
		id = Item::items.getItemIdByName(Lua::getString(L, 1));
		if (id == 0) {
			lua_pushnil(L);
			return 1;
		}
	}

	const auto &container = Item::CreateItemAsContainer(id, size);
	if (!container) {
		lua_pushnil(L);
		return 1;
	}

	if (lua_gettop(L) >= 3) {
		const Position &position = Lua::getPosition(L, 3);
		const auto &tile = g_game().map.getTile(position);
		if (!tile) {
			lua_pushnil(L);
			return 1;
		}

		g_game().internalAddItem(tile, container, INDEX_WHEREEVER, FLAG_NOLIMIT);
	} else {
		Lua::getScriptEnv()->addTempItem(container);
		container->setParent(VirtualCylinder::virtualCylinder);
	}

	Lua::pushUserdata<Container>(L, container);
	Lua::setMetatable(L, -1, "Container");
	return 1;
}

int GameFunctions::luaGameCreateMonster(lua_State* L) {
	// Game.createMonster(monsterName, position[, extended = false[, force = false[, master = nil[, instanceId = 0]]]])
	const auto &monster = Monster::createMonster(Lua::getString(L, 1));
	if (!monster) {
		lua_pushnil(L);
		return 1;
	}

	bool isSummon = false;
	if (lua_gettop(L) >= 5 && lua_type(L, 5) != LUA_TNIL) {
		if (const auto &master = Lua::getCreature(L, 5)) {
			monster->setMaster(master, true);
			isSummon = true;
		}
	}
	if (lua_gettop(L) >= 6) {
		const auto explicitId = Lua::getNumber<uint32_t>(L, 6, 0);
		if (explicitId != 0) {
			monster->setInstanceId(explicitId);
		}
	}
	// Faceless-style script summons omit instanceId; inherit from thinking boss.
	if (monster->getInstanceId() == 0) {
		const auto actorId = Game::getInstanceActorId();
		if (actorId != 0) {
			monster->setInstanceId(actorId);
		}
	}

	const Position &position = Lua::getPosition(L, 2);
	const bool extended = Lua::getBoolean(L, 3, false);
	const bool force = Lua::getBoolean(L, 4, false);
	if (g_game().placeCreature(monster, position, extended, force)) {
		// Home for idle/walk-back (spawn tile). Expeditions overwrite with the party anchor.
		monster->setMasterPos(monster->getPosition());
		monster->onSpawn(position);
		const auto &mtype = monster->getMonsterType();
		if (mtype && mtype->info.raceid > 0 && mtype->info.bosstiaryRace == BosstiaryRarity_t::RARITY_ARCHFOE) {
			for (const auto &spectator : Spectators().find<Player>(monster->getPosition(), true, 0, 0, 0, 0, true, monster->getInstanceId())) {
				if (const auto &tmpPlayer = spectator->getPlayer()) {
					tmpPlayer->sendBosstiaryCooldownTimer();
				}
			}
		}

		Lua::pushUserdata<Monster>(L, monster);
		Lua::setMetatable(L, -1, "Monster");
	} else {
		if (isSummon) {
			monster->setMaster(nullptr);
		} else {
		}
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameGenerateNpc(lua_State* L) {
	// Game.generateNpc(npcName)
	const auto &npc = Npc::createNpc(Lua::getString(L, 1));
	if (!npc) {
		lua_pushnil(L);
		return 1;
	} else {
		Lua::pushUserdata<Npc>(L, npc);
		Lua::setMetatable(L, -1, "Npc");
	}
	return 1;
}

int GameFunctions::luaGameCreateNpc(lua_State* L) {
	// Game.createNpc(npcName, position[, extended = false[, force = false[, instanceId = 0]]])
	const auto &npc = Npc::createNpc(Lua::getString(L, 1));
	if (!npc) {
		lua_pushnil(L);
		return 1;
	}

	const Position &position = Lua::getPosition(L, 2);
	const bool extended = Lua::getBoolean(L, 3, false);
	const bool force = Lua::getBoolean(L, 4, false);
	const uint32_t instanceId = Lua::getNumber<uint32_t>(L, 5, 0);
	if (instanceId != 0) {
		npc->setInstanceId(instanceId);
	}
	if (g_game().placeCreature(npc, position, extended, force)) {
		Lua::pushUserdata<Npc>(L, npc);
		Lua::setMetatable(L, -1, "Npc");
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameCreateTile(lua_State* L) {
	// Game.createTile(x, y, z[, isDynamic = false])
	// Game.createTile(position[, isDynamic = false])
	Position position;
	bool isDynamic;
	if (Lua::isTable(L, 1)) {
		position = Lua::getPosition(L, 1);
		isDynamic = Lua::getBoolean(L, 2, false);
	} else {
		position.x = Lua::getNumber<uint16_t>(L, 1);
		position.y = Lua::getNumber<uint16_t>(L, 2);
		position.z = Lua::getNumber<uint16_t>(L, 3);
		isDynamic = Lua::getBoolean(L, 4, false);
	}

	Lua::pushUserdata(L, g_game().map.getOrCreateTile(position, isDynamic));
	Lua::setMetatable(L, -1, "Tile");
	return 1;
}

int GameFunctions::luaGameGetBestiaryCharm(lua_State* L) {
	// Game.getBestiaryCharm()
	const auto c_list = g_game().getCharmList();
	lua_createtable(L, c_list.size(), 0);

	int index = 0;
	for (const auto &charmPtr : c_list) {
		Lua::pushUserdata<Charm>(L, charmPtr);
		Lua::setMetatable(L, -1, "Charm");
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameCreateBestiaryCharm(lua_State* L) {
	// Game.createBestiaryCharm(id)
	if (const std::shared_ptr<Charm> &charm = g_iobestiary().getBestiaryCharm(static_cast<charmRune_t>(Lua::getNumber<int8_t>(L, 1, 0)), true)) {
		Lua::pushUserdata<Charm>(L, charm);
		Lua::setMetatable(L, -1, "Charm");
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameCreateItemClassification(lua_State* L) {
	// Game.createItemClassification(id)
	const ItemClassification* itemClassification = g_game().getItemsClassification(Lua::getNumber<uint8_t>(L, 1), true);
	if (itemClassification) {
		Lua::pushUserdata<const ItemClassification>(L, itemClassification);
		Lua::setMetatable(L, -1, "ItemClassification");
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameStartRaid(lua_State* L) {
	// Game.startRaid(raidName)
	const std::string &raidName = Lua::getString(L, 1);

	const auto &raid = g_game().raids.getRaidByName(raidName);
	if (!raid || !raid->isLoaded()) {
		lua_pushnumber(L, RETURNVALUE_NOSUCHRAIDEXISTS);
		return 1;
	}

	if (g_game().raids.getRunning() || raid->getState() == RAIDSTATE_EXECUTING) {
		lua_pushnumber(L, RETURNVALUE_ANOTHERRAIDISALREADYEXECUTING);
		return 1;
	}

	g_game().raids.setRunning(raid);
	raid->startRaid();
	lua_pushnumber(L, RETURNVALUE_NOERROR);
	return 1;
}

int GameFunctions::luaGameGetClientVersion(lua_State* L) {
	// Game.getClientVersion()
	lua_createtable(L, 0, 3);
	Lua::setField(L, "min", CLIENT_VERSION);
	Lua::setField(L, "max", CLIENT_VERSION);
	const std::string version = fmt::format("{}.{}", CLIENT_VERSION_UPPER, CLIENT_VERSION_LOWER);
	Lua::setField(L, "string", version);
	return 1;
}

int GameFunctions::luaGameSetImprovedRespawnZones(lua_State* L) {
	// Game.setImprovedRespawnZones(rects) ; rects = { {x1, y1, x2, y2}, ... } (whole replace)
	std::vector<ImprovedRespawnZone> zones;
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_pushnil(L);
	while (lua_next(L, 1) != 0) {
		luaL_checktype(L, -1, LUA_TTABLE);
		lua_rawgeti(L, -1, 1);
		lua_rawgeti(L, -2, 2);
		lua_rawgeti(L, -3, 3);
		lua_rawgeti(L, -4, 4);
		zones.push_back(ImprovedRespawnZone {
			static_cast<uint16_t>(luaL_checknumber(L, -4)),
			static_cast<uint16_t>(luaL_checknumber(L, -3)),
			static_cast<uint16_t>(luaL_checknumber(L, -2)),
			static_cast<uint16_t>(luaL_checknumber(L, -1)),
		});
		lua_pop(L, 5);
	}
	g_game().setImprovedRespawnZones(std::move(zones));
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameReload(lua_State* L) {
	// Game.reload(reloadType)
	const Reload_t reloadType = Lua::getNumber<Reload_t>(L, 1);
	if (GameReload::getReloadNumber(reloadType) == GameReload::getReloadNumber(Reload_t::RELOAD_TYPE_NONE)) {
		Lua::reportErrorFunc("Reload type is none");
		Lua::pushBoolean(L, false);
		return 0;
	}

	if (GameReload::getReloadNumber(reloadType) >= GameReload::getReloadNumber(Reload_t::RELOAD_TYPE_LAST)) {
		Lua::reportErrorFunc("Reload type not exist");
		Lua::pushBoolean(L, false);
		return 0;
	}

	Lua::pushBoolean(L, GameReload::init(reloadType));
	lua_gc(g_luaEnvironment().getLuaState(), LUA_GCCOLLECT, 0);
	return 1;
}

int GameFunctions::luaGameHasEffect(lua_State* L) {
	// Game.hasEffect(effectId)
	const uint16_t effectId = Lua::getNumber<uint16_t>(L, 1);
	Lua::pushBoolean(L, g_game().hasEffect(effectId));
	return 1;
}

int GameFunctions::luaGameHasDistanceEffect(lua_State* L) {
	// Game.hasDistanceEffect(effectId)
	const uint16_t effectId = Lua::getNumber<uint16_t>(L, 1);
	Lua::pushBoolean(L, g_game().hasDistanceEffect(effectId));
	return 1;
}

int GameFunctions::luaGameGetOfflinePlayer(lua_State* L) {
	// Game.getOfflinePlayer(name or id)
	std::shared_ptr<Player> player = nullptr;
	if (Lua::isNumber(L, 1)) {
		const uint32_t id = Lua::getNumber<uint32_t>(L, 1);
		if (id >= Player::getFirstID() && id <= Player::getLastID()) {
			player = g_game().getPlayerByID(id, true);
		} else {
			player = g_game().getPlayerByGUID(id, true);
		}
	} else if (Lua::isString(L, 1)) {
		const auto name = Lua::getString(L, 1);
		player = g_game().getPlayerByName(name, true);
	}
	if (!player) {
		lua_pushnil(L);
	} else {
		Lua::pushUserdata<Player>(L, player);
		Lua::setMetatable(L, -1, "Player");
	}

	return 1;
}

int GameFunctions::luaGameHeadlessLogin(lua_State* L) {
	// Game.headlessLogin(name or guid[, position[, instanceId = 0]])
	// Places a headless Player (no ProtocolGame) online.
	// NOTE: DB load is synchronous on the dispatcher — prefer headlessLoginBatch for multi-login.
	Position position;
	const bool hasPosition = lua_gettop(L) >= 2 && !Lua::isNil(L, 2);
	if (hasPosition) {
		position = Lua::getPosition(L, 2);
	}
	const uint32_t instanceId = lua_gettop(L) >= 3 ? Lua::getNumber<uint32_t>(L, 3, 0) : 0;

	std::shared_ptr<Player> existing = nullptr;
	std::string name;
	uint32_t guid = 0;
	if (Lua::isNumber(L, 1)) {
		guid = Lua::getNumber<uint32_t>(L, 1);
		existing = g_game().getPlayerByGUID(guid, false);
		if (!existing) {
			name = IOLoginData::getNameByGuid(guid);
		}
	} else if (Lua::isString(L, 1)) {
		name = Lua::getString(L, 1);
		existing = g_game().getPlayerByName(name, false);
	} else {
		lua_pushnil(L);
		return 1;
	}

	if (existing) {
		// Refuse stealing a live UI client session.
		if (!existing->isHeadless() && existing->getProtocolVersion() > 0) {
			lua_pushnil(L);
			return 1;
		}
		reclaimHeadlessPlayer(existing, position, hasPosition, instanceId);
		Lua::pushUserdata<Player>(L, existing);
		Lua::setMetatable(L, -1, "Player");
		return 1;
	}

	if (name.empty() && guid == 0) {
		lua_pushnil(L);
		return 1;
	}

	auto player = std::make_shared<Player>(nullptr);
	const bool loaded = guid != 0
		? IOLoginData::loadPlayerById(player, guid, false)
		: IOLoginData::loadPlayerByName(player, name, false);
	if (!loaded) {
		g_logger().warn("[Game.headlessLogin] load failed for '{}'/guid {}", name, guid);
		lua_pushnil(L);
		return 1;
	}

	name = player->getName();
	if (!player->getGUID()) {
		lua_pushnil(L);
		return 1;
	}

	if (!placeHeadlessPlayer(player, position, hasPosition, instanceId)) {
		g_logger().warn("[Game.headlessLogin] could not place '{}'", name);
		lua_pushnil(L);
		return 1;
	}

	g_logger().info("[Game.headlessLogin] '{}' online (headless)", player->getName());

	Lua::pushUserdata<Player>(L, player);
	Lua::setMetatable(L, -1, "Player");
	return 1;
}

int GameFunctions::luaGameHeadlessLoginBatch(lua_State* L) {
	// Game.headlessLoginBatch(names, position, callback[, instanceId = 0])
	// names: array of character name strings (and/or guids as numbers)
	// callback(players|nil, err|nil) — invoked on the game dispatcher after place.
	// DB loads run on ThreadPool so the dispatcher is not blocked.
	if (!lua_istable(L, 1) || !lua_isfunction(L, 3)) {
		lua_pushnil(L);
		Lua::pushString(L, "headlessLoginBatch(names, position, callback[, instanceId]) expected");
		return 2;
	}

	Position position;
	const bool hasPosition = !Lua::isNil(L, 2);
	if (hasPosition) {
		position = Lua::getPosition(L, 2);
	}
	const uint32_t instanceId = lua_gettop(L) >= 4 ? Lua::getNumber<uint32_t>(L, 4, 0) : 0;

	lua_pushvalue(L, 3);
	const int32_t callbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
	const auto scriptId = Lua::getScriptEnv()->getScriptId();

	std::vector<HeadlessBatchSlot> slots;
	lua_pushnil(L);
	while (lua_next(L, 1) != 0) {
		HeadlessBatchSlot slot;
		if (Lua::isNumber(L, -1)) {
			slot.kind = HeadlessBatchSlot::Kind::Guid;
			slot.guid = Lua::getNumber<uint32_t>(L, -1);
			slot.existing = g_game().getPlayerByGUID(slot.guid, false);
			if (!slot.existing) {
				slot.name = IOLoginData::getNameByGuid(slot.guid);
			}
		} else if (Lua::isString(L, -1)) {
			slot.kind = HeadlessBatchSlot::Kind::Name;
			slot.name = Lua::getString(L, -1);
			slot.existing = g_game().getPlayerByName(slot.name, false);
			if (slot.existing) {
				slot.guid = slot.existing->getGUID();
			}
		} else {
			lua_pop(L, 1);
			continue;
		}
		slots.push_back(std::move(slot));
		lua_pop(L, 1);
	}

	auto invokeCallback = [callbackRef, scriptId](const std::vector<std::shared_ptr<Player>> &players, const std::string &error) {
		lua_State* luaState = g_luaEnvironment().getLuaState();
		if (!luaState) {
			return;
		}
		if (!Lua::reserveScriptEnv()) {
			luaL_unref(luaState, LUA_REGISTRYINDEX, callbackRef);
			return;
		}

		lua_rawgeti(luaState, LUA_REGISTRYINDEX, callbackRef);
		if (!error.empty() || players.empty()) {
			lua_pushnil(luaState);
			Lua::pushString(luaState, error.empty() ? "headless login batch failed" : error);
		} else {
			lua_createtable(luaState, static_cast<int>(players.size()), 0);
			int i = 1;
			for (const auto &player : players) {
				Lua::pushUserdata<Player>(luaState, player);
				Lua::setMetatable(luaState, -1, "Player");
				lua_rawseti(luaState, -2, i++);
			}
			lua_pushnil(luaState);
		}
		const auto env = Lua::getScriptEnv();
		env->setScriptId(scriptId, &g_luaEnvironment());
		g_luaEnvironment().callFunction(2);
		luaL_unref(luaState, LUA_REGISTRYINDEX, callbackRef);
	};

	// Never invoke the Lua callback re-entrantly from this C call (script env is busy).
	auto scheduleCallback = [invokeCallback](std::vector<std::shared_ptr<Player>> players, std::string error) {
		g_dispatcher().addEvent(
			[invokeCallback, players = std::move(players), error = std::move(error)]() {
				invokeCallback(players, error);
			},
			"Game.headlessLoginBatch callback"
		);
	};

	if (slots.empty()) {
		scheduleCallback({}, "no characters to login");
		return 0;
	}

	// Claim already-online headless players on the dispatcher; queue the rest for off-thread load.
	std::vector<std::shared_ptr<Player>> claimed(slots.size());
	std::vector<size_t> needLoad;
	needLoad.reserve(slots.size());

	for (size_t i = 0; i < slots.size(); ++i) {
		auto &slot = slots[i];
		if (slot.existing) {
			if (!slot.existing->isHeadless() && slot.existing->getProtocolVersion() > 0) {
				scheduleCallback({}, fmt::format("{} is online on a real client", slot.existing->getName()));
				return 0;
			}
			reclaimHeadlessPlayer(slot.existing, position, hasPosition, instanceId);
			claimed[i] = slot.existing;
			continue;
		}
		if (slot.name.empty() && slot.guid == 0) {
			scheduleCallback({}, "invalid character identity");
			return 0;
		}
		needLoad.push_back(i);
	}

	if (needLoad.empty()) {
		std::vector<std::shared_ptr<Player>> players;
		players.reserve(claimed.size());
		for (const auto &p : claimed) {
			if (p) {
				players.push_back(p);
			}
		}
		scheduleCallback(std::move(players), {});
		return 0;
	}

	auto results = std::make_shared<std::vector<HeadlessBatchLoadResult>>(needLoad.size());
	auto remaining = std::make_shared<std::atomic<size_t>>(needLoad.size());
	auto slotsPtr = std::make_shared<std::vector<HeadlessBatchSlot>>(std::move(slots));
	auto claimedPtr = std::make_shared<std::vector<std::shared_ptr<Player>>>(std::move(claimed));

	auto finishOnDispatcher = [invokeCallback, results, slotsPtr, claimedPtr, position, hasPosition, needLoad, instanceId]() {
		std::vector<std::shared_ptr<Player>> placed;
		placed.reserve(slotsPtr->size());
		std::string firstError;

		for (size_t r = 0; r < needLoad.size(); ++r) {
			const auto &load = (*results)[r];
			const size_t slotIndex = needLoad[r];
			if (!load.ok || !load.player) {
				if (firstError.empty()) {
					firstError = load.error.empty() ? "headless load failed" : load.error;
				}
				continue;
			}

			// Another session may have logged in while we were loading.
			auto live = g_game().getPlayerByGUID(load.player->getGUID(), false);
			if (live && live.get() != load.player.get()) {
				if (!live->isHeadless() && live->getProtocolVersion() > 0) {
					if (firstError.empty()) {
						firstError = fmt::format("{} is online on a real client", live->getName());
					}
					continue;
				}
				reclaimHeadlessPlayer(live, position, hasPosition, instanceId);
				(*claimedPtr)[slotIndex] = live;
				continue;
			}

			if (!placeHeadlessPlayer(load.player, position, hasPosition, instanceId)) {
				if (firstError.empty()) {
					firstError = fmt::format("could not place '{}'", load.player->getName());
				}
				continue;
			}
			g_logger().info("[Game.headlessLoginBatch] '{}' online (headless)", load.player->getName());
			(*claimedPtr)[slotIndex] = load.player;
		}

		for (const auto &p : *claimedPtr) {
			if (p) {
				placed.push_back(p);
			}
		}

		if (!firstError.empty() || placed.size() != slotsPtr->size()) {
			for (const auto &p : placed) {
				if (p && p->isHeadless() && p->getProtocolVersion() == 0) {
					// Only roll back players we placed in this batch that were newly online.
					// Already-claimed headless companions stay up for the caller to manage.
				}
			}
			// Rollback newly placed companions from this batch so a partial deploy does not leak.
			for (size_t r = 0; r < needLoad.size(); ++r) {
				const size_t slotIndex = needLoad[r];
				auto &p = (*claimedPtr)[slotIndex];
				if (!p || (*slotsPtr)[slotIndex].existing) {
					continue;
				}
				if (p->isHeadless() && p->getProtocolVersion() == 0) {
					p->removePlayer(true, true);
				}
				p.reset();
			}
			invokeCallback({}, firstError.empty() ? "headless login batch failed" : firstError);
			return;
		}

		invokeCallback(placed, {});
	};

	for (size_t r = 0; r < needLoad.size(); ++r) {
		const size_t slotIndex = needLoad[r];
		const HeadlessBatchSlot slot = (*slotsPtr)[slotIndex];
		ThreadPool::getInstance().detach_task([results, remaining, r, slot, slotIndex, finishOnDispatcher]() {
			HeadlessBatchLoadResult out;
			out.index = slotIndex;
			auto player = std::make_shared<Player>(nullptr);
			const bool loaded = slot.kind == HeadlessBatchSlot::Kind::Guid && slot.guid != 0
				? IOLoginData::loadPlayerById(player, slot.guid, false)
				: IOLoginData::loadPlayerByName(player, slot.name, false);
			if (!loaded || !player->getGUID()) {
				out.ok = false;
				out.error = fmt::format(
					"load failed for '{}'/guid {}",
					slot.name,
					slot.guid
				);
				g_logger().warn("[Game.headlessLoginBatch] {}", out.error);
			} else {
				out.ok = true;
				out.player = std::move(player);
			}
			(*results)[r] = std::move(out);
			if (remaining->fetch_sub(1) == 1) {
				g_dispatcher().addEvent(finishOnDispatcher, "Game.headlessLoginBatch finish");
			}
		});
	}

	return 0;
}

int GameFunctions::luaGameHeadlessLogout(lua_State* L) {
	// Game.headlessLogout(player) — save + remove offline without a client.
	const auto &player = Lua::getPlayer(L, 1);
	if (!player) {
		Lua::pushBoolean(L, false);
		return 1;
	}
	if (!player->isHeadless() || player->getProtocolVersion() > 0) {
		// Refuse logging out a real session via headless API.
		Lua::pushBoolean(L, false);
		return 1;
	}

	g_logger().info("[Game.headlessLogout] '{}'", player->getName());
	player->removePlayer(true, true);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameDeliverCompanionFeatureUI(lua_State* L) {
	// Game.deliverCompanionFeatureUI(viewer, owner, feature)
	const auto &viewer = Lua::getPlayer(L, 1);
	const auto &owner = Lua::getPlayer(L, 2);
	const auto feature = Lua::getString(L, 3);
	if (!viewer || !owner || feature.empty()) {
		Lua::pushBoolean(L, false);
		return 1;
	}
	Lua::pushBoolean(L, g_game().deliverCompanionFeatureUI(viewer, owner, feature));
	return 1;
}

int GameFunctions::luaGameGetNormalizedPlayerName(lua_State* L) {
	// Game.getNormalizedPlayerName(name[, isNewName = false])
	const auto name = Lua::getString(L, 1);
	const auto isNewName = Lua::getBoolean(L, 2, false);
	const auto &player = g_game().getPlayerByName(name, true, isNewName);
	if (player) {
		Lua::pushString(L, player->getName());
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameGetNormalizedGuildName(lua_State* L) {
	// Game.getNormalizedGuildName(name)
	const auto name = Lua::getString(L, 1);
	const auto &guild = g_game().getGuildByName(name, true);
	if (guild) {
		Lua::pushString(L, guild->getName());
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int GameFunctions::luaGameAddInfluencedMonster(lua_State* L) {
	// Game.addInfluencedMonster(monster)
	const auto &monster = Lua::getUserdataShared<Monster>(L, 1);
	if (!monster) {
		Lua::reportErrorFunc(Lua::getErrorDesc(LUA_ERROR_MONSTER_NOT_FOUND));
		Lua::pushBoolean(L, false);
		return 0;
	}

	lua_pushboolean(L, g_game().addInfluencedMonster(monster));
	return 1;
}

int GameFunctions::luaGameRemoveInfluencedMonster(lua_State* L) {
	// Game.removeInfluencedMonster(monsterId)
	const uint32_t monsterId = Lua::getNumber<uint32_t>(L, 1);
	const auto create = Lua::getBoolean(L, 2, false);
	lua_pushnumber(L, g_game().removeInfluencedMonster(monsterId, create));
	return 1;
}

int GameFunctions::luaGameGetInfluencedMonsters(lua_State* L) {
	// Game.getInfluencedMonsters()
	const auto &monsters = g_game().getInfluencedMonsters();
	lua_createtable(L, static_cast<int>(monsters.size()), 0);
	int index = 0;
	for (const auto monsterId : monsters) {
		++index;
		lua_pushnumber(L, monsterId);
		lua_rawseti(L, -2, index);
	}

	return 1;
}

int GameFunctions::luaGameGetLadderIds(lua_State* L) {
	// Game.getLadderIds()
	const auto &ladders = Item::items.getLadders();
	lua_createtable(L, static_cast<int>(ladders.size()), 0);
	int index = 0;
	for (const auto &ladderId : ladders) {
		++index;
		lua_pushnumber(L, static_cast<lua_Number>(ladderId));
		lua_rawseti(L, -2, index);
	}

	return 1;
}

int GameFunctions::luaGameGetDummies(lua_State* L) {
	/**
	 * @brief Retrieve dummy IDs categorized by type.
	 * @details This function provides a table containing two sub-tables: one for free dummies and one for house (or premium) dummies.

	* @note usage on lua:
	    local dummies = Game.getDummies()
	    local rate = dummies[1] -- Retrieve dummy rate
	*/

	const auto &dummies = Item::items.getDummys();
	lua_createtable(L, dummies.size(), 0);
	for (const auto &[dummyId, rate] : dummies) {
		lua_pushnumber(L, static_cast<lua_Number>(rate));
		lua_rawseti(L, -2, dummyId);
	}
	return 1;
}

int GameFunctions::luaGameMakeFiendishMonster(lua_State* L) {
	// Game.makeFiendishMonster(monsterId[default= 0])
	const auto monsterId = Lua::getNumber<uint32_t>(L, 1, 0);
	const auto createForgeableMonsters = Lua::getBoolean(L, 2, false);
	lua_pushnumber(L, g_game().makeFiendishMonster(monsterId, createForgeableMonsters));
	return 1;
}

int GameFunctions::luaGameRemoveFiendishMonster(lua_State* L) {
	// Game.removeFiendishMonster(monsterId)
	const uint32_t monsterId = Lua::getNumber<uint32_t>(L, 1);
	const auto create = Lua::getBoolean(L, 2, false);
	lua_pushnumber(L, g_game().removeFiendishMonster(monsterId, create));
	return 1;
}

int GameFunctions::luaGameGetFiendishMonsters(lua_State* L) {
	// Game.getFiendishMonsters()
	const auto &monsters = g_game().getFiendishMonsters();

	lua_createtable(L, static_cast<int>(monsters.size()), 0);
	int index = 0;
	for (const auto monsterId : monsters) {
		++index;
		lua_pushnumber(L, monsterId);
		lua_rawseti(L, -2, index);
	}

	return 1;
}

int GameFunctions::luaGameGetBoostedBoss(lua_State* L) {
	// Game.getBoostedBoss()
	Lua::pushString(L, g_ioBosstiary().getBoostedBossName());
	return 1;
}

int GameFunctions::luaGameGetTalkActions(lua_State* L) {
	// Game.getTalkActions()
	const auto talkactionsMap = g_talkActions().getTalkActionsMap();
	lua_createtable(L, static_cast<int>(talkactionsMap.size()), 0);

	for (const auto &[talkName, talkactionSharedPtr] : talkactionsMap) {
		Lua::pushUserdata<TalkAction>(L, talkactionSharedPtr);
		Lua::setMetatable(L, -1, "TalkAction");
		lua_setfield(L, -2, talkName.c_str());
	}
	return 1;
}

int GameFunctions::luaGameGetEventCallbacks(lua_State* L) {
	lua_createtable(L, 0, 0);
	lua_pushcfunction(L, EventCallbackFunctions::luaEventCallbackLoad);
	for (const auto &[value, name] : magic_enum::enum_entries<EventCallback_t>()) {
		if (value != EventCallback_t::none) {
			std::string methodName = magic_enum::enum_name(value).data();
			lua_pushstring(L, methodName.c_str());
			// Copy the function reference to the top of the stack
			lua_pushvalue(L, -2);
			lua_settable(L, -4);
		}
	}
	// Pop the function
	lua_pop(L, 1);
	return 1;
}

int GameFunctions::luaGameRegisterAchievement(lua_State* L) {
	// Game.registerAchievement(id, name, description, secret, grade, points)
	if (lua_gettop(L) < 6) {
		Lua::reportErrorFunc("Achievement can only be registered with all params.");
		return 1;
	}

	const uint16_t id = Lua::getNumber<uint16_t>(L, 1);
	const std::string name = Lua::getString(L, 2);
	const std::string description = Lua::getString(L, 3);
	const bool secret = Lua::getBoolean(L, 4);
	const uint8_t grade = Lua::getNumber<uint8_t>(L, 5);
	const uint8_t points = Lua::getNumber<uint8_t>(L, 6);
	g_game().registerAchievement(id, name, description, secret, grade, points);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameGetAchievementInfoById(lua_State* L) {
	// Game.getAchievementInfoById(id)
	const uint16_t id = Lua::getNumber<uint16_t>(L, 1);
	const Achievement achievement = g_game().getAchievementById(id);
	if (achievement.id == 0) {
		Lua::reportErrorFunc("Achievement id is wrong");
		return 1;
	}

	lua_createtable(L, 0, 6);
	Lua::setField(L, "id", achievement.id);
	Lua::setField(L, "name", achievement.name);
	Lua::setField(L, "description", achievement.description);
	Lua::setField(L, "points", achievement.points);
	Lua::setField(L, "grade", achievement.grade);
	Lua::setField(L, "secret", achievement.secret);
	return 1;
}

int GameFunctions::luaGameGetAchievementInfoByName(lua_State* L) {
	// Game.getAchievementInfoByName(name)
	const std::string name = Lua::getString(L, 1);
	const Achievement achievement = g_game().getAchievementByName(name);
	if (achievement.id == 0) {
		Lua::reportErrorFunc("Achievement name is wrong");
		return 1;
	}

	lua_createtable(L, 0, 6);
	Lua::setField(L, "id", achievement.id);
	Lua::setField(L, "name", achievement.name);
	Lua::setField(L, "description", achievement.description);
	Lua::setField(L, "points", achievement.points);
	Lua::setField(L, "grade", achievement.grade);
	Lua::setField(L, "secret", achievement.secret);
	return 1;
}

int GameFunctions::luaGameGetSecretAchievements(lua_State* L) {
	// Game.getSecretAchievements()
	const std::vector<Achievement> &achievements = g_game().getSecretAchievements();
	int index = 0;
	lua_createtable(L, achievements.size(), 0);
	for (const auto &achievement : achievements) {
		lua_createtable(L, 0, 6);
		Lua::setField(L, "id", achievement.id);
		Lua::setField(L, "name", achievement.name);
		Lua::setField(L, "description", achievement.description);
		Lua::setField(L, "points", achievement.points);
		Lua::setField(L, "grade", achievement.grade);
		Lua::setField(L, "secret", achievement.secret);
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetPublicAchievements(lua_State* L) {
	// Game.getPublicAchievements()
	const std::vector<Achievement> &achievements = g_game().getPublicAchievements();
	int index = 0;
	lua_createtable(L, achievements.size(), 0);
	for (const auto &achievement : achievements) {
		lua_createtable(L, 0, 6);
		Lua::setField(L, "id", achievement.id);
		Lua::setField(L, "name", achievement.name);
		Lua::setField(L, "description", achievement.description);
		Lua::setField(L, "points", achievement.points);
		Lua::setField(L, "grade", achievement.grade);
		Lua::setField(L, "secret", achievement.secret);
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetAchievements(lua_State* L) {
	// Game.getAchievements()
	const std::map<uint16_t, Achievement> &achievements = g_game().getAchievements();
	int index = 0;
	lua_createtable(L, achievements.size(), 0);
	for (const auto &achievement_it : achievements) {
		lua_createtable(L, 0, 6);
		Lua::setField(L, "id", achievement_it.first);
		Lua::setField(L, "name", achievement_it.second.name);
		Lua::setField(L, "description", achievement_it.second.description);
		Lua::setField(L, "points", achievement_it.second.points);
		Lua::setField(L, "grade", achievement_it.second.grade);
		Lua::setField(L, "secret", achievement_it.second.secret);
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int GameFunctions::luaGameGetTitleByName(lua_State* L) {
	// Game.getTitleByName(titleName)
	const std::string titleName = Lua::getString(L, 1);
	if (titleName.empty()) {
		lua_pushnil(L);
		return 1;
	}

	const Title &title = g_game().getTitleByName(titleName);
	if (title.m_maleName.empty() && title.m_femaleName.empty()) {
		lua_pushnil(L);
		return 1;
	}

	lua_createtable(L, 0, 4);
	Lua::pushString(L, title.m_maleName);
	lua_setfield(L, -2, "maleName");

	Lua::pushString(L, title.m_femaleName);
	lua_setfield(L, -2, "femaleName");

	Lua::pushNumber(L, title.m_id);
	lua_setfield(L, -2, "id");

	Lua::pushString(L, title.m_description);
	lua_setfield(L, -2, "description");
	return 1;
}

int GameFunctions::luaHouseGetHouseCountByAccount(lua_State* L) {
	// Game:getHouseCountByAccount(accountId)
	const auto &houses = g_game().map.houses.getHouses();
	if (houses.empty()) {
		Lua::reportErrorFunc("Houses not found");
		lua_pushnil(L);
		return 1;
	}

	uint32_t accountId = Lua::getNumber<uint32_t>(L, 2);
	uint16_t count = 0;
	for (const auto &[id, house] : houses) {
		if (house->isEphemeral()) {
			continue;
		}
		if (house->getOwnerAccountId() == accountId) {
			++count;
		}
	}
	lua_pushnumber(L, count);
	return 1;
}

int GameFunctions::luaGameSetGuildMotd(lua_State* L) {
	// Game:setGuildMotd(guildId, newMotd)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string newMotd = Lua::getString(L, 2);

	g_game().setGuildMotd(guildId, newMotd);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameDisbandGuild(lua_State* L) {
	// Game:disbandGuild(guildId)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);

	g_game().disbandGuild(guildId);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameInvitePlayerToGuild(lua_State* L) {
	// Game:invitePlayerToGuild(guildId, playerName)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string playerName = Lua::getString(L, 2);

	g_game().invitePlayerToGuild(guildId, playerName);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameRemovePlayerFromGuild(lua_State* L) {
	// Game:removePlayerFromGuild(guildId, playerName)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string playerName = Lua::getString(L, 2);

	g_game().removePlayerFromGuild(guildId, playerName);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGamePromotePlayer(lua_State* L) {
	// Game:promotePlayer(guildId, playerName)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string playerName = Lua::getString(L, 2);

	g_game().promotePlayer(guildId, playerName);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameDemotePlayer(lua_State* L) {
	// Game:demotePlayer(guildId, playerName)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string playerName = Lua::getString(L, 2);

	g_game().demotePlayer(guildId, playerName);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGamePassLeadership(lua_State* L) {
	// Game:passLeadership(guildId, newLeaderName)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string newLeaderName = Lua::getString(L, 2);

	g_game().passLeadership(guildId, newLeaderName);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameSetPlayerGuildNick(lua_State* L) {
	// Game:setPlayerGuildNick(guildId, playerName, nick)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	const std::string playerName = Lua::getString(L, 2);
	const std::string nick = Lua::getString(L, 3);

	g_game().setPlayerGuildNick(guildId, playerName, nick);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameSetRankName(lua_State* L) {
	// Game:setRankName(guildId, rankLevel, newName)
	uint32_t guildId = Lua::getNumber<uint32_t>(L, 1);
	uint8_t rankLevel = Lua::getNumber<uint8_t>(L, 2);
	const std::string newName = Lua::getString(L, 3);

	g_game().setRankName(guildId, rankLevel, newName);
	Lua::pushBoolean(L, true);
	return 1;
}

int GameFunctions::luaGameCreateGuild(lua_State* L) {
	// Game:createGuild(guildName, leaderName)
	const std::string guildName = Lua::getString(L, 1);
	const std::string leaderName = Lua::getString(L, 2);

	uint32_t guildId = g_game().createGuild(guildName, leaderName);
	Lua::pushNumber(L, guildId);
	return 1;
}

int GameFunctions::luaGameJoinGuild(lua_State* L) {
	// Game:joinGuild(guildName, playerName)
	const std::string guildName = Lua::getString(L, 1);
	const std::string playerName = Lua::getString(L, 2);

	bool success = g_game().joinGuild(guildName, playerName);
	Lua::pushBoolean(L, success);
	return 1;
}
