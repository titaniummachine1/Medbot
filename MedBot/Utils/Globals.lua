-- Define the G module
local G = {}

G.Menu = {
	Tabs = {
		Main = true,
		Settings = false,
		Visuals = false,
		Movement = false,
	},

	Main = {
		Enable = true,
		Skip_Nodes = false, --skips nodes if it can go directly to ones closer to target.
		Optymise_Path = false, --straighten the nodes into segments so you would go in straight line
		OptimizationLimit = 20, --how many nodes ahead to optymise
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
	},
	Visuals = {
		EnableVisuals = true,
		memoryUsage = true,
		drawNodes = true, -- Draws all nodes on the map
		drawNodeIDs = true, -- Show node IDs  [[ Used by: MedBot.Visuals ]]
		drawPath = true, -- Draws the path to the current goal
		Objective = true,
		drawCurrentNode = false, -- Draws the current node
		showHidingSpots = true, -- Show hiding spots (areas where health packs are located)  [[ Used by: MedBot.Visuals ]]
		showConnections = true, -- Show connections between nodes  [[ Used by: MedBot.Visuals ]]
		showAreas = true, -- Show area outlines  [[ Used by: MedBot.Visuals ]]
	},
	Movement = {
		lookatpath = false, -- Look at where we are walking
		smoothLookAtPath = true, -- Set this to true to enable smooth look at path
		Smart_Jump = true, -- jumps perfectly before obstacle to be at peek of jump height when at colision point
	},
}

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
	vHitbox = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) },
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
	NodeTouchDistance = 10,
	NodeTouchHeight = 82,
	workLimit = 1,
}

G.Navigation = {
	path = nil,
	rawNodes = nil,
	nodes = nil,
	currentNode = nil,
	currentNodePos = nil,
	currentNodeID = 1,
	currentNodeTicks = 0,
	FirstAgentNode = 1,
	SecondAgentNode = 2,
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

function G.ReloadNodes()
	G.Navigation.nodes = G.Navigation.rawNodes
end

return G
