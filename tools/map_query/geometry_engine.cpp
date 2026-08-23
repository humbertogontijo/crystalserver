////////////////////////////////////////////////////////////////////////
// Geometry engine for expedition generation.
////////////////////////////////////////////////////////////////////////

#include "geometry_engine.hpp"

#include "items/items.hpp"
#include "map/mapcache.hpp"

#include <algorithm>
#include <cstdint>
#include <queue>
#include <set>
#include <string>

namespace map_query {

namespace {

constexpr int TEAM_CLOSE_RADIUS = 2;
constexpr int TEAM_RANGED_RADIUS = 4;
constexpr int TEAM_MIN_CLOSE = 1;
constexpr int TEAM_MIN_RANGED = 2;
constexpr int FILL_BEST_NEAR_RADIUS = 3;
constexpr int PIN_FLOOD_SEED_RADIUS = 2;
constexpr int PIN_FLOOD_SEED_RADIUS_EXPANDED = 5;
/** Stop trying neighborhood seeds once a fill this large is found (matches TS). */
constexpr size_t PIN_FLOOD_EARLY_EXIT_SCORE = 12;
constexpr int DEFAULT_MAX_TILES = 8000;
constexpr int HUNT_FILL_CLIP_RADIUS = 128;
constexpr int MAX_HOLE_FLOOR_DOWN = 8;

const int CARDINAL_DX[4] = { 0, 1, 0, -1 };
const int CARDINAL_DY[4] = { -1, 0, 1, 0 };
const int FORMATION_RADII[3] = { 1, 2, 4 };
const int FORMATION_WEIGHTS[3] = { 4, 2, 1 };

std::shared_ptr<BasicTile> getCachedTile(const Map &map, uint16_t x, uint16_t y, uint8_t z) {
	const auto *sector = map.getMapSector(x, y);
	if (!sector) {
		return nullptr;
	}
	auto &mutableSector = const_cast<MapSector &>(*sector);
	const auto floor = mutableSector.getFloor(z);
	if (!floor) {
		return nullptr;
	}
	return floor->getTileCache(x, y);
}

bool sidIsDoor(uint16_t sid, const std::unordered_set<uint16_t> &doorSids) {
	return sid > 0 && doorSids.contains(sid);
}

bool sidIsFloorDown(uint16_t sid, const std::unordered_set<uint16_t> &floorDownSids) {
	return sid > 0 && floorDownSids.contains(sid);
}

struct SparseTile {
	uint16_t groundSid = 0;
	bool hasGround = false;
	std::vector<uint16_t> itemSids;
	bool hasTeleport = false;
	uint16_t destX = 0;
	uint16_t destY = 0;
	uint8_t destZ = 0;
};

void firstTeleportDest(const std::shared_ptr<BasicItem> &item, uint16_t &destX, uint16_t &destY, uint8_t &destZ) {
	if (!item) {
		return;
	}
	if (item->destX != 0 || item->destY != 0 || item->destZ != 0) {
		destX = item->destX;
		destY = item->destY;
		destZ = item->destZ;
		return;
	}
	for (const auto &child : item->items) {
		firstTeleportDest(child, destX, destY, destZ);
		if (destX != 0 || destY != 0 || destZ != 0) {
			return;
		}
	}
}

SparseTile basicTileToSparse(const std::shared_ptr<BasicTile> &tile) {
	SparseTile out;
	if (!tile) {
		return out;
	}
	if (tile->ground) {
		out.groundSid = tile->ground->id;
		out.hasGround = out.groundSid > 0;
	}
	for (const auto &item : tile->items) {
		if (!item) {
			continue;
		}
		out.itemSids.push_back(item->id);
	}
	if (!out.hasGround && !out.itemSids.empty()) {
		out.groundSid = out.itemSids.front();
		out.itemSids.erase(out.itemSids.begin());
		out.hasGround = out.groundSid > 0;
	}
	uint16_t destX = 0;
	uint16_t destY = 0;
	uint8_t destZ = 0;
	if (tile->ground) {
		firstTeleportDest(tile->ground, destX, destY, destZ);
	}
	if (destX == 0 && destY == 0 && destZ == 0) {
		for (const auto &item : tile->items) {
			firstTeleportDest(item, destX, destY, destZ);
			if (destX != 0 || destY != 0 || destZ != 0) {
				break;
			}
		}
	}
	if (destX != 0 || destY != 0 || destZ != 0) {
		out.hasTeleport = true;
		out.destX = destX;
		out.destY = destY;
		out.destZ = destZ;
	}
	return out;
}

std::string coordKey(uint16_t x, uint16_t y, uint8_t z) {
	return fmt::format("{},{},{}", x, y, static_cast<int>(z));
}

struct FloodFillResult {
	std::vector<std::pair<int32_t, int32_t>> tiles;
	int32_t originX = 0;
	int32_t originY = 0;
	int32_t width = 0;
	int32_t height = 0;
	uint8_t z = 0;
	std::string rejected;
};

bool inClip(int32_t x, int32_t y, int32_t cx, int32_t cy, int radius) {
	return std::max(std::abs(x - cx), std::abs(y - cy)) <= radius;
}

FloodFillResult floodFillWalkable(
	const Map &map,
	Coord seed,
	int clipRadius,
	int maxTiles,
	const std::unordered_set<uint16_t> &doorSids,
	bool passDoors,
	int32_t clipCx,
	int32_t clipCy
) {
	auto isWalkable = [&](uint16_t x, uint16_t y, uint8_t z) -> bool {
		const auto basic = getCachedTile(map, x, y, z);
		const auto sparse = basicTileToSparse(basic);
		if (!sparse.hasGround || sparse.groundSid == 0) {
			return false;
		}
		if (passDoors) {
			if (sidIsDoor(sparse.groundSid, doorSids)) {
				return true;
			}
			for (const auto sid : sparse.itemSids) {
				if (sidIsDoor(sid, doorSids)) {
					return true;
				}
			}
		}
		const auto &groundType = Item::items.getItemType(sparse.groundSid);
		if (groundType.blockSolid) {
			return false;
		}
		for (const auto sid : sparse.itemSids) {
			if (sid > 0 && Item::items.getItemType(sid).blockSolid) {
				return false;
			}
		}
		return true;
	};

	FloodFillResult empty;
	empty.rejected = "empty";
	empty.z = seed.z;
	if (!isWalkable(seed.x, seed.y, seed.z)) {
		return empty;
	}

	std::set<std::string> visited;
	std::vector<std::pair<int32_t, int32_t>> inside;
	std::vector<Coord> queue;
	queue.push_back(seed);
	visited.insert(coordKey(seed.x, seed.y, seed.z));

	int32_t minX = seed.x;
	int32_t maxX = seed.x;
	int32_t minY = seed.y;
	int32_t maxY = seed.y;
	bool overCap = false;

	const int32_t offsets[4][2] = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } };

	while (!queue.empty()) {
		const auto cur = queue.back();
		queue.pop_back();
		inside.emplace_back(cur.x, cur.y);
		if (static_cast<int>(inside.size()) > maxTiles) {
			overCap = true;
			break;
		}
		minX = std::min(minX, static_cast<int32_t>(cur.x));
		maxX = std::max(maxX, static_cast<int32_t>(cur.x));
		minY = std::min(minY, static_cast<int32_t>(cur.y));
		maxY = std::max(maxY, static_cast<int32_t>(cur.y));
		if (maxX - minX + 1 > maxTiles || maxY - minY + 1 > maxTiles) {
			overCap = true;
			break;
		}
		for (const auto &off : offsets) {
			const int32_t nx = static_cast<int32_t>(cur.x) + off[0];
			const int32_t ny = static_cast<int32_t>(cur.y) + off[1];
			if (!inClip(nx, ny, clipCx, clipCy, clipRadius)) {
				continue;
			}
			if (nx < 0 || ny < 0 || nx > UINT16_MAX || ny > UINT16_MAX) {
				continue;
			}
			const auto ux = static_cast<uint16_t>(nx);
			const auto uy = static_cast<uint16_t>(ny);
			const auto key = coordKey(ux, uy, cur.z);
			if (visited.contains(key)) {
				continue;
			}
			visited.insert(key);
			if (!isWalkable(ux, uy, cur.z)) {
				continue;
			}
			queue.push_back({ ux, uy, cur.z });
		}
	}

	if (overCap) {
		FloodFillResult over;
		over.rejected = "over-cap";
		over.z = seed.z;
		return over;
	}
	if (inside.empty()) {
		return empty;
	}

	FloodFillResult out;
	out.tiles = std::move(inside);
	out.originX = minX;
	out.originY = minY;
	out.width = maxX - minX + 1;
	out.height = maxY - minY + 1;
	out.z = seed.z;
	out.rejected = "";
	return out;
}

FloodFillResult floodFillBestNear(
	const Map &map,
	Coord origin,
	int clipRadius,
	int maxTiles,
	const std::unordered_set<uint16_t> &doorSids,
	bool passDoors,
	int32_t clipCx,
	int32_t clipCy
) {
	FloodFillResult empty;
	empty.rejected = "empty";
	empty.z = origin.z;
	FloodFillResult best = empty;
	for (int r = 0; r <= FILL_BEST_NEAR_RADIUS; ++r) {
		for (int dy = -r; dy <= r; ++dy) {
			for (int dx = -r; dx <= r; ++dx) {
				if (r > 0 && std::max(std::abs(dx), std::abs(dy)) != r) {
					continue;
				}
				const int sx = static_cast<int>(origin.x) + dx;
				const int sy = static_cast<int>(origin.y) + dy;
				if (sx < 0 || sy < 0) {
					continue;
				}
				const Coord seed {
					static_cast<uint16_t>(sx),
					static_cast<uint16_t>(sy),
					origin.z,
				};
				auto fill = floodFillWalkable(map, seed, clipRadius, maxTiles, doorSids, passDoors, clipCx, clipCy);
				if (!fill.rejected.empty() || fill.tiles.empty()) {
					continue;
				}
				if (!best.rejected.empty() || fill.tiles.size() > best.tiles.size()) {
					best = std::move(fill);
				}
				if (static_cast<int>(best.tiles.size()) > 12) {
					return best;
				}
			}
		}
		if (r >= 2 && best.tiles.empty()) {
			break;
		}
	}
	return best;
}

size_t scoreFloorsJson(const json &floors) {
	size_t score = 0;
	for (const auto &floor : floors) {
		score += floor.at("tiles").size();
	}
	return score;
}

FloodFillResult fillSolidAabb(const FloodFillResult &fill) {
	if (!fill.rejected.empty() || fill.tiles.empty()) {
		return fill;
	}
	FloodFillResult out = fill;
	out.tiles.clear();
	for (int32_t y = fill.originY; y < fill.originY + fill.height; ++y) {
		for (int32_t x = fill.originX; x < fill.originX + fill.width; ++x) {
			out.tiles.emplace_back(x, y);
		}
	}
	return out;
}

bool tileHasFloorDownSid(const SparseTile &sparse, const std::unordered_set<uint16_t> &floorDownSids) {
	if (sidIsFloorDown(sparse.groundSid, floorDownSids)) {
		return true;
	}
	for (const auto sid : sparse.itemSids) {
		if (sidIsFloorDown(sid, floorDownSids)) {
			return true;
		}
	}
	return false;
}

} // namespace

GeometryEngine::GeometryEngine(Map &map) :
	map_(map) {
}

void GeometryEngine::readSidSet(const json &req, const char *key, std::unordered_set<uint16_t> &out) {
	out.clear();
	if (!req.contains(key)) {
		return;
	}
	for (const auto &v : req.at(key)) {
		out.insert(v.get<uint16_t>());
	}
}

Coord GeometryEngine::parseCoord(const json &c) {
	return {
		c.at("x").get<uint16_t>(),
		c.at("y").get<uint16_t>(),
		c.at("z").get<uint8_t>(),
	};
}

void GeometryEngine::configure(const json &req) {
	readSidSet(req, "doorSids", doorSids_);
	readSidSet(req, "floorDownSids", floorDownSids_);
}

bool GeometryEngine::isUnpassSid(uint16_t sid) const {
	if (sid == 0 || sid >= Item::items.size()) {
		return false;
	}
	return Item::items.getItemType(sid).blockSolid;
}

bool GeometryEngine::isUnsightSid(uint16_t sid) const {
	if (sid == 0 || sid >= Item::items.size()) {
		return false;
	}
	return Item::items.getItemType(sid).blockProjectile;
}

TileFlags GeometryEngine::classify(uint16_t x, uint16_t y, uint8_t z) const {
	TileFlags out;
	const auto basic = getCachedTile(map_, x, y, z);
	if (!basic) {
		return out;
	}
	const auto sparse = basicTileToSparse(basic);
	out.hasTile = true;
	out.groundSid = sparse.groundSid;
	if (!sparse.hasGround || sparse.groundSid == 0) {
		return out;
	}
	out.unpass = isUnpassSid(sparse.groundSid);
	for (const auto sid : sparse.itemSids) {
		if (sid > 0 && isUnpassSid(sid)) {
			out.unpass = true;
		}
		if (sid > 0 && isUnsightSid(sid)) {
			out.unsight = true;
		}
		if (sidIsDoor(sid, doorSids_)) {
			out.door = true;
		}
		if (sidIsFloorDown(sid, floorDownSids_)) {
			out.floorDown = true;
		}
	}
	if (sidIsDoor(sparse.groundSid, doorSids_)) {
		out.door = true;
	}
	if (sidIsFloorDown(sparse.groundSid, floorDownSids_)) {
		out.floorDown = true;
	}
	if (isUnsightSid(sparse.groundSid)) {
		out.unsight = true;
	}
	out.hasTeleport = sparse.hasTeleport;
	out.teleportDest = { sparse.destX, sparse.destY, sparse.destZ };
	out.walkable = !out.unpass;
	return out;
}

bool GeometryEngine::isSpawnable(const TileFlags &f) const {
	return f.hasTile && f.groundSid > 0 && !f.unpass;
}

bool GeometryEngine::hasOpenNeighborhood(uint16_t x, uint16_t y, uint8_t z) const {
	for (int dy = -1; dy <= 1; ++dy) {
		for (int dx = -1; dx <= 1; ++dx) {
			const int nx = static_cast<int>(x) + dx;
			const int ny = static_cast<int>(y) + dy;
			if (nx < 0 || ny < 0) {
				return false;
			}
			if (!isSpawnable(classify(static_cast<uint16_t>(nx), static_cast<uint16_t>(ny), z))) {
				return false;
			}
		}
	}
	return true;
}

bool GeometryEngine::cardinalSightClear(uint16_t cx, uint16_t cy, uint8_t cz, int radius, int dir) const {
	for (int step = 1; step <= radius; ++step) {
		const int nx = static_cast<int>(cx) + CARDINAL_DX[dir] * step;
		const int ny = static_cast<int>(cy) + CARDINAL_DY[dir] * step;
		if (nx < 0 || ny < 0) {
			return false;
		}
		const auto f = classify(static_cast<uint16_t>(nx), static_cast<uint16_t>(ny), cz);
		if (f.unsight) {
			return false;
		}
	}
	return true;
}

bool GeometryEngine::cardinalSlotUsable(uint16_t cx, uint16_t cy, uint8_t cz, int radius, int dir) const {
	const int sx = static_cast<int>(cx) + CARDINAL_DX[dir] * radius;
	const int sy = static_cast<int>(cy) + CARDINAL_DY[dir] * radius;
	if (sx < 0 || sy < 0) {
		return false;
	}
	const auto f = classify(static_cast<uint16_t>(sx), static_cast<uint16_t>(sy), cz);
	if (!isSpawnable(f)) {
		return false;
	}
	return cardinalSightClear(cx, cy, cz, radius, dir);
}

int GeometryEngine::countUsableCardinals(uint16_t cx, uint16_t cy, uint8_t cz, int radius) const {
	int n = 0;
	for (int dir = 0; dir < 4; ++dir) {
		if (cardinalSlotUsable(cx, cy, cz, radius, dir)) {
			++n;
		}
	}
	return n;
}

int GeometryEngine::countOpenCardinals(uint16_t cx, uint16_t cy, uint8_t cz, int radius) const {
	int n = 0;
	for (int dir = 0; dir < 4; ++dir) {
		const int sx = static_cast<int>(cx) + CARDINAL_DX[dir] * radius;
		const int sy = static_cast<int>(cy) + CARDINAL_DY[dir] * radius;
		if (sx < 0 || sy < 0) {
			continue;
		}
		if (isSpawnable(classify(static_cast<uint16_t>(sx), static_cast<uint16_t>(sy), cz))) {
			++n;
		}
	}
	return n;
}

bool GeometryEngine::teamFits(uint16_t x, uint16_t y, uint8_t z) const {
	if (!hasOpenNeighborhood(x, y, z)) {
		return false;
	}
	if (countUsableCardinals(x, y, z, TEAM_CLOSE_RADIUS) < TEAM_MIN_CLOSE) {
		return false;
	}
	return countUsableCardinals(x, y, z, TEAM_RANGED_RADIUS) >= TEAM_MIN_RANGED;
}

int GeometryEngine::positionScore(uint16_t x, uint16_t y, uint8_t z) const {
	if (!hasOpenNeighborhood(x, y, z)) {
		return -1;
	}
	int score = 0;
	for (int i = 0; i < 3; ++i) {
		score += countOpenCardinals(x, y, z, FORMATION_RADII[i]) * FORMATION_WEIGHTS[i];
	}
	return score;
}

json GeometryEngine::queryTeamFits(const json &req) const {
	json results = json::array();
	for (const auto &c : req.at("centers")) {
		const auto coord = parseCoord(c);
		results.push_back(teamFits(coord.x, coord.y, coord.z));
	}
	return json { { "fits", results } };
}

json GeometryEngine::queryPositionScores(const json &req) const {
	json results = json::array();
	for (const auto &c : req.at("centers")) {
		const auto coord = parseCoord(c);
		results.push_back(positionScore(coord.x, coord.y, coord.z));
	}
	return json { { "scores", results } };
}

json GeometryEngine::queryTileFlags(const json &req) const {
	json tiles = json::array();
	const bool sparseOnly = req.value("sparseOnly", true);

	auto emit = [&](uint16_t x, uint16_t y, uint8_t z) {
		const auto f = classify(x, y, z);
		if (!f.hasTile) {
			return;
		}
		if (sparseOnly && f.walkable && !f.door && !f.floorDown && !f.hasTeleport && !f.unsight) {
			return;
		}
		uint8_t flags = 0;
		if (f.walkable) {
			flags |= 1;
		}
		if (f.unpass) {
			flags |= 2;
		}
		if (f.unsight) {
			flags |= 4;
		}
		if (f.door) {
			flags |= 8;
		}
		if (f.floorDown) {
			flags |= 16;
		}
		if (f.hasTeleport) {
			flags |= 32;
		}
		json row {
			{ "x", x },
			{ "y", y },
			{ "z", z },
			{ "flags", flags },
			{ "groundSid", f.groundSid },
		};
		if (f.hasTeleport) {
			row["teleportDest"] = json {
				{ "x", f.teleportDest.x },
				{ "y", f.teleportDest.y },
				{ "z", f.teleportDest.z },
			};
		}
		tiles.push_back(std::move(row));
	};

	if (req.contains("coords")) {
		for (const auto &c : req.at("coords")) {
			const auto coord = parseCoord(c);
			emit(coord.x, coord.y, coord.z);
		}
	} else if (req.contains("bounds")) {
		for (const auto &box : req.at("bounds")) {
			const int32_t minX = box.at("minX").get<int32_t>();
			const int32_t maxX = box.at("maxX").get<int32_t>();
			const int32_t minY = box.at("minY").get<int32_t>();
			const int32_t maxY = box.at("maxY").get<int32_t>();
			const int32_t minZ = box.at("minZ").get<int32_t>();
			const int32_t maxZ = box.at("maxZ").get<int32_t>();
			for (int32_t z = minZ; z <= maxZ; ++z) {
				for (int32_t x = minX; x <= maxX; ++x) {
					for (int32_t y = minY; y <= maxY; ++y) {
						if (x < 0 || y < 0 || z < 0 || z >= MAP_MAX_LAYERS) {
							continue;
						}
						emit(static_cast<uint16_t>(x), static_cast<uint16_t>(y), static_cast<uint8_t>(z));
					}
				}
			}
		}
	}
	return json { { "tiles", tiles } };
}

json GeometryEngine::queryFloodFillFloors(const json &req) const {
	const auto seed = parseCoord(req.at("seed"));
	const int clipRadius = req.value("clipRadius", HUNT_FILL_CLIP_RADIUS);
	const int maxTiles = req.value("maxTiles", DEFAULT_MAX_TILES);
	const int maxDown = req.value("maxDown", MAX_HOLE_FLOOR_DOWN);
	const bool passDoors = !doorSids_.empty();
	const int32_t rootCx = seed.x;
	const int32_t rootCy = seed.y;

	json floors = json::array();
	std::set<uint8_t> seenZ;
	std::queue<Coord> queue;
	queue.push(seed);

	while (!queue.empty()) {
		const auto floorSeed = queue.front();
		queue.pop();
		if (seenZ.contains(floorSeed.z)) {
			continue;
		}
		const int offset = static_cast<int>(floorSeed.z) - static_cast<int>(seed.z);
		if (offset < 0 || offset > maxDown) {
			continue;
		}

		auto fill = floodFillWalkable(map_, floorSeed, clipRadius, maxTiles, doorSids_, passDoors, rootCx, rootCy);
		if (!fill.rejected.empty() || fill.tiles.empty()) {
			fill = floodFillBestNear(map_, floorSeed, clipRadius, maxTiles, doorSids_, passDoors, rootCx, rootCy);
		}
		if (!fill.rejected.empty() || fill.tiles.empty()) {
			continue;
		}
		if (fill.width * fill.height <= maxTiles) {
			fill = fillSolidAabb(fill);
		} else if (static_cast<int>(fill.tiles.size()) > maxTiles) {
			continue;
		}

		seenZ.insert(floorSeed.z);

		json tileRows = json::array();
		for (const auto &[tx, ty] : fill.tiles) {
			tileRows.push_back(json { { "x", tx }, { "y", ty } });
		}
		floors.push_back(json {
			{ "floorOffset", offset },
			{ "z", fill.z },
			{ "originX", fill.originX },
			{ "originY", fill.originY },
			{ "width", fill.width },
			{ "height", fill.height },
			{ "tiles", tileRows },
			{ "seed", json { { "x", floorSeed.x }, { "y", floorSeed.y }, { "z", floorSeed.z } } },
		});

		if (offset >= maxDown) {
			continue;
		}

		std::set<std::string> nextKeys;
		for (const auto &[tx, ty] : fill.tiles) {
			const auto basic = getCachedTile(map_, static_cast<uint16_t>(tx), static_cast<uint16_t>(ty), fill.z);
			const auto sparse = basicTileToSparse(basic);
			if (tileHasFloorDownSid(sparse, floorDownSids_)) {
				const uint8_t nz = static_cast<uint8_t>(fill.z + 1);
				if (nz <= 15 && !seenZ.contains(nz)) {
					const auto key = coordKey(static_cast<uint16_t>(tx), static_cast<uint16_t>(ty), nz);
					if (!nextKeys.contains(key)) {
						nextKeys.insert(key);
						queue.push({ static_cast<uint16_t>(tx), static_cast<uint16_t>(ty), nz });
					}
				}
			}
			if (sparse.hasTeleport && sparse.destZ >= fill.z) {
				if (sparse.destX > 256 || sparse.destY > 256) {
					if (!inClip(static_cast<int32_t>(sparse.destX), static_cast<int32_t>(sparse.destY), rootCx, rootCy, clipRadius)) {
						continue;
					}
					if (!seenZ.contains(sparse.destZ)) {
						const auto key = coordKey(sparse.destX, sparse.destY, sparse.destZ);
						if (!nextKeys.contains(key)) {
							nextKeys.insert(key);
							queue.push({ sparse.destX, sparse.destY, sparse.destZ });
						}
					}
				}
			}
		}
	}

	return json { { "floors", floors } };
}

json GeometryEngine::queryFloodFillFloorsBatch(const json &req) const {
	const int clipRadius = req.value("clipRadius", HUNT_FILL_CLIP_RADIUS);
	const int maxTiles = req.value("maxTiles", DEFAULT_MAX_TILES);
	const int maxDown = req.value("maxDown", MAX_HOLE_FLOOR_DOWN);
	json results = json::array();
	for (const auto &seedJson : req.at("seeds")) {
		const json single {
			{ "seed", seedJson },
			{ "clipRadius", clipRadius },
			{ "maxTiles", maxTiles },
			{ "maxDown", maxDown },
		};
		results.push_back(json {
			{ "seed", seedJson },
			{ "floors", queryFloodFillFloors(single).at("floors") },
		});
	}
	return json { { "results", results } };
}

json GeometryEngine::queryFloodFillFloorsBestNear(const json &req) const {
	const auto origin = parseCoord(req.at("origin"));
	const int clipRadius = req.value("clipRadius", HUNT_FILL_CLIP_RADIUS);
	const int maxTiles = req.value("maxTiles", DEFAULT_MAX_TILES);
	const int maxDown = req.value("maxDown", MAX_HOLE_FLOOR_DOWN);

	size_t bestScore = 0;
	json bestFloors = json::array();

	for (int r = 0; r <= FILL_BEST_NEAR_RADIUS; ++r) {
		for (int dy = -r; dy <= r; ++dy) {
			for (int dx = -r; dx <= r; ++dx) {
				if (r > 0 && std::max(std::abs(dx), std::abs(dy)) != r) {
					continue;
				}
				const int sx = static_cast<int>(origin.x) + dx;
				const int sy = static_cast<int>(origin.y) + dy;
				if (sx < 0 || sy < 0 || sx > UINT16_MAX || sy > UINT16_MAX) {
					continue;
				}
				const json sub {
					{ "seed", json {
						{ "x", static_cast<uint16_t>(sx) },
						{ "y", static_cast<uint16_t>(sy) },
						{ "z", origin.z },
					} },
					{ "clipRadius", clipRadius },
					{ "maxTiles", maxTiles },
					{ "maxDown", maxDown },
				};
				const auto floors = queryFloodFillFloors(sub).at("floors");
				const auto score = scoreFloorsJson(floors);
				if (score > bestScore) {
					bestScore = score;
					bestFloors = floors;
				}
				if (bestScore > PIN_FLOOD_EARLY_EXIT_SCORE) {
					return json { { "floors", bestFloors } };
				}
			}
		}
		if (r >= 2 && bestScore == 0) {
			break;
		}
	}
	return json { { "floors", bestFloors } };
}

json GeometryEngine::queryFloodFillFloorsBestNearBatch(const json &req) const {
	json results = json::array();
	for (const auto &originJson : req.at("origins")) {
		json single {
			{ "origin", originJson },
		};
		if (req.contains("clipRadius")) {
			single["clipRadius"] = req.at("clipRadius");
		}
		if (req.contains("maxTiles")) {
			single["maxTiles"] = req.at("maxTiles");
		}
		if (req.contains("maxDown")) {
			single["maxDown"] = req.at("maxDown");
		}
		results.push_back(json {
			{ "origin", originJson },
			{ "floors", queryFloodFillFloorsBestNear(single).at("floors") },
		});
	}
	return json { { "results", results } };
}

json GeometryEngine::queryFloodFillFromPin(const json &req) const {
	const auto pin = parseCoord(req.at("pin"));
	const int innerRadius = req.value("innerRadius", PIN_FLOOD_SEED_RADIUS);
	const int outerRadius = req.value("outerRadius", PIN_FLOOD_SEED_RADIUS_EXPANDED);

	auto collectWalkable = [&](int radius, int minCheb, int maxCheb, std::vector<Coord> &out) {
		for (int dy = -radius; dy <= radius; ++dy) {
			for (int dx = -radius; dx <= radius; ++dx) {
				const int cheb = std::max(std::abs(dx), std::abs(dy));
				if (cheb < minCheb || cheb > maxCheb) {
					continue;
				}
				const int x = static_cast<int>(pin.x) + dx;
				const int y = static_cast<int>(pin.y) + dy;
				if (x < 0 || y < 0) {
					continue;
				}
				const auto flags = classify(static_cast<uint16_t>(x), static_cast<uint16_t>(y), pin.z);
				if (flags.walkable) {
					out.push_back({ static_cast<uint16_t>(x), static_cast<uint16_t>(y), pin.z });
				}
			}
		}
	};

	auto ringHasBlocker = [&](int innerR, int outerR) -> bool {
		for (int dy = -outerR; dy <= outerR; ++dy) {
			for (int dx = -outerR; dx <= outerR; ++dx) {
				const int cheb = std::max(std::abs(dx), std::abs(dy));
				if (cheb <= innerR) {
					continue;
				}
				const int x = static_cast<int>(pin.x) + dx;
				const int y = static_cast<int>(pin.y) + dy;
				if (x < 0 || y < 0) {
					continue;
				}
				const auto flags = classify(static_cast<uint16_t>(x), static_cast<uint16_t>(y), pin.z);
				if (!flags.hasTile || !flags.walkable) {
					return true;
				}
			}
		}
		return false;
	};

	auto scoreFloors = [](const json &floors) -> size_t {
		size_t score = 0;
		for (const auto &floor : floors) {
			score += floor.at("tiles").size();
		}
		return score;
	};

	std::set<std::string> seen;
	size_t bestScore = 0;
	json bestFloors = json::array();

	auto trySeed = [&](const Coord &seed) {
		const auto key = coordKey(seed.x, seed.y, seed.z);
		if (seen.contains(key)) {
			return;
		}
		seen.insert(key);
		const json sub {
			{ "seed", json { { "x", seed.x }, { "y", seed.y }, { "z", seed.z } } },
		};
		const auto floors = queryFloodFillFloors(sub).at("floors");
		const auto score = scoreFloors(floors);
		if (score > bestScore) {
			bestScore = score;
			bestFloors = floors;
		}
	};

	const auto pinFlags = classify(pin.x, pin.y, pin.z);
	if (pinFlags.walkable) {
		trySeed(pin);
		if (bestScore > PIN_FLOOD_EARLY_EXIT_SCORE) {
			return json { { "floors", bestFloors } };
		}
	}

	std::vector<Coord> inner;
	collectWalkable(innerRadius, 0, innerRadius, inner);
	for (const auto &coord : inner) {
		trySeed(coord);
		if (bestScore > PIN_FLOOD_EARLY_EXIT_SCORE) {
			return json { { "floors", bestFloors } };
		}
	}
	if (bestScore > 0) {
		return json { { "floors", bestFloors } };
	}
	if (!ringHasBlocker(innerRadius, outerRadius)) {
		return json { { "floors", bestFloors } };
	}

	std::vector<Coord> ring;
	collectWalkable(outerRadius, innerRadius + 1, outerRadius, ring);
	for (const auto &coord : ring) {
		trySeed(coord);
		if (bestScore > PIN_FLOOD_EARLY_EXIT_SCORE) {
			return json { { "floors", bestFloors } };
		}
	}
	return json { { "floors", bestFloors } };
}

json GeometryEngine::queryFloodFillFromPins(const json &req) const {
	json results = json::array();
	const int innerRadius = req.value("innerRadius", PIN_FLOOD_SEED_RADIUS);
	const int outerRadius = req.value("outerRadius", PIN_FLOOD_SEED_RADIUS_EXPANDED);
	for (const auto &pinJson : req.at("pins")) {
		json single {
			{ "pin", pinJson },
			{ "innerRadius", innerRadius },
			{ "outerRadius", outerRadius },
		};
		results.push_back(json {
			{ "pin", pinJson },
			{ "floors", queryFloodFillFromPin(single).at("floors") },
		});
	}
	return json { { "results", results } };
}

json GeometryEngine::queryTeleports() {
	if (teleportsCache_.has_value()) {
		return json { { "teleports", *teleportsCache_ } };
	}
	json rows = json::array();
	map_.forEachCachedBasicTile([&](uint16_t x, uint16_t y, uint8_t z, const std::shared_ptr<BasicTile> &tile) {
		const auto sparse = basicTileToSparse(tile);
		if (!sparse.hasTeleport) {
			return;
		}
		if (sparse.destX <= 256 && sparse.destY <= 256) {
			return;
		}
		rows.push_back(json {
			{ "from", json { { "x", x }, { "y", y }, { "z", z } } },
			{ "dest", json { { "x", sparse.destX }, { "y", sparse.destY }, { "z", sparse.destZ } } },
		});
	});
	teleportsCache_ = rows;
	return json { { "teleports", rows } };
}

} // namespace map_query
