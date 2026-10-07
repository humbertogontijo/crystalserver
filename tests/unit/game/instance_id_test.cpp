#include "pch.hpp"

#include <boost/ut.hpp>

#include "game/instance_id.hpp"

using namespace boost::ut;

suite<"instance_id"> instanceIdTest = [] {
	test("packs kind, subarea and channel") = [] {
		const InstanceId id(InstanceKind::Hunt, 2104284, 7);
		expect(id.kind() == InstanceKind::Hunt);
		expect(eq(id.subareaId(), 2104284u));
		expect(eq(id.channel(), uint16_t { 7 }));
		expect(id.isConcrete());
		expect(!id.isWorld());
		expect(!id.isAny());
		expect(id.withChannel(3) == InstanceId(InstanceKind::Hunt, 2104284, 3));
	};

	test("key round-trips for every kind") = [] {
		for (uint8_t k = 1; k < static_cast<uint8_t>(InstanceKind::Count); ++k) {
			const auto kind = static_cast<InstanceKind>(k);
			for (const auto &[subareaId, channel] : std::vector<std::pair<uint32_t, uint16_t>> { { 0, 0 }, { 1, 1 }, { 2996931, 65535 }, { 0xFFFFFFFFu, 12 } }) {
				const InstanceId id(kind, subareaId, channel);
				const auto parsed = InstanceId::fromKey(id.toKey());
				expect(parsed.has_value() && *parsed == id) << id.toKey();
			}
		}
	};

	test("world key") = [] {
		expect(eq(InstanceId::World.toKey(), std::string("world:0:0")));
		const auto parsed = InstanceId::fromKey("world:0:0");
		expect(parsed.has_value() && parsed->isWorld());
	};

	test("canonical text form") = [] {
		expect(eq(InstanceId(InstanceKind::City, 2005011, 2).toKey(), std::string("city:2005011:2")));
		expect(eq(InstanceId(InstanceKind::WorldBoss, 5, 0).toKey(), std::string("worldboss:5:0")));
		expect(eq(InstanceId(InstanceKind::Soulpit, 9, 1).toKey(), std::string("soulpit:9:1")));
	};

	test("rejects invalid keys") = [] {
		for (const std::string_view key : {
				 "",
				 "hunt",
				 "hunt:1",
				 "hunt:1:",
				 "hunt::1",
				 ":1:1",
				 "dungeon:1:1",
				 "Hunt:1:1",
				 "hunt:-1:0",
				 "hunt:1:-1",
				 "hunt:1:65536",
				 "hunt:4294967296:0",
				 "hunt:1:1:1",
				 "hunt:1x:1",
				 " hunt:1:1",
				 "world:1:0",
				 "world:0:1",
				 "any:0:0",
			 }) {
			expect(!InstanceId::fromKey(key).has_value()) << key;
		}
	};

	test("kind names round-trip") = [] {
		for (uint8_t k = 0; k < static_cast<uint8_t>(InstanceKind::Count); ++k) {
			const auto kind = static_cast<InstanceKind>(k);
			const auto parsed = instanceKindFromName(instanceKindName(kind));
			expect(parsed.has_value() && *parsed == kind);
		}
		expect(!instanceKindFromName("any").has_value());
	};

	test("kind classes") = [] {
		expect(isOpenWorldKind(InstanceKind::City));
		expect(isOpenWorldKind(InstanceKind::Hunt));
		expect(!isOpenWorldKind(InstanceKind::Hub));
		expect(!isOpenWorldKind(InstanceKind::Raid));
		expect(isPrivateOnlyKind(InstanceKind::Soulpit));
		expect(isPrivateOnlyKind(InstanceKind::WorldBoss));
		expect(!isPrivateOnlyKind(InstanceKind::Hunt));
		expect(InstanceId(InstanceKind::Hub, 1, 0).isImplicitMain());
		expect(InstanceId(InstanceKind::City, 1, 0).isImplicitMain());
		expect(!InstanceId(InstanceKind::City, 1, 1).isImplicitMain());
		expect(!InstanceId(InstanceKind::Raid, 1, 0).isImplicitMain());
	};

	test("any is a wildcard, never world") = [] {
		expect(InstanceId::Any.isAny());
		expect(!InstanceId::Any.isWorld());
		expect(!InstanceId::Any.isConcrete());
		expect(InstanceId::Any != InstanceId::World);
	};
};
