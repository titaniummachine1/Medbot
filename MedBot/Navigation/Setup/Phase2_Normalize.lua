--##########################################################################
--  Phase2_Normalize.lua  ·  Normalize and enrich connection data
--##########################################################################

local Common = require("MedBot.Core.Common")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local Phase2_Normalize = {}

local Log = Common.Log.new("Phase2_Normalize")

--##########################################################################
--  LOCAL HELPERS
--##########################################################################

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
				end
			end
		end
	end

	Log:Info("Phase 2 complete: %d nodes normalized with %d connections", nodeCount, connectionCount)
	return nodes
end

return Phase2_Normalize
