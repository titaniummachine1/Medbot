--[[
Node Skipper - Simple forward-progress node skipping
Logic:
1. Respect Skip_Nodes toggle
2. Only skip when the player is closer to the next node than the current node is
3. Returns fixed skip count (1) to advance steadily without funneling
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local WorkManager = require("MedBot.WorkManager")
local PathValidator = require("MedBot.Navigation.IsWalkable")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Initialize/reset state when needed
function NodeSkipper.Reset()
	G.Navigation.nextNodeCloser = false
end

-- SINGLE SOURCE OF TRUTH for node skipping
-- Checks if we should skip current node and executes the skip
-- RETURNS: true if skipped, false otherwise
function NodeSkipper.TrySkipNode(currentPos, removeNodeCallback)
	-- Respect Skip_Nodes menu setting
	if not G.Menu.Navigation.Skip_Nodes then
		Log:Debug("Skip_Nodes is disabled")
		return false
	end

	Log:Debug("Skip_Nodes is ENABLED, checking conditions...")

	local path = G.Navigation.path
	if not path then
		Log:Debug("ABORT - No path exists")
		return false
	end

	-- Path goes player → goal (normal order)
	-- path[1] = current target (walking toward RIGHT NOW)
	-- path[2] = next node (after current)
	-- path[3] = skip target (validate if we can reach this directly)
	if #path < 3 then
		Log:Debug("ABORT - Path too short (length=%d, need 3+)", #path)
		return false
	end

	local currentNode = path[1] -- Current target
	local nextNode = path[2] -- Next after current
	local skipToNode = path[3] -- Skip target

	if not currentNode or not nextNode or not skipToNode then
		Log:Debug("ABORT - Missing nodes")
		return false
	end

	if not currentNode.pos or not nextNode.pos or not skipToNode.pos then
		Log:Debug("ABORT - Missing node positions")
		return false
	end

	Log:Debug("Path valid, checking distances (path length=%d)", #path)
	Log:Debug(
		"path[1]=%s (current), path[2]=%s (next), path[3]=%s (skip target)",
		tostring(currentNode.id or "nil"),
		tostring(nextNode.id or "nil"),
		tostring(skipToNode.id or "nil")
	)

	-- CRITICAL: Only skip if we're actually AT or PAST path[1]
	-- If player is far from path[1], we haven't reached it yet (e.g., fell and need to climb back)
	local distPlayerToCurrent = Common.Distance3D(currentPos, currentNode.pos)
	local REACH_THRESHOLD = 60 -- Same as MovementDecisions reach distance

	if distPlayerToCurrent > REACH_THRESHOLD then
		Log:Debug(
			"ABORT - Haven't reached path[1] yet (dist=%.0f > threshold=%d)",
			distPlayerToCurrent,
			REACH_THRESHOLD
		)
		Log:Debug("Path[1] might be above/behind us after falling - don't skip until we reach it")
		return false
	end

	local distPlayerToSkip = Common.Distance3D(currentPos, skipToNode.pos)
	local distNextToSkip = Common.Distance3D(nextNode.pos, skipToNode.pos)

	Log:Debug("Player pos=(%.0f,%.0f,%.0f)", currentPos.x, currentPos.y, currentPos.z)
	Log:Debug("path[1] (current) pos=(%.0f,%.0f,%.0f)", currentNode.pos.x, currentNode.pos.y, currentNode.pos.z)
	Log:Debug("path[2] (next) pos=(%.0f,%.0f,%.0f)", nextNode.pos.x, nextNode.pos.y, nextNode.pos.z)
	Log:Debug("path[3] (skip target) pos=(%.0f,%.0f,%.0f)", skipToNode.pos.x, skipToNode.pos.y, skipToNode.pos.z)

	-- Only skip if player is closer to skip target than NEXT node is to skip target
	-- (meaning we're progressing past the current node already)
	if distPlayerToSkip >= distNextToSkip then
		Log:Debug("ABORT - Not closer (player=%.0f >= next=%.0f)", distPlayerToSkip, distNextToSkip)
		return false -- Don't skip if we're not moving forward
	end

	Log:Debug("Distance check PASSED (player=%.0f < next=%.0f)", distPlayerToSkip, distNextToSkip)

	-- VALIDATION: Check if we can walk DIRECTLY to skip target (path[3])
	Log:Debug("=== Validate path to SKIP TARGET (path[3]) ===")
	Log:Debug(
		"FROM PLAYER(%.0f,%.0f,%.0f) TO SKIP_TARGET(%.0f,%.0f,%.0f)",
		currentPos.x,
		currentPos.y,
		currentPos.z,
		skipToNode.pos.x,
		skipToNode.pos.y,
		skipToNode.pos.z
	)

	if not WorkManager.attemptWork(11, "node_skip_validation") then
		Log:Debug("Skip validation on cooldown - waiting 11 ticks between checks")
		return false
	end

	local isWalkable = PathValidator.Path(currentPos, skipToNode.pos)
	Log:Debug("Can reach skip target directly: %s", tostring(isWalkable))

	-- Debug logging (respects G.Menu.Main.Debug)
	Log:Debug(
		"Skip check: playerDist=%.0f nextDist=%.0f walkable=%s",
		distPlayerToSkip,
		distNextToSkip,
		tostring(isWalkable)
	)

	if not isWalkable then
		Log:Debug("Skip blocked: path not walkable (wall detected)")
		return false -- Don't skip if path has walls/obstacles
	end

	-- Execute the skip - remove path[1] (current node) so path[2] becomes new current
	if removeNodeCallback then
		Log:Debug("Skipping path[1] (node %s) - direct path to path[3] validated", tostring(currentNode.id))
		removeNodeCallback()
		return true
	end

	return false
end

return NodeSkipper
