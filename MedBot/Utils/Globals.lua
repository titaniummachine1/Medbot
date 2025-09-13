local DefaultConfig = require("MedBot.Utils.DefaultConfig")
-- Define the G module
local G = {}

G.Menu = DefaultConfig

G.Default = {
	entity = nil,
	index = 1,
	team = 1,
	Class = 1,
	flags = 1,
	OnGround = true,
	Origin = Vector3(0, 0, 0),
	ViewAngles = EulerAngles(90, 0, 0),
	Viewheight = Vector3(0, 0, 75),
	VisPos = Vector3(0, 0, 75),
	vHitbox = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 45) },
}

G.pLocal = G.Default

G.World_Default = {
	players = {},
	healthPacks = {}, -- Stores positions of health packs
	spawns = {}, -- Stores positions of spawn points
	payloads = {}, -- Stores payload entities in payload maps
	flags = {}, -- Stores flag entities in CTF maps (implicitly included in the logic)
}

G.World = G.World_Default

G.Misc = {
	NodeTouchDistance = 24,
	NodeTouchHeight = 82,
	workLimit = 1,
}

G.Navigation = {
	path = nil,
	nodes = nil,
	currentNodeIndex = 1, -- Current node we're moving towards (1 = first node in path)
	currentNodeTicks = 0,
	stuckStartTick = nil, -- Track when we first entered stuck state
	FirstAgentNode = 1,
	SecondAgentNode = 2,
	lastKnownTargetPosition = nil, -- Remember last position of follow target
	goalPos = nil, -- Current goal world position
	goalNodeId = nil, -- Closest node to the goal position
	navMeshUpdated = false, -- Set when navmesh is rebuilt
}

-- SmartJump configuration
G.Menu.SmartJump = {
	Enable = true,
	Debug = false,
}

-- SmartJump runtime state and constants
G.SmartJump = G.SmartJump or {
    -- Constants (must be defined first)
    Constants = {
        GRAVITY = 800, -- Gravity per second squared
        JUMP_FORCE = 271, -- Initial vertical boost for a duck jump
        MAX_JUMP_HEIGHT = Vector3(0, 0, 72), -- Maximum jump height vector
        MAX_WALKABLE_ANGLE = 45, -- Maximum angle considered walkable

        -- State definitions
        STATE_IDLE = "STATE_IDLE",
        STATE_PREPARE_JUMP = "STATE_PREPARE_JUMP",
        STATE_CTAP = "STATE_CTAP",
        STATE_ASCENDING = "STATE_ASCENDING",
        STATE_DESCENDING = "STATE_DESCENDING"
    },
    
    -- Runtime state
    jumpState = "STATE_IDLE",
    ShouldJump = false,
    LastSmartJumpAttempt = 0,
    LastEmergencyJump = 0,
    ObstacleDetected = false,
    RequestEmergencyJump = false,
    
    -- Movement state
    SimulationPath = {},
    PredPos = nil,
    JumpPeekPos = nil,
    HitObstacle = false,
    lastAngle = nil,
    stateStartTime = 0,
    lastState = nil,
    lastJumpTime = 0
}

-- Bot movement tracking (for SmartJump integration)
G.BotIsMoving = false -- Track if bot is actively moving
G.BotMovementDirection = Vector3(0, 0, 0) -- Bot's intended movement direction

-- Memory management and cache tracking
G.Cache = {
	lastCleanup = 0,
	cleanupInterval = 2000, -- Clean up every 2000 ticks (~30 seconds)
	maxCacheSize = 1000, -- Maximum number of cached items
}

G.Tasks = {
	None = 0,
	Objective = 1,
	Follow = 2,
	Health = 3,
	Medic = 4,
	Goto = 5,
}

G.Current_Tasks = {}
G.Current_Task = G.Tasks.Objective

G.Benchmark = {
	MemUsage = 0,
}

-- Define states
G.States = {
	IDLE = "IDLE",
	PATHFINDING = "PATHFINDING",
	MOVING = "MOVING",
	STUCK = "STUCK",
}

G.currentState = nil
G.prevState = nil -- Track previous bot state
G.wasManualWalking = false -- Track if user manually walked last tick

-- Function to clean up memory and caches
function G.CleanupMemory()
	local currentTick = globals.TickCount()
	if currentTick - G.Cache.lastCleanup < G.Cache.cleanupInterval then
		return -- Too soon to cleanup
	end

	-- Update memory usage statistics
	local memUsage = collectgarbage("count")
	G.Benchmark.MemUsage = memUsage

	-- NOTE: Fine point caches are kept to avoid expensive re-generation
	-- when garbage collection happens.

	-- Hierarchical pathfinding removed
	G.Navigation.hierarchical = nil

	-- Reset stuck timer if it's been set for too long (prevents infinite stuck states)
	if G.Navigation.stuckStartTick and (currentTick - G.Navigation.stuckStartTick) > 1000 then
		print("Reset stuck timer during cleanup (was stuck for >1000 ticks)")
		G.Navigation.stuckStartTick = nil
		G.Navigation.currentNodeTicks = 0
	end

	-- Force garbage collection if memory usage is high
	local memBefore = memUsage
	if memUsage > 1024 * 1024 then -- More than 1GB
		collectgarbage("collect")
		memUsage = collectgarbage("count")
		G.Benchmark.MemUsage = memUsage
		print(string.format("Force GC: %.2f MB -> %.2f MB", memBefore / 1024, memUsage / 1024))
	end

	G.Cache.lastCleanup = currentTick
end

return G
