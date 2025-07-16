local Heap = require("MedBot.Utils.Heap")

---@alias PathNode { id : integer, x : number, y : number, z : number }

---@class AStar
local AStar = {}

local function ManhattanDistance(nodeA, nodeB)
	return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

local function HeuristicCostEstimate(nodeA, nodeB)
	return ManhattanDistance(nodeA, nodeB)
end

local function reconstructPath(cameFrom, current)
	local totalPath = { current }
	while cameFrom[current] do
		current = cameFrom[current]
		table.insert(totalPath, 1, current) -- Insert at beginning to get start-to-goal order
	end
	return totalPath
end

-- Optimized A-Star using precomputed costs (primary algorithm for all pathfinding)
function AStar.NormalPath(start, goal, nodes, adjacentFun)
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)
	local closedSet = {}
	local gScore, fScore, cameFrom = {}, {}, {}
	gScore[start] = 0
	fScore[start] = HeuristicCostEstimate(start, goal)

	openSet:push({ node = start, fScore = fScore[start] })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local current = currentData.node

		if current.id == goal.id then
			return reconstructPath(cameFrom, current)
		end

		closedSet[current] = true

		-- adjacentFun now returns {node=targetNode, cost=connectionCost}
		for _, neighborData in ipairs(adjacentFun(current, nodes)) do
			local neighbor = neighborData.node
			local connectionCost = neighborData.cost

			if not closedSet[neighbor] then
				-- Calculate distance cost (Manhattan distance for efficiency)
				local distanceCost = HeuristicCostEstimate(current, neighbor)

				-- Total cost = distance + precomputed connection cost
				local totalMoveCost = distanceCost + connectionCost

				local tentativeGScore = gScore[current] + totalMoveCost

				if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
					cameFrom[neighbor] = current
					gScore[neighbor] = tentativeGScore
					fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
					openSet:push({ node = neighbor, fScore = fScore[neighbor] })
				end
			end
		end
	end

	return nil -- Path not found if loop exits
end

-- REMOVED HPA* - Now using Dual A* system instead

-- A* pathfinding for fine points within an area (sub-node pathfinding)
---@param startPoint table Start fine point
---@param goalPoint table Goal fine point
---@param finePoints table[] Array of all fine points in the area
---@return table[]|nil Path of fine points or nil if no path found
function AStar.AStarOnFinePoints(startPoint, goalPoint, finePoints)
	if not startPoint or not goalPoint or not finePoints then
		return nil
	end

	if startPoint.id == goalPoint.id then
		return { startPoint }
	end

	-- Build neighbor lookup for faster access
	local pointLookup = {}
	for _, point in ipairs(finePoints) do
		pointLookup[point.id] = point
	end

	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)
	local closedSet = {}
	local gScore, fScore, cameFrom = {}, {}, {}

	gScore[startPoint.id] = 0
	fScore[startPoint.id] = HeuristicCostEstimate(startPoint, goalPoint)

	openSet:push({ point = startPoint, fScore = fScore[startPoint.id] })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local current = currentData.point

		if current.id == goalPoint.id then
			-- Reconstruct path
			local path = { current }
			local currentId = current.id
			while cameFrom[currentId] do
				currentId = cameFrom[currentId]
				local point = pointLookup[currentId]
				if point then
					table.insert(path, 1, point)
				end
			end
			return path
		end

		closedSet[current.id] = true

		-- Check all neighbors of current point
		if current.neighbors then
			for _, neighborData in ipairs(current.neighbors) do
				local neighbor = neighborData.point
				if neighbor and not closedSet[neighbor.id] then
					local moveCost = neighborData.cost or 1
					local tentativeGScore = gScore[current.id] + moveCost

					if not gScore[neighbor.id] or tentativeGScore < gScore[neighbor.id] then
						cameFrom[neighbor.id] = current.id
						gScore[neighbor.id] = tentativeGScore
						fScore[neighbor.id] = tentativeGScore + HeuristicCostEstimate(neighbor, goalPoint)

						openSet:push({ point = neighbor, fScore = fScore[neighbor.id] })
					end
				end
			end
		end
	end

	return nil -- No path found
end

--- Find best entry point into an area from a previous area
---@param areaInfo table Current area information
---@param previousAreaNode table Previous area node
---@return table|nil Best entry point or nil
function AStar.FindBestEntryPoint(areaInfo, previousAreaNode)
	local bestPoint, bestDist = nil, math.huge

	for _, point in ipairs(areaInfo.edgePoints or {}) do
		local dist = (point.pos - previousAreaNode.pos):Length()
		if dist < bestDist then
			bestDist = dist
			bestPoint = point
		end
	end

	return bestPoint
end

--- Find best exit point from an area toward next area
---@param areaInfo table Current area information
---@param nextAreaNode table Next area node
---@return table|nil Best exit point or nil
function AStar.FindBestExitPoint(areaInfo, nextAreaNode)
	local bestPoint, bestDist = nil, math.huge

	for _, point in ipairs(areaInfo.edgePoints or {}) do
		local dist = (point.pos - nextAreaNode.pos):Length()
		if dist < bestDist then
			bestDist = dist
			bestPoint = point
		end
	end

	return bestPoint
end

return AStar
