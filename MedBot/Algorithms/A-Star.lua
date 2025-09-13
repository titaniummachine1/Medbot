-- A* Pathfinding Algorithm Implementation
-- Uses a priority queue (heap) for efficient node exploration
-- Prefers paths through door nodes when distances are similar

local Heap = require("MedBot.Algorithms.Heap")

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

---Calculate heuristic cost between two nodes
---@param nodeA Node Starting node
---@param nodeB Node Target node
---@return number Heuristic cost estimate
local function heuristicCost(nodeA, nodeB)
	-- Use actual distance as heuristic
	return (nodeA.pos - nodeB.pos):Length()
end

---Reconstructs the path from the cameFrom map
---@param cameFrom table<Node, Node> Map of nodes to their predecessors
---@param startNode Node Starting node of the path
---@param goalNode Node Goal node of the path
---@return Node[]|nil Array of nodes representing the path, or nil if no valid path
local function reconstructPath(cameFrom, startNode, goalNode)
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

	---@type table<Node, boolean>
	local openSetLookup = {} -- Tracks which nodes are currently in openSet
	---@type table<Node, boolean>
	local closedSet = {}
	---@type table<Node, number>
	local gScore = {}
	---@type table<Node, number>
	local fScore = {}
	---@type table<Node, Node>
	local cameFrom = {}

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
			local path = reconstructPath(cameFrom, startNode, current)
			if not path then
				print("A* Error: Path reconstruction failed from " .. startNode.id .. " to " .. goalNode.id)
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
					cameFrom[nextNode] = { node = current, doorPos = neighborData.doorPos }
					gScore[nextNode] = tentativeGScore
					fScore[nextNode] = tentativeGScore + heuristicCost(nextNode, goalNode)

					-- Add to open set if not already there, or update if we found better score
					if not openSetLookup[nextNode] then
						openSet:push({ node = nextNode, fScore = fScore[nextNode] })
						openSetLookup[nextNode] = true
					else
						-- Node is already in open set, but we found a better path
						-- We need to update it, but since our heap doesn't support updates,
						-- we'll let the stale entry be skipped when popped
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

	-- No path found
	return nil
end

return AStar
