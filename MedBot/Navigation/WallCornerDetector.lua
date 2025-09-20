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
		north = {}, -- dirY = -1
		south = {}, -- dirY = 1
		east = {}, -- dirX = 1
		west = {}, -- dirX = -1
	}

	if not area.c then
		return neighbors
	end

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

-- Calculate distance from point to line segment (2D, ignores Z completely)
local function pointToLineSegmentDistance(point, lineStart, lineEnd)
	local dx = lineEnd.x - lineStart.x
	local dy = lineEnd.y - lineStart.y
	local length = Vector3(dx, dy, 0):Length2D()

	if length == 0 then
		-- Line segment is a point - use Common.Distance2D
		local point2D = Vector3(point.x, point.y, 0)
		local start2D = Vector3(lineStart.x, lineStart.y, 0)
		return Common.Distance2D(point2D, start2D)
	end

	-- Calculate projection parameter
	local t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / (length * length)

	-- Clamp t to [0, 1] to stay within segment bounds
	t = math.max(0, math.min(1, t))

	-- Calculate closest point on line segment
	local closestX = lineStart.x + t * dx
	local closestY = lineStart.y + t * dy

	-- Use Common.Distance2D for final distance calculation (ignore Z)
	local point2D = Vector3(point.x, point.y, 0)
	local closest2D = Vector3(closestX, closestY, 0)
	return Common.Distance2D(point2D, closest2D)
end

-- Check if point lies on neighbor border (improved version)
local function pointLiesOnNeighborBorder(point, neighbor, direction)
	if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
		return false
	end

	local maxDistance = 18.0 -- Allow up to 18 units distance for lenient detection

	-- Check all 4 border edges of the neighbor
	local edges = {
		{ neighbor.nw, neighbor.ne }, -- North edge
		{ neighbor.ne, neighbor.se }, -- East edge
		{ neighbor.se, neighbor.sw }, -- South edge
		{ neighbor.sw, neighbor.nw }, -- West edge
	}

	-- Check distance to each edge using 2D calculation (ignore Z)
	for _, edge in ipairs(edges) do
		local distance = pointToLineSegmentDistance(point, edge[1], edge[2])
		if distance <= maxDistance then
			return true -- Point is close enough to this border edge
		end
	end

	return false -- Point is too far from all border edges
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

						-- Simplified: wall corner gets 1 point for each neighbor it's close to
						local proximityScore = 0
						for _, neighbor in ipairs(neighbors.north) do
							if pointLiesOnNeighborBorder(corner, neighbor, direction) then
								proximityScore = proximityScore + 1
							end
						end
						for _, neighbor in ipairs(neighbors.south) do
							if pointLiesOnNeighborBorder(corner, neighbor, direction) then
								proximityScore = proximityScore + 1
							end
						end
						for _, neighbor in ipairs(neighbors.east) do
							if pointLiesOnNeighborBorder(corner, neighbor, direction) then
								proximityScore = proximityScore + 1
							end
						end
						for _, neighbor in ipairs(neighbors.west) do
							if pointLiesOnNeighborBorder(corner, neighbor, direction) then
								proximityScore = proximityScore + 1
							end
						end

						-- Debug: log proximity scores for first few corners
						if allCornerCount <= 10 then
							Log:Debug(
								"Corner at (%.1f,%.1f,%.1f) in direction %s has %d proximity score",
								corner.x,
								corner.y,
								corner.z,
								direction,
								proximityScore
							)
						end

						-- Simplified classification: wall corner if exactly 1 neighbor contact
						local cornerType = "not_wall"
						if proximityScore == 1 then
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
