--##########################################################################
--  NodeHelpers.lua  ·  Helper functions for safe node access
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local NodeHelpers = {}
local Log = Common.Log.new("NodeHelpers")

-- Safe node getter with logging
function NodeHelpers.GetNodeSafe(id)
	if not G.Navigation.nodes then
		Log:Debug("GetNodeSafe: G.Navigation.nodes is nil")
		return nil
	end
	
	local node = G.Navigation.nodes[id]
	if not node then
		Log:Debug("GetNodeSafe: Node %s not found", tostring(id))
		return nil
	end
	
	return node
end

-- Check if nodes table is valid
function NodeHelpers.ValidateNodesTable()
	if not G.Navigation.nodes then
		Log:Warn("ValidateNodesTable: G.Navigation.nodes is nil")
		return false
	end
	
	if not next(G.Navigation.nodes) then
		Log:Warn("ValidateNodesTable: G.Navigation.nodes is empty")
		return false
	end
	
	return true
end

return NodeHelpers
