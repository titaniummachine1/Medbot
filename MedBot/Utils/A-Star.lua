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

-- Function to get connection cost between two nodes (returns 1 if no cost specified, or actual cost)
local function GetConnectionCost(nodeA, nodeB, nodes)
	-- Check all directions for a connection with cost
	for dir = 1, 4 do
		local cDir = nodeA.c[dir]
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				-- Handle both integer ID and table with cost
				local targetId = (type(connection) == "table") and connection.node or connection
				local cost = (type(connection) == "table") and connection.cost or 1

				if targetId == nodeB.id then
					return cost
				end
			end
		end
	end
	return 1 -- Default cost if no connection found
end

local function reconstructPath(cameFrom, current)
	local totalPath = { current }
	while cameFrom[current] do
		current = cameFrom[current]
		table.insert(totalPath, 1, current) -- Insert at beginning to get start-to-goal order
	end
	return totalPath
end

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

		for _, neighbor in ipairs(adjacentFun(current, nodes)) do
			if not closedSet[neighbor] then
				-- Use connection cost instead of just distance
				local connectionCost = GetConnectionCost(current, neighbor, nodes)
				local tentativeGScore = gScore[current] + (HeuristicCostEstimate(current, neighbor) * connectionCost)

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

		for _, neighbor in ipairs(getNeighbors(currentNode, nodes)) do
			if not closedSet[neighbor] then
				cameFrom[neighbor] = currentNode
				openSet:push({ node = neighbor, heuristic = HeuristicCostEstimate(neighbor, goal) })
			end
		end
	end

	return nil -- Path not found if the open set is empty
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
