--##########################################################################
--  Phase2_Normalize.lua  ·  Normalize and enrich connection data
--##########################################################################

local Common = require("MedBot.Core.Common")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local Phase2_Normalize = {}

local Log = Common.Log.new("Phase2_Normalize")

local function getSortAxisForDirection(dirId)
	if dirId == "north" or dirId == "south" then
		return "x"
	elseif dirId == "east" or dirId == "west" then
		return "y"
	else
		return nil
	end
end

local function sortConnectionsByNeighborPosition(node, dirId, dir, nodes)
	if not dir.connections or #dir.connections < 2 then
		return
	end

	local axis = getSortAxisForDirection(dirId)
	if not axis then
		return
	end

	table.sort(dir.connections, function(a, b)
		local nodeIdA = ConnectionUtils.GetNodeId(a)
		local nodeIdB = ConnectionUtils.GetNodeId(b)

		local neighborA = nodes[nodeIdA]
		local neighborB = nodes[nodeIdB]

		if not neighborA or not neighborA.pos then
			return false
		end
		if not neighborB or not neighborB.pos then
			return true
		end

		return neighborA.pos[axis] < neighborB.pos[axis]
	end)
end

local function precomputeNodeBounds(node)
	if not node.nw or not node.ne or not node.sw or not node.se then
		return
	end

	-- Precompute horizontal bounds for fast containment checks
	node._minX = math.min(node.nw.x, node.ne.x, node.sw.x, node.se.x)
	node._maxX = math.max(node.nw.x, node.ne.x, node.sw.x, node.se.x)
	node._minY = math.min(node.nw.y, node.ne.y, node.sw.y, node.se.y)
	node._maxY = math.max(node.nw.y, node.ne.y, node.sw.y, node.se.y)
end

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Normalize all connections in the node graph and precompute bounds
--- @param nodes table areaId -> node mapping
--- @return table nodes (same table, modified in place)
function Phase2_Normalize.Execute(nodes)
	assert(type(nodes) == "table", "Phase2_Normalize.Execute: nodes must be table")

	local nodeCount = 0
	local connectionCount = 0

	for nodeId, node in pairs(nodes) do
		nodeCount = nodeCount + 1

		-- Precompute bounds for fast containment checks
		precomputeNodeBounds(node)

		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						dir.connections[i] = ConnectionUtils.NormalizeEntry(connection)
						connectionCount = connectionCount + 1
					end
					sortConnectionsByNeighborPosition(node, dirId, dir, nodes)
				end
			end
		end
	end

	Log:Info("Phase 2 complete: %d nodes normalized with %d connections", nodeCount, connectionCount)
	return nodes
end

return Phase2_Normalize
