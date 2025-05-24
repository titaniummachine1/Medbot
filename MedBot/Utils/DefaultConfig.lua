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
		Enable = false,
		Skip_Nodes = false, --skips nodes if it can go directly to ones closer to target.
		Optymise_Path = false, --straighten the nodes into segments so you would go in straight line
		OptimizationLimit = 20, --how many nodes ahead to optymise
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
		CleanupConnections = false, -- Cleanup invalid connections during map load (disable to prevent crashes)
		AllowExpensiveChecks = false, -- Allow expensive walkability checks (rarely needed)
		-- Hierarchical pathfinding settings (fixed 24-unit spacing)
		UseHierarchicalPathfinding = false, -- Enable fine-grained points within areas for better accuracy
	},
	Visuals = {
		renderDistance = 800,
		EnableVisuals = true,
		memoryUsage = true,
		-- Combo-based display options
		basicDisplay = {true, true, true, true, false}, -- Show Nodes, Node IDs, Nav Connections, Areas, Fine Points
		connectionDisplay = {true, true, true}, -- Intra-Area, Inter-Area, Edge-to-Edge connections
		-- Individual settings (automatically set by combo selections)
		drawNodes = true, -- Draws all nodes on the map
		drawNodeIDs = true, -- Show node IDs  [[ Used by: MedBot.Visuals ]]
		drawPath = true, -- Draws the path to the current goal
		Objective = true,
		drawCurrentNode = false, -- Draws the current node
		showHidingSpots = true, -- Show hiding spots (areas where health packs are located)  [[ Used by: MedBot.Visuals ]]
		showConnections = true, -- Show connections between nodes  [[ Used by: MedBot.Visuals ]]
		showAreas = true, -- Show area outlines  [[ Used by: MedBot.Visuals ]]
		showFinePoints = false, -- Show fine-grained points within areas
		-- Fine point connection controls
		showIntraConnections = true, -- Show connections within the same area (blue)
		showInterConnections = true, -- Show connections between different areas (orange)
		showEdgeConnections = true, -- Show edge-to-edge connections within areas (bright blue)
	},
	Movement = {
		lookatpath = false, -- Look at where we are walking
		smoothLookAtPath = true, -- Set this to true to enable smooth look at path
		Smart_Jump = true, -- jumps perfectly before obstacle to be at peek of jump height when at colision point
	},
}

return defaultconfig
