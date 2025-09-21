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
	G.Navigation.skipAgents = nil -- Reset agent-based skipping state
	WorkManager.resetCooldown("continuous_node_skip_walkability")
	WorkManager.resetCooldown("node_skip_walkability")
	WorkManager.resetCooldown("agent_based_skipping") -- Reset new agent-based cooldown
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
	if not path or #path < 3 then -- Need at least current + next + one more
		return false
	end

	-- Initialize agent state if not exists
	if not G.Navigation.skipAgents then
		G.Navigation.skipAgents = {
			agentA = { nodeIndex = 1, pos = path[1].pos }, -- Agent A at current node
			agentB = { nodeIndex = 2, pos = path[2].pos }, -- Agent B at next node
			maxNodeDistance = G.Menu.Main.MaxNodesSkipped or 10, -- Max nodes ahead to check
		}
	end

	local agents = G.Navigation.skipAgents

	-- Reset if path changed
	if agents.agentA.nodeIndex > #path or agents.agentB.nodeIndex > #path then
		G.Navigation.skipAgents = nil
		return false
	end

	-- Run one iteration every 22 ticks
	if not WorkManager.attemptWork(CONTINUOUS_SKIP_COOLDOWN, "agent_based_skipping") then
		return false
	end

	Log:Debug(
		"Agent skip check - A:%d B:%d (dist:%d)",
		agents.agentA.nodeIndex,
		agents.agentB.nodeIndex,
		agents.agentB.nodeIndex - agents.agentA.nodeIndex
	)

	-- Check if agent B is too far ahead
	if agents.agentB.nodeIndex - agents.agentA.nodeIndex >= agents.maxNodeDistance then
		Log:Info("Reached max node distance (%d) - stopping skip checks", agents.maxNodeDistance)
		G.Navigation.skipAgents = nil
		return false
	end

	-- Check walkability from agent A to agent B using ISWalkable module
	local isWalkable = ISWalkable.Path(agents.agentA.pos, agents.agentB.pos)

	if isWalkable then
		-- Success: skip directly from agent A to agent B
		local nodesSkipped = agents.agentB.nodeIndex - agents.agentA.nodeIndex
		Log:Info(
			"Skipping %d nodes directly from %d to %d (walkable)",
			nodesSkipped,
			agents.agentA.nodeIndex,
			agents.agentB.nodeIndex
		)

		-- Modify path to skip directly (not just remove nodes)
		local newPath = {}
		for i = 1, agents.agentA.nodeIndex do
			newPath[i] = path[i] -- Keep nodes up to agent A
		end
		for i = agents.agentB.nodeIndex, #path do
			newPath[#newPath + 1] = path[i] -- Add nodes from agent B onward
		end

		G.Navigation.path = newPath

		-- Reset agents for next skip session
		G.Navigation.skipAgents = nil
		return true
	else
		-- Not walkable: move agent A behind agent B and advance B
		Log:Debug("Not walkable to B - moving A behind B")

		-- Move agent A to current agent B position
		agents.agentA.nodeIndex = agents.agentB.nodeIndex
		agents.agentA.pos = agents.agentB.pos

		-- Advance agent B to next node if possible
		local nextBIndex = agents.agentB.nodeIndex + 1
		if nextBIndex <= #path then
			agents.agentB.nodeIndex = nextBIndex
			agents.agentB.pos = path[nextBIndex].pos
		else
			-- Can't advance B further, stop
			Log:Info("Reached path end - stopping skip checks")
			G.Navigation.skipAgents = nil
			return false
		end
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
