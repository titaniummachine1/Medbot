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
	Origin = Vector3({ 0, 0, 0 }),
	ViewAngles = EulerAngles({ 90, 0, 0 }),
	Viewheight = Vector3({ 0, 0, 75 }),
	VisPos = Vector3({ 0, 0, 75 }),
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
	FirstAgentNode = 1,
	SecondAgentNode = 2,
	lastKnownTargetPosition = nil, -- Remember last position of follow target
}

-- SmartJump integration
G.ShouldJump = false -- Set by SmartJump module when jump should be performed
G.LastSmartJumpAttempt = 0 -- Track last time SmartJump was attempted
G.LastEmergencyJump = 0 -- Track last emergency jump time
G.ObstacleDetected = false -- Track if obstacle is detected but no jump attempted
G.RequestEmergencyJump = false -- Request emergency jump from stuck detection

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

-- Function to clean up memory and caches
function G.CleanupMemory()
	local currentTick = globals.TickCount()
	if currentTick - G.Cache.lastCleanup < G.Cache.cleanupInterval then
		return -- Too soon to cleanup
	end

	-- Clear old cached fine points if we have too many areas cached
	if G.Navigation.nodes then
		local cachedCount = 0
		local areasToClean = {}

		for areaId, area in pairs(G.Navigation.nodes) do
			if area.finePoints then
				cachedCount = cachedCount + 1
				if cachedCount > G.Cache.maxCacheSize then
					table.insert(areasToClean, areaId)
				end
			end
		end

		-- Clear oldest cached fine points
		for _, areaId in ipairs(areasToClean) do
			if G.Navigation.nodes[areaId] then
				G.Navigation.nodes[areaId].finePoints = nil
			end
		end

		if #areasToClean > 0 then
			print(string.format("Cleaned up %d cached fine point areas", #areasToClean))
		end
	end

	-- Clear unused hierarchical data if pathfinding is disabled
	if not G.Menu.Main.UseHierarchicalPathfinding and G.Navigation.hierarchical then
		G.Navigation.hierarchical = nil
		print("Cleared hierarchical data (not in use)")
	end

	-- Force garbage collection if memory usage is high
	local memUsage = collectgarbage("count")
	if memUsage > 512 * 1024 then -- More than 512MB
		collectgarbage("collect")
		print(string.format("Force GC: %.2f MB -> %.2f MB", memUsage / 1024, collectgarbage("count") / 1024))
	end

	G.Cache.lastCleanup = currentTick
end

return G
