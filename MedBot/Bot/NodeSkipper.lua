--[[
Node Skipper - Centralized node skipping system
Consolidates all node skipping logic from across the codebase
Handles Skip_Nodes menu setting and provides clean API for other modules
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local ISWalkable = require("MedBot.Navigation.ISWalkable")
local WorkManager = require("MedBot.WorkManager")

local NodeSkipper = {}
local Log = Common.Log.new("NodeSkipper")

-- Constants for timing
local WALKABILITY_CHECK_COOLDOWN = 2 -- ticks (~83ms) between expensive walkability checks
local CONTINUOUS_SKIP_COOLDOWN = 22 -- ticks (~366ms) for continuous skipping

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Check if next node is closer than current (cheap distance check)
local function CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode then
		return false
	end

	local distToCurrent = Common.Distance3D(currentPos, currentNode.pos)
	local distToNext = Common.Distance3D(currentPos, nextNode.pos)

	return distToNext < distToCurrent
end

-- Check if path from current position to next node is walkable (expensive)
local function CheckNextNodeWalkable(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode then
		return false
	end

	local walkMode = G.Menu.Main.WalkableMode or "Smooth"
	return ISWalkable.IsWalkable(currentPos, nextNode.pos)
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Initialize/reset state when needed
function NodeSkipper.Reset()
	G.Navigation.nextNodeCloser = false
	WorkManager.resetCooldown("continuous_node_skip_walkability")
	WorkManager.resetCooldown("node_skip_walkability")
	WorkManager.resetCooldown("active_skip_check") -- Reset active skip check cooldown
	WorkManager.resetCooldown("passive_skip_check") -- Reset passive skip check cooldown
	Log:Debug("NodeSkipper state reset")
end

-- Continuous hybrid node skipping check (called by MovementDecisions)
-- HYBRID SYSTEM: Separate Passive + Active checking
-- Passive: Independent distance-based skipping (cheap, frequent)
-- Active: Walkability-based skipping (expensive, less frequent)
function NodeSkipper.CheckContinuousSkip(currentPos, removeNodeCallback)
	-- Respect Skip_Nodes menu setting
	if not G.Menu.Main.Skip_Nodes then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		return false
	end

	-- PASSIVE SYSTEM: Always try distance-based skipping first (cheap, runs every 11 ticks)
	local passiveSkipped = false
	if WorkManager.attemptWork(11, "passive_skip_check") then -- Half the frequency of active
		if CheckNextNodeCloser(currentPos, currentNode, nextNode) then
			Log:Info("Passive skip: Next node %d closer than current %d - skipping", nextNode.id, currentNode.id)

			-- Skip the current node
			if removeNodeCallback then
				removeNodeCallback()
			end
			passiveSkipped = true
		end
	end

	-- ACTIVE SYSTEM: Walkability-based skipping (expensive, runs every 22 ticks)
	if not WorkManager.attemptWork(CONTINUOUS_SKIP_COOLDOWN, "active_skip_check") then
		return passiveSkipped -- Return if passive skipped, false otherwise
	end

	Log:Debug("Active skip check - checking path from player to next node %d", nextNode.id)

	-- Active check - is path from current position to next node walkable?
	if ISWalkable.Path(currentPos, nextNode.pos) then
		Log:Info(
			"Active skip: Path to next node %d is walkable - skipping current node %d",
			nextNode.id,
			currentNode.id
		)

		-- Skip the current node by removing it
		if removeNodeCallback then
			removeNodeCallback()
		end
		return true
	else
		Log:Debug("Active skip: Path to next node %d not walkable - will run agent system")
		-- TODO: Implement agent system when path is not walkable
		return passiveSkipped
	end
end

return NodeSkipper
