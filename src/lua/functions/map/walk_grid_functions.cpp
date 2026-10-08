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

#include "lua/functions/map/walk_grid_functions.hpp"

#include "game/game.hpp"
#include "game/subarea_registry.hpp"
#include "items/tile.hpp"
#include "lua/functions/lua_functions_loader.hpp"
#include "map/walk_grid.hpp"

namespace {
	constexpr size_t WALK_GRID_DEFAULT_CAP = 12000;
	constexpr size_t WALK_GRID_MAX_CAP = 200000;

	int32_t optField(lua_State* L, int32_t arg, const char* key, int32_t fallback) {
		lua_getfield(L, arg, key);
		const int32_t value = lua_isnumber(L, -1) ? static_cast<int32_t>(lua_tonumber(L, -1)) : fallback;
		lua_pop(L, 1);
		return value;
	}
}

void WalkGridFunctions::init(lua_State* L) {
	Lua::registerSharedClass(L, "WalkGrid", "");
	Lua::registerMethod(L, "WalkGrid", "size", WalkGridFunctions::luaWalkGridSize);
	Lua::registerMethod(L, "WalkGrid", "getZ", WalkGridFunctions::luaWalkGridGetZ);
	Lua::registerMethod(L, "WalkGrid", "contains", WalkGridFunctions::luaWalkGridContains);
	Lua::registerMethod(L, "WalkGrid", "getTiles", WalkGridFunctions::luaWalkGridGetTiles);
	Lua::registerMethod(L, "WalkGrid", "bfs", WalkGridFunctions::luaWalkGridBfs);

	Lua::registerMethod(L, "Game", "walkGrid", WalkGridFunctions::luaGameWalkGrid);
}

int WalkGridFunctions::luaGameWalkGrid(lua_State* L) {
	// Game.walkGrid(seedPos[, {instance, subareaId, minX, minY, maxX, maxY, cap}])
	const Position seed = Lua::getPosition(L, 1);
	std::optional<InstanceId> instanceId;
	uint32_t subareaId = 0;
	size_t cap = WALK_GRID_DEFAULT_CAP;
	int32_t minX = 0;
	int32_t minY = 0;
	int32_t maxX = std::numeric_limits<uint16_t>::max();
	int32_t maxY = std::numeric_limits<uint16_t>::max();
	if (Lua::isTable(L, 2)) {
		lua_getfield(L, 2, "instance");
		const bool ok = Lua::readInstanceId(L, lua_gettop(L), instanceId);
		lua_pop(L, 1);
		if (!ok) {
			lua_pushnil(L);
			return 1;
		}
		subareaId = static_cast<uint32_t>(std::max(0, optField(L, 2, "subareaId", 0)));
		cap = std::clamp<size_t>(static_cast<size_t>(std::max(1, optField(L, 2, "cap", static_cast<int32_t>(WALK_GRID_DEFAULT_CAP)))), 1, WALK_GRID_MAX_CAP);
		minX = optField(L, 2, "minX", minX);
		minY = optField(L, 2, "minY", minY);
		maxX = optField(L, 2, "maxX", maxX);
		maxY = optField(L, 2, "maxY", maxY);
	}

	const uint8_t z = seed.z;
	const auto &subareas = g_subareas();
	const bool fenced = subareaId != 0 && subareas.enabled();
	const auto standable = [&](int32_t x, int32_t y) {
		if (x < minX || y < minY || x > maxX || y > maxY || x < 0 || y < 0 || x > 0xFFFF || y > 0xFFFF) {
			return false;
		}
		const Position pos(static_cast<uint16_t>(x), static_cast<uint16_t>(y), z);
		if (fenced && subareas.regionAt(pos) != subareaId) {
			return false;
		}
		const auto &tile = g_game().map.getTile(pos);
		if (!tile || !tile->getGround()) {
			return false;
		}
		if (tile->hasFlag(TILESTATE_FLOORCHANGE) || tile->hasFlag(TILESTATE_PROTECTIONZONE)) {
			return false;
		}
		const auto blocks = [&](ItemProperty prop) {
			return instanceId ? tile->hasProperty(prop, *instanceId) : tile->hasProperty(prop);
		};
		return !blocks(CONST_PROP_BLOCKSOLID) && !blocks(CONST_PROP_IMMOVABLEBLOCKSOLID) && !blocks(CONST_PROP_BLOCKPATH);
	};

	const auto grid = WalkGrid::flood(seed.x, seed.y, z, standable, cap);
	if (!grid) {
		lua_pushnil(L);
		return 1;
	}
	Lua::pushUserdata<WalkGrid>(L, grid);
	Lua::setMetatable(L, -1, "WalkGrid");
	return 1;
}

int WalkGridFunctions::luaWalkGridSize(lua_State* L) {
	// walkGrid:size()
	const auto &grid = Lua::getUserdataShared<WalkGrid>(L, 1);
	lua_pushnumber(L, grid ? static_cast<lua_Number>(grid->size()) : 0);
	return 1;
}

int WalkGridFunctions::luaWalkGridGetZ(lua_State* L) {
	// walkGrid:getZ()
	const auto &grid = Lua::getUserdataShared<WalkGrid>(L, 1);
	lua_pushnumber(L, grid ? grid->getZ() : 0);
	return 1;
}

int WalkGridFunctions::luaWalkGridContains(lua_State* L) {
	// walkGrid:contains(x, y)
	const auto &grid = Lua::getUserdataShared<WalkGrid>(L, 1);
	Lua::pushBoolean(L, grid && grid->contains(Lua::getNumber<int32_t>(L, 2), Lua::getNumber<int32_t>(L, 3)));
	return 1;
}

int WalkGridFunctions::luaWalkGridGetTiles(lua_State* L) {
	// walkGrid:getTiles() -> { {x, y}, ... }
	const auto &grid = Lua::getUserdataShared<WalkGrid>(L, 1);
	if (!grid) {
		lua_pushnil(L);
		return 1;
	}
	const auto &tiles = grid->getTiles();
	lua_createtable(L, static_cast<int>(tiles.size()), 0);
	int index = 0;
	for (const auto &[x, y] : tiles) {
		lua_createtable(L, 2, 0);
		lua_pushnumber(L, x);
		lua_rawseti(L, -2, 1);
		lua_pushnumber(L, y);
		lua_rawseti(L, -2, 2);
		lua_rawseti(L, -2, ++index);
	}
	return 1;
}

int WalkGridFunctions::luaWalkGridBfs(lua_State* L) {
	// walkGrid:bfs(x, y[, maxDepth[, targetKeys]]) -> dist, parent (keyed by x * 65536 + y)
	const auto &grid = Lua::getUserdataShared<WalkGrid>(L, 1);
	if (!grid) {
		lua_pushnil(L);
		return 1;
	}
	const auto x = Lua::getNumber<int32_t>(L, 2);
	const auto y = Lua::getNumber<int32_t>(L, 3);
	const auto maxDepth = Lua::isNumber(L, 4) ? Lua::getNumber<int32_t>(L, 4) : -1;
	std::vector<WalkGrid::Key> targets;
	const bool hasTargets = Lua::isTable(L, 5);
	if (hasTargets) {
		const auto count = lua_objlen(L, 5);
		targets.reserve(count);
		for (size_t i = 1; i <= count; ++i) {
			lua_rawgeti(L, 5, static_cast<int>(i));
			targets.push_back(static_cast<WalkGrid::Key>(lua_tonumber(L, -1)));
			lua_pop(L, 1);
		}
	}
	const auto nodes = grid->bfs(x, y, maxDepth, hasTargets ? &targets : nullptr);
	lua_createtable(L, 0, static_cast<int>(nodes.size()));
	lua_createtable(L, 0, static_cast<int>(nodes.size()));
	for (const auto &node : nodes) {
		lua_pushnumber(L, static_cast<lua_Number>(node.key));
		lua_pushnumber(L, node.dist);
		lua_rawset(L, -4);
		if (node.parent != node.key) {
			lua_pushnumber(L, static_cast<lua_Number>(node.key));
			lua_pushnumber(L, static_cast<lua_Number>(node.parent));
			lua_rawset(L, -3);
		}
	}
	return 2;
}
