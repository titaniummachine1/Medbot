--##########################################################################
--  Node.lua  ·  Clean Node API following black box principles
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local SetupOrchestrator = require("MedBot.Navigation.Setup.SetupOrchestrator")
local Phase3_KDTree = require("MedBot.Navigation.Setup.Phase3_KDTree")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local ConnectionBuilder = require("MedBot.Navigation.ConnectionBuilder")

local Log = Common.Log.new("Node")
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

-- Setup and loading - uses explicit phase orchestration
function Node.Setup()
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return
	end

	-- Explicit flow: Phase1 → Phase2 → SET GLOBAL → Phase3 → Phase4
	SetupOrchestrator.ExecuteFullSetup()
end

function Node.ResetSetup()
	G.Navigation.navMeshUpdated = false
	Log:Info("Navigation setup state reset")
end

function Node.LoadNavFile()
	return SetupOrchestrator.ExecuteFullSetup()
end

function Node.LoadFile(navFile)
	return SetupOrchestrator.ExecuteFullSetup(navFile)
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

-- Check if position is within area's horizontal bounds (X/Y) with height limit
-- Uses precomputed bounds from Phase2_Normalize for speed
local function isWithinAreaBounds(pos, node)
	if not node._minX or not node.pos then
		return false
	end

	-- Fast horizontal bounds check using precomputed values (>= for border inclusion)
	local inHorizontalBounds = pos.x >= node._minX
		and pos.x <= node._maxX
		and pos.y >= node._minY
		and pos.y <= node._maxY
	if not inHorizontalBounds then
		return false
	end

	-- Height limit: ±72 units to prevent finding areas through doors/floors
	local heightDiff = math.abs(pos.z - node.pos.z)
	if heightDiff > 72 then
		return false
	end

	return true
end

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end

	-- Pure KD-tree search for maximum speed - just return closest by center
	if G.Navigation.kdTree then
		local nearest = Phase3_KDTree.FindNearest(G.Navigation.kdTree, pos)
		if nearest then
			return nearest.node
		end
	end

	-- Fallback: Brute force scan
	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		if not node.isDoor then
			local dist = (node.pos - pos):Length()
			if dist < closestDist then
				closestNode, closestDist = node, dist
			end
		end
	end

	return closestNode
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

-- Get area at position - accurate containment check
-- Uses KD-tree to find nearest candidates, checks up to 10 for containment
function Node.GetAreaAtPosition(pos)
	if not G.Navigation.nodes then
		return nil
	end

	-- Use KD-tree for efficient nearest neighbor search
	if G.Navigation.kdTree then
		-- Get 10 nearest candidates by center distance
		local nearest = Phase3_KDTree.FindKNearest(G.Navigation.kdTree, pos, 10)

		-- Check each candidate for containment using precomputed bounds
		for _, candidate in ipairs(nearest) do
			if isWithinAreaBounds(pos, candidate.node) then
				Log:Debug("GetAreaAtPosition: Found containing area %s", candidate.id)
				return candidate.node
			end
		end

		-- No containing area found in top 10, return closest by center
		if nearest[1] then
			Log:Debug("GetAreaAtPosition: No containing area in top 10, using closest %s", nearest[1].id)
			return nearest[1].node
		end
	end

	-- Fallback: Brute force scan with multi-point distance
	local closestNode, closestMinDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		if not node.isDoor then
			-- Check containment first
			if isWithinAreaBounds(pos, node) then
				return node
			end
			-- Track closest for fallback
			local minDist = getMinDistanceToArea(pos, node)
			if minDist < closestMinDist then
				closestNode, closestMinDist = node, minDist
			end
		end
	end

	return closestNode
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
