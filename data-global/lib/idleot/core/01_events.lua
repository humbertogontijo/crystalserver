-- Product event bus. A module publishes what happened (IdleEvents.emit) and others react
-- (IdleEvents.on) without calling each other, so a new system hooks in without touching
-- the publisher. Handlers run in subscription order, each under pcall: a failing handler
-- is logged and the rest still run. Emitting an event nobody listens to costs one lookup.
--
-- Events (arguments):
--   instance.released (instanceKey)                    engine released an instance (any kind)
--   session.started (session)                          expedition party entered its instance
--   session.ended (session)                            expedition session cleaned up
--   member.paused (run, player)                        AI stopped driving a member (manual / pause);
--                                                      run: expedition session or open-world cave run
--   member.resumed (run, player)                       AI drives the member again
--   boss.bound (session, monster)                      expedition bound a (new form of a) boss
--   encounter.stage (encounter, stageNumber)           an Encounter (stock or instance copy) entered a stage
--   creature.eventRegistered (creature, eventName)     creature event registered on a creature
--   creature.eventUnregistered (creature, eventName)   creature event unregistered from a creature
--   monster.died (monster, killer)                     product-tracked monster died (expeditions, raids)
--   zone.itemAdded (zone, item)                        item placed inside a zone
--   zone.itemRemoved (zone, item)                      item removed from a zone (transform: removed then added)
--   player.walkDone (player, completed)                the player's queued walk ran out or was cancelled
--                                                      (next tick; any walk, scripted or client)
--
-- Prefer Scope:on (02_scope.lua) in session / instance code: it unsubscribes on dispose.

IdleEvents = IdleEvents or { handlers = {} }
IdleEvents.keyed = IdleEvents.keyed or {}

local handlers, keyed = IdleEvents.handlers, IdleEvents.keyed

--- Subscribe `fn(...)` to `name`. Returns a function that unsubscribes it. A `key` replaces
--- the earlier subscription with that key (module-level subscriptions stay single when the
--- libs are reloaded).
function IdleEvents.on(name, fn, key)
	if key then
		local slot = name .. "|" .. key
		if keyed[slot] then
			keyed[slot]()
		end
		local unsubscribe = IdleEvents.on(name, fn)
		keyed[slot] = unsubscribe
		return unsubscribe
	end
	-- Lists are copied on write, so an emit in progress keeps the list it started with.
	local copy = {}
	for i, handler in ipairs(handlers[name] or {}) do
		copy[i] = handler
	end
	copy[#copy + 1] = fn
	handlers[name] = copy
	local subscribed = true
	return function()
		local current = subscribed and handlers[name]
		if not current then
			return
		end
		subscribed = false
		local kept, removed = {}, false
		for _, handler in ipairs(current) do
			if handler == fn and not removed then
				removed = true
			else
				kept[#kept + 1] = handler
			end
		end
		handlers[name] = #kept > 0 and kept or nil
	end
end

--- True when something listens to `name` (skip building costly arguments otherwise).
function IdleEvents.has(name)
	return handlers[name] ~= nil
end

function IdleEvents.emit(name, ...)
	local list = handlers[name]
	if not list then
		return
	end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok then
			logger.error("[IdleEvents] {} handler failed: {}", name, tostring(err))
		end
	end
end
