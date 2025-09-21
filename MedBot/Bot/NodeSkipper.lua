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
local CONTINUOUS_SKIP_COOLDOWN = 2 -- ticks (~366ms) for active skipping
local AGENT_SKIP_COOLDOWN = 4 -- ticks (~550ms) for agent system (slower, more expensive)

-- ============================================================================
-- AGENT SYSTEM
-- ============================================================================

-- Single-agent progressive skipping system
-- Agent starts from next node and advances until it finds non-walkable path
-- RETURNS: number of nodes to skip (0 if none)
local function RunAgentSkipping(currentPos)
	local path = G.Navigation.path
	if not path or #path < 3 then -- Need at least current + next + one more
		Common.DebugLog("Debug", "Agent system: Path too short (%d nodes), aborting", path and #path or 0)
		return 0
	end

	local skipCount = 0
	local agentIndex = 2 -- Start from next node (path[2])

	Common.DebugLog("Debug", "Agent system: Starting from node %d (path index %d)", path[agentIndex].id, agentIndex)

	-- Agent advances along path, checking walkability at each step
	while agentIndex < #path do
		local agentNode = path[agentIndex]
		local nextCheckNode = path[agentIndex + 1]

		if not nextCheckNode then
			break -- End of path
		end

		Common.DebugLog("Debug", "Agent at node %d, checking walkability to node %d", agentNode.id, nextCheckNode.id)

		-- Check if path from current position to next check node is walkable
		if ISWalkable.Path(currentPos, nextCheckNode.pos) then
			Common.DebugLog("Debug", "Agent: Path to node %d walkable, advancing agent", nextCheckNode.id)
			agentIndex = agentIndex + 1
			skipCount = skipCount + 1
		else
			Common.DebugLog("Debug", "Agent: Path to node %d not walkable, stopping agent", nextCheckNode.id)
			break -- Found obstacle, stop here
		end
	end

	Common.DebugLog("Debug", "Agent system: Found %d skippable nodes", skipCount)
	return skipCount
end

-- Check if next node is closer than current (cheap distance check)
local function CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode then
		return false
	end

	local distToCurrent = Common.Distance3D(currentPos, currentNode.pos)
	local distToNext = Common.Distance3D(currentPos, nextNode.pos)

	return distToNext < distToCurrent
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Initialize/reset state when needed
function NodeSkipper.Reset()
	G.Navigation.nextNodeCloser = false
	WorkManager.resetCooldown("active_skip_check") -- Reset active skip check cooldown
	WorkManager.resetCooldown("passive_skip_check") -- Reset passive skip check cooldown
	WorkManager.resetCooldown("agent_skip_check") -- Reset agent skip check cooldown
	Log:Debug("NodeSkipper state reset")
end

-- Continuous hybrid node skipping check (called by MovementDecisions)
-- COMPLETE SYSTEM: Passive + Active + Agent checking (all independent)
-- RETURNS: number of nodes to skip (0 = no skip, max from all systems)
-- NO SIDE EFFECTS - pure decision function
function NodeSkipper.CheckContinuousSkip(currentPos)
	-- Respect Skip_Nodes menu setting
	if not G.Menu.Main.Skip_Nodes then
		return 0
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return 0
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		return 0
	end

	local maxNodesToSkip = 0

	-- PASSIVE SYSTEM: Distance-based skipping (cheap, runs every 11 ticks)
	if WorkManager.attemptWork(11, "passive_skip_check") then
		if CheckNextNodeCloser(currentPos, currentNode, nextNode) then
			Common.DebugLog("Debug", "Passive skip: Next node %d closer than current %d - skip 1 node", nextNode.id, currentNode.id)
			maxNodesToSkip = math.max(maxNodesToSkip, 1)
		end
	end

	-- ACTIVE SYSTEM: Walkability-based skipping (expensive, runs every 22 ticks)
	if WorkManager.attemptWork(CONTINUOUS_SKIP_COOLDOWN, "active_skip_check") then
		Common.DebugLog("Debug", "Active skip check - checking path from player to next node %d", nextNode.id)

		if ISWalkable.Path(currentPos, nextNode.pos) then
			Common.DebugLog("Debug", "Active skip: Path to next node %d is walkable - skip 1 node", nextNode.id)
			maxNodesToSkip = math.max(maxNodesToSkip, 1)
		end
	end

	-- AGENT SYSTEM: Progressive multi-node skipping (most expensive, runs every 33 ticks)
	if WorkManager.attemptWork(AGENT_SKIP_COOLDOWN, "agent_skip_check") then
		Common.DebugLog("Debug", "Agent system check - running progressive skip analysis")
		local agentSkipCount = RunAgentSkipping(currentPos)
		if agentSkipCount > 0 then
			Common.DebugLog("Debug", "Agent system: Found %d nodes to skip", agentSkipCount)
			maxNodesToSkip = math.max(maxNodesToSkip, agentSkipCount)
		end
	end

	return maxNodesToSkip
end

return NodeSkipper
