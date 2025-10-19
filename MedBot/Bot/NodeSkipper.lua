--[[
Node Skipper - Simple forward-progress node skipping
Logic:
1. Respect Skip_Nodes toggle
2. Only skip when the player is closer to the next node than the current node is
3. Returns fixed skip count (1) to advance steadily without funneling
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local NodeSkipper = {}

-- ============================================================================
-- NODE SKIPPING HELPERS
-- ============================================================================

-- ============================================================================
-- SKIP LOGIC
-- ============================================================================

-- Check if player is closer to next node than current node is to next node
-- This prevents backwalking - only skip if we've moved forward past current
local function CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		return false
	end

	local distPlayerToNext = Common.Distance3D(currentPos, nextNode.pos)
	local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

	return distPlayerToNext < distCurrentToNext
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Initialize/reset state when needed
function NodeSkipper.Reset()
	G.Navigation.nextNodeCloser = false
end

-- Continuous node skipping check (runs every tick)
-- Uses door-based funneling algorithm
-- RETURNS: number of nodes to skip (0 = no skip)
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

	-- Check if we're closer to next node (avoid backwalking)
	if not CheckNextNodeCloser(currentPos, currentNode, nextNode) then
		return 0 -- Don't skip if we're not moving forward
	end

	return 1
end

return NodeSkipper
