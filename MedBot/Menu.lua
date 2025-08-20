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
local Node = require("MedBot.Modules.Node")
local Visuals = require("MedBot.Visuals")

-- Profiler disabled to prevent crashes
local Profiler = nil

-- Disable all profiler functions to prevent crashes
local function ProfilerBeginSystem(name) end
local function ProfilerEndSystem() end

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

			G.Menu.SmartJump.Debug = G.Menu.SmartJump.Debug or false
			G.Menu.SmartJump.Debug = TimMenu.Checkbox("Smart Jump Debug", G.Menu.SmartJump.Debug)
			TimMenu.Tooltip("Print Smart Jump debug logs to console")
			TimMenu.NextLine()

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

			-- Auto-recalculate costs if mode changed
			if G.Menu.Main.WalkableMode ~= previousMode then
				Node.RecalculateConnectionCosts()
			end
			TimMenu.Tooltip(
				"Applies to path following only. Aggressive also enables direct skipping when path is walkable"
			)
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

			-- Align naming with visuals: renderRadius is what Visuals.lua reads
			G.Menu.Visuals.renderRadius = G.Menu.Visuals.renderRadius or G.Menu.Visuals.renderDistance or 800
			G.Menu.Visuals.renderRadius = TimMenu.Slider("Render Radius", G.Menu.Visuals.renderRadius, 100, 3000, 100)
			TimMenu.NextLine()

			G.Menu.Visuals.chunkSize = G.Menu.Visuals.chunkSize or 256
			G.Menu.Visuals.chunkSize = TimMenu.Slider("Chunk Size", G.Menu.Visuals.chunkSize, 64, 512, 16)
			TimMenu.NextLine()

			G.Menu.Visuals.renderChunks = G.Menu.Visuals.renderChunks or 3
			G.Menu.Visuals.renderChunks = TimMenu.Slider("Render Chunks", G.Menu.Visuals.renderChunks, 1, 10, 1)
			Visuals.MaybeRebuildGrid()
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Node Display Section
			TimMenu.BeginSector("Display Options")
			-- Basic display options
			local basicOptions = { "Show Nodes", "Show Node IDs", "Show Nav Connections", "Show Areas", "Show Doors" }
			G.Menu.Visuals.basicDisplay = G.Menu.Visuals.basicDisplay or { true, true, true, true, true }
			G.Menu.Visuals.basicDisplay = TimMenu.Combo("Basic Display", G.Menu.Visuals.basicDisplay, basicOptions)
			TimMenu.NextLine()

			-- Update individual settings based on combo selection
			G.Menu.Visuals.drawNodes = G.Menu.Visuals.basicDisplay[1]
			G.Menu.Visuals.drawNodeIDs = G.Menu.Visuals.basicDisplay[2]
			G.Menu.Visuals.showConnections = G.Menu.Visuals.basicDisplay[3]
			G.Menu.Visuals.showAreas = G.Menu.Visuals.basicDisplay[4]
			G.Menu.Visuals.showDoors = G.Menu.Visuals.basicDisplay[5]
			TimMenu.EndSector()
		end

		TimMenu.End() -- Properly close the menu
	end
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule
