--##########################################################################
--  SetupOrchestrator.lua  ·  Coordinates all setup phases explicitly
--##########################################################################
--
--  Flow:
--    Phase1: Load raw nav file → nodes
--    Phase2: Normalize connections → nodes (enriched)
--    [SET G.Navigation.nodes = nodes]  <- BASIC SETUP COMPLETE
--    Phase3: Build KD-tree spatial index (uses global nodes)
--    Phase4: Wall corners + Door generation (uses global nodes)
--
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local Phase1_NavLoad = require("MedBot.Navigation.Setup.Phase1_NavLoad")
local Phase2_Normalize = require("MedBot.Navigation.Setup.Phase2_Normalize")
local Phase3_KDTree = require("MedBot.Navigation.Setup.Phase3_KDTree")
local Phase4_Doors = require("MedBot.Navigation.Setup.Phase4_Doors")

local SetupOrchestrator = {}

local Log = Common.Log.new("SetupOrchestrator")

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Execute full navigation setup with explicit data flow
--- @param navFilePath string|nil Optional nav file path, or auto-detect from map
--- @return boolean success
function SetupOrchestrator.ExecuteFullSetup(navFilePath)
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return true
	end

	-- Auto-detect nav file if not provided
	if not navFilePath then
		local mapName = engine.GetMapName()
		if not mapName or mapName == "" then
			Log:Error("No map name available and no nav file path provided")
			return false
		end
		navFilePath = "tf/" .. string.gsub(mapName, ".bsp", ".nav")
	end

	Log:Info("=== Starting Navigation Setup ===")
	Log:Info("Target: %s", navFilePath)

	-- ========================================================================
	-- PHASE 1: Load raw nav data
	-- ========================================================================
	local nodes, err = Phase1_NavLoad.Execute(navFilePath)
	if not nodes then
		Log:Error("Phase 1 failed: %s", err or "unknown error")

		-- Auto-generate if file not found
		if err == "File not found" then
			Log:Warning("Nav file not found, attempting generation...")
			local generated = SetupOrchestrator.TryGenerateNavFile()
			if generated then
				-- Retry once after generation
				nodes, err = Phase1_NavLoad.Execute(navFilePath)
			end
		end

		if not nodes then
			return false
		end
	end

	-- ========================================================================
	-- PHASE 2: Normalize connections (basic enrichment)
	-- ========================================================================
	nodes = Phase2_Normalize.Execute(nodes)

	-- ========================================================================
	-- BASIC SETUP COMPLETE - Set global for advanced phases
	-- ========================================================================
	G.Navigation.nodes = nodes

	-- Count nodes (dictionary table, # operator doesn't work)
	local nodeCount = 0
	for _ in pairs(nodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Basic setup complete: %d nodes ready", nodeCount)

	-- ========================================================================
	-- PHASE 3: Build KD-tree spatial index
	-- ========================================================================
	local kdTree = Phase3_KDTree.Execute(nodes)
	if kdTree then
		G.Navigation.kdTree = kdTree
	end

	-- ========================================================================
	-- PHASE 4: Advanced parsing (doors, wall corners)
	-- ========================================================================
	local success = Phase4_Doors.Execute()
	if not success then
		Log:Error("Phase 4 (advanced parsing) failed")
		-- Still mark as updated since basic setup worked
	end

	G.Navigation.navMeshUpdated = true
	Log:Info("=== Navigation Setup Complete ===")
	return true
end

--- Try to generate nav file using game commands
--- @return boolean success
function SetupOrchestrator.TryGenerateNavFile()
	local ok = pcall(function()
		client.RemoveConVarProtection("sv_cheats")
		client.RemoveConVarProtection("nav_generate")
		client.SetConVar("sv_cheats", "1")
		client.Command("nav_generate", true)
	end)

	if not ok then
		Log:Error("Failed to initiate nav generation")
		return false
	end

	Log:Info("Nav generation initiated, waiting...")

	-- Wait for generation (10 seconds)
	local startTime = os.time()
	repeat
	until os.time() - startTime > 10

	return true
end

--- Execute ONLY basic setup (Phases 1-2), no doors/KD-tree
--- Useful for testing or when advanced features not needed
--- @param navFilePath string|nil Optional nav file path
--- @return table|nil nodes
function SetupOrchestrator.ExecuteBasicSetup(navFilePath)
	if not navFilePath then
		local mapName = engine.GetMapName()
		if not mapName or mapName == "" then
			Log:Error("No map name available")
			return nil
		end
		navFilePath = "tf/" .. string.gsub(mapName, ".bsp", ".nav")
	end

	Log:Info("=== Starting Basic Navigation Setup ===")

	local nodes, err = Phase1_NavLoad.Execute(navFilePath)
	if not nodes then
		Log:Error("Phase 1 failed: %s", err or "unknown error")
		return nil
	end

	nodes = Phase2_Normalize.Execute(nodes)

	G.Navigation.nodes = nodes
	G.Navigation.navMeshUpdated = true

	-- Count nodes (dictionary table, # operator doesn't work)
	local nodeCount = 0
	for _ in pairs(nodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Basic setup complete: %d nodes", nodeCount)
	return nodes
end

return SetupOrchestrator
