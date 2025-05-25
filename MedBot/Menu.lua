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
local G = require("MedBot.Utils.Globals")

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

	if TimMenu.Begin("MedBot Control") then
		-- Tab control
		G.Menu.Tab = TimMenu.TabControl("MedBotTabs", { "Main", "Visuals" }, G.Menu.Tab)
		TimMenu.NextLine()

		if G.Menu.Tab == "Main" then
			-- Bot Control Section
			TimMenu.BeginSector("Bot Control")
			G.Menu.Main.Enable = TimMenu.Checkbox("Enable Bot", G.Menu.Main.Enable)
			TimMenu.NextLine()

			G.Menu.Main.SelfHealTreshold =
				TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
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
			G.Menu.Main.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Main.Skip_Nodes)
			TimMenu.Tooltip("Allow skipping nodes when direct path is walkable (handles all optimization)")
			TimMenu.NextLine()

			-- Smart Jump (works independently of MedBot enable state)
			G.Menu.SmartJump = G.Menu.SmartJump or {}
			G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable ~= false)
			TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")
			TimMenu.NextLine()

			-- Walkable Mode Selector for both node skipping and SmartJump
			G.Menu.Main.WalkableMode = G.Menu.Main.WalkableMode or "Smooth"
			local walkableModes = { "Smooth Walking (Step 18u)", "Aggressive Walking (Jump 72u)" }
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

			-- Auto-recalculate costs if mode changed
			if G.Menu.Main.WalkableMode ~= previousMode then
				local success, Node = pcall(require, "MedBot.Modules.Node")
				if success and Node then
					Node.RecalculateConnectionCosts()
				end
			end
			TimMenu.Tooltip("Smooth: Only 18-unit steps + height costs, Aggressive: Allow 72-unit jumps no extra cost")
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Path Optimiser Settings
			TimMenu.BeginSector("Path Optimiser (Advanced)")
			G.Menu.Main.OptimizerLookahead = G.Menu.Main.OptimizerLookahead or 10
			G.Menu.Main.OptimizerLookahead = TimMenu.Slider("Lookahead Nodes", G.Menu.Main.OptimizerLookahead, 5, 30, 1)
			TimMenu.Tooltip("How many nodes ahead to check for skipping (higher = more aggressive skipping)")
			TimMenu.NextLine()

			G.Menu.Main.OptimizerDistance = G.Menu.Main.OptimizerDistance or 600
			G.Menu.Main.OptimizerDistance =
				TimMenu.Slider("Lookahead Distance", G.Menu.Main.OptimizerDistance, 300, 1200, 50)
			TimMenu.Tooltip("Maximum distance in units to check for skipping")
			TimMenu.NextLine()

			G.Menu.Main.OptimizerCooldown = G.Menu.Main.OptimizerCooldown or 12
			G.Menu.Main.OptimizerCooldown = TimMenu.Slider("Failure Cooldown", G.Menu.Main.OptimizerCooldown, 6, 60, 3)
			TimMenu.Tooltip("How many ticks to wait before retrying a failed skip (prevents oscillation)")
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

			G.Menu.Main.UseHierarchicalPathfinding =
				TimMenu.Checkbox("Use Hierarchical Pathfinding", G.Menu.Main.UseHierarchicalPathfinding or false)
			TimMenu.Tooltip("Generate fine-grained points within areas for more accurate local pathfinding")
			TimMenu.NextLine()

			-- Connection processing status display
			if G.Menu.Main.CleanupConnections then
				local Node = require("MedBot.Modules.Node")
				local status = Node.GetConnectionProcessingStatus()
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
			G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
			TimMenu.NextLine()

			G.Menu.Visuals.renderDistance = G.Menu.Visuals.renderDistance or 800
			G.Menu.Visuals.renderDistance =
				TimMenu.Slider("Render Distance", G.Menu.Visuals.renderDistance, 100, 3000, 100)
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Node Display Section
			TimMenu.BeginSector("Display Options")
			-- Basic display options
			local basicOptions =
				{ "Show Nodes", "Show Node IDs", "Show Nav Connections", "Show Areas", "Show Fine Points" }
			G.Menu.Visuals.basicDisplay = G.Menu.Visuals.basicDisplay or { true, true, true, true, false }
			G.Menu.Visuals.basicDisplay = TimMenu.Combo("Basic Display", G.Menu.Visuals.basicDisplay, basicOptions)
			TimMenu.NextLine()

			-- Update individual settings based on combo selection
			G.Menu.Visuals.drawNodes = G.Menu.Visuals.basicDisplay[1]
			G.Menu.Visuals.drawNodeIDs = G.Menu.Visuals.basicDisplay[2]
			G.Menu.Visuals.showConnections = G.Menu.Visuals.basicDisplay[3]
			G.Menu.Visuals.showAreas = G.Menu.Visuals.basicDisplay[4]
			G.Menu.Visuals.showFinePoints = G.Menu.Visuals.basicDisplay[5]

			-- Fine Point Connection Options (only show if fine points are enabled)
			if G.Menu.Visuals.showFinePoints then
				local connectionOptions =
					{ "Intra-Area Connections", "Inter-Area Connections", "Edge-to-Edge Connections" }
				G.Menu.Visuals.connectionDisplay = G.Menu.Visuals.connectionDisplay or { true, true, true }
				G.Menu.Visuals.connectionDisplay =
					TimMenu.Combo("Fine Point Connections", G.Menu.Visuals.connectionDisplay, connectionOptions)
				TimMenu.Tooltip("Blue: intra-area, Orange: inter-area, Bright blue: edge-to-edge")
				TimMenu.NextLine()

				-- Update individual connection settings
				G.Menu.Visuals.showIntraConnections = G.Menu.Visuals.connectionDisplay[1]
				G.Menu.Visuals.showInterConnections = G.Menu.Visuals.connectionDisplay[2]
				G.Menu.Visuals.showEdgeConnections = G.Menu.Visuals.connectionDisplay[3]
			end
			TimMenu.EndSector()
		end

		TimMenu.End() -- Properly close the menu
	end
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule
