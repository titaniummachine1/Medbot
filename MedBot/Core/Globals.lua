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

-- SmartJump integration
G.ShouldJump = false -- Set by SmartJump module when jump should be performed
G.LastSmartJumpAttempt = 0 -- Track last time SmartJump was attempted
G.LastEmergencyJump = 0 -- Track last emergency jump time
G.ObstacleDetected = false -- Track if obstacle is detected but no jump attempted
G.RequestEmergencyJump = false -- Request emergency jump from stuck detection

-- SmartJump state table
G.SmartJump = {
	Enable = true,
	SimulationPath = {},
	PredPos = nil,
	HitObstacle = false,
	JumpPeekPos = nil,
	stateStartTime = 0,
	lastState = nil,
	jumpState = "STATE_IDLE", -- Added missing jumpState initialization
	lastJumpTime = 0, -- Added missing lastJumpTime
	LastObstacleHeight = 0,
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

	-- 🛠️ FIX MEMORY LEAKS: Clean up debug timestamps and temporary variables
	local cleanupThreshold = 300 -- 5 seconds worth of ticks
	local keysToRemove = {}

	-- Find debug timestamps and temporary variables to clean up
	for key, value in pairs(G) do
		-- Clean up debug timestamps (keys ending with "Tick" that are numbers)
		if type(key) == "string" and key:find("Tick") and type(value) == "number" then
			if currentTick - value > cleanupThreshold then
				table.insert(keysToRemove, key)
			end
		end

		-- Clean up temporary debug variables (starting with "__" or containing "Debug")
		if type(key) == "string" and (key:sub(1, 2) == "__" or key:find("Debug")) then
			if type(value) == "number" and currentTick - value > cleanupThreshold then
				table.insert(keysToRemove, key)
			elseif type(value) ~= "number" then
				-- Clean up non-numeric debug variables immediately
				table.insert(keysToRemove, key)
			end
		end

		-- Clean up temporary cache variables that might accumulate
		if type(key) == "string" and key:find("Cache") and type(value) == "table" then
			if value.tick and currentTick - value.tick > cleanupThreshold then
				table.insert(keysToRemove, key)
			end
		end
	end

	-- Remove the identified keys
	for _, key in ipairs(keysToRemove) do
		G[key] = nil
	end

	if #keysToRemove > 0 then
		print(string.format("Cleaned up %d debug/temporary variables from G table", #keysToRemove))
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
