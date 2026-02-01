--##########################################################################
--  Phase2_Normalize.lua  ·  Normalize and enrich connection data
--##########################################################################

local Common = require("MedBot.Core.Common")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local Phase2_Normalize = {}

local Log = Common.Log.new("Phase2_Normalize")

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Normalize all connections in the node graph
--- @param nodes table areaId -> node mapping
--- @return table nodes (same table, modified in place)
function Phase2_Normalize.Execute(nodes)
    assert(type(nodes) == "table", "Phase2_Normalize.Execute: nodes must be table")

    Log:Info("Normalizing connections for %d nodes", #nodes)

    local connectionCount = 0
    for nodeId, node in pairs(nodes) do
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

    Log:Info("Phase 2 complete: %d connections normalized", connectionCount)
    return nodes
end

return Phase2_Normalize
