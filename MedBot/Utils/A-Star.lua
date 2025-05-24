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

-- Optimized A-Star using precomputed costs (for complex scenarios)
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

-- Optimized GBFS using precomputed costs (primary algorithm for fine-grained pathfinding)
function AStar.GBFSPath(start, goal, nodes, getNeighbors)
	local openSet = Heap.new(function(a, b)
		return a.heuristic < b.heuristic
	end)
	local closedSet = {}
	local cameFrom = {}

	openSet:push({ node = start, heuristic = HeuristicCostEstimate(start, goal) })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local currentNode = currentData.node

		if currentNode.id == goal.id then
			return reconstructPath(cameFrom, currentNode)
		end

		closedSet[currentNode] = true

		-- getNeighbors now returns {node=targetNode, cost=connectionCost}
		for _, neighborData in ipairs(getNeighbors(currentNode, nodes)) do
			local neighbor = neighborData.node
			local connectionCost = neighborData.cost

			if not closedSet[neighbor] and connectionCost > 0 then -- Valid connection
				cameFrom[neighbor] = currentNode
				-- Use connection cost to influence heuristic (higher cost = less preferred)
				local adjustedHeuristic = HeuristicCostEstimate(neighbor, goal) + (connectionCost - 1)
				openSet:push({ node = neighbor, heuristic = adjustedHeuristic })
			end
		end
	end

	return nil -- Path not found if the open set is empty
end

--- HPA* Hierarchical Pathfinding Implementation
---@param startPos Vector3 Start position in world space
---@param goalPos Vector3 Goal position in world space
---@param nodes table Nav mesh nodes (areas)
---@param hierarchicalData table Fine-grained hierarchical data
---@return table[]|nil Path of fine-grained points or nil if no path found
function AStar.HPAStarPath(startPos, goalPos, nodes, hierarchicalData)
	if not hierarchicalData or not hierarchicalData.areas then
		return nil -- No hierarchical data available
	end

	-- Phase 1: Find which areas contain start and goal positions
	local startArea, goalArea = nil, nil
	local startAreaDist, goalAreaDist = math.huge, math.huge

	for areaId, areaInfo in pairs(hierarchicalData.areas) do
		local areaNode = nodes[areaId]
		if areaNode then
			local distToStart = (areaNode.pos - startPos):Length()
			local distToGoal = (areaNode.pos - goalPos):Length()

			if distToStart < startAreaDist then
				startAreaDist = distToStart
				startArea = areaInfo
			end

			if distToGoal < goalAreaDist then
				goalAreaDist = distToGoal
				goalArea = areaInfo
			end
		end
	end

	if not startArea or not goalArea then
		return nil -- Could not find containing areas
	end

	-- Phase 2: If start and goal are in same area, use fine-grained pathfinding only
	if startArea.id == goalArea.id then
		return AStar.FindPathWithinArea(startPos, goalPos, startArea)
	end

	-- Phase 3: Find high-level path between areas
	local areaPath = AStar.NormalPath(nodes[startArea.id], nodes[goalArea.id], nodes, function(node, nodeList)
		local Node = require("MedBot.Modules.Node")
		return Node.GetAdjacentNodesSimple(node, nodeList)
	end)

	if not areaPath or #areaPath == 0 then
		return nil -- No high-level path found
	end

	-- Phase 4: Build detailed path using fine points within each area
	local detailedPath = {}

	for i = 1, #areaPath do
		local currentAreaNode = areaPath[i]
		local currentAreaInfo = hierarchicalData.areas[currentAreaNode.id]

		if not currentAreaInfo then
			goto continue
		end

		if i == 1 then
			-- First area: path from start position to exit point
			local exitPoint = AStar.FindBestExitPoint(currentAreaInfo, areaPath[i + 1])
			local pathSegment =
				AStar.FindPathWithinArea(startPos, exitPoint and exitPoint.pos or currentAreaNode.pos, currentAreaInfo)
			if pathSegment then
				for _, point in ipairs(pathSegment) do
					table.insert(detailedPath, point)
				end
			end
		elseif i == #areaPath then
			-- Last area: path from entry point to goal position
			local entryPoint = AStar.FindBestEntryPoint(currentAreaInfo, areaPath[i - 1])
			local pathSegment =
				AStar.FindPathWithinArea(entryPoint and entryPoint.pos or currentAreaNode.pos, goalPos, currentAreaInfo)
			if pathSegment then
				for _, point in ipairs(pathSegment) do
					table.insert(detailedPath, point)
				end
			end
		else
			-- Middle area: path from entry to exit point
			local entryPoint = AStar.FindBestEntryPoint(currentAreaInfo, areaPath[i - 1])
			local exitPoint = AStar.FindBestExitPoint(currentAreaInfo, areaPath[i + 1])

			if entryPoint and exitPoint then
				local pathSegment = AStar.FindPathWithinArea(entryPoint.pos, exitPoint.pos, currentAreaInfo)
				if pathSegment then
					for _, point in ipairs(pathSegment) do
						table.insert(detailedPath, point)
					end
				end
			end
		end

		::continue::
	end

	return #detailedPath > 0 and detailedPath or nil
end

--- Find path within a single area using fine points
---@param startPos Vector3 Start position
---@param goalPos Vector3 Goal position
---@param areaInfo table Area information with fine points
---@return table[]|nil Array of fine points or nil if no path found
function AStar.FindPathWithinArea(startPos, goalPos, areaInfo)
	if not areaInfo.points or #areaInfo.points == 0 then
		return nil
	end

	-- Find closest fine points to start and goal
	local startPoint, goalPoint = nil, nil
	local startDist, goalDist = math.huge, math.huge

	for _, point in ipairs(areaInfo.points) do
		local distToStart = (point.pos - startPos):Length()
		local distToGoal = (point.pos - goalPos):Length()

		if distToStart < startDist then
			startDist = distToStart
			startPoint = point
		end

		if distToGoal < goalDist then
			goalDist = distToGoal
			goalPoint = point
		end
	end

	if not startPoint or not goalPoint then
		return nil
	end

	-- Use A* on fine points within the area
	return AStar.AStarOnFinePoints(startPoint, goalPoint, areaInfo.points)
end

--- A* pathfinding on fine points with neighbor connections
---@param startPoint table Starting fine point
---@param goalPoint table Goal fine point
---@param finePoints table[] All fine points in the area
---@return table[]|nil Path of fine points or nil if no path found
function AStar.AStarOnFinePoints(startPoint, goalPoint, finePoints)
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)
	local closedSet = {}
	local gScore, fScore, cameFrom = {}, {}, {}

	gScore[startPoint] = 0
	fScore[startPoint] = (startPoint.pos - goalPoint.pos):Length()

	openSet:push({ node = startPoint, fScore = fScore[startPoint] })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local current = currentData.node

		if current.id == goalPoint.id then
			return reconstructPath(cameFrom, current)
		end

		closedSet[current] = true

		-- Check neighbors of current fine point
		for _, neighbor in ipairs(current.neighbors or {}) do
			local neighborPoint = neighbor.point
			if not closedSet[neighborPoint] then
				local tentativeGScore = gScore[current] + (neighbor.cost or 1)

				if not gScore[neighborPoint] or tentativeGScore < gScore[neighborPoint] then
					cameFrom[neighborPoint] = current
					gScore[neighborPoint] = tentativeGScore
					fScore[neighborPoint] = tentativeGScore + (neighborPoint.pos - goalPoint.pos):Length()
					openSet:push({ node = neighborPoint, fScore = fScore[neighborPoint] })
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

--[[ 2
    
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

local function AStarPath(start, goal, nodes, adjacentFun)
    local openSet = Heap.new(function(a, b) return a.fScore < b.fScore end)
    local closedSet = {}
    local gScore, fScore = {}, {}
    gScore[start] = 0
    fScore[start] = HeuristicCostEstimate(start, goal)

    openSet:push({node = start, path = {start}, fScore = fScore[start]})

    local function pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
        gScore[neighbor] = tentativeGScore
        fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
        local newPath = {table.unpack(currentPath)}
        table.insert(newPath, neighbor)
        openSet:push({node = neighbor, path = newPath, fScore = fScore[neighbor]})
    end

    while not openSet:empty() do
        local currentData = openSet:pop()
        local current = currentData.node
        local currentPath = currentData.path

        if current.id == goal.id then
            local reversedPath = {}
            for i = #currentPath, 1, -1 do
                table.insert(reversedPath, currentPath[i])
            end
            return reversedPath
        end

        closedSet[current] = true

        local adjacentNodes = adjacentFun(current, nodes)
        for _, neighbor in ipairs(adjacentNodes) do
            if not closedSet[neighbor] then
                local tentativeGScore = gScore[current] + HeuristicCostEstimate(current, neighbor)

                if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
                    neighbor.previous = current
                    pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
                end
            end
        end
    end

    return nil -- Path not found if loop exits
end

AStar.Path = AStarPath

return AStar
]]

--------------------------------------------

--[[ 1
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

local function AStarPath(start, goal, nodes, adjacentFun)
    local openSet, closedSet = Heap.new(), {}
    local gScore, fScore = {}, {}
    gScore[start] = 0
    fScore[start] = HeuristicCostEstimate(start, goal)

    openSet.Compare = function(a, b) return fScore[a.node] < fScore[b.node] end
    openSet:push({node = start, path = {start}})

    local function pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
        gScore[neighbor] = tentativeGScore
        fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
        local newPath = {table.unpack(currentPath)}
        table.insert(newPath, neighbor)
        openSet:push({node = neighbor, path = newPath})
    end

    while not openSet:empty() do
        local currentData = openSet:pop()
        local current = currentData.node
        local currentPath = currentData.path

        if current.id == goal.id then
            local reversedPath = {}
            for i = #currentPath, 1, -1 do
                table.insert(reversedPath, currentPath[i])
            end
            return reversedPath
        end

        closedSet[current] = true

        local adjacentNodes = adjacentFun(current, nodes)
        for _, neighbor in ipairs(adjacentNodes) do
            local neighborNotInClosedSet = closedSet[neighbor] and 0 or 1
            local tentativeGScore = gScore[current] + HeuristicCostEstimate(current, neighbor)

            local newGScore = (not gScore[neighbor] and 1 or 0) + (tentativeGScore < (gScore[neighbor] or math.huge) and 1 or 0)
            local condition = neighborNotInClosedSet * newGScore

            if condition > 0 then
                pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
            end
        end
    end

    return nil -- Path not found if loop exits
end

AStar.Path = AStarPath

return AStar]]
