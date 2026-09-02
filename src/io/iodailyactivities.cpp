////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////
#include "io/iodailyactivities.hpp"

#include "creatures/monsters/monsters.hpp"
#include "creatures/players/player.hpp"
#include "database/database.hpp"
#include "game/game.hpp"
#include "game/scheduling/dispatcher.hpp"
#include "lib/di/container.hpp"
#include "lua/lua_definitions.hpp"
#include "lua/scripts/luascript.hpp"
#include "lua/scripts/scripts.hpp"
#include "utils/tools.hpp"

#include <ctime>
#include <sstream>

namespace {
constexpr int64_t kStateNotifyThrottleMs = 1500;

void callActivityBoostOnStatChanged(const std::shared_ptr<Player> &player, const std::string &activityId) {
	if (!player) {
		return;
	}
	auto &scriptInterface = g_scripts().getScriptInterface();
	lua_State* L = scriptInterface.getLuaState();
	if (!L) {
		return;
	}
	if (g_dispatcher().context().isAsync()) {
		return;
	}
	if (!Lua::reserveScriptEnv()) {
		g_logger().error("[IODailyActivities] ActivityBoost onStatChanged Lua call stack overflow");
		return;
	}

	ScriptEnvironment* env = Lua::getScriptEnv();
	env->setScriptId(EVENT_ID_USER, &scriptInterface);

	lua_getglobal(L, "ActivityBoostActivities");
	if (lua_type(L, -1) != LUA_TTABLE) {
		lua_pop(L, 1);
		Lua::resetScriptEnv();
		return;
	}
	lua_getfield(L, -1, "onStatChanged");
	lua_remove(L, -2);
	if (lua_type(L, -1) != LUA_TFUNCTION) {
		lua_pop(L, 1);
		Lua::resetScriptEnv();
		return;
	}
	Lua::pushUserdata<Player>(L, player);
	Lua::setMetatable(L, -1, "Player");
	Lua::pushString(L, activityId);
	scriptInterface.callFunction(2);
}
} // namespace

IODailyActivities &IODailyActivities::getInstance() {
	return inject<IODailyActivities>();
}

std::string IODailyActivities::todayKey() {
	time_t now = time(nullptr);
	tm local {};
#if defined(_MSC_VER)
	localtime_s(&local, &now);
#else
	localtime_r(&now, &local);
#endif
	char buf[16];
	strftime(buf, sizeof(buf), "%Y-%m-%d", &local);
	return buf;
}

uint32_t *IODailyActivities::statPtr(DailyActivityData &data, const std::string &activityId) {
	if (activityId == "daily_hunt") {
		return &data.dailyHunt;
	}
	if (activityId == "solo_boss") {
		return &data.soloBoss;
	}
	if (activityId == "world_boss") {
		return &data.worldBoss;
	}
	if (activityId == "bounty_hunter") {
		return &data.bountyHunter;
	}
	return nullptr;
}

void IODailyActivities::ensureDay(const std::shared_ptr<Player> &player) {
	if (!player) {
		return;
	}
	auto &data = player->getDailyActivityData();
	const auto today = todayKey();
	if (data.activityDay == today) {
		return;
	}
	data.activityDay = today;
	data.dailyHunt = 0;
	data.soloBoss = 0;
	data.worldBoss = 0;
	data.bountyHunter = 0;
	data.lastStateNotifyMs = 0;
}

uint32_t IODailyActivities::getStat(const std::shared_ptr<Player> &player, const std::string &activityId) {
	if (!player) {
		return 0;
	}
	ensureDay(player);
	const uint32_t *ptr = statPtr(player->getDailyActivityData(), activityId);
	return ptr ? *ptr : 0;
}

uint32_t IODailyActivities::addStat(const std::shared_ptr<Player> &player, const std::string &activityId, uint32_t delta) {
	if (!player || delta == 0) {
		return getStat(player, activityId);
	}
	ensureDay(player);
	uint32_t *ptr = statPtr(player->getDailyActivityData(), activityId);
	if (!ptr) {
		return 0;
	}
	const uint64_t next = static_cast<uint64_t>(*ptr) + delta;
	*ptr = next > UINT32_MAX ? UINT32_MAX : static_cast<uint32_t>(next);
	return *ptr;
}

void IODailyActivities::notifyLua(const std::shared_ptr<Player> &player, const std::string &activityId, bool force) {
	if (!player) {
		return;
	}
	auto &data = player->getDailyActivityData();
	const int64_t now = OTSYS_TIME();
	if (!force && data.lastStateNotifyMs > 0 && (now - data.lastStateNotifyMs) < kStateNotifyThrottleMs) {
		return;
	}
	data.lastStateNotifyMs = now;
	callActivityBoostOnStatChanged(player, activityId);
}

void IODailyActivities::onCreatureKill(const std::shared_ptr<Player> &player, uint16_t raceId) {
	if (!player) {
		return;
	}

	const auto mtype = g_monsters().getMonsterTypeByRaceId(raceId);
	const auto &bestiaryList = g_game().getBestiaryList();
	const bool validBestiaryCreature = mtype
		&& mtype->info.experience > 0
		&& mtype->info.isPreyable
		&& !mtype->info.isPreyExclusive
		&& bestiaryList.find(raceId) != bestiaryList.end();
	if (!validBestiaryCreature) {
		return;
	}

	ensureDay(player);
	auto &data = player->getDailyActivityData();
	if (data.dailyHunt < UINT32_MAX) {
		data.dailyHunt++;
	}

	// Force notify when crossing typical daily goal so XP credit is not delayed.
	const bool force = data.dailyHunt == 250;
	notifyLua(player, "daily_hunt", force);
}

bool IODailyActivities::save(const std::shared_ptr<Player> &player) {
	if (!player) {
		g_logger().warn("[IODailyActivities::save] - Player nullptr");
		return false;
	}

	ensureDay(player);
	const auto &data = player->getDailyActivityData();
	Database &db = Database::getInstance();

	std::ostringstream query;
	query << "INSERT INTO `player_daily_activities` ("
		  << "`player_id`, `activity_day`, `daily_hunt`, `solo_boss`, `world_boss`, `bounty_hunter`"
		  << ") VALUES ("
		  << player->getGUID() << ", "
		  << db.escapeString(data.activityDay) << ", "
		  << data.dailyHunt << ", "
		  << data.soloBoss << ", "
		  << data.worldBoss << ", "
		  << data.bountyHunter
		  << ") ON DUPLICATE KEY UPDATE "
		  << "`activity_day` = VALUES(`activity_day`), "
		  << "`daily_hunt` = VALUES(`daily_hunt`), "
		  << "`solo_boss` = VALUES(`solo_boss`), "
		  << "`world_boss` = VALUES(`world_boss`), "
		  << "`bounty_hunter` = VALUES(`bounty_hunter`)";

	if (!db.executeQuery(query.str())) {
		g_logger().warn("[IODailyActivities::save] - Error saving daily activities for player: {}", player->getName());
		return false;
	}
	return true;
}

void IODailyActivities::load(const std::shared_ptr<Player> &player) {
	if (!player) {
		g_logger().warn("[IODailyActivities::load] - Player nullptr");
		return;
	}

	Database &db = Database::getInstance();
	std::ostringstream query;
	query << "SELECT `activity_day`, `daily_hunt`, `solo_boss`, `world_boss`, `bounty_hunter` "
		  << "FROM `player_daily_activities` WHERE `player_id` = " << player->getGUID();
	DBResult_ptr result = db.storeQuery(query.str());
	if (!result) {
		ensureDay(player);
		return;
	}

	auto &data = player->getDailyActivityData();
	data.activityDay = result->getString("activity_day");
	data.dailyHunt = result->getNumber<uint32_t>("daily_hunt");
	data.soloBoss = result->getNumber<uint32_t>("solo_boss");
	data.worldBoss = result->getNumber<uint32_t>("world_boss");
	data.bountyHunter = result->getNumber<uint32_t>("bounty_hunter");
	ensureDay(player);
}
