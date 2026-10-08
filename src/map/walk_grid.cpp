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

#include "map/walk_grid.hpp"

#include <array>
#include <deque>

namespace {
	// Same order as the hunt pipeline (hold_routes.NEIGHBORS) and AnchorSpot.
	constexpr std::array<std::pair<int32_t, int32_t>, 8> NEIGHBOURS { {
		{ 0, -1 },
		{ 1, 0 },
		{ 0, 1 },
		{ -1, 0 },
		{ 1, -1 },
		{ 1, 1 },
		{ -1, 1 },
		{ -1, -1 },
	} };
}

std::shared_ptr<WalkGrid> WalkGrid::flood(int32_t seedX, int32_t seedY, uint8_t z, const StandableFn &standable, size_t cap) {
	if (cap == 0 || !standable(seedX, seedY)) {
		return nullptr;
	}
	auto grid = std::make_shared<WalkGrid>();
	grid->z = z;
	std::unordered_set<Key> rejected;
	std::deque<std::pair<int32_t, int32_t>> queue;
	grid->tiles.insert(tileKey(seedX, seedY));
	grid->order.emplace_back(seedX, seedY);
	queue.emplace_back(seedX, seedY);
	while (!queue.empty() && grid->tiles.size() < cap) {
		const auto [x, y] = queue.front();
		queue.pop_front();
		for (const auto &[dx, dy] : NEIGHBOURS) {
			const int32_t nx = x + dx;
			const int32_t ny = y + dy;
			const Key key = tileKey(nx, ny);
			if (grid->tiles.contains(key) || rejected.contains(key)) {
				continue;
			}
			if (!standable(nx, ny)) {
				rejected.insert(key);
				continue;
			}
			grid->tiles.insert(key);
			grid->order.emplace_back(nx, ny);
			queue.emplace_back(nx, ny);
			if (grid->tiles.size() >= cap) {
				break;
			}
		}
	}
	return grid;
}

std::vector<WalkGrid::Node> WalkGrid::bfs(int32_t x, int32_t y, int32_t maxDepth, const std::vector<Key>* targets) const {
	std::vector<Node> out;
	std::unordered_map<Key, int32_t> dist;
	const Key start = tileKey(x, y);
	dist.emplace(start, 0);
	out.push_back({ start, 0, start });

	std::unordered_set<Key> remaining;
	const bool watchTargets = targets != nullptr && !targets->empty();
	if (watchTargets) {
		remaining.insert(targets->begin(), targets->end());
		remaining.erase(start);
	}

	std::deque<std::pair<int32_t, int32_t>> queue;
	queue.emplace_back(x, y);
	while (!queue.empty()) {
		const auto [cx, cy] = queue.front();
		queue.pop_front();
		const Key here = tileKey(cx, cy);
		const int32_t d = dist[here];
		if (maxDepth >= 0 && d >= maxDepth) {
			continue;
		}
		for (const auto &[dx, dy] : NEIGHBOURS) {
			const int32_t nx = cx + dx;
			const int32_t ny = cy + dy;
			const Key key = tileKey(nx, ny);
			if (dist.contains(key) || !tiles.contains(key)) {
				continue;
			}
			dist.emplace(key, d + 1);
			out.push_back({ key, d + 1, here });
			queue.emplace_back(nx, ny);
			if (watchTargets) {
				remaining.erase(key);
				if (remaining.empty()) {
					return out;
				}
			}
		}
	}
	return out;
}
