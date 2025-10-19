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
	G.Menu.Tab = TimMenu.TabControl("MedBotTabs", { "Main", "Navigation", "Visuals" }, G.Menu.Tab)
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

		-- Smart Jump (works independently of MedBot enable state)
		G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable)
		TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")
		TimMenu.EndSector()
	elseif G.Menu.Tab == "Navigation" then
		-- Movement & Pathfinding Section
		TimMenu.BeginSector("Pathfinding Settings")
		-- Store previous value to detect changes
		local prevSkipNodes = G.Menu.Navigation.Skip_Nodes
		G.Menu.Navigation.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Navigation.Skip_Nodes)
		-- Only update if value changed to avoid flickering
		if G.Menu.Navigation.Skip_Nodes ~= prevSkipNodes then
			-- Clear path to force recalculation with new setting
			if G.Navigation then
				G.Navigation.path = {}
			end
		end
		TimMenu.Tooltip("Allow skipping nodes when direct path is walkable (handles all optimization)")
		TimMenu.NextLine()

		-- Max Skip Range slider
		G.Menu.Main.MaxSkipRange = G.Menu.Main.MaxSkipRange or 500
		G.Menu.Main.MaxSkipRange = TimMenu.Slider("Max Skip Range", G.Menu.Main.MaxSkipRange, 100, 2000, 50)
		TimMenu.Tooltip("Maximum distance to skip nodes in units (default: 500)")
		TimMenu.NextLine()

		-- Stop Distance slider for FOLLOWING state
		G.Menu.Navigation.StopDistance = G.Menu.Navigation.StopDistance or 50
		G.Menu.Navigation.StopDistance = TimMenu.Slider("Stop Distance", G.Menu.Navigation.StopDistance, 20, 200, 5)
		TimMenu.Tooltip("Distance to stop from dynamic targets like payload (FOLLOWING state)")
		TimMenu.NextLine()

		G.Menu.Navigation.WalkableMode = G.Menu.Navigation.WalkableMode or "Smooth"
		local walkableModes = { "Smooth", "Aggressive" }
		-- Get current mode as index number
		local currentModeIndex = (G.Menu.Navigation.WalkableMode == "Aggressive") and 2 or 1

		-- TimMenu.Selector expects a number, not a table
		local selectedIndex = TimMenu.Selector("Walkable Mode", currentModeIndex, walkableModes)

		-- Update the mode based on selection
		if selectedIndex == 1 then
			G.Menu.Navigation.WalkableMode = "Smooth"
		elseif selectedIndex == 2 then
			G.Menu.Navigation.WalkableMode = "Aggressive"
		end

		TimMenu.Tooltip("Smooth uses 18-unit steps, Aggressive allows 72-unit jumps")
		TimMenu.EndSector()

		TimMenu.NextLine()

		-- Advanced Navigation Settings
		TimMenu.BeginSector("Advanced Settings")
		G.Menu.Navigation.CleanupConnections =
			TimMenu.Checkbox("Cleanup Invalid Connections", G.Menu.Navigation.CleanupConnections or false)
		TimMenu.Tooltip("Clean up navigation connections on map load (DISABLE if causing performance issues)")
		TimMenu.NextLine()

		-- Connection processing status display
		if G.Menu.Navigation.CleanupConnections then
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
		G.Menu.Visuals.Debug_Mode = TimMenu.Checkbox("Debug Mode", G.Menu.Visuals.Debug_Mode or false)
		TimMenu.Tooltip("Enable debug visuals and verbose logging for troubleshooting")
		TimMenu.NextLine()
		-- Initialize only if nil (not false)
		if G.Menu.Visuals.EnableVisuals == nil then
			G.Menu.Visuals.EnableVisuals = true
		end
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
		TimMenu.NextLine()

		-- SmartJump Visualization Section
		TimMenu.BeginSector("SmartJump Visuals")
		
		G.Menu.Visuals.showSmartJump = G.Menu.Visuals.showSmartJump or false
		G.Menu.Visuals.showSmartJump = TimMenu.Checkbox("Show SmartJump", G.Menu.Visuals.showSmartJump)
		TimMenu.Tooltip("Display SmartJump simulation path and landing prediction")
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
