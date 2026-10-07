#include "pch.hpp"

#include <boost/ut.hpp>

#include "game/instance_registry.hpp"
#include "injection_fixture.hpp"

using namespace boost::ut;

namespace {
	InstanceRegistry::AllocOptions reserved(std::string owner = {}, std::string tag = {}) {
		InstanceRegistry::AllocOptions options;
		options.reserved = true;
		options.owner = std::move(owner);
		options.tag = std::move(tag);
		return options;
	}
}

suite<"instance_registry"> instanceRegistryTest = [] {
	InjectionFixture injectionFixture {};

	test("world and implicit main channels are always live") = [] {
		InstanceRegistry registry;
		expect(registry.isLive(InstanceId::World));
		expect(registry.isLive(InstanceId(InstanceKind::City, 10, 0)));
		expect(registry.isLive(InstanceId(InstanceKind::Hub, 1, 0)));
		expect(!registry.isLive(InstanceId::Any));
		expect(!registry.isLive(InstanceId(InstanceKind::City, 10, 1)));
		expect(!registry.isLive(InstanceId(InstanceKind::Raid, 10, 0)));
	};

	test("allocate records owner and tag") = [] {
		InstanceRegistry registry;
		const auto id = registry.allocate(InstanceKind::Hunt, 42, reserved("team-1", "boss"));
		expect(id.has_value());
		expect(id->kind() == InstanceKind::Hunt);
		expect(eq(id->subareaId(), 42u));
		expect(neq(id->channel(), uint16_t { 0 })) << "hunt channel 0 is the public main layer";
		expect(registry.isLive(*id));
		expect(registry.isReserved(*id));
		expect(registry.isPrivate(*id));
		const auto* record = registry.find(*id);
		expect(record != nullptr);
		expect(eq(record->owner, std::string("team-1")));
		expect(eq(record->tag, std::string("boss")));
	};

	test("private-only kinds start at channel 0") = [] {
		InstanceRegistry registry;
		const auto id = registry.allocate(InstanceKind::Raid, 7, reserved());
		expect(id.has_value() && id->channel() == 0);
		expect(registry.isPrivate(*id));
	};

	test("released numbers are not reused by the next session") = [] {
		InstanceRegistry registry;
		const auto first = registry.allocate(InstanceKind::Raid, 7, reserved());
		const auto second = registry.allocate(InstanceKind::Raid, 7, reserved());
		expect(first.has_value() && second.has_value());
		expect(*first != *second);
		expect(registry.release(*first));
		expect(!registry.isLive(*first));
		expect(!registry.release(*first)) << "double release";
		const auto third = registry.allocate(InstanceKind::Raid, 7, reserved());
		expect(third.has_value());
		expect(*third != *first);
		expect(*third != *second);
		expect(third->channel() > second->channel());
	};

	test("closing instances are not live") = [] {
		InstanceRegistry registry;
		const auto id = registry.allocate(InstanceKind::Arena, 3, reserved());
		expect(id.has_value());
		expect(registry.markClosing(*id));
		expect(!registry.isLive(*id));
		expect(registry.find(*id) != nullptr);
	};

	test("subareas count channels independently") = [] {
		InstanceRegistry registry;
		const auto a = registry.allocate(InstanceKind::Raid, 1, reserved());
		const auto b = registry.allocate(InstanceKind::Raid, 2, reserved());
		expect(a.has_value() && b.has_value());
		expect(eq(a->channel(), b->channel()));
		expect(*a != *b);
	};

	test("invalid kinds are refused") = [] {
		InstanceRegistry registry;
		expect(!registry.allocate(InstanceKind::World, 1, reserved()).has_value());
		expect(!registry.allocate(InstanceKind::Any, 1, reserved()).has_value());
		expect(!registry.allocate(InstanceKind::Count, 1, reserved()).has_value());
	};

	test("allocate returns nullopt when every channel is taken") = [] {
		InstanceRegistry registry;
		uint32_t opened = 0;
		while (registry.allocate(InstanceKind::Lobby, 9, reserved()).has_value()) {
			++opened;
			if (opened > 0x10000) {
				break;
			}
		}
		expect(eq(opened, 0x10000u));
		expect(!registry.allocate(InstanceKind::Lobby, 9, reserved()).has_value());
	};

	test("members follow player binds") = [] {
		InstanceRegistry registry;
		const auto hunt = registry.allocate(InstanceKind::Hunt, 5, reserved());
		expect(hunt.has_value());
		const InstanceId city(InstanceKind::City, 5, 0);

		registry.setPlayerInstance(100, city);
		registry.setPlayerInstance(101, city);
		expect(eq(registry.playerCount(city), 2u));

		registry.updatePlayerInstance(100, *hunt);
		expect(eq(registry.playerCount(city), 1u));
		expect(eq(registry.playerCount(*hunt), 1u));
		expect(registry.members(*hunt) == std::vector<uint32_t> { 100 });

		registry.updatePlayerInstance(999, *hunt);
		expect(eq(registry.playerCount(*hunt), 1u)) << "update ignores players that never logged in";

		registry.removePlayer(100);
		expect(eq(registry.playerCount(*hunt), 0u));
		expect(registry.members(*hunt).empty());
		registry.removePlayer(100);
	};

	test("pickChannel prefers the current channel and respects capacity") = [] {
		InstanceRegistry registry;
		registry.setKindCapacity(InstanceKind::City, 1);
		const auto first = registry.pickChannel(InstanceKind::City, 8, std::nullopt);
		expect(first.has_value() && first->channel() == 0);
		registry.setPlayerInstance(1, *first);

		const auto overflow = registry.pickChannel(InstanceKind::City, 8, std::nullopt);
		expect(overflow.has_value() && overflow->channel() != 0) << "main layer is full";
		expect(registry.isLive(*overflow));
		expect(!registry.isPrivate(*overflow));

		const auto reservedId = registry.allocate(InstanceKind::City, 8, reserved());
		expect(reservedId.has_value());
		const auto picked = registry.pickChannel(InstanceKind::City, 8, reservedId->channel());
		expect(picked.has_value() && *picked != *reservedId) << "reserved channels are never picked";
	};
};
