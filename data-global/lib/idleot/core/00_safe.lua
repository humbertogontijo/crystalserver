-- IdleSafe.call runs a step whose failure must not abort its caller (one module's hook in
-- a login / save / think fan-out) and logs the error with its traceback instead of
-- dropping it. Code already running in an IdleEvents handler or a Scope callback is
-- protected and logged there; call it directly.

IdleSafe = IdleSafe or {}

local traceback = debug.traceback

local function finish(tag, ok, ...)
	if not ok then
		logger.error("[{}] {}", tag, tostring((...)))
	end
	return ok, ...
end

--- `fn(...)` under xpcall. Returns ok followed by fn's results (or the error).
function IdleSafe.call(tag, fn, ...)
	return finish(tag, xpcall(fn, traceback, ...))
end
