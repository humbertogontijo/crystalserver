#include "pch.hpp"

#include <boost/ut.hpp>

#include "creatures/combat/combat.hpp"

using namespace boost::ut;

namespace {
	// Width of the wave per row in front of its centre (dy = 0 is the centre row).
	std::map<int32_t, std::pair<int32_t, int32_t>> rowExtents(const std::vector<std::pair<int32_t, int32_t>> &offsets) {
		std::map<int32_t, std::pair<int32_t, int32_t>> rows;
		for (const auto &[dx, dy] : offsets) {
			auto it = rows.find(dy);
			if (it == rows.end()) {
				rows[dy] = { dx, dx };
			} else {
				it->second.first = std::min(it->second.first, dx);
				it->second.second = std::max(it->second.second, dx);
			}
		}
		return rows;
	}
}

suite<"area_combat"> areaCombatTest = [] {
	test("wave length 8 spread 3 facing north") = [] {
		AreaCombat area;
		area.setupArea(8, 3);
		const auto offsets = area.getOffsets(DIRECTION_NORTH);
		const auto rows = rowExtents(offsets);
		expect(eq(rows.size(), size_t { 8 }));
		expect(eq(rows.begin()->first, -7));
		expect(eq(rows.rbegin()->first, 0));
		// Narrow near the caster, widest at the far end.
		expect(eq(rows.at(0).first, 0) and eq(rows.at(0).second, 0));
		expect(eq(rows.at(-1).first, 0) and eq(rows.at(-1).second, 0));
		expect(eq(rows.at(-2).first, -1) and eq(rows.at(-2).second, 1));
		expect(eq(rows.at(-7).first, -2) and eq(rows.at(-7).second, 2));
	};

	test("beam is one tile wide") = [] {
		AreaCombat area;
		area.setupArea(7, 0);
		const auto offsets = area.getOffsets(DIRECTION_NORTH);
		expect(eq(offsets.size(), size_t { 7 }));
		for (const auto &[dx, dy] : offsets) {
			expect(eq(dx, 0));
			expect(dy <= 0 and dy >= -6);
		}
	};

	test("rotated areas keep the tile count") = [] {
		AreaCombat area;
		area.setupArea(8, 3);
		const auto north = area.getOffsets(DIRECTION_NORTH).size();
		expect(eq(area.getOffsets(DIRECTION_EAST).size(), north));
		expect(eq(area.getOffsets(DIRECTION_SOUTH).size(), north));
		expect(eq(area.getOffsets(DIRECTION_WEST).size(), north));
	};
};
