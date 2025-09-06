--##########################################################################
--  WallCornerDetector.lua  ·  Detects wall corners for door clamping
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local WallCornerDetector = {}

local Log = Common.Log.new("WallCornerDetector")

-- Group neighbors by 4 directions for an area
local function groupNeighborsByDirection(area, nodes)
	local neighbors = {
		north = {},  -- dirY = -1
		south = {},  -- dirY = 1  
		east = {},   -- dirX = 1
		west = {}    -- dirX = -1
	}
	
	if not area.c then return neighbors end
	
	for dirId, dir in pairs(area.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = (type(connection) == "table") and connection.node or connection
				local neighbor = nodes[targetId]
				if neighbor then
					-- Determine direction from area to neighbor
					local dx = neighbor.pos.x - area.pos.x
					local dy = neighbor.pos.y - area.pos.y
					
					if math.abs(dx) >= math.abs(dy) then
						if dx > 0 then
							table.insert(neighbors.east, neighbor)
						else
							table.insert(neighbors.west, neighbor)
						end
					else
						if dy > 0 then
							table.insert(neighbors.south, neighbor)
						else
							table.insert(neighbors.north, neighbor)
						end
					end
				end
			end
		end
	end
	
	return neighbors
end

-- Get 2 corner points for a direction edge
local function getDirectionCorners(area, direction)
	if not (area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end
	
	if direction == "north" then return area.nw, area.ne end
	if direction == "south" then return area.se, area.sw end  
	if direction == "east" then return area.ne, area.se end
	if direction == "west" then return area.sw, area.nw end
	
	return nil, nil
end

-- Check if point lies on neighbor's border edge facing our area
local function pointLiesOnNeighborBorder(point, neighbor, direction)
	if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
		return false
	end
	
	local tolerance = 1.0 -- Small tolerance for misaligned borders
	
	if direction == "north" then
		-- Check if point lies on neighbor's south edge
		local edge1, edge2 = neighbor.se, neighbor.sw
		-- Check if point.y matches edge Y and point.x is between edge X coords
		return math.abs(point.y - edge1.y) < tolerance and 
		       point.x >= math.min(edge1.x, edge2.x) - tolerance and
		       point.x <= math.max(edge1.x, edge2.x) + tolerance
	elseif direction == "south" then
		-- Check if point lies on neighbor's north edge  
		local edge1, edge2 = neighbor.nw, neighbor.ne
		return math.abs(point.y - edge1.y) < tolerance and
		       point.x >= math.min(edge1.x, edge2.x) - tolerance and
		       point.x <= math.max(edge1.x, edge2.x) + tolerance
	elseif direction == "east" then
		-- Check if point lies on neighbor's west edge
		local edge1, edge2 = neighbor.sw, neighbor.nw  
		return math.abs(point.x - edge1.x) < tolerance and
		       point.y >= math.min(edge1.y, edge2.y) - tolerance and
		       point.y <= math.max(edge1.y, edge2.y) + tolerance
	elseif direction == "west" then
		-- Check if point lies on neighbor's east edge
		local edge1, edge2 = neighbor.ne, neighbor.se
		return math.abs(point.x - edge1.x) < tolerance and
		       point.y >= math.min(edge1.y, edge2.y) - tolerance and
		       point.y <= math.max(edge1.y, edge2.y) + tolerance
	end
	
	return false
end

-- Count how many neighbor borders a corner lies on
local function countNeighborBorders(corner, neighbors, direction)
	local count = 0
	for _, neighbor in ipairs(neighbors) do
		if pointLiesOnNeighborBorder(corner, neighbor, direction) then
			count = count + 1
		end
	end
	return count
end

function WallCornerDetector.DetectWallCorners()
	local nodes = G.Navigation.nodes
	if not nodes then 
		Log:Warn("No nodes available for wall corner detection")
		return 
	end
	
	local wallCornerCount = 0
	local allCornerCount = 0
	local nodeCount = 0
	
	for nodeId, area in pairs(nodes) do
		nodeCount = nodeCount + 1
		if area.nw and area.ne and area.se and area.sw then
			-- Initialize wall corner storage on node
			area.wallCorners = {}
			area.allCorners = {}
			
			local neighbors = groupNeighborsByDirection(area, nodes)
			
			-- Debug: log neighbor counts for first few nodes
			if nodeCount <= 3 then
				local totalNeighbors = #neighbors.north + #neighbors.south + #neighbors.east + #neighbors.west
				Log:Debug("Node %s has %d neighbors (N:%d S:%d E:%d W:%d)", 
					tostring(nodeId), totalNeighbors, #neighbors.north, #neighbors.south, #neighbors.east, #neighbors.west)
			end
			
			-- Check all 4 directions
			for direction, dirNeighbors in pairs(neighbors) do
				local corner1, corner2 = getDirectionCorners(area, direction)
				if corner1 and corner2 then
					-- Check both corners of this direction
					for _, corner in ipairs({corner1, corner2}) do
						table.insert(area.allCorners, corner)
						allCornerCount = allCornerCount + 1
						
						local borderCount = countNeighborBorders(corner, dirNeighbors, direction)
						
						-- Debug: log border counts for first few corners
						if allCornerCount <= 10 then
							Log:Debug("Corner at (%.1f,%.1f,%.1f) in direction %s has %d border contacts", 
								corner.x, corner.y, corner.z, direction, borderCount)
						end
						
						-- Corner is wall corner if it lies on <2 neighbor borders
						if borderCount < 2 then
							table.insert(area.wallCorners, corner)
							wallCornerCount = wallCornerCount + 1
						end
					end
				end
			end
		end
	end
	
	Log:Info("Processed %d nodes, detected %d wall corners out of %d total corners", 
		nodeCount, wallCornerCount, allCornerCount)
	
	-- Console output for immediate visibility
	print("WallCornerDetector: " .. wallCornerCount .. " wall corners found")
	
	-- Debug: log first few nodes with wall corners
	local debugCount = 0
	for nodeId, area in pairs(nodes) do
		if area.wallCorners and #area.wallCorners > 0 then
			debugCount = debugCount + 1
			if debugCount <= 3 then
				Log:Debug("Node %s has %d wall corners", tostring(nodeId), #area.wallCorners)
				for i, corner in ipairs(area.wallCorners) do
					Log:Debug("  Wall corner %d: (%.1f,%.1f,%.1f)", i, corner.x, corner.y, corner.z)
				end
			end
		end
	end
end

return WallCornerDetector
