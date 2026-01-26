--[[
    Greedy Best-First Search Algorithm
    Fastest possible pathfinding using straight-line heuristic
    Always expands node closest to destination (no cost consideration)
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")

local Greedy = {}

-- Calculate straight-line distance heuristic (Euclidean distance)
local function heuristic(startPos, goalPos)
	local dx = startPos.x - goalPos.x
	local dy = startPos.y - goalPos.y
	local dz = startPos.z - goalPos.z
	return math.abs(dx) + math.abs(dy) + math.abs(dz)
end

-- Main greedy pathfinding function
function Greedy.FindPath(startPos, goalPos, maxIterations)
	maxIterations = maxIterations or 500

	local startNode = Navigation.GetClosestNode(startPos)
	local goalNode = Navigation.GetClosestNode(goalPos)

	if not startNode or not goalNode then
		return {}
	end

	if startNode.id == goalNode.id then
		return { startNode.id }
	end

	-- Priority queue based on distance to goal (min-heap)
	local openSet = {}
	local closedSet = {}
	local cameFrom = {}

	-- Insert start node with its heuristic value
	table.insert(openSet, {
		nodeId = startNode.id,
		priority = heuristic(startPos, goalPos),
	})

	local iterations = 0

	while #openSet > 0 and iterations < maxIterations do
		iterations = iterations + 1

		-- Get node with lowest heuristic value (closest to goal)
		local current = table.remove(openSet, 1)

		-- Skip if already visited
		if closedSet[current.nodeId] then
			goto continue
		end

		closedSet[current.nodeId] = true

		-- Goal reached
		if current.nodeId == goalNode.id then
			-- Reconstruct path
			local path = {}
			local node = goalNode.id

			while node do
				table.insert(path, 1, node)
				node = cameFrom[node]
			end

			return path
		end

		-- Get current node data
		local currentNode = Navigation.GetNode(current.nodeId)
		if not currentNode then
			goto continue
		end

		-- Explore neighbors
		local adjacent = Navigation.GetAdjacentNodes(current.nodeId)
		for _, neighborId in ipairs(adjacent) do
			if not closedSet[neighborId] then
				local neighborNode = Navigation.GetNode(neighborId)
				if neighborNode then
					-- Calculate heuristic for neighbor
					local neighborPos = Vector3(neighborNode.x, neighborNode.y, neighborNode.z)
					local hValue = heuristic(neighborPos, goalPos)

					-- Add to open set
					table.insert(openSet, {
						nodeId = neighborId,
						priority = hValue,
					})

					-- Track parent
					if not cameFrom[neighborId] then
						cameFrom[neighborId] = current.nodeId
					end
				end
			end
		end

		-- Sort open set by priority (lowest first)
		table.sort(openSet, function(a, b)
			return a.priority < b.priority
		end)

		::continue::
	end

	-- No path found within iteration limit
	return {}
end

-- Simple version with even less overhead for very fast pathfinding
function Greedy.FindPathFast(startPos, goalPos, maxNodes)
	maxNodes = maxNodes or 100

	local startNode = Navigation.GetClosestNode(startPos)
	local goalNode = Navigation.GetClosestNode(goalPos)

	if not startNode or not goalNode then
		return {}
	end

	if startNode.id == goalNode.id then
		return { startNode.id }
	end

	local path = { startNode.id }
	local currentId = startNode.id
	local visited = { [currentId] = true }

	for i = 1, maxNodes do
		if currentId == goalNode.id then
			return path
		end

		local adjacent = Navigation.GetAdjacentNodes(currentId)
		local bestNeighbor = nil
		local bestDistance = math.huge

		-- Find neighbor closest to goal
		for _, neighborId in ipairs(adjacent) do
			if not visited[neighborId] then
				local neighborNode = Navigation.GetNode(neighborId)
				if neighborNode then
					local neighborPos = Vector3(neighborNode.x, neighborNode.y, neighborNode.z)
					local distance = heuristic(neighborPos, goalPos)

					if distance < bestDistance then
						bestDistance = distance
						bestNeighbor = neighborId
					end
				end
			end
		end

		if not bestNeighbor then
			break -- Dead end
		end

		table.insert(path, bestNeighbor)
		visited[bestNeighbor] = true
		currentId = bestNeighbor
	end

	return path
end

print("Greedy Best-First Search algorithm loaded")

return Greedy
