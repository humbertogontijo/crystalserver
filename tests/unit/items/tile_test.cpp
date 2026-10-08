#include "pch.hpp"

#include <boost/ut.hpp>

#include "items/tile.hpp"

using namespace boost::ut;

suite<"tile"> tileTest = [] {
	test("a tile without ground is never standable") = [] {
		const auto tile = std::make_shared<StaticTile>(100, 100, 7);
		expect(!tile->isStandable());
		expect(!tile->isStandable(InstanceId::World));
	};
};
