#include "pch.hpp"

#include <boost/ut.hpp>

#include "map/walk_grid.hpp"

using namespace boost::ut;

namespace {
	// '#' blocked, '.' standable; row index is y, column is x.
	WalkGrid::StandableFn fromRows(const std::vector<std::string> &rows) {
		return [rows](int32_t x, int32_t y) {
			if (y < 0 || y >= static_cast<int32_t>(rows.size())) {
				return false;
			}
			const auto &row = rows[static_cast<size_t>(y)];
			return x >= 0 && x < static_cast<int32_t>(row.size()) && row[static_cast<size_t>(x)] == '.';
		};
	}

	int32_t distOf(const std::vector<WalkGrid::Node> &nodes, int32_t x, int32_t y) {
		for (const auto &node : nodes) {
			if (node.key == WalkGrid::tileKey(x, y)) {
				return node.dist;
			}
		}
		return -1;
	}
}

suite<"walk_grid"> walkGridTest = [] {
	test("flood keeps only the seed component") = [] {
		const auto grid = WalkGrid::flood(0, 0, 7, fromRows({ "..#..", "..#..", "..#.." }), 100);
		expect(grid != nullptr);
		expect(eq(grid->size(), size_t { 6 }));
		expect(grid->contains(1, 2));
		expect(!grid->contains(3, 0));
		expect(eq(grid->getZ(), uint8_t { 7 }));
	};

	test("flood connects diagonally and honours the cap") = [] {
		const auto standable = fromRows({ ".#", "#." });
		expect(eq(WalkGrid::flood(0, 0, 7, standable, 100)->size(), size_t { 2 }));
		expect(eq(WalkGrid::flood(0, 0, 7, fromRows({ "....." }), 3)->size(), size_t { 3 }));
		expect(WalkGrid::flood(1, 0, 7, standable, 100) == nullptr);
	};

	test("bfs walks only grid tiles with chebyshev steps") = [] {
		const auto grid = WalkGrid::flood(0, 0, 7, fromRows({ ".....", "####.", "....." }), 100);
		const auto nodes = grid->bfs(0, 0, -1, nullptr);
		expect(eq(distOf(nodes, 4, 0), 4));
		expect(eq(distOf(nodes, 0, 2), 8));
		expect(eq(nodes.front().parent, nodes.front().key));
	};

	test("bfs depth limit and target early exit") = [] {
		const auto grid = WalkGrid::flood(0, 0, 7, fromRows({ "........" }), 100);
		expect(eq(grid->bfs(0, 0, 2, nullptr).size(), size_t { 3 }));
		const std::vector<WalkGrid::Key> targets { WalkGrid::tileKey(3, 0) };
		const auto nodes = grid->bfs(0, 0, -1, &targets);
		expect(eq(nodes.size(), size_t { 4 }));
		expect(eq(nodes.back().key, WalkGrid::tileKey(3, 0)));
	};

	test("neighbour order matches the hunt pipeline") = [] {
		const auto grid = WalkGrid::flood(1, 1, 7, fromRows({ "...", "...", "..." }), 100);
		const auto nodes = grid->bfs(1, 1, 1, nullptr);
		const std::vector<WalkGrid::Key> expected {
			WalkGrid::tileKey(1, 1),
			WalkGrid::tileKey(1, 0),
			WalkGrid::tileKey(2, 1),
			WalkGrid::tileKey(1, 2),
			WalkGrid::tileKey(0, 1),
			WalkGrid::tileKey(2, 0),
			WalkGrid::tileKey(2, 2),
			WalkGrid::tileKey(0, 2),
			WalkGrid::tileKey(0, 0),
		};
		expect(eq(nodes.size(), expected.size()));
		for (size_t i = 0; i < expected.size() && i < nodes.size(); ++i) {
			expect(eq(nodes[i].key, expected[i])) << "index" << i;
		}
	};
};
