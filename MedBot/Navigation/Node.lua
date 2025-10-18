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

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end

	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		-- Skip door nodes - only return actual area nodes
		if not node.isDoor then
			local dist = (node.pos - pos):Length()
			if dist < closestDist then
				closestNode, closestDist = node, dist
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
