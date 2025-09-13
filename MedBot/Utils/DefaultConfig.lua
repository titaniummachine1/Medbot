local defaultconfig
defaultconfig = {
	Tab = "Main",
	Tabs = {
		Main = true,
		Settings = false,
		Visuals = false,
		Movement = false,
	},

	Main = {
		Enable = true,
		Skip_Nodes = true, --skips nodes if it can go directly to ones closer to target.
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
		LookingAhead = true, -- Enable automatic camera rotation towards target node
		WalkableMode = "Smooth", -- "Smooth" uses 18-unit steps, "Aggressive" allows 72-unit jumps
		CleanupConnections = true, -- Cleanup invalid connections during map load (disable to prevent crashes)
		AllowExpensiveChecks = true, -- Allow expensive walkability checks for proper stair/ramp connections
		Duck_Grab = false, --only for testing rn
		-- Hierarchical pathfinding removed
	},
	Visuals = {
		renderRadius = 400, -- Manhattan radius used by visuals culling (x+y+z)
		chunkSize = 256,
		renderChunks = 3,
		EnableVisuals = true,
		memoryUsage = true,
		ignorePathRadius = true, -- When true, path lines ignore render radius and draw full route
		showAgentBoxes = false, -- Optional legacy agent 3D boxes
		-- Combo-based display options
		basicDisplay = { false, false, false, true, true, false }, -- Show Nodes, Node IDs, Nav Connections, Areas, Doors, Corner Connections
		-- Individual settings (automatically set by combo selections)
		drawNodes = false, -- Draws all nodes on the map
		drawNodeIDs = false, -- Show node IDs  [[ Used by: MedBot.Visuals ]]
		drawPath = true, -- Draws the path to the current goal
		Objective = true,
		drawCurrentNode = false, -- Draws the current node
		showHidingSpots = false, -- Show hiding spots (areas where health packs are located)  [[ Used by: MedBot.Visuals ]]
		showConnections = false, -- Show connections between nodes  [[ Used by: MedBot.Visuals ]]
		showAreas = true, -- Show area outlines  [[ Used by: MedBot.Visuals ]]
		showDoors = true,
		showCornerConnections = false, -- Show corner connections  [[ Used by: MedBot.Visuals ]]
	},
	Movement = {
		lookatpath = true, -- Look at where we are walking
		smoothLookAtPath = true, -- Set this to true to enable smooth look at path
		Smart_Jump = true, -- jumps perfectly before obstacle to be at peek of jump height when at colision point
	},
	SmartJump = {
		Enable = true,
		Debug = false,
	},
}

return defaultconfig
