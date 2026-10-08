////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include "game/game_definitions.hpp"
#include "game/instance_id.hpp"

#include <parallel_hashmap/phmap.h>

#include <array>
#include <map>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

class Player;

/**
 * Single source of truth for live instances.
 *
 * A channel is a parallel layer of a subarea: channel N is unique within its {kind, subarea};
 * channel 0 is the main public layer of open-world kinds and the hub and always exists.
 * Public channels fill up to the kind's player cap before a new one opens; reserved channels
 * belong to one owner (expedition team, lobby room, raid, ...) and are never handed out by
 * pickChannel. Reserved channel numbers are allocated from a per-{kind, subarea} counter that
 * only moves forward, so a key captured by a script does not silently point at a newer session.
 *
 * Membership (online players and monsters per instance) is maintained incrementally by
 * Game::addPlayer / removePlayer / addMonster / removeMonster and Creature::setInstanceId.
 */
class InstanceRegistry {
public:
	enum class State : uint8_t {
		Live,
		Closing,
	};

	struct Instance {
		InstanceId id;
		bool reserved = false;
		std::string owner;
		/** Free-form label (world boss band, soul pit, ...). */
		std::string tag;
		int64_t createdAt = 0;
		/** Milliseconds since epoch the channel last became empty (0 = has players / unknown). */
		int64_t emptySince = 0;
		State state = State::Live;
		std::optional<WorldType_t> worldType;
	};

	struct AllocOptions {
		bool reserved = true;
		std::string owner;
		std::string tag;
	};

	/** Who is picking a channel: their player id, cap bypass (gods) and party companions. */
	struct PickHints {
		uint32_t playerId = 0;
		bool bypassCap = false;
		std::vector<uint32_t> companions;
	};

	static InstanceRegistry &getInstance();

	/** 0 = unlimited. */
	void setKindCapacity(InstanceKind kind, uint32_t maxPlayers);
	[[nodiscard]] uint32_t kindCapacity(InstanceKind kind) const;

	/** Opens a new channel of {kind, subareaId}; nullopt when the kind is invalid or every number is taken. */
	[[nodiscard]] std::optional<InstanceId> allocate(InstanceKind kind, uint32_t subareaId, const AllocOptions &options);
	/** Opens `instanceId` as a public channel (no-op when already live). */
	void open(InstanceId instanceId);
	/** Marks a live instance as tearing down: isLive() turns false while its content is swept. */
	bool markClosing(InstanceId instanceId);
	/** Forgets an instance. Returns false when it was not registered. */
	bool release(InstanceId instanceId);

	[[nodiscard]] const Instance* find(InstanceId instanceId) const;
	/** World, implicit main channels and registered instances that are not closing. */
	[[nodiscard]] bool isLive(InstanceId instanceId) const;
	[[nodiscard]] bool isReserved(InstanceId instanceId) const;
	/** Private session layer: a reserved channel, or a kind that only exists as private sessions
	 *  (lobby, raid, arena, world boss, soul pit). World/hub/open-world public channels are not. */
	[[nodiscard]] bool isPrivate(InstanceId instanceId) const;
	/** Live channel ids of {kind, subareaId}, ascending (channel 0 included for open-world kinds). */
	[[nodiscard]] std::vector<InstanceId> channelsOf(InstanceKind kind, uint32_t subareaId) const;
	/** Every registered instance (implicit main channels only once opened). */
	[[nodiscard]] std::vector<InstanceId> all() const;

	/** Per-instance PvP override; false when the instance is not live. */
	bool setWorldType(InstanceId instanceId, WorldType_t type);
	[[nodiscard]] std::optional<WorldType_t> worldType(InstanceId instanceId) const;

	/** Online player joins the registry (Game::addPlayer). */
	void setPlayerInstance(uint32_t playerId, InstanceId instanceId);
	/** Rebind of a player already online; no-op for players not yet added. */
	void updatePlayerInstance(uint32_t playerId, InstanceId instanceId);
	void removePlayer(uint32_t playerId);
	/** Online players currently bound to `instanceId`. */
	[[nodiscard]] uint32_t playerCount(InstanceId instanceId) const;
	[[nodiscard]] std::vector<uint32_t> members(InstanceId instanceId) const;

	/** Monster on the map joins the registry (Game::addMonster). */
	void setMonsterInstance(uint32_t monsterId, InstanceId instanceId);
	/** Rebind of a monster already on the map; no-op for monsters not yet added. */
	void updateMonsterInstance(uint32_t monsterId, InstanceId instanceId);
	void removeMonster(uint32_t monsterId);
	/** Monsters currently bound to `instanceId` (summons included). */
	[[nodiscard]] uint32_t monsterCount(InstanceId instanceId) const;
	[[nodiscard]] std::vector<uint32_t> monsters(InstanceId instanceId) const;

	/**
	 * Public channel a player should join on {kind, subareaId}. Channel numbers belong to their
	 * subarea, so a channel number never carries over from another subarea:
	 * 1) `preferred` (an explicit channel request) when it is live/public (or 0) and has room,
	 * 2) the player's current channel when they already are on this {kind, subarea},
	 * 3) the channel holding most of the player's party (lowest on ties) with room,
	 * 4) the lowest public channel with room,
	 * 5) a newly opened channel.
	 * Gods bypass the cap.
	 */
	[[nodiscard]] std::optional<InstanceId> pickChannel(InstanceKind kind, uint32_t subareaId, std::optional<uint16_t> preferred, const std::shared_ptr<Player> &player = nullptr);
	[[nodiscard]] std::optional<InstanceId> pickChannel(InstanceKind kind, uint32_t subareaId, std::optional<uint16_t> preferred, const PickHints &hints);

	/**
	 * Refreshes emptiness of every public non-main channel and returns the ones empty for at
	 * least `graceMs`. The caller tears down their content, then releases them.
	 */
	[[nodiscard]] std::vector<InstanceId> sweepIdle(int64_t nowMs, int64_t graceMs);

private:
	[[nodiscard]] static InstanceId groupKey(InstanceKind kind, uint32_t subareaId) {
		return InstanceId(kind, subareaId, 0);
	}
	/** Creature id <-> instance, maintained incrementally. */
	struct CreatureIndex {
		void bind(uint32_t creatureId, InstanceId instanceId);
		void rebind(uint32_t creatureId, InstanceId instanceId);
		void unbind(uint32_t creatureId);
		[[nodiscard]] uint32_t count(InstanceId instanceId) const;
		[[nodiscard]] bool contains(InstanceId instanceId, uint32_t creatureId) const;
		[[nodiscard]] std::vector<uint32_t> ids(InstanceId instanceId) const;
		[[nodiscard]] std::optional<InstanceId> instanceOf(uint32_t creatureId) const;

	private:
		phmap::flat_hash_map<InstanceId, phmap::flat_hash_set<uint32_t>> idsByInstance;
		phmap::flat_hash_map<uint32_t, InstanceId> instanceById;
	};

	Instance &emplace(InstanceId id, bool reserved, std::string owner, std::string tag);
	[[nodiscard]] uint32_t playerCountExcluding(InstanceId instanceId, uint32_t playerId) const;

	std::array<uint32_t, static_cast<size_t>(InstanceKind::Count)> capacityByKind {};
	// groupKey -> channel number -> record
	phmap::flat_hash_map<InstanceId, std::map<uint16_t, Instance>> channelsByGroup;
	// groupKey -> next reserved channel number to try
	phmap::flat_hash_map<InstanceId, uint32_t> nextReservedByGroup;
	CreatureIndex playerIndex;
	CreatureIndex monsterIndex;
};

constexpr auto g_instanceRegistry = InstanceRegistry::getInstance;
