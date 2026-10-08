-- Cave walker knobs shared by expedition hunts and open-world runs (Cavebot).
-- ExpeditionConfig aliases every key in SHARED_KEYS (expeditions/02_config.lua).

CavebotConfig = CavebotConfig or {}

-- Run tick (open-world runs; expedition sessions tick in ExpeditionAI at the same rate).
CavebotConfig.TICK_MS = 250
-- Engaged monsters farther than this from the anchor stop being tracked. Bookkeeping
-- only: the lure and the leash only count chasers on a member's screen.
CavebotConfig.RELEASE_RADIUS = 18
-- Engaged monsters that make no progress toward the party for this long stop being tracked.
CavebotConfig.PULL_STALL_MS = 8000
-- Dynamic lure: walking the cave route, once lure * LURE_STOP_FACTOR monsters engage
-- the team (on the anchor's screen or chasing a member on its screen) the anchor halts: at the next
-- hold when it is on screen, else near where it stands (LURE_FULL_SPOT_STEPS).
-- `cave.lure` counts spawns seen over a whole lure walk (it also sets hunt levels);
-- the party kills on the way, so only about half of that is ever on screen at once.
CavebotConfig.LURE_STOP_FACTOR = 0.5
-- A halt walks on (still attacking) once the monsters in the lure add up
-- to at most this many full-health monsters: the sum of their health fractions, so 1
-- can be one untouched monster or two at half health.
CavebotConfig.LURE_RESUME_LOAD = 1
-- Halted with engaged monsters but no kill for this long (out of reach): walk on.
CavebotConfig.HALT_STUCK_MS = 20000
-- A halt walks straight to the best fight tile (AnchorSpot terrain score, the one
-- generation placed the hold with) within this many walking steps of the hold.
CavebotConfig.HALT_SPOT_STEPS = 3
-- A halt tile the anchor cannot path to is replaced by the next best near the hold at
-- most HALT_REPICK_MAX times, then by the most open free tile next to the anchor once,
-- then it fights where it stands.
CavebotConfig.HALT_REPICK_MAX = 4
-- Blocker rule: the anchor stands still this long with an
-- attackable monster in the way of its next waypoint → halt and kill it.
CavebotConfig.BLOCKER_MS = 1000
-- Lure leash (any count): walking, the anchor stands still when a monster chasing any
-- member trails that member by more than LURE_LAG_SQM (it would lose its lock) or the
-- anchor by more than LURE_LEASH_SQM (kept on the anchor's screen), and walks on once
-- every chaser is within LURE_LAG_RESUME_SQM of its target and LURE_LEASH_SQM - 2 of the
-- anchor. A wait whose lag does not shrink for LURE_LAG_STALL_MS gives those chasers up
-- for PULL_STALL_MS. Never waits while LURE_WAIT_SKIP_ADJACENT or more chasers are
-- adjacent (anti-trap).
CavebotConfig.LURE_LAG_SQM = 4
CavebotConfig.LURE_LAG_RESUME_SQM = 2
CavebotConfig.LURE_LEASH_SQM = 6
CavebotConfig.LURE_LAG_STALL_MS = 2500
CavebotConfig.LURE_WAIT_SKIP_ADJACENT = 4
-- Lure full mid-route (no hold on screen): halt at the best spot within this many
-- walking steps of the anchor, inside the viewport so the pack stays in sight.
CavebotConfig.LURE_FULL_SPOT_STEPS = 4
-- ...unless the best spot there has fewer than HALT_OPEN_RING standable neighbours and
-- the next hold is within LURE_FULL_HOLD_SQM: then it walks on and fights at the hold.
CavebotConfig.HALT_OPEN_RING = 7
CavebotConfig.LURE_FULL_HOLD_SQM = 8
-- Anchor within this Chebyshev distance of a waypoint counts as reached.
CavebotConfig.WAYPOINT_REACH = 1
-- Advance to the next waypoint this many steps early, so its path replaces the
-- current one mid-walk instead of restarting from a standstill.
CavebotConfig.WAYPOINT_LOOKAHEAD = 1
-- No progress toward the current waypoint for this long (walking alone) skips it.
CavebotConfig.WAYPOINT_STALL_MS = 6000
-- Fiendish Hunt: off screen but within this Chebyshev distance of the anchor, the
-- anchor detours off the route toward the forced Fiendish. A Fiendish the party
-- cannot reach (stalled detour / stuck halt) is ignored for FIENDISH_IGNORE_MS.
CavebotConfig.FIENDISH_DETOUR_SQM = 14
CavebotConfig.FIENDISH_IGNORE_MS = 30000
-- Lure bounds (pack size the anchor halts at). Hunts ship their own `cave.lure`
-- (uncapped, it also sets hunt levels); the halt count is clamped to LURE_MAX.
CavebotConfig.LURE_MAX = 16
CavebotConfig.LURE_DEFAULT = 1

-- Open-world layers the cavebot runs in (Instance.kind of public channels).
CavebotConfig.OPEN_KINDS = { hunt = true, wild = true }
-- A route a generated walk needs at least this many spawn tiles for.
CavebotConfig.GENERATED_MIN_SPAWNS = 2
-- Flood cap (tiles) of the walk component a route is generated on.
CavebotConfig.WALK_GRID_CAP = 12000

CavebotConfig.SHARED_KEYS = {
	"RELEASE_RADIUS",
	"PULL_STALL_MS",
	"LURE_STOP_FACTOR",
	"LURE_RESUME_LOAD",
	"HALT_STUCK_MS",
	"HALT_SPOT_STEPS",
	"HALT_REPICK_MAX",
	"BLOCKER_MS",
	"LURE_LAG_SQM",
	"LURE_LAG_RESUME_SQM",
	"LURE_LEASH_SQM",
	"LURE_LAG_STALL_MS",
	"LURE_WAIT_SKIP_ADJACENT",
	"LURE_FULL_SPOT_STEPS",
	"HALT_OPEN_RING",
	"LURE_FULL_HOLD_SQM",
	"WAYPOINT_REACH",
	"WAYPOINT_LOOKAHEAD",
	"WAYPOINT_STALL_MS",
	"FIENDISH_DETOUR_SQM",
	"FIENDISH_IGNORE_MS",
	"LURE_MAX",
	"LURE_DEFAULT",
}
