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

#pragma once

#include "lua/global/shared_object.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

/**
 * One floor's 8-connected walkable component around a seed tile (cave route
 * generation, Lua `Game.walkGrid`). Tiles are keyed like Lua `AnchorSpot.tileKey`
 * (x * 65536 + y). Searches walk only tiles inside the component, in the neighbour
 * order the hunt pipeline uses, so paths match the offline route builder.
 */
class WalkGrid final : public SharedObject {
public:
	using Key = int64_t;
	using StandableFn = std::function<bool(int32_t x, int32_t y)>;

	struct Node {
		Key key;
		int32_t dist;
		/** Key of the tile it was reached from; equals `key` for the start. */
		Key parent;
	};

	static constexpr Key tileKey(int32_t x, int32_t y) {
		return static_cast<Key>(x) * 65536 + y;
	}

	/** Flood from (seedX, seedY) over `standable` tiles, at most `cap` tiles. Null when the seed is not standable. */
	static std::shared_ptr<WalkGrid> flood(int32_t seedX, int32_t seedY, uint8_t z, const StandableFn &standable, size_t cap);

	[[nodiscard]] bool contains(int32_t x, int32_t y) const {
		return tiles.contains(tileKey(x, y));
	}
	[[nodiscard]] size_t size() const {
		return tiles.size();
	}
	[[nodiscard]] uint8_t getZ() const {
		return z;
	}

	/**
	 * Breadth-first search from (x, y) over component tiles; the start always counts.
	 * `maxDepth` < 0: unbounded. With `targets` it stops as soon as every target other
	 * than the start was reached (an empty remainder stops after the first new tile).
	 * Returns the discovered tiles in visit order.
	 */
	[[nodiscard]] std::vector<Node> bfs(int32_t x, int32_t y, int32_t maxDepth, const std::vector<Key>* targets) const;

private:
	uint8_t z = 0;
	std::unordered_set<Key> tiles;
};
