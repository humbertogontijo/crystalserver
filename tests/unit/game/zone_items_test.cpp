#include "pch.hpp"

#include <boost/ut.hpp>

#include "game/zones/zone.hpp"
#include "items/item.hpp"

using namespace boost::ut;

suite<"zone_items"> zoneItemsTest = [] {
	test("the item cache follows adds, transforms and removes") = [] {
		auto &types = Item::items.getItems();
		if (types.size() < 3) {
			types.resize(3);
		}
		Zone zone("zone_items_test");
		const auto lit = std::make_shared<Item>(1, 0, InstanceId::World);
		const auto unlit = std::make_shared<Item>(2, 0, InstanceId::World);

		zone.itemAdded(lit);
		expect(eq(zone.getItems().size(), size_t { 1 }));

		// Tile::onUpdateTileItem reports a transform as a remove then an add.
		zone.itemRemoved(lit);
		zone.itemAdded(unlit);
		const auto items = zone.getItems();
		expect(eq(items.size(), size_t { 1 }));
		expect(items.front() == unlit);

		zone.itemRemoved(unlit);
		expect(zone.getItems().empty());
		zone.itemAdded(nullptr);
		expect(zone.getItems().empty());
	};
};
