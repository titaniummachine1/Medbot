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
		east = {}, -- dirId = 2 (index 1 in C++)
		south = {}, -- dirId = 3 (index 2 in C++)
		west = {}, -- dirId = 4 (index 3 in C++)
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
-- Returns: proximity score (0.99 if at edge, 1.0 if perfectly within), and the neighbor
local function checkPointOnNeighborBoundary(point, neighbor, direction)
	if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
		return 0, nil
	end

	local tolerance = 2.0 -- Increased to handle minor nav mesh misalignments

	-- Determine shared axis and get neighbor's facing edge bounds
	local axis, corner1, corner2
	if direction == "north" then
		axis = "x"
		corner1, corner2 = neighbor.sw, neighbor.se -- Neighbor's south boundary
	elseif direction == "south" then
		axis = "x"
		corner1, corner2 = neighbor.nw, neighbor.ne -- Neighbor's north boundary
	elseif direction == "east" then
		axis = "y"
		corner1, corner2 = neighbor.sw, neighbor.nw -- Neighbor's west boundary
	elseif direction == "west" then
		axis = "y"
		corner1, corner2 = neighbor.se, neighbor.ne -- Neighbor's east boundary
	else
		return 0, nil
	end

	-- Get bounds on shared axis
	local minCoord = math.min(corner1[axis], corner2[axis])
	local maxCoord = math.max(corner1[axis], corner2[axis])
	local pointCoord = point[axis]

	-- Outside bounds entirely
	if pointCoord < minCoord - tolerance or pointCoord > maxCoord + tolerance then
		return 0, nil
	end

	-- Check if at edge (near min or max boundary)
	local distFromMin = math.abs(pointCoord - minCoord)
	local distFromMax = math.abs(pointCoord - maxCoord)

	if distFromMin < tolerance or distFromMax < tolerance then
		return 0.99, neighbor -- At edge
	else
		return 1.0, neighbor -- Perfectly within
	end
end

-- Get corner type and its two adjacent directions
-- Returns: dir1, dir2 (the two directions adjacent to this corner)
local function getCornerDirections(area, corner)
	if corner == area.nw then
		return "north", "west"
	elseif corner == area.ne then
		return "north", "east"
	elseif corner == area.se then
		return "south", "east"
	elseif corner == area.sw then
		return "south", "west"
	end
	return nil, nil
end

-- Get diagonal direction from two adjacent directions
local function getDiagonalDirection(dir1, dir2)
	if (dir1 == "north" and dir2 == "east") or (dir1 == "east" and dir2 == "north") then
		return "north", "east" -- NE diagonal
	elseif (dir1 == "north" and dir2 == "west") or (dir1 == "west" and dir2 == "north") then
		return "north", "west" -- NW diagonal
	elseif (dir1 == "south" and dir2 == "east") or (dir1 == "east" and dir2 == "south") then
		return "south", "east" -- SE diagonal
	elseif (dir1 == "south" and dir2 == "west") or (dir1 == "west" and dir2 == "south") then
		return "south", "west" -- SW diagonal
	end
	return nil, nil
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

			-- Check all 4 corners individually
			local corners = { area.nw, area.ne, area.se, area.sw }
			for _, corner in ipairs(corners) do
				table.insert(area.allCorners, corner)
				allCornerCount = allCornerCount + 1

				-- Get the two adjacent directions for this corner
				local dir1, dir2 = getCornerDirections(area, corner)
				if not dir1 or not dir2 then
					goto continue_corner
				end

				-- FAST PATH: Check if either adjacent direction is empty
				local hasDir1 = neighbors[dir1] and #neighbors[dir1] > 0
				local hasDir2 = neighbors[dir2] and #neighbors[dir2] > 0

				if not hasDir1 or not hasDir2 then
					-- Corner is exposed (no neighbors on at least one side)
					table.insert(area.wallCorners, corner)
					wallCornerCount = wallCornerCount + 1
					goto continue_corner
				end

				-- COMPLEX PATH: Both directions have neighbors
				-- Calculate proximity score from neighbors on both adjacent sides
				local proximityScore = 0
				local neighborDir1 = nil -- Track which neighbor contributed from dir1
				local neighborDir2 = nil -- Track which neighbor contributed from dir2

				-- Check dir1 neighbors
				for _, neighbor in ipairs(neighbors[dir1]) do
					local score, contrib = checkPointOnNeighborBoundary(corner, neighbor, dir1)
					if score > 0 then
						proximityScore = proximityScore + score
						if not neighborDir1 then
							neighborDir1 = contrib -- Track first contributor
						end
					end
				end

				-- Check dir2 neighbors
				for _, neighbor in ipairs(neighbors[dir2]) do
					local score, contrib = checkPointOnNeighborBoundary(corner, neighbor, dir2)
					if score > 0 then
						proximityScore = proximityScore + score
						if not neighborDir2 then
							neighborDir2 = contrib -- Track first contributor
						end
					end
				end

				-- Classification based on proximity score:
				-- >= 2.0: Definitely inner corner (surrounded)
				-- 1.99: Need validation (might be concave)
				-- 1.98: Concave corner - do diagonal validation
				-- < 1.98: Wall corner

				local isWallCorner = false
				local reason = ""

				if proximityScore >= 2.0 then
					-- Perfectly surrounded, definitely inner corner
					isWallCorner = false
					reason = "surrounded"
				elseif proximityScore >= 1.99 then
					-- Very close to surrounded, assume inner corner
					isWallCorner = false
					reason = "almost_surrounded"
				elseif proximityScore == 1.98 then
					-- Concave corner case - do diagonal validation
					-- Check if diagonal neighbor exists and covers this corner
					local diagonalFound = false

					if neighborDir1 and neighborDir1.c and neighborDir2 then
						-- Get neighbors of neighborDir1 in dir2 direction
						local diagDir1, diagDir2 = getDiagonalDirection(dir1, dir2)
						if diagDir1 and diagDir2 then
							-- Check neighborDir1's connections in dir2 direction
							for dirId, dirData in pairs(neighborDir1.c) do
								if dirData.connections then
									for _, conn in ipairs(dirData.connections) do
										local connId = (type(conn) == "table") and conn.node or conn
										local diagNeighbor = nodes[connId]
										if diagNeighbor then
											-- Check if our corner lies on this diagonal neighbor
											local score1 = checkPointOnNeighborBoundary(corner, diagNeighbor, dir1)
											local score2 = checkPointOnNeighborBoundary(corner, diagNeighbor, dir2)
											if score1 > 0 or score2 > 0 then
												diagonalFound = true
												break
											end
										end
									end
								end
								if diagonalFound then
									break
								end
							end
						end
					end

					if diagonalFound then
						isWallCorner = false -- Part of diagonal group, inner corner
						reason = "diagonal_group"
					else
						isWallCorner = true -- Concave wall corner
						reason = "concave"
					end
				else
					-- Score < 1.98, definitely a wall corner
					isWallCorner = true
					reason = "low_score"
				end

				if isWallCorner then
					table.insert(area.wallCorners, corner)
					wallCornerCount = wallCornerCount + 1
				end

				::continue_corner::
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
