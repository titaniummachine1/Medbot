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
local function heuristicCost(nodeA, nodeB)
	-- Euclidean distance heuristic
	local dx = nodeA.pos.x - nodeB.pos.x
	local dy = nodeA.pos.y - nodeB.pos.y
	local dz = nodeA.pos.z - nodeB.pos.z
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	return dist
end

----------------------------------------------------------------
-- Path Reconstruction (O(n) instead of O(n²))
----------------------------------------------------------------
---@param cameFrom table<Node, {node:Node}>
---@param startNode Node
---@param goalNode Node
---@return Node[]|nil
local function reconstructPath(cameFrom, startNode, goalNode)
	local path = {}
	local current = goalNode

	-- Build reversed path (sequential memory writes)
	while current and current ~= startNode do
		path[#path + 1] = current
		local cf = cameFrom[current]
		if cf and cf.node then
			current = cf.node
		else
			Log:Error("A* reconstructPath failed: missing cameFrom for node " .. (current.id or "unknown"))
			return nil
		end
	end

	if not current or current ~= startNode then
		return nil
	end

	path[#path + 1] = startNode

	-- Reverse in place (O(n) total)
	local i, j = 1, #path
	while i < j do
		path[i], path[j] = path[j], path[i]
		i = i + 1
		j = j - 1
	end

	return path
end

----------------------------------------------------------------
-- Path Smoothing: Remove unnecessary waypoints
----------------------------------------------------------------
local function smoothPath(rawPath)
	if not rawPath or #rawPath < 3 then
		return rawPath
	end

	local smoothed = { rawPath[1] } -- Always keep start
	local i = 2

	while i <= #rawPath do
		local curr = rawPath[i]
		local lastKept = smoothed[#smoothed]

		-- Look ahead to see if we can skip waypoints
		local canSkip = true
		for j = i + 1, #rawPath do
			local future = rawPath[j]

			-- Check if the direct path is significantly shorter
			local directDist = (lastKept.pos - future.pos):Length()
			local waypointDist = 0

			-- Calculate total distance through waypoints
			for k = i, j - 1 do
				waypointDist = waypointDist + (rawPath[k].pos - rawPath[k + 1].pos):Length()
			end

			-- If direct path is significantly shorter, we can skip waypoints
			if directDist < waypointDist * 0.8 then
				-- Check for obstacles (simplified)
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
			table.insert(smoothed, curr)
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

local function reconstructAndSmoothPath(cameFrom, startNode, goalNode)
	local rawPath = reconstructPath(cameFrom, startNode, goalNode)
	if not rawPath then
		return nil
	end
	return smoothPath(rawPath)
end

-- A* Module Table
local AStar = {}

---Find the shortest path between two nodes using A* algorithm
---@param startNode Node Starting node
---@param goalNode Node Target node
---@param nodes table<integer, Node> Lookup table of all nodes by ID
---@param adjacentFun fun(node: Node, nodes: table): NeighborDataArray Function to get adjacent nodes
---@return Node[]|nil path Array of nodes representing the path, or nil if no path exists
function AStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	if not (startNode and goalNode and startNode.id and goalNode.id) then
		return nil
	end

	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)

	local openSetLookup = getPooledTable()
	local closedSet = getPooledTable()
	local gScore = getPooledTable()
	local fScore = getPooledTable()
	local cameFrom = getPooledTable()

	gScore[startNode] = 0
	fScore[startNode] = heuristicCost(startNode, goalNode)

	openSet:push({ node = startNode, fScore = fScore[startNode] })
	openSetLookup[startNode] = true

	while not openSet:empty() do
		local currentEntry = openSet:pop()
		local current = currentEntry.node
		openSetLookup[current] = nil

		if closedSet[current] then
			goto continue
		end

		if current == goalNode then
			local path = reconstructAndSmoothPath(cameFrom, startNode, current)
			releaseTables(openSetLookup, closedSet, gScore, fScore, cameFrom)
			return path
		end

		closedSet[current] = true

		-- Direct call, no pcall overhead
		local neighbors = adjacentFun(current, nodes)
		for i = 1, #neighbors do
			local neighborData = neighbors[i]
			local nextNode = neighborData.node
			if closedSet[nextNode] then
				goto continueNeighbor
			end

			local connectionCost = neighborData.cost or (current.pos - nextNode.pos):Length()

			local tentativeG = gScore[current] + connectionCost
			if not gScore[nextNode] or tentativeG < gScore[nextNode] then
				cameFrom[nextNode] = { node = current }
				gScore[nextNode] = tentativeG
				fScore[nextNode] = tentativeG + heuristicCost(nextNode, goalNode)

				if not openSetLookup[nextNode] then
					openSet:push({ node = nextNode, fScore = fScore[nextNode] })
					openSetLookup[nextNode] = true
				else
					-- Duplicate push instead of decrease-key hack
					openSet:push({ node = nextNode, fScore = fScore[nextNode] })
				end
			end

			::continueNeighbor::
		end

		::continue::
	end

	releaseTables(openSetLookup, closedSet, gScore, fScore, cameFrom)
	return nil
end

return AStar
