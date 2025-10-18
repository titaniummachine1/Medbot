--##########################################################################
--  Node.lua  ·  Clean Node API following black box principles
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local NavLoader = require("MedBot.Navigation.NavLoader")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local ConnectionBuilder = require("MedBot.Navigation.ConnectionBuilder")

local Log = Common.Log.new("Node")
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

-- Setup and loading
function Node.Setup()
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return
	end

	NavLoader.LoadNavFile()
	ConnectionBuilder.NormalizeConnections()

	-- CRITICAL: Detect wall corners BEFORE building doors so clamping can work!
	local WallCornerGenerator = require("MedBot.Navigation.WallCornerGenerator")
	assert(WallCornerGenerator, "Node.Setup: WallCornerGenerator module failed to load")
	WallCornerGenerator.DetectWallCorners()
	local nodeCount = G.Navigation.nodes and #G.Navigation.nodes or 0
	Log:Info("Wall corners detected: " .. nodeCount .. " nodes processed")

	ConnectionBuilder.BuildDoorsForConnections()
	Log:Info("Doors built with wall corner clamping applied")

	Log:Info("Navigation setup complete - wall corners and doors processed")
end

function Node.ResetSetup()
	G.Navigation.navMeshUpdated = false
	Log:Info("Navigation setup state reset")
end

function Node.LoadNavFile()
	return NavLoader.LoadNavFile()
end

function Node.LoadFile(navFile)
	return NavLoader.LoadFile(navFile)
end

-- Node management
function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes and G.Navigation.nodes[id] or nil
end

-- Check if position is within area's horizontal bounds (X/Y only)
local function isWithinAreaBounds(pos, node)
	if not node.nw or not node.se then
		return false
	end

	-- Get horizontal bounds from corners
	local minX = math.min(node.nw.x, node.ne.x, node.sw.x, node.se.x)
	local maxX = math.max(node.nw.x, node.ne.x, node.sw.x, node.se.x)
	local minY = math.min(node.nw.y, node.ne.y, node.sw.y, node.se.y)
	local maxY = math.max(node.nw.y, node.ne.y, node.sw.y, node.se.y)

	return pos.x >= minX and pos.x <= maxX and pos.y >= minY and pos.y <= maxY
end

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end

	-- Step 1: Find closest area by center distance (3D)
	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		if not node.isDoor then
			local dist = (node.pos - pos):Length()
			if dist < closestDist then
				closestNode, closestDist = node, dist
			end
		end
	end

	if not closestNode then
		return nil
	end

	-- Step 1.5: Check if closest area contains position (fast path)
	if isWithinAreaBounds(pos, closestNode) then
		Log:Debug("GetClosestNode: Position within starting area %s (no flood fill needed)", closestNode.id)
		return closestNode
	end

	-- Step 2: Flood fill from closest node to depth 4 (traverse all connections like visuals)
	local candidates = {} -- List of candidate nodes
	local visited = {} -- Track visited nodes
	local queue = { { node = closestNode, depth = 0 } }
	visited[closestNode.id] = true
	candidates[1] = closestNode
	local candidateCount = 1

	local queueStart = 1
	while queueStart <= #queue do
		local current = queue[queueStart]
		queueStart = queueStart + 1

		if current.depth < 4 then
			-- Get all adjacent nodes (areas AND doors like visuals do)
			local adjacent = Node.GetAdjacentNodesOnly(current.node, G.Navigation.nodes)
			for _, adjNode in ipairs(adjacent) do
				if not visited[adjNode.id] then
					visited[adjNode.id] = true
					table.insert(queue, { node = adjNode, depth = current.depth + 1 })

					-- Only add areas to candidates (skip doors)
					if not adjNode.isDoor then
						candidateCount = candidateCount + 1
						candidates[candidateCount] = adjNode
					end
				end
			end
		end
	end

	-- Step 3: Check which candidate contains the target (horizontal bounds check)
	for i = 1, candidateCount do
		if isWithinAreaBounds(pos, candidates[i]) then
			Log:Debug("Found containing area: %s", candidates[i].id)
			return candidates[i]
		end
	end

	-- Step 4: No area contains target - sort by distance and pick closest
	-- List is already roughly sorted by BFS order, final sort is faster
	for i = 1, candidateCount do
		candidates[i]._dist = (candidates[i].pos - pos):Length()
	end

	table.sort(candidates, function(a, b)
		return a._dist < b._dist
	end)

	Log:Debug("No containing area found, using closest from %d candidates", candidateCount)
	return candidates[1]
end

-- Get minimum distance from position to area (checks center + all 4 corners)
local function getMinDistanceToArea(pos, node)
	if not node.pos or not node.nw or not node.ne or not node.sw or not node.se then
		return math.huge
	end

	-- Calculate distance to center + all 4 corners
	local distCenter = (node.pos - pos):Length()
	local distNW = (node.nw - pos):Length()
	local distNE = (node.ne - pos):Length()
	local distSW = (node.sw - pos):Length()
	local distSE = (node.se - pos):Length()

	-- Return minimum distance
	return math.min(distCenter, distNW, distNE, distSW, distSE)
end

-- Get area at position - more precise than GetClosestNode
-- Uses flood fill + multi-point distance check (center + corners)
function Node.GetAreaAtPosition(pos)
	if not G.Navigation.nodes then
		return nil
	end

	-- Step 1: Find closest area by center distance (initial seed)
	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		if not node.isDoor then
			local dist = (node.pos - pos):Length()
			if dist < closestDist then
				closestNode, closestDist = node, dist
			end
		end
	end

	if not closestNode then
		return nil
	end

	-- Step 1.5: Check if closest area contains position (fast path)
	if isWithinAreaBounds(pos, closestNode) then
		Log:Debug("GetAreaAtPosition: Position within starting area %s (no flood fill needed)", closestNode.id)
		return closestNode
	end

	-- Step 2: Flood fill from closest node to depth 7 (traverse all connections like visuals)
	local candidates = {}
	local visited = {}
	local queue = { { node = closestNode, depth = 0 } }
	visited[closestNode.id] = true
	candidates[1] = closestNode
	local candidateCount = 1

	local queueStart = 1
	while queueStart <= #queue do
		local current = queue[queueStart]
		queueStart = queueStart + 1

		if current.depth < 7 then
			-- Get all adjacent nodes (areas AND doors like visuals do)
			local adjacent = Node.GetAdjacentNodesOnly(current.node, G.Navigation.nodes)
			for _, adjNode in ipairs(adjacent) do
				if not visited[adjNode.id] then
					visited[adjNode.id] = true
					table.insert(queue, { node = adjNode, depth = current.depth + 1 })

					-- Only add areas to candidates (skip doors)
					if not adjNode.isDoor then
						candidateCount = candidateCount + 1
						candidates[candidateCount] = adjNode
					end
				end
			end
		end
	end

	-- Step 3: Calculate distances for all candidates
	for i = 1, candidateCount do
		candidates[i]._minDist = getMinDistanceToArea(pos, candidates[i])
	end

	-- Step 4: Sort ALL candidates by distance (closest first)
	table.sort(candidates, function(a, b)
		return a._minDist < b._minDist
	end)

	-- DEBUG: Log top 10 candidates and total count
	Log:Info("GetAreaAtPosition: Found %d total candidates, showing top 10:", candidateCount)
	for i = 1, math.min(10, candidateCount) do
		local c = candidates[i]
		local contains = isWithinAreaBounds(pos, c)
		Log:Info("  [%d] Area %s: minDist=%.1f, contains=%s", i, c.id, c._minDist, tostring(contains))
	end

	-- Step 5: Check sorted list for first area that contains position horizontally
	for i = 1, candidateCount do
		if isWithinAreaBounds(pos, candidates[i]) then
			Log:Info(
				"GetAreaAtPosition: Picked area %s at position %d (minDist=%.1f)",
				candidates[i].id,
				i,
				candidates[i]._minDist
			)
			return candidates[i]
		end
	end

	-- Step 6: No containing area - return closest by distance (first in sorted list)
	Log:Debug(
		"GetAreaAtPosition: No containing area, using closest from %d candidates (minDist=%.1f)",
		candidateCount,
		candidates[1]._minDist
	)
	return candidates[1]
end

-- Connection utilities
function Node.GetConnectionNodeId(connection)
	return ConnectionUtils.GetNodeId(connection)
end

---@param node Node The node to check
---@return boolean True if the node is a door node
function Node.IsDoorNode(node)
	return node and node.isDoor == true
end

function Node.GetConnectionCost(connection)
	return ConnectionUtils.GetCost(connection)
end

function Node.GetConnectionEntry(nodeA, nodeB)
	return ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
end

function Node.GetDoorTargetPoint(areaA, areaB)
	return ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
end

-- Connection management
function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			table.insert(dir.connections, { node = nodeB.id, cost = 1 })
			dir.count = #dir.connections
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for i = #dir.connections, 1, -1 do
				local targetId = ConnectionUtils.GetNodeId(dir.connections[i])
				if targetId == nodeB.id then
					table.remove(dir.connections, i)
				end
			end
			dir.count = #dir.connections
		end
	end
end

-- Door-aware adjacency: handles areas, doors, and door-to-door connections
function Node.GetAdjacentNodesSimple(node, nodes)
	local neighbors = {}

	if not node.c then
		return neighbors
	end

	for dirId, dir in pairs(node.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				local targetNode = nodes[targetId]

				if targetNode then
					-- Simple adjacency - just return connected nodes
					local cost = (node.pos - targetNode.pos):Length()
					table.insert(neighbors, {
						node = targetNode,
						cost = cost,
					})
				end
			end
		end
	end

	return neighbors
end

-- Optimized version for when only nodes are needed (no cost data)
function Node.GetAdjacentNodesOnly(node, nodes)
	if not node or not node.c or not nodes then
		return {}
	end

	local adjacent = {}
	local count = 0

	-- FIX: Use pairs() for named directional keys, not ipairs()
	for _, dir in pairs(node.c) do
		local connections = dir.connections
		if connections then
			for i = 1, #connections do
				local targetId = ConnectionUtils.GetNodeId(connections[i])
				local targetNode = nodes[targetId]
				if targetNode then
					count = count + 1
					adjacent[count] = targetNode
				end
			end
		end
	end

	return adjacent
end

-- CleanupConnections removed - AccessibilityChecker was disabled (used area centers, not edges)

function Node.NormalizeConnections()
	ConnectionBuilder.NormalizeConnections()
end

function Node.BuildDoorsForConnections()
	ConnectionBuilder.BuildDoorsForConnections()
end

return Node
