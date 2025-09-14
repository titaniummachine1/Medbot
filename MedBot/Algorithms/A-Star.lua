-- A* Pathfinding Algorithm Implementation
-- Uses a priority queue (heap) for efficient node exploration
-- Prefers paths through door nodes when distances are similar

local Heap = require("MedBot.Algorithms.Heap")
local Common = require("MedBot.Core.Common")
local Log = Common.Log.new("AStar")

-- Memory Pooling System for GC Optimization
local tablePool = {}
local poolSize = 0
local maxPoolSize = 1000

local function getPooledTable()
	local t = table.remove(tablePool)
	if t then
		poolSize = poolSize - 1
		return t
	end
	return {}
end

local function releaseTable(t)
	if not t then
		return
	end

	-- Clear the table
	for k in pairs(t) do
		t[k] = nil
	end

	-- Add to pool if not full
	if poolSize < maxPoolSize then
		table.insert(tablePool, t)
		poolSize = poolSize + 1
	end
end

-- Batch release for efficiency
local function releaseTables(...)
	for i = 1, select("#", ...) do
		releaseTable(select(i, ...))
	end
end

-- Type definitions for A* pathfinding

---@class Vector3
---@field x number X coordinate
---@field y number Y coordinate
---@field z number Z coordinate

---@class Node
---@field pos Vector3 Position in 3D space
---@field id integer Unique node identifier
---@field isDoor? boolean Whether this node represents a door
---@field areaId? integer Area this node belongs to
---@field c? table Connection data

---@class NeighborData
---@field node Node Target node
---@field cost number Cost to traverse to this node
---@field isDoor? boolean Whether this connection is a door

---@class AStar
local AStar = {}

---@alias NodeMap table<integer, Node>
---@alias NeighborDataArray NeighborData[]

---Calculate heuristic cost between two nodes (simplified back to distance)
---@param nodeA Node Starting node
---@param nodeB Node Target node
---@return number Heuristic cost estimate
local function heuristicCost(nodeA, nodeB)
	-- Simple distance-based heuristic (admissible)
	return (nodeA.pos - nodeB.pos):Length()
end

---Reconstructs the path from the cameFrom map
---@param cameFrom table<Node, Node> Map of nodes to their predecessors
---@param startNode Node Starting node of the path
---@param goalNode Node Goal node of the path
---@return Node[]|nil Array of nodes representing the path, or nil if no valid path
local function reconstructPath(cameFrom, startNode, goalNode)
	-- Track best path found for early termination
	local bestPathFound = nil
	local bestPathCost = math.huge
	local path = {}
	local current = goalNode

	-- Reconstruct path in reverse (from goal to start)
	while current and current ~= startNode do
		table.insert(path, 1, current)
		local cameFromData = cameFrom[current]
		if cameFromData and cameFromData.node then
			current = cameFromData.node
		elseif cameFrom[current] then
			current = cameFrom[current] -- fallback for old format
		else
			print("A* Error: No path found - cameFrom data missing for node " .. (current.id or "unknown"))
			return nil
		end
	end

	-- If we couldn't reconstruct the path, return nil
	if not current or current ~= startNode then
		return nil
	end

	-- Add start node
	table.insert(path, 1, startNode)

	-- Path optimization - skip intermediate area centers between doors of same area
	if #path <= 2 then
		return path
	end

	local optimizedPath = { path[1] }
	local i = 2

	while i <= #path do
		local curr = path[i]
		local next = path[i + 1]
		local prev = optimizedPath[#optimizedPath]

		-- Since A* now naturally finds optimal door positions, we don't need complex optimization
		-- Just add the current node to the path
		table.insert(optimizedPath, curr)
		i = i + 1
	end

	return optimizedPath
end

-- Path Smoothing: Remove unnecessary waypoints and straighten zigzag paths
local function smoothPath(rawPath)
	if not rawPath or #rawPath < 3 then
		return rawPath
	end

	local smoothed = { rawPath[1] } -- Always keep start
	local i = 2

	while i < #rawPath do
		local current = rawPath[i]
		local lastKept = smoothed[#smoothed]

		-- Look ahead to see if we can skip waypoints
		local canSkip = true
		for j = i + 1, #rawPath do
			local future = rawPath[j]

			-- Check if the direct path from lastKept to future is walkable
			-- For now, use a simple distance-based check to avoid navmesh issues
			local directDist = (lastKept.pos - future.pos):Length()
			local waypointDist = 0

			-- Calculate total distance through waypoints
			for k = i, j - 1 do
				waypointDist = waypointDist + (rawPath[k].pos - rawPath[k + 1].pos):Length()
			end

			-- If direct path is significantly shorter, we can skip waypoints
			if directDist < waypointDist * 0.8 then
				-- Check for obstacles (simplified - just check if any waypoint has special properties)
				local hasObstacle = false
				for k = i, j - 1 do
					if rawPath[k].isDoor then
						hasObstacle = true
						break
					end
				end

				if not hasObstacle then
					i = j - 1 -- Skip to this future waypoint
					canSkip = false
					break
				end
			end
		end

		if canSkip then
			-- Add current waypoint to smoothed path
			table.insert(smoothed, current)
		end
		i = i + 1
	end

	-- Always keep the goal
	if #smoothed > 0 and smoothed[#smoothed] ~= rawPath[#rawPath] then
		table.insert(smoothed, rawPath[#rawPath])
	end

	Log:Debug("Path smoothed: " .. #rawPath .. " -> " .. #smoothed .. " waypoints")
	return smoothed
end

-- Apply path smoothing to the reconstructed path
local function reconstructAndSmoothPath(cameFrom, startNode, goalNode)
	local rawPath = reconstructPath(cameFrom, startNode, goalNode)
	if not rawPath then
		return nil
	end

	return smoothPath(rawPath)
end

---Find the shortest path between two nodes using A* algorithm
---@param startNode Node Starting node
---@param goalNode Node Target node
---@param nodes NodeMap Lookup table of all nodes by ID
---@param adjacentFun fun(node: Node, nodes: NodeMap): NeighborDataArray Function to get adjacent nodes
---@return Node[]|nil path Array of nodes representing the path, or nil if no path exists
function AStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	-- Input validation
	if not startNode or not goalNode or not nodes or not adjacentFun then
		return nil
	end

	if not startNode.id or not goalNode.id then
		return nil
	end

	-- Priority queue based on fScore
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)

	-- Use pooled tables for memory efficiency
	local openSetLookup = getPooledTable() -- Tracks which nodes are currently in openSet
	local closedSet = getPooledTable()
	local gScore = getPooledTable()
	local fScore = getPooledTable()
	local cameFrom = getPooledTable()

	-- Initialize start node
	gScore[startNode] = 0
	fScore[startNode] = heuristicCost(startNode, goalNode)
	openSet:push({ node = startNode, fScore = fScore[startNode] })
	openSetLookup[startNode] = true

	while not openSet:empty() do
		local currentEntry = openSet:pop()
		local current = currentEntry.node
		openSetLookup[current] = nil -- no longer in open set

		if closedSet[current] then
			-- Skip stale entries (if we pushed the same node twice with a worse score)
			goto continue
		end

		-- Goal reached -> reconstruct path
		if current.id == goalNode.id then
			local path = reconstructAndSmoothPath(cameFrom, startNode, current)
			if not path then
				print(string.format("A* Error: Path reconstruction failed from %s to %s", startNode.id, goalNode.id))
			end
			-- Clean up before returning
			for node in pairs(openSetLookup) do
				openSetLookup[node] = nil
			end
			for node in pairs(closedSet) do
				closedSet[node] = nil
			end
			for node in pairs(gScore) do
				gScore[node] = nil
			end
			for node in pairs(fScore) do
				fScore[node] = nil
			end
			for node in pairs(cameFrom) do
				cameFrom[node] = nil
			end
			releaseTables(openSetLookup, closedSet, gScore, fScore, cameFrom)
			return path
		end

		-- Mark current as processed
		closedSet[current] = true

		-- Explore neighbors
		local ok, neighbors, errorMsg = pcall(adjacentFun, current, nodes)
		if not ok then
			print(
				"A* Error: Failed to get neighbors for node "
					.. (current.id or "unknown")
					.. ": "
					.. (errorMsg or "unknown error")
			)
			goto continue
		end
		if type(neighbors) == "table" then
			for _, neighborData in ipairs(neighbors) do
				if not neighborData or not neighborData.node then
					print("A* Warning: Invalid neighbor data encountered")
					goto continueNeighbor
				end

				local nextNode = neighborData.node
				if closedSet[nextNode] then
					goto continueNeighbor -- already processed
				end

				-- Use only the actual connection cost (no heuristic in g-score)
				local connectionCost = neighborData.cost or (current.pos - nextNode.pos):Length()
				local tentativeGScore = (gScore[current] or 0) + connectionCost

				-- Found a better path?
				if not gScore[nextNode] or tentativeGScore < gScore[nextNode] then
					-- Update cameFrom even if we found a better path
					cameFrom[nextNode] = { node = current, doorPos = neighborData.doorPos }
					gScore[nextNode] = tentativeGScore
					fScore[nextNode] = tentativeGScore + heuristicCost(nextNode, goalNode)

					-- Add to open set if not already there
					if not openSetLookup[nextNode] then
						openSet:push({ node = nextNode, fScore = fScore[nextNode] })
						openSetLookup[nextNode] = true
					else
						-- Node is already in open set with a worse score
						-- Since our heap doesn't support efficient updates, we mark this node
						-- for reprocessing by adding a small penalty to ensure it's processed again
						local markedForUpdate = false
						if not cameFrom[nextNode] then
							cameFrom[nextNode] = { node = current, doorPos = neighborData.doorPos, updateFlag = true }
							markedForUpdate = true
						else
							-- Mark existing entry for update
							cameFrom[nextNode].updateFlag = true
							markedForUpdate = true
						end

						if markedForUpdate then
							-- Add a small penalty to ensure this node gets reprocessed
							local penalty = 0.001
							fScore[nextNode] = fScore[nextNode] - penalty
							Log:Debug("Marked node " .. nextNode.id .. " for reprocessing with better path")
						end
					end
				end

				::continueNeighbor::
			end
		end

		::continue::
	end

	-- Clean up temporary data structures
	for node in pairs(openSetLookup) do
		openSetLookup[node] = nil
	end
	for node in pairs(closedSet) do
		closedSet[node] = nil
	end
	for node in pairs(gScore) do
		gScore[node] = nil
	end
	for node in pairs(fScore) do
		fScore[node] = nil
	end
	for node in pairs(cameFrom) do
		cameFrom[node] = nil
	end
	releaseTables(openSetLookup, closedSet, gScore, fScore, cameFrom)

	-- No path found
	return nil
end

return AStar
