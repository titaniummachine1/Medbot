--##########################################################################
--  Node.lua  ·  Clean Node API following black box principles
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local NavLoader = require("MedBot.Navigation.NavLoader")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local ConnectionBuilder = require("MedBot.Navigation.ConnectionBuilder")
local AccessibilityChecker = require("MedBot.Navigation.AccessibilityChecker")

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
	AccessibilityChecker.PruneInvalidConnections(G.Navigation.nodes)
	ConnectionBuilder.BuildDoorsForConnections()
	
	Log:Info("Navigation setup complete")
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
	if not G.Navigation.nodes then return nil end
	
	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		local dist = (node.pos - pos):Length()
		if dist < closestDist then
			closestNode, closestDist = node, dist
		end
	end
	return closestNode
end

-- Connection utilities
function Node.GetConnectionNodeId(connection)
	return ConnectionUtils.GetNodeId(connection)
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
	if not nodeA or not nodeB then return end
	
	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			table.insert(dir.connections, { node = nodeB.id, cost = 1 })
			dir.count = #dir.connections
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then return end
	
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

-- Pathfinding adjacency
function Node.GetAdjacentNodesSimple(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then return adjacent end
	
	for dirId, dir in pairs(node.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				local targetNode = nodes[targetId]
				if targetNode then
					table.insert(adjacent, {
						node = targetNode,
						cost = ConnectionUtils.GetCost(connection)
					})
				end
			end
		end
	end
	
	return adjacent
end

function Node.GetAdjacentNodesOnly(node, nodes)
	local adjacent = {}
	local adjacentWithCost = Node.GetAdjacentNodesSimple(node, nodes)
	
	for _, entry in ipairs(adjacentWithCost) do
		table.insert(adjacent, entry.node)
	end
	
	return adjacent
end

-- Legacy compatibility
function Node.CleanupConnections()
	local nodes = Node.GetNodes()
	if nodes then
		AccessibilityChecker.PruneInvalidConnections(nodes)
		Log:Info("Connections cleaned up")
	end
end

function Node.NormalizeConnections()
	ConnectionBuilder.NormalizeConnections()
end

function Node.BuildDoorsForConnections()
	ConnectionBuilder.BuildDoorsForConnections()
end

-- Processing status
function Node.GetConnectionProcessingStatus()
	return {
		isProcessing = false,
		currentPhase = "complete",
		processedCount = 0,
		totalCount = 0,
		phaseDescription = "Connection processing complete"
	}
end

function Node.ProcessConnectionsBackground()
	-- Simplified - no background processing needed
end

function Node.StopConnectionProcessing()
	-- No-op - no background processing
end

return Node
