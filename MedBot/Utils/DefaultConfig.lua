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
		Duck_Grab = true,
		Debug = false, -- Enable debug logging across all modules
	},
	Visuals = {
		EnableVisuals = true,
		connectionDepth = 4, -- Flood-fill depth: how many connection steps from player to visualize (1-50)
		memoryUsage = false,
		drawPath = true, -- Draws the path to the current goal
		showConnections = true, -- Show area↔door triangle connections
		showAreas = true, -- Show area outlines
		showDoors = true, -- Show door lines (cyan)
		showCornerConnections = false, -- Show wall corner points (orange)
		showD2D = false, -- Show door-to-door connections (light blue)
		showNodeIds = false, -- Show node ID numbers for debugging
		showAgentBoxes = false, -- Show agent boxes
		showSmartJump = false, -- Show SmartJump hitbox and trajectory visualization
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
