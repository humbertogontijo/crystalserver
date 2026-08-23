////////////////////////////////////////////////////////////////////////
// map_query_session — load OTBM once, serve geometry JSON ops in-process.
////////////////////////////////////////////////////////////////////////

#include "map_query_session.hpp"

#include "config/configmanager.hpp"
#include "game/game.hpp"
#include "io/iomap.hpp"
#include "items/items.hpp"
#include "lib/di/container.hpp"
#include "map/map.hpp"
#include "map/mapcache.hpp"
#include "utils/tools.hpp"

#include <chrono>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <unordered_set>

namespace map_query {
namespace {

struct SparseTile {
	uint16_t groundSid = 0;
	bool hasGround = false;
	std::vector<uint16_t> itemSids;
	std::vector<uint16_t> actionIds;
	bool hasTeleport = false;
	uint16_t destX = 0;
	uint16_t destY = 0;
	uint8_t destZ = 0;
};

void collectActionIds(uint16_t aid, std::vector<uint16_t> &into) {
	if (aid > 0) {
		into.push_back(aid);
	}
}

void collectItemActionIds(const std::shared_ptr<BasicItem> &item, std::vector<uint16_t> &into) {
	if (!item) {
		return;
	}
	collectActionIds(item->actionId, into);
	for (const auto &child : item->items) {
		collectItemActionIds(child, into);
	}
}

bool itemHasTeleport(const std::shared_ptr<BasicItem> &item) {
	if (!item) {
		return false;
	}
	if (item->destX != 0 || item->destY != 0 || item->destZ != 0) {
		return true;
	}
	for (const auto &child : item->items) {
		if (itemHasTeleport(child)) {
			return true;
		}
	}
	return false;
}

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
		collectItemActionIds(tile->ground, out.actionIds);
	}
	for (const auto &item : tile->items) {
		if (!item) {
			continue;
		}
		out.itemSids.push_back(item->id);
		collectItemActionIds(item, out.actionIds);
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

json sparseTileJson(uint16_t x, uint16_t y, uint8_t z, const SparseTile &tile) {
	json j {
		{ "key", fmt::format("{},{},{}", x, y, static_cast<int>(z)) },
		{ "x", x },
		{ "y", y },
		{ "z", z },
		{ "groundSid", tile.hasGround ? json(tile.groundSid) : json(nullptr) },
		{ "itemSids", tile.itemSids },
	};
	if (!tile.actionIds.empty()) {
		j["actionIds"] = tile.actionIds;
	}
	if (tile.hasTeleport) {
		j["teleportDest"] = json {
			{ "x", tile.destX },
			{ "y", tile.destY },
			{ "z", tile.destZ },
		};
	}
	return j;
}

std::string tileKey(uint16_t x, uint16_t y, uint8_t z) {
	return fmt::format("{},{},{}", x, y, static_cast<int>(z));
}

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

void bootstrapItems() {
	const auto coreFolder = g_configManager().getString(CORE_DIRECTORY);
	if (g_game().loadAppearanceProtobuf(coreFolder + "/items/appearances.dat") != ERROR_NONE) {
		throw std::runtime_error("failed to load appearances.dat");
	}
	if (!Item::items.loadFromXml()) {
		throw std::runtime_error("failed to load items.xml");
	}
}

void loadConfig(const std::string &configPath) {
	const std::filesystem::path configFile = std::filesystem::absolute(configPath);
	if (!std::filesystem::exists(configFile)) {
		throw std::runtime_error("config not found: " + configFile.string());
	}
	std::filesystem::current_path(configFile.parent_path());
	g_configManager().setConfigFileLua(configFile.filename().string());
	if (!g_configManager().load()) {
		throw std::runtime_error("failed to load config.lua");
	}
}

std::unique_ptr<Map> loadOtbmMap(const std::string &otbmPath, int64_t &loadMs) {
	const std::filesystem::path mapFile = std::filesystem::absolute(otbmPath);
	if (!std::filesystem::exists(mapFile)) {
		throw std::runtime_error("otbm not found: " + mapFile.string());
	}
	auto map = std::make_unique<Map>();
	const auto t0 = std::chrono::steady_clock::now();
	map->load(mapFile.string());
	const auto t1 = std::chrono::steady_clock::now();
	loadMs = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
	return map;
}

json townsJson(const Map &map) {
	json rows = json::array();
	for (const auto &[townId, town] : map.towns.getTowns()) {
		if (!town || townId == 0) {
			continue;
		}
		const auto &pos = town->getTemplePosition();
		rows.push_back(json {
			{ "id", townId },
			{ "name", town->getName() },
			{ "x", pos.x },
			{ "y", pos.y },
			{ "z", pos.z },
		});
	}
	return rows;
}

json queryTilesAt(const Map &map, const json &req) {
	std::unordered_set<std::string> needed;
	for (const auto &coord : req.at("coords")) {
		const uint16_t x = coord.at("x").get<uint16_t>();
		const uint16_t y = coord.at("y").get<uint16_t>();
		const uint8_t z = coord.at("z").get<uint8_t>();
		needed.insert(tileKey(x, y, z));
	}
	json tiles = json::array();
	for (const auto &coord : req.at("coords")) {
		const uint16_t x = coord.at("x").get<uint16_t>();
		const uint16_t y = coord.at("y").get<uint16_t>();
		const uint8_t z = coord.at("z").get<uint8_t>();
		const auto key = tileKey(x, y, z);
		if (!needed.contains(key)) {
			continue;
		}
		needed.erase(key);
		const auto basic = getCachedTile(map, x, y, z);
		if (!basic) {
			continue;
		}
		tiles.push_back(sparseTileJson(x, y, z, basicTileToSparse(basic)));
	}
	return json { { "tiles", tiles } };
}

json queryTilesInBounds(const Map &map, const json &req) {
	json tiles = json::array();
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
					const auto ux = static_cast<uint16_t>(x);
					const auto uy = static_cast<uint16_t>(y);
					const auto uz = static_cast<uint8_t>(z);
					const auto basic = getCachedTile(map, ux, uy, uz);
					if (!basic) {
						continue;
					}
					tiles.push_back(sparseTileJson(ux, uy, uz, basicTileToSparse(basic)));
				}
			}
		}
	}
	return json { { "tiles", tiles } };
}

json handleRequest(Map &map, GeometryEngine &geometry, const json &req) {
	const std::string op = req.at("op").get<std::string>();
	if (op == "tiles-at") {
		return queryTilesAt(map, req);
	}
	if (op == "tiles-in-bounds") {
		return queryTilesInBounds(map, req);
	}
	if (op == "towns") {
		return json { { "towns", townsJson(map) } };
	}
	if (op == "teleports") {
		return geometry.queryTeleports();
	}
	if (op == "configure") {
		geometry.configure(req);
		return json { { "ok", true } };
	}
	if (op == "tile-flags") {
		return geometry.queryTileFlags(req);
	}
	if (op == "team-fits") {
		return geometry.queryTeamFits(req);
	}
	if (op == "position-scores") {
		return geometry.queryPositionScores(req);
	}
	if (op == "flood-fill-floors") {
		return geometry.queryFloodFillFloors(req);
	}
	if (op == "flood-fill-floors-batch") {
		return geometry.queryFloodFillFloorsBatch(req);
	}
	if (op == "flood-fill-floors-best-near") {
		return geometry.queryFloodFillFloorsBestNear(req);
	}
	if (op == "flood-fill-floors-best-near-batch") {
		return geometry.queryFloodFillFloorsBestNearBatch(req);
	}
	if (op == "flood-fill-from-pin") {
		return geometry.queryFloodFillFromPin(req);
	}
	if (op == "flood-fill-from-pins") {
		return geometry.queryFloodFillFromPins(req);
	}
	throw std::runtime_error("unknown op: " + op);
}

} // namespace

MapQuerySession::MapQuerySession(std::unique_ptr<Map> map, int64_t loadMs) :
	map_(std::move(map)),
	loadMs_(loadMs),
	geometry_(*map_) {
}

std::unique_ptr<MapQuerySession> MapQuerySession::create(
	const std::string &configPath,
	const std::string &otbmPath
) {
	loadConfig(configPath);
	bootstrapItems();
	int64_t loadMs = 0;
	auto map = loadOtbmMap(otbmPath, loadMs);
	return std::unique_ptr<MapQuerySession>(new MapQuerySession(std::move(map), loadMs));
}

json MapQuerySession::readyJson() const {
	size_t tileCount = 0;
	map_->forEachCachedBasicTile([&](uint16_t, uint16_t, uint8_t, const std::shared_ptr<BasicTile> &) {
		++tileCount;
	});
	return json {
		{ "ready", true },
		{ "loadMs", loadMs_ },
		{ "tiles", tileCount },
	};
}

json MapQuerySession::query(const json &req) {
	return handleRequest(*map_, geometry_, req);
}

} // namespace map_query
