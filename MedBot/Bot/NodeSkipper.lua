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
local CONTINUOUS_SKIP_COOLDOWN = 2
local AGENT_SKIP_COOLDOWN = 4

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

		-- Stop agent if next node is a door - doors are transition points
		if nextCheckNode.isDoor then
			Common.DebugLog("Debug", "Agent stopped: next node %d is a door (transition point)", nextCheckNode.id)
			break
		end

		Common.DebugLog("Debug", "Agent at node %d, checking walkability to node %d", agentNode.id, nextCheckNode.id)

		-- Check if path from AGENT's current position to next check node is walkable
		-- Agent position = where the agent currently is on the path (not player position)
		if ISWalkable.Path(agentNode.pos, nextCheckNode.pos) then
			Common.DebugLog("Debug", "Agent: Path from %d to %d walkable, advancing agent", agentNode.id, nextCheckNode.id)
			agentIndex = agentIndex + 1
			skipCount = skipCount + 1
		else
			Common.DebugLog("Debug", "Agent: Path from %d to %d not walkable, stopping agent", agentNode.id, nextCheckNode.id)
			break -- Found obstacle, stop here
		end
	end

	Common.DebugLog("Debug", "Agent system: Found %d skippable nodes", skipCount)
	return skipCount
end

-- Check if we're closer to next node than current node is (geometric check)
-- This guarantees it's better to go for next node
local function CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode then
		return false
	end

	local distPlayerToNext = Common.Distance3D(currentPos, nextNode.pos)
	local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

	-- If we're closer to next node than current node is, we can skip
	return distPlayerToNext < distCurrentToNext
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Initialize/reset state when needed
function NodeSkipper.Reset()
	G.Navigation.nextNodeCloser = false
	WorkManager.resetCooldown("active_skip_check") -- Reset active skip check cooldown
	WorkManager.resetCooldown("passive_walkability_check") -- Reset passive walkability check cooldown
	WorkManager.resetCooldown("agent_skip_check") -- Reset agent skip check cooldown
	WorkManager.resetCooldown("manual_mode_walkability") -- Reset manual mode walkability check
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

	-- NEVER skip door nodes - they are transition points, not walkable destinations
	if nextNode.isDoor then
		return 0
	end

	local maxNodesToSkip = 0

	-- PASSIVE SYSTEM: Simple distance check (runs every tick - very cheap)
	if CheckNextNodeCloser(currentPos, currentNode, nextNode) then
		-- We're geometrically closer to next node - check if path is walkable (throttled)
		if WorkManager.attemptWork(11, "passive_walkability_check") then
			if ISWalkable.Path(currentPos, nextNode.pos) then
				Common.DebugLog(
					"Debug",
					"Passive skip: Next node %d closer and walkable - skip 1 node",
					nextNode.id
				)
				maxNodesToSkip = math.max(maxNodesToSkip, 1)
			else
				Common.DebugLog(
					"Debug",
					"Passive skip: Next node %d closer but NOT walkable - no skip",
					nextNode.id
				)
			end
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
