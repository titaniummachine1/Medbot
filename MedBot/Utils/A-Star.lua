local Heap = require("MedBot.Utils.Heap")

---@class AStar
local AStar = {}

-- Simple Manhattan distance heuristic
local function manhattanDistance(nodeA, nodeB)
	return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

-- Reconstruct path from cameFrom map
local function reconstructPath(cameFrom, current)
	local path = { current }
	while cameFrom[current] do
		current = cameFrom[current]
		table.insert(path, 1, current)
	end
	return path
end

-- Clean, simple A* implementation that works with our data structure
-- adjacentFun returns: { {node = targetNode, cost = connectionCost}, ... }
function AStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	if not startNode or not goalNode or not nodes or not adjacentFun then
		return nil
	end

	-- Safety check: ensure nodes have valid IDs
	if not startNode.id or not goalNode.id then
		return nil
	end

	-- Initialize data structures
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)

	local closedSet = {} -- Track visited nodes
	local gScore = {} -- Cost from start to node
	local fScore = {} -- Total estimated cost (gScore + heuristic)
	local cameFrom = {} -- Path reconstruction

	-- Initialize start node
	gScore[startNode] = 0
	fScore[startNode] = manhattanDistance(startNode, goalNode)
	openSet:push({ node = startNode, fScore = fScore[startNode] })

	local iterations = 0
	local maxIterations = 10000 -- Safety limit

	while not openSet:empty() and iterations < maxIterations do
		iterations = iterations + 1

		-- Get node with lowest fScore
		local currentData = openSet:pop()
		local current = currentData.node

		-- Check if we reached the goal
		if current.id == goalNode.id then
			return reconstructPath(cameFrom, current)
		end

		-- Mark current node as visited
		closedSet[current] = true

		-- Get adjacent nodes with their costs
		local success, neighbors = pcall(adjacentFun, current, nodes)
		if not success then
			-- If adjacency function fails, skip this node
			goto continue
		end

		-- Process each neighbor
		for _, neighborData in ipairs(neighbors) do
			local neighbor = neighborData.node
			local connectionCost = neighborData.cost or 1

			-- Skip if already visited
			if closedSet[neighbor] then
				goto continue_neighbor
			end

			-- Calculate tentative gScore
			local tentativeGScore = gScore[current] + connectionCost

			-- Check if this path is better than previous ones
			if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
				-- This path is better, update it
				cameFrom[neighbor] = current
				gScore[neighbor] = tentativeGScore
				fScore[neighbor] = tentativeGScore + manhattanDistance(neighbor, goalNode)

				-- Add to open set
				openSet:push({ node = neighbor, fScore = fScore[neighbor] })
			end

			::continue_neighbor::
		end

		::continue::
	end

	-- No path found
	return nil
end

return AStar
