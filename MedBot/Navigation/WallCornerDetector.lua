--##########################################################################
--  WallCornerDetector.lua  ·  Detects wall corners for door clamping
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local WallCornerDetector = {}

local Log = Common.Log.new("WallCornerDetector")

-- Group neighbors by 4 directions for an area using existing dirId from connections
-- Source Engine nav format: connectionData[4] in NESW order (North, East, South, West)
local function groupNeighborsByDirection(area, nodes)
	local neighbors = {
		north = {}, -- dirId = 1 (index 0 in C++)
		east = {},  -- dirId = 2 (index 1 in C++)
		south = {}, -- dirId = 3 (index 2 in C++)
		west = {},  -- dirId = 4 (index 3 in C++)
	}

	if not area.c then
		return neighbors
	end

	-- dirId IS the direction - use it directly from NESW array
	for dirId, dir in pairs(area.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = (type(connection) == "table") and connection.node or connection
				local neighbor = nodes[targetId]
				if neighbor then
					-- Map dirId to direction name (NESW order)
					if dirId == 1 then
						table.insert(neighbors.north, neighbor)
					elseif dirId == 2 then
						table.insert(neighbors.east, neighbor)
					elseif dirId == 3 then
						table.insert(neighbors.south, neighbor)
					elseif dirId == 4 then
						table.insert(neighbors.west, neighbor)
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

	if direction == "north" then
		return area.nw, area.ne
	end
	if direction == "south" then
		return area.se, area.sw
	end
	if direction == "east" then
		return area.ne, area.se
	end
	if direction == "west" then
		return area.sw, area.nw
	end

	return nil, nil
end

-- Check if point lies on neighbor's facing boundary using shared axis
-- Returns proximity score: 0.99 if on edge, 1.0 if within tolerance, 0 if outside
local function pointLiesOnNeighborBorder(point, neighbor, direction)
	if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
		return 0
	end

	local tolerance = 1.0

	-- Determine shared axis and get neighbor's edge bounds on that axis
	local axis, corner1, corner2
	if direction == "north" then
		-- North/South share X axis, neighbor's south boundary
		axis = "x"
		corner1, corner2 = neighbor.sw, neighbor.se
	elseif direction == "south" then
		-- North/South share X axis, neighbor's north boundary
		axis = "x"
		corner1, corner2 = neighbor.nw, neighbor.ne
	elseif direction == "east" then
		-- East/West share Y axis, neighbor's west boundary
		axis = "y"
		corner1, corner2 = neighbor.sw, neighbor.nw
	elseif direction == "west" then
		-- East/West share Y axis, neighbor's east boundary
		axis = "y"
		corner1, corner2 = neighbor.se, neighbor.ne
	else
		return 0
	end

	-- Get bounds on shared axis
	local minCoord = math.min(corner1[axis], corner2[axis])
	local maxCoord = math.max(corner1[axis], corner2[axis])
	local pointCoord = point[axis]

	-- Check if point lies within bounds on shared axis
	if pointCoord < minCoord - tolerance or pointCoord > maxCoord + tolerance then
		return 0 -- Outside bounds
	end

	-- Check if point is at edge (near min or max)
	local distFromMin = math.abs(pointCoord - minCoord)
	local distFromMax = math.abs(pointCoord - maxCoord)

	if distFromMin < tolerance or distFromMax < tolerance then
		return 0.99 -- On edge
	else
		return 1.0 -- Within bounds
	end
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
				Log:Debug(
					"Node %s has %d neighbors (N:%d S:%d E:%d W:%d)",
					tostring(nodeId),
					totalNeighbors,
					#neighbors.north,
					#neighbors.south,
					#neighbors.east,
					#neighbors.west
				)
			end

			-- Check all 4 directions
			for direction, dirNeighbors in pairs(neighbors) do
				local corner1, corner2 = getDirectionCorners(area, direction)
				if corner1 and corner2 then
					-- Check both corners of this direction
					for _, corner in ipairs({ corner1, corner2 }) do
						table.insert(area.allCorners, corner)
						allCornerCount = allCornerCount + 1

						-- Calculate proximity score: sum of all neighbor border scores
						-- 0.99 = on edge, 1.0 = within tolerance
						local proximityScore = 0
						for _, neighbor in ipairs(neighbors.north) do
							proximityScore = proximityScore + pointLiesOnNeighborBorder(corner, neighbor, "north")
						end
						for _, neighbor in ipairs(neighbors.south) do
							proximityScore = proximityScore + pointLiesOnNeighborBorder(corner, neighbor, "south")
						end
						for _, neighbor in ipairs(neighbors.east) do
							proximityScore = proximityScore + pointLiesOnNeighborBorder(corner, neighbor, "east")
						end
						for _, neighbor in ipairs(neighbors.west) do
							proximityScore = proximityScore + pointLiesOnNeighborBorder(corner, neighbor, "west")
						end

						-- Debug: log proximity scores for first few corners
						if allCornerCount <= 10 then
							Log:Debug(
								"Corner at (%.1f,%.1f,%.1f) in direction %s has %.2f proximity score",
								corner.x,
								corner.y,
								corner.z,
								direction,
								proximityScore
							)
						end

						-- Classification:
						-- < 1.99 = outer corner (wall corner)
						-- >= 1.99 = inner corner (fully surrounded)
						local cornerType = "not_wall"
						if proximityScore < 1.99 then
							cornerType = "wall"
							table.insert(area.wallCorners, corner) -- Mark as wall corner
							wallCornerCount = wallCornerCount + 1
						end

						-- Store corner classification for debugging
						if not area.cornerTypes then
							area.cornerTypes = {}
						end
						table.insert(area.cornerTypes, {
							pos = corner,
							type = cornerType,
							proximityScore = proximityScore,
							direction = direction,
						})
					end
				end
			end
		end
	end

	Log:Info(
		"Processed %d nodes, detected %d wall corners out of %d total corners",
		nodeCount,
		wallCornerCount,
		allCornerCount
	)

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
