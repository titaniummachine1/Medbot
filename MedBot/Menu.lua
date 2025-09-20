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

		-- Duck_Grab
		G.Menu.Main.Duck_Grab = TimMenu.Checkbox("Duck Grab", G.Menu.Main.Duck_Grab)
		TimMenu.Tooltip(
			"(EXPERIMENTAL) allows duck grabbing when jumping on obstacles worlds fastest but not finished will make bot slower due to missed jumps"
		)
		TimMenu.NextLine()

		-- Smart Jump (works independently of MedBot enable state)
		G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable)
		TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")

		-- Path optimisation mode for following nodes
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

		G.Menu.Main.AllowExpensiveChecks =
			TimMenu.Checkbox("Allow Expensive Walkability Checks", G.Menu.Main.AllowExpensiveChecks or false)
		TimMenu.Tooltip("Enable expensive trace-based walkability validation (rarely needed)")
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

		-- Align naming with visuals: renderRadius is what Visuals.lua reads
		if G.Menu.Visuals.renderRadius == nil then
			G.Menu.Visuals.renderRadius = 800
		end
		G.Menu.Visuals.renderRadius = TimMenu.Slider("Render Radius", G.Menu.Visuals.renderRadius, 100, 3000, 100)
		TimMenu.NextLine()

		-- Connection depth for flood-fill visualization
		if G.Menu.Visuals.connectionDepth == nil then
			G.Menu.Visuals.connectionDepth = 3
		end
		G.Menu.Visuals.connectionDepth = TimMenu.Slider("Connection Depth", G.Menu.Visuals.connectionDepth, 0, 10, 1)
		TimMenu.Tooltip("How many connection steps away from player to visualize (0 = only current node, 10 = maximum range)")
		TimMenu.NextLine()

		-- Node Display Section
		TimMenu.BeginSector("Display Options")
		-- Basic display options
		local basicOptions = {
			"Show Nodes",
			"Show Node IDs",
			"Show Nav Connections",
			"Show Areas",
			"Show Doors",
			"Show Corner Connections",
		}

		-- Initialize basicDisplay array if it doesn't exist
		if G.Menu.Visuals.basicDisplay == nil then
			G.Menu.Visuals.basicDisplay = { true, true, true, true, true, false }
		end

		-- Update individual settings based on combo selection
		G.Menu.Visuals.drawNodes = G.Menu.Visuals.basicDisplay[1] or false
		G.Menu.Visuals.drawNodeIDs = G.Menu.Visuals.basicDisplay[2] or false
		G.Menu.Visuals.showConnections = G.Menu.Visuals.basicDisplay[3] or false
		G.Menu.Visuals.showAreas = G.Menu.Visuals.basicDisplay[4] or false
		G.Menu.Visuals.showDoors = G.Menu.Visuals.basicDisplay[5] or false
		G.Menu.Visuals.showCornerConnections = G.Menu.Visuals.basicDisplay[6] or false

		-- Create a simple combo for basic display options
		local currentBasicDisplay = ""
		if G.Menu.Visuals.showConnections then currentBasicDisplay = currentBasicDisplay .. "1" else currentBasicDisplay = currentBasicDisplay .. "0" end
		if G.Menu.Visuals.showAreas then currentBasicDisplay = currentBasicDisplay .. "1" else currentBasicDisplay = currentBasicDisplay .. "0" end
		if G.Menu.Visuals.showDoors then currentBasicDisplay = currentBasicDisplay .. "1" else currentBasicDisplay = currentBasicDisplay .. "0" end
		if G.Menu.Visuals.showCornerConnections then currentBasicDisplay = currentBasicDisplay .. "1" else currentBasicDisplay = currentBasicDisplay .. "0" end

		local basicDisplayOptions = {
			"Connections + Areas + Doors + Corners",
			"Connections + Areas + Doors",
			"Connections + Areas",
			"Connections Only",
			"None"
		}

		local displayIndex = 1
		if currentBasicDisplay == "1111" then displayIndex = 1
		elseif currentBasicDisplay == "1110" then displayIndex = 2
		elseif currentBasicDisplay == "1100" then displayIndex = 3
		elseif currentBasicDisplay == "1000" then displayIndex = 4
		else displayIndex = 5 end

		local newDisplayIndex = TimMenu.Selector("Basic Display", displayIndex, basicDisplayOptions)
		TimMenu.NextLine()

		-- Update settings based on selection
		if newDisplayIndex == 1 then
			G.Menu.Visuals.showConnections = true
			G.Menu.Visuals.showAreas = true
			G.Menu.Visuals.showDoors = true
			G.Menu.Visuals.showCornerConnections = true
		elseif newDisplayIndex == 2 then
			G.Menu.Visuals.showConnections = true
			G.Menu.Visuals.showAreas = true
			G.Menu.Visuals.showDoors = true
			G.Menu.Visuals.showCornerConnections = false
		elseif newDisplayIndex == 3 then
			G.Menu.Visuals.showConnections = true
			G.Menu.Visuals.showAreas = true
			G.Menu.Visuals.showDoors = false
			G.Menu.Visuals.showCornerConnections = false
		elseif newDisplayIndex == 4 then
			G.Menu.Visuals.showConnections = true
			G.Menu.Visuals.showAreas = false
			G.Menu.Visuals.showDoors = false
			G.Menu.Visuals.showCornerConnections = false
		else
			G.Menu.Visuals.showConnections = false
			G.Menu.Visuals.showAreas = false
			G.Menu.Visuals.showDoors = false
			G.Menu.Visuals.showCornerConnections = false
		end

		-- Update the basicDisplay array to match
		G.Menu.Visuals.basicDisplay = {
			false, -- drawNodes (not used)
			false, -- drawNodeIDs (not used)
			G.Menu.Visuals.showConnections,
			G.Menu.Visuals.showAreas,
			G.Menu.Visuals.showDoors,
			G.Menu.Visuals.showCornerConnections
		}

		-- Additional visual options
		G.Menu.Visuals.showAgentBoxes = G.Menu.Visuals.showAgentBoxes or false
		G.Menu.Visuals.showAgentBoxes = TimMenu.Checkbox("Show Agent Boxes", G.Menu.Visuals.showAgentBoxes)
		TimMenu.NextLine()

		G.Menu.Visuals.drawPath = G.Menu.Visuals.drawPath or false
		G.Menu.Visuals.drawPath = TimMenu.Checkbox("Draw Path", G.Menu.Visuals.drawPath)
		TimMenu.NextLine()

		G.Menu.Visuals.ignorePathRadius = G.Menu.Visuals.ignorePathRadius or false
		G.Menu.Visuals.ignorePathRadius = TimMenu.Checkbox("Ignore Path Radius", G.Menu.Visuals.ignorePathRadius)
		TimMenu.NextLine()

		G.Menu.Visuals.memoryUsage = G.Menu.Visuals.memoryUsage or false
		G.Menu.Visuals.memoryUsage = TimMenu.Checkbox("Show Memory Usage", G.Menu.Visuals.memoryUsage)
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
