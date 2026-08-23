////////////////////////////////////////////////////////////////////////
// Geometry engine for expedition generation (tile flags, team-fit, flood).
////////////////////////////////////////////////////////////////////////

#pragma once

#include "map/map.hpp"

#include <nlohmann/json.hpp>
#include <optional>
#include <unordered_set>
#include <vector>

namespace map_query {

using json = nlohmann::json;

struct Coord {
	uint16_t x = 0;
	uint16_t y = 0;
	uint8_t z = 0;
};

struct TileFlags {
	bool hasTile = false;
	bool walkable = false;
	bool unpass = false;
	bool unsight = false;
	bool door = false;
	bool floorDown = false;
	bool hasTeleport = false;
	uint16_t groundSid = 0;
	Coord teleportDest {};
};

class GeometryEngine {
public:
	explicit GeometryEngine(Map &map);

	void configure(const json &req);
	json queryTeamFits(const json &req) const;
	json queryPositionScores(const json &req) const;
	json queryTileFlags(const json &req) const;
	json queryFloodFillFloors(const json &req) const;
	json queryFloodFillFloorsBatch(const json &req) const;
	json queryFloodFillFloorsBestNear(const json &req) const;
	json queryFloodFillFloorsBestNearBatch(const json &req) const;
	json queryFloodFillFromPin(const json &req) const;
	json queryFloodFillFromPins(const json &req) const;
	json queryTeleports();

private:
	Map &map_;
	std::unordered_set<uint16_t> doorSids_;
	std::unordered_set<uint16_t> floorDownSids_;
	std::optional<json> teleportsCache_;

	TileFlags classify(uint16_t x, uint16_t y, uint8_t z) const;
	bool isUnpassSid(uint16_t sid) const;
	bool isUnsightSid(uint16_t sid) const;
	bool isSpawnable(const TileFlags &f) const;
	bool hasOpenNeighborhood(uint16_t x, uint16_t y, uint8_t z) const;
	bool cardinalSightClear(uint16_t cx, uint16_t cy, uint8_t cz, int radius, int dir) const;
	bool cardinalSlotUsable(uint16_t cx, uint16_t cy, uint8_t cz, int radius, int dir) const;
	int countUsableCardinals(uint16_t cx, uint16_t cy, uint8_t cz, int radius) const;
	int countOpenCardinals(uint16_t cx, uint16_t cy, uint8_t cz, int radius) const;
	bool teamFits(uint16_t x, uint16_t y, uint8_t z) const;
	int positionScore(uint16_t x, uint16_t y, uint8_t z) const;

	static void readSidSet(const json &req, const char *key, std::unordered_set<uint16_t> &out);
	static Coord parseCoord(const json &c);
};

} // namespace map_query
