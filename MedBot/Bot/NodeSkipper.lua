--[[
Node Skipper - Door-based funneling node skipping
Logic:
1. Use doors as portals (left/right edges)
2. Funnel only in the direction the path is going (from connection data)
3. Skip node if next node closer to player than current node to next node (avoid backwalking)
4. Use max skip range from menu settings
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local ConnectionBuilder = require("MedBot.Navigation.ConnectionBuilder")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local NodeSkipper = {}

-- ============================================================================
-- 2D FUNNEL ALGORITHM (uses doors as portals)
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

-- Get door data between two nodes
-- Returns door with left/middle/right positions or nil
local function getDoorBetweenNodes(nodeA, nodeB)
	if not (nodeA and nodeB) then
		return nil
	end
	
	local nodes = G.Navigation.nodes
	if not nodes then
		return nil
	end
	
	-- Try both orderings for door prefix
	local doorPrefix1 = nodeA.id .. "_" .. nodeB.id
	local doorPrefix2 = nodeB.id .. "_" .. nodeA.id
	
	for _, prefix in ipairs({doorPrefix1, doorPrefix2}) do
		-- Check for middle door first (always exists)
		local middleDoorId = prefix .. "_middle"
		local middleDoor = nodes[middleDoorId]
		
		if middleDoor and middleDoor.pos then
			-- Found door - get left/right if they exist
			local leftDoorId = prefix .. "_left"
			local rightDoorId = prefix .. "_right"
			
			local leftDoor = nodes[leftDoorId]
			local rightDoor = nodes[rightDoorId]
			
			return {
				left = leftDoor and leftDoor.pos or nil,
				middle = middleDoor.pos,
				right = rightDoor and rightDoor.pos or nil
			}
		end
	end
	
	return nil
end

-- Door-based funnel algorithm
-- Uses doors as portals with left/right edges
-- Only funnels in the direction the path is going (from connection data)
-- Path structure: path[1] = closest to player, path[#path] = destination (furthest)
-- Returns: number of nodes we can skip (0 = no skip)
local function RunFunneling(currentPos, path)
	if not path or #path < 2 then
		return 0 -- Need at least 2 nodes
	end

	-- Get range limit from menu settings
	local maxSkipRange = G.Menu.Main.MaxSkipRange or 500
	
	-- Start funnel from player position (2D)
	local apex = to2D(currentPos)
	local leftEdge = apex
	local rightEdge = apex
	
	local nodesSkipped = 0
	
	-- Process path forward (from closest to furthest)
	-- path[1] is closest, path[#path] is destination
	for i = 1, #path - 1 do
		local currentNode = path[i]
		local nextNode = path[i + 1]
		
		-- Check range limit FIRST - enforce for ALL nodes
		if currentNode.pos then
			local dist = Common.Distance3D(currentPos, currentNode.pos)
			if dist > maxSkipRange then
				return nodesSkipped
			end
		end
		
		if nextNode.pos then
			local dist = Common.Distance3D(currentPos, nextNode.pos)
			if dist > maxSkipRange then
				return nodesSkipped
			end
		end
		
		-- Skip door nodes (they're waypoints, no geometry)
		if currentNode.isDoor then
			nodesSkipped = nodesSkipped + 1
			goto continue_funnel
		end
		
		if nextNode.isDoor then
			nodesSkipped = nodesSkipped + 1
			goto continue_funnel
		end
		
		-- Get door between current and next (portal)
		local door = getDoorBetweenNodes(currentNode, nextNode)
		if not door or not door.middle then
			-- No door portal found - stop funneling
			return nodesSkipped
		end
		
		-- Use left/right if they exist, otherwise use middle as both
		local leftPortal = door.left and to2D(door.left) or to2D(door.middle)
		local rightPortal = door.right and to2D(door.right) or to2D(door.middle)
		
		-- Determine left/right relative to apex using cross product
		local toLeft = sub2D(leftPortal, apex)
		local toRight = sub2D(rightPortal, apex)
		local cross = cross2D(toLeft, toRight)
		
		-- Swap if necessary
		if cross < 0 then
			leftPortal, rightPortal = rightPortal, leftPortal
		end
		
		-- Try to narrow left edge
		local leftCross = cross2D(sub2D(leftPortal, apex), sub2D(leftEdge, apex))
		if leftCross >= 0 then
			-- Check if it crosses right edge (funnel closes)
			if cross2D(sub2D(leftPortal, apex), sub2D(rightEdge, apex)) < 0 then
				return nodesSkipped -- Funnel closed, can't skip further
			end
			leftEdge = leftPortal
		end
		
		-- Try to narrow right edge
		local rightCross = cross2D(sub2D(rightPortal, apex), sub2D(rightEdge, apex))
		if rightCross <= 0 then
			-- Check if it crosses left edge (funnel closes)
			if cross2D(sub2D(rightPortal, apex), sub2D(leftEdge, apex)) > 0 then
				return nodesSkipped -- Funnel closed, can't skip further
			end
			rightEdge = rightPortal
		end
		
		-- Funnel successfully narrowed - can skip this node
		nodesSkipped = nodesSkipped + 1
		
		::continue_funnel::
	end
	
	return nodesSkipped
end

-- ============================================================================
-- SKIP LOGIC
-- ============================================================================

-- Check if we're closer to next node than current node is
-- This prevents backwalking
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

	-- If current node is a door, skip it immediately
	if currentNode.isDoor then
		return 1
	end

	-- Check if we're closer to next node (avoid backwalking)
	if not CheckNextNodeCloser(currentPos, currentNode, nextNode) then
		return 0 -- Don't skip if we're not moving forward
	end

	-- Run funneling algorithm
	local skipCount = RunFunneling(currentPos, path)
	
	return skipCount
end

return NodeSkipper
