--[[debug commands
    client.SetConVar("cl_vWeapon_sway_interp",              0)             -- Set cl_vWeapon_sway_interp to 0
    client.SetConVar("cl_jiggle_bone_framerate_cutoff", 0)             -- Set cl_jiggle_bone_framerate_cutoff to 0
    client.SetConVar("cl_bobcycle",                     10000)         -- Set cl_bobcycle to 10000
    client.SetConVar("sv_cheats", 1)                                    -- debug fast setup
    client.SetConVar("mp_disable_respawn_times", 1)
    client.SetConVar("mp_respawnwavetime", -1)
    client.SetConVar("mp_teams_unbalance_limit", 1000)

    -- debug command: ent_fire !picker Addoutput "health 99999" --superbot
]]
local MenuModule = {}

-- Import globals
local G = require("MedBot.Core.Globals")
-- local Node = require("MedBot.Navigation.Node")  -- Temporarily disabled
-- local Visuals = require("MedBot.Visuals")       -- Temporarily disabled

-- Try loading TimMenu
---@type boolean, table
local menuLoaded, TimMenu = pcall(require, "TimMenu")
assert(menuLoaded, "TimMenu not found, please install it!")

-- Draw the menu
local function OnDrawMenu()
	-- Only draw when the Lmaobox menu is open
	if not gui.IsMenuOpen() then
		return
	end

	-- Begin the menu and store the result
	if not TimMenu.Begin("MedBot Control") then
		return
	end
	-- Tab control
	G.Menu.Tab = TimMenu.TabControl("MedBotTabs", { "Main", "Visuals" }, G.Menu.Tab)
	TimMenu.NextLine()

	if G.Menu.Tab == "Main" then
		-- Bot Control Section
		TimMenu.BeginSector("Bot Control")
		G.Menu.Main.Enable = TimMenu.Checkbox("Enable Pathfinding", G.Menu.Main.Enable)
		TimMenu.Tooltip("Enables the main bot functionality")
		TimMenu.NextLine()

		-- Add Enable Walking toggle
		-- Initialize EnableWalking to true if not set
		if G.Menu.Main.EnableWalking == nil then
			G.Menu.Main.EnableWalking = true
		end
		local newWalkingValue = TimMenu.Checkbox("Enable Walking", G.Menu.Main.EnableWalking)
		-- Only update if value changed to avoid flickering
		if newWalkingValue ~= G.Menu.Main.EnableWalking then
			G.Menu.Main.EnableWalking = newWalkingValue
		end
		TimMenu.Tooltip("Enable/disable bot movement (pathfinding still works)")
		TimMenu.NextLine()

		G.Menu.Main.SelfHealTreshold = TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
		TimMenu.NextLine()

		G.Menu.Main.LookingAhead = TimMenu.Checkbox("Auto Rotate Camera", G.Menu.Main.LookingAhead or false)
		TimMenu.Tooltip("Enable automatic camera rotation towards target node (disable for manual camera control)")
		TimMenu.NextLine()

		G.Menu.Main.smoothFactor = G.Menu.Main.smoothFactor or 0.1
		G.Menu.Main.smoothFactor = TimMenu.Slider("Smooth Factor", G.Menu.Main.smoothFactor, 0.01, 1, 0.01)
		TimMenu.Tooltip("Camera rotation smoothness (only when Auto Rotate Camera is enabled)")
		TimMenu.EndSector()

		TimMenu.NextLine()

		-- Movement & Pathfinding Section
		TimMenu.BeginSector("Movement & Pathfinding")
		-- Store previous value to detect changes
		local prevSkipNodes = G.Menu.Main.Skip_Nodes
		G.Menu.Main.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Main.Skip_Nodes)
		-- Only update if value changed to avoid flickering
		if G.Menu.Main.Skip_Nodes ~= prevSkipNodes then
			-- Clear path to force recalculation with new setting
			if G.Navigation then
				G.Navigation.path = {}
			end
		end
		TimMenu.Tooltip("Allow skipping nodes when direct path is walkable (handles all optimization)")
		TimMenu.NextLine()

		-- Max Nodes Skipped slider
		G.Menu.Main.MaxNodesSkipped = G.Menu.Main.MaxNodesSkipped or 10
		G.Menu.Main.MaxNodesSkipped = TimMenu.Slider("Max Nodes Skipped", G.Menu.Main.MaxNodesSkipped, 1, 50, 1)
		TimMenu.Tooltip("Maximum nodes to skip in one continuous sequence (default: 10)")
		TimMenu.NextLine()

		-- Debug output toggle (controls Smart Jump and Node Skipper debug prints)
		G.Menu.Main.Debug = TimMenu.Checkbox("Enable Debug Output", G.Menu.Main.Debug or false)
		TimMenu.Tooltip("Enable debug prints from Smart Jump and Node Skipper (useful for debugging but spammy)")
		TimMenu.NextLine()

		-- Smart Jump (works independently of MedBot enable state)
		G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable)
		TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")
		TimMenu.NextLine()
		G.Menu.Main.WalkableMode = G.Menu.Main.WalkableMode or "Smooth"
		local walkableModes = { "Smooth", "Aggressive" }
		-- Get current mode as index number
		local currentModeIndex = (G.Menu.Main.WalkableMode == "Aggressive") and 2 or 1
		local previousMode = G.Menu.Main.WalkableMode

		-- TimMenu.Selector expects a number, not a table
		local selectedIndex = TimMenu.Selector("Walkable Mode", currentModeIndex, walkableModes)

		-- Update the mode based on selection
		if selectedIndex == 1 then
			G.Menu.Main.WalkableMode = "Smooth"
		elseif selectedIndex == 2 then
			G.Menu.Main.WalkableMode = "Aggressive"
		end

		TimMenu.Tooltip("Applies to path following only. Aggressive also enables direct skipping when path is walkable")
		TimMenu.EndSector()

		TimMenu.NextLine()

		-- Advanced Settings Section
		TimMenu.BeginSector("Advanced Settings")
		G.Menu.Main.CleanupConnections =
			TimMenu.Checkbox("Cleanup Invalid Connections", G.Menu.Main.CleanupConnections or false)
		TimMenu.Tooltip("Clean up navigation connections on map load (DISABLE if causing performance issues)")
		TimMenu.NextLine()

		-- Hierarchical pathfinding removed: single-layer areas only

		-- Connection processing status display
		if G.Menu.Main.CleanupConnections then
			-- local status = Node.GetConnectionProcessingStatus() -- Temporarily disabled
			local status = { isProcessing = false }
			if status.isProcessing then
				local phaseNames = {
					[1] = "Basic validation",
					[2] = "Expensive fallback",
					[3] = "Stair patching",
					[4] = "Fine point stitching",
				}
				TimMenu.Text(
					string.format(
						"Processing Connections: Phase %d (%s)",
						status.currentPhase,
						phaseNames[status.currentPhase] or "Unknown"
					)
				)
				TimMenu.NextLine()
				TimMenu.Text(
					string.format(
						"Progress: %d/%d nodes (FPS: %.1f)",
						status.processedNodes,
						status.totalNodes,
						status.currentFPS
					)
				)
				TimMenu.NextLine()
				TimMenu.Text(
					string.format(
						"Found: %d connections, Expensive: %d, Fine points: %d",
						status.connectionsFound,
						status.expensiveChecksUsed,
						status.finePointConnectionsAdded
					)
				)
				TimMenu.NextLine()
			end
		end

		TimMenu.EndSector()
	elseif G.Menu.Tab == "Visuals" then
		-- Visual Settings Section
		TimMenu.BeginSector("Visual Settings")
		G.Menu.Visuals.EnableVisuals = G.Menu.Visuals.EnableVisuals or true
		G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
		TimMenu.NextLine()

		-- Draw depth for flood-fill visualization (controls how far from player to render navmesh)
		G.Menu.Visuals.connectionDepth = G.Menu.Visuals.connectionDepth or 10
		G.Menu.Visuals.connectionDepth = TimMenu.Slider("Draw Depth", G.Menu.Visuals.connectionDepth, 1, 50, 1)
		TimMenu.Tooltip(
			"How many connection steps away from player to visualize (1 = only current node, 50 = maximum range). Controls flood-fill rendering of all navmesh elements except path arrows."
		)
		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()

		-- Display Section
		TimMenu.BeginSector("Display Options")
		
		-- Multi-selection combo for all visual elements
		local visualElements = {"Areas", "Doors", "Wall Corners", "Connections", "D2D Connections"}
		local visualSelections = {
			G.Menu.Visuals.showAreas or false,
			G.Menu.Visuals.showDoors or false,
			G.Menu.Visuals.showCornerConnections or false,
			G.Menu.Visuals.showConnections == nil and true or G.Menu.Visuals.showConnections, -- Default ON
			G.Menu.Visuals.showD2D or false,
		}

		local newSelections = TimMenu.Combo("Visual Elements", visualSelections, visualElements)

		-- Update state based on selections
		G.Menu.Visuals.showAreas = newSelections[1]
		G.Menu.Visuals.showDoors = newSelections[2]
		G.Menu.Visuals.showCornerConnections = newSelections[3]
		G.Menu.Visuals.showConnections = newSelections[4]
		G.Menu.Visuals.showD2D = newSelections[5]
		TimMenu.NextLine()

		-- Additional visual options
		G.Menu.Visuals.showAgentBoxes = G.Menu.Visuals.showAgentBoxes or false
		G.Menu.Visuals.showAgentBoxes = TimMenu.Checkbox("Show Agent Boxes", G.Menu.Visuals.showAgentBoxes)

		G.Menu.Visuals.drawPath = G.Menu.Visuals.drawPath or false
		G.Menu.Visuals.drawPath = TimMenu.Checkbox("Draw Path", G.Menu.Visuals.drawPath)
		TimMenu.NextLine()

		G.Menu.Visuals.memoryUsage = G.Menu.Visuals.memoryUsage or false
		G.Menu.Visuals.memoryUsage = TimMenu.Checkbox("Show Memory Usage", G.Menu.Visuals.memoryUsage)
		TimMenu.NextLine()

		G.Menu.Visuals.showNodeIds = G.Menu.Visuals.showNodeIds or false
		G.Menu.Visuals.showNodeIds = TimMenu.Checkbox("Show Node IDs", G.Menu.Visuals.showNodeIds)
		TimMenu.Tooltip("Display node ID numbers on the map for debugging")
		TimMenu.NextLine()

		TimMenu.EndSector()
	end

	-- Always end the menu if we began it
	TimMenu.End()
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule
