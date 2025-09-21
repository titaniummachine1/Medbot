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
local WALKABILITY_CHECK_COOLDOWN = 5 -- ticks (~83ms) between expensive walkability checks
local CONTINUOUS_SKIP_COOLDOWN = 22 -- ticks (~366ms) for continuous skipping

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Check if next node is closer than current (cheap distance check)
local function CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode then
		return false
	end

	local distToCurrent = Common.Distance2D(currentPos, currentNode.pos)
	local distToNext = Common.Distance2D(currentPos, nextNode.pos)

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
	WorkManager.resetCooldown("simple_skip_check") -- Reset simple skip check cooldown
	Log:Debug("NodeSkipper state reset")
end

-- Check for path optimization (called during pathfinding)
-- This replaces PathOptimizer.optimize()
function NodeSkipper.OptimizePath(origin, path, goalPos, removeNodeCallback, resetTimerCallback)
	-- Respect Skip_Nodes menu setting
	if not G.Menu.Main.Skip_Nodes then
		return false
	end

	-- Early exit if invalid path
	if not path or #path <= 1 then
		return false
	end

	-- Throttle optimization attempts
	if not WorkManager.attemptWork(5, "path_optimize") then
		return false
	end

	-- Need at least 3 nodes (current + next + goal)
	if #path < 3 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not (currentNode and nextNode and currentNode.pos and nextNode.pos) then
		return false
	end

	-- Algorithm: Skip if next node is closer than current
	local distToCurrent = Common.Distance3D(origin, currentNode.pos)
	local distToNext = Common.Distance3D(origin, nextNode.pos)

	if distToNext < distToCurrent then
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if ISWalkable.PathCached(origin, nextNode.pos, walkMode) then
			if removeNodeCallback then
				removeNodeCallback()
			end
			if resetTimerCallback then
				resetTimerCallback()
			end
			Log:Debug("Optimized path - skipped to closer next node %.1f < %.1f units", distToNext, distToCurrent)
			return true
		else
			Log:Debug("Next node closer but not walkable - staying on current")
		end
	end

	return false
end

-- Check for node skipping when reaching a target (called by MovementDecisions)
function NodeSkipper.CheckSkipOnReach(currentPos, removeNodeCallback)
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

	if not currentNode or not nextNode then
		return false
	end

	-- Reset cooldown for immediate check when reaching node
	NodeSkipper.ResetWalkabilityCooldown()

	-- Check if next node is walkable
	if CheckNextNodeWalkable(currentPos, currentNode, nextNode) then
		Log:Info("Skipped current node %d -> next node %d (reached target)", currentNode.id, nextNode.id)
		if removeNodeCallback then
			removeNodeCallback()
		end
		return true
	end

	return false
end

-- Continuous node skipping check (called by MovementDecisions)
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

	-- Run one iteration every 22 ticks
	if not WorkManager.attemptWork(CONTINUOUS_SKIP_COOLDOWN, "simple_skip_check") then
		return false
	end

	-- Simple robust check: Is next node closer to us than current node?
	local distToCurrent = Common.Distance3D(currentPos, currentNode.pos)
	local distToNext = Common.Distance3D(currentPos, nextNode.pos)

	if distToNext >= distToCurrent then
		-- Next node is not closer, don't skip
		return false
	end

	Log:Debug("Next node %d is closer (%.1f < %.1f)", nextNode.id, distToNext, distToCurrent)

	-- Next node is closer - check if path to it is walkable
	if ISWalkable.Path(currentPos, nextNode.pos) then
		Log:Info("Skipping to closer next node %d (%.1f < %.1f units)", nextNode.id, distToNext, distToCurrent)

		-- Remove the current node to skip to the next one
		if removeNodeCallback then
			removeNodeCallback()
		end
		return true
	else
		Log:Debug("Next node %d closer but not walkable", nextNode.id)
	end

	return false
end

-- Check for speed penalties and force repath (replaces PathOptimizer.checkSpeedPenalty)
function NodeSkipper.CheckSpeedPenalty(origin, currentTarget, currentNode, path)
	if not currentTarget or not currentNode or not path then
		return false
	end

	-- Throttle speed penalty checks
	if not WorkManager.attemptWork(33, "speed_penalty_check") then
		return false
	end

	-- Get current player speed
	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		return false
	end

	local velocity = pLocal:EstimateAbsVelocity() or Vector3(0, 0, 0)
	local speed = velocity:Length2D()

	-- Only trigger if speed is below threshold
	if speed >= 50 then
		return false
	end

	Log:Debug("Speed penalty check triggered - speed: %.1f", speed)

	-- Check if direct path to current target is walkable
	if not ISWalkable.Path(origin, currentTarget) then
		Log:Debug("Direct path to target not walkable - adding penalty")

		-- Add penalty to connection
		if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
			local nextNode = path[2]
			if nextNode then
				G.CircuitBreaker.addConnectionFailure(currentNode, nextNode)
			end
		end

		-- Force repath
		if G.StateHandler and G.StateHandler.forceRepath then
			G.StateHandler.forceRepath()
			Log:Debug("Forced repath due to unwalkable connection")
			return true
		end
	end

	return false
end

return NodeSkipper
