--[[
Node Skipper - Simple funneling-based node skipping
Two skip modes:
1. Proximity skip: Skip to next node if we're closer to it than current node is
2. Funneling skip: Use 2D funnel algorithm on area quads to skip multiple nodes
Runs every tick (no WorkManager cooldowns)
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local NodeSkipper = {}
local Log = Common.Log.new("NodeSkipper")

-- ============================================================================
-- 2D FUNNEL ALGORITHM (horizontal only, ignore Z)
-- ============================================================================

-- Get 2D vector (ignore Z)
local function to2D(v)
	return { x = v.x, y = v.y }
end

-- 2D cross product (returns scalar)
local function cross2D(a, b)
	return a.x * b.y - a.y * b.x
end

-- 2D vector subtraction
local function sub2D(a, b)
	return { x = a.x - b.x, y = a.y - b.y }
end

-- Find the two shared corners between consecutive quads (portal edge)
-- Returns left, right corners of the portal (or nil if no shared edge)
local function findPortalEdge(prevNode, nextNode)
	if not (prevNode.nw and prevNode.ne and prevNode.se and prevNode.sw) then
		return nil, nil
	end
	if not (nextNode.nw and nextNode.ne and nextNode.se and nextNode.sw) then
		return nil, nil
	end
	
	-- Get all 4 corners from each node
	local prevCorners = { prevNode.nw, prevNode.ne, prevNode.se, prevNode.sw }
	local nextCorners = { nextNode.nw, nextNode.ne, nextNode.se, nextNode.sw }
	
	-- Find shared corners (within small epsilon for floating point)
	local sharedCorners = {}
	local epsilon = 1.0
	
	for _, pc in ipairs(prevCorners) do
		for _, nc in ipairs(nextCorners) do
			local dist = math.sqrt((pc.x - nc.x)^2 + (pc.y - nc.y)^2)
			if dist < epsilon then
				table.insert(sharedCorners, to2D(pc))
				break
			end
		end
	end
	
	-- Need exactly 2 shared corners for a valid portal
	if #sharedCorners == 2 then
		return sharedCorners[1], sharedCorners[2]
	end
	
	-- Fallback: use opposite corners if areas are separate
	-- Use NW and SE as default portal
	return to2D(nextNode.nw), to2D(nextNode.se)
end

-- Simple funnel algorithm on nav quads (4 corners per area)
-- Returns: number of nodes we can skip (0 = no skip)
local function RunFunneling(currentPos, path)
	if not path or #path < 3 then
		return 0 -- Need current + next + at least one more
	end

	-- Start funnel from current position (2D only)
	local apex = to2D(currentPos)
	local leftEdge = apex
	local rightEdge = apex
	
	-- Process each portal between consecutive nodes
	for i = 2, #path do
		local prevNode = path[i - 1]
		local node = path[i]
		
		-- Stop at door nodes - they're transition points
		if node.isDoor then
			Common.DebugLog("Debug", "Funnel: Stopped at door node %d", node.id)
			return math.max(0, i - 2)
		end
		
		-- Find portal edge between prev and current node
		local portal1, portal2 = findPortalEdge(prevNode, node)
		if not portal1 or not portal2 then
			Common.DebugLog("Debug", "Funnel: No portal found at node %d, stopping", node.id)
			return math.max(0, i - 2)
		end
		
		-- Determine which portal point is left/right based on cross product
		local toPortal1 = sub2D(portal1, apex)
		local toPortal2 = sub2D(portal2, apex)
		local cross = cross2D(toPortal1, toPortal2)
		
		local leftPortal, rightPortal
		if cross > 0 then
			leftPortal = portal1
			rightPortal = portal2
		else
			leftPortal = portal2
			rightPortal = portal1
		end
		
		-- Try to narrow left edge
		local leftCross = cross2D(sub2D(leftPortal, apex), sub2D(leftEdge, apex))
		if leftCross >= 0 then
			-- Check if it crosses right edge
			if cross2D(sub2D(leftPortal, apex), sub2D(rightEdge, apex)) < 0 then
				-- Funnel closes - stop here
				Common.DebugLog("Debug", "Funnel: Left crossed right at node %d", node.id)
				return math.max(0, i - 2)
			end
			leftEdge = leftPortal
		end
		
		-- Try to narrow right edge
		local rightCross = cross2D(sub2D(rightPortal, apex), sub2D(rightEdge, apex))
		if rightCross <= 0 then
			-- Check if it crosses left edge
			if cross2D(sub2D(rightPortal, apex), sub2D(leftEdge, apex)) > 0 then
				-- Funnel closes - stop here
				Common.DebugLog("Debug", "Funnel: Right crossed left at node %d", node.id)
				return math.max(0, i - 2)
			end
			rightEdge = rightPortal
		end
		
		Common.DebugLog("Debug", "Funnel: Node %d in corridor, continuing", node.id)
	end
	
	-- Successfully funneled through all nodes
	local skipCount = #path - 1
	Common.DebugLog("Debug", "Funnel: Can skip %d nodes", skipCount)
	return skipCount
end

-- ============================================================================
-- PROXIMITY SKIP
-- ============================================================================

-- Check if we're closer to next node than current node is (geometric check)
local function CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode then
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
	Log:Debug("NodeSkipper state reset")
end

-- Continuous node skipping check (runs every tick)
-- Two modes:
-- 1. Proximity skip: Skip to next node if closer to it
-- 2. Funneling skip: Use funnel algorithm to skip multiple nodes
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

	-- NEVER skip door nodes
	if nextNode.isDoor then
		return 0
	end

	-- MODE 1: Funneling skip - try to skip multiple nodes using funnel algorithm
	-- Try this FIRST since it can skip more nodes than proximity
	if #path > 2 then
		local funnelSkip = RunFunneling(currentPos, path)
		if funnelSkip > 0 then
			Common.DebugLog("Debug", "Funneling skip: Can skip %d nodes", funnelSkip)
			return funnelSkip
		end
	end

	-- MODE 2: Proximity skip - fallback if funneling didn't work
	-- If we're closer to next node, skip current
	if CheckNextNodeCloser(currentPos, currentNode, nextNode) then
		Common.DebugLog("Debug", "Proximity skip: Closer to next node %d", nextNode.id)
		return 1
	end

	return 0
end

return NodeSkipper
