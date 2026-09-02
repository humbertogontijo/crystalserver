////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////
#pragma once

#include <cstdint>
#include <memory>
#include <string>

class Player;

// Today's daily-activity counters (reset each calendar day). Same persistence
// shape as weekly/bounty task progress: in-memory on the player, flushed on save.
class DailyActivityData {
public:
	DailyActivityData() = default;

	std::string activityDay;
	uint32_t dailyHunt = 0;
	uint32_t soloBoss = 0;
	uint32_t worldBoss = 0;
	uint32_t bountyHunter = 0;

	// Throttle for Activity Boost opcode pushes after hunt kills.
	int64_t lastStateNotifyMs = 0;
};

class IODailyActivities {
public:
	IODailyActivities() = default;

	IODailyActivities(const IODailyActivities &) = delete;
	void operator=(const IODailyActivities &) = delete;

	static IODailyActivities &getInstance();

	// Ensure activityDay matches today; zeroes counters on rollover.
	void ensureDay(const std::shared_ptr<Player> &player);

	uint32_t getStat(const std::shared_ptr<Player> &player, const std::string &activityId);
	uint32_t addStat(const std::shared_ptr<Player> &player, const std::string &activityId, uint32_t delta);

	// Qualifying bestiary kill (same filter as weekly "any creature").
	void onCreatureKill(const std::shared_ptr<Player> &player, uint16_t raceId);

	bool save(const std::shared_ptr<Player> &player);
	void load(const std::shared_ptr<Player> &player);

private:
	static std::string todayKey();
	static uint32_t *statPtr(DailyActivityData &data, const std::string &activityId);
	void notifyLua(const std::shared_ptr<Player> &player, const std::string &activityId, bool force);
};

constexpr auto g_iodailyactivities = IODailyActivities::getInstance;
