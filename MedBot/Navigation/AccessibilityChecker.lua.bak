--##########################################################################
--  AccessibilityChecker.lua  ·  Node accessibility validation
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local EdgeCalculator = require("MedBot.Navigation.EdgeCalculator")
local isWalkable = require("MedBot.Navigation.ISWalkable")

local AccessibilityChecker = {}

-- Constants
local DROP_HEIGHT = 144
local MAX_JUMP = 72
local STEP_HEIGHT = 18

local function isNodeAccessible(nodeA, nodeB, allowExpensive)
	local heightDiff = nodeB.pos.z - nodeA.pos.z

	-- Always allow going downward (falling) regardless of height - no penalty
	if heightDiff <= 0 then
		return true, 1 -- No penalty for falling
	end

	-- For upward movement, check if it's within jump range
	if heightDiff <= MAX_JUMP then
		-- Small step penalty for jumping (encourages ground-level paths)
		return true, 1 + (heightDiff / MAX_JUMP) * 0.5 -- Max 1.5x penalty
	end

	-- Height difference too large for jumping
	return false, math.huge
end

function AccessibilityChecker.IsAccessible(nodeA, nodeB, allowExpensive)
	if not nodeA or not nodeB then
		return false, math.huge
	end
	
	-- Skip expensive checks unless specifically allowed
	if not allowExpensive then
		return isNodeAccessible(nodeA, nodeB, false)
	end
	
	-- Full accessibility check with walkability
	local accessible, cost = isNodeAccessible(nodeA, nodeB, true)
	if not accessible then
		return false, math.huge
	end
	
	-- Additional walkability check if needed
	if isWalkable and isWalkable.CheckWalkability then
		local walkable = isWalkable.CheckWalkability(nodeA.pos, nodeB.pos)
		if not walkable then
			return false, math.huge
		end
	end
	
	return true, cost
end

function AccessibilityChecker.PruneInvalidConnections(nodes)
	if not nodes then return end
	
	local totalPruned = 0
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					local validConnections = {}
					for i, connection in ipairs(dir.connections) do
						local targetId = (type(connection) == "table") and connection.node or connection
						local targetNode = nodes[targetId]
						
						if targetNode then
							local accessible, cost = AccessibilityChecker.IsAccessible(node, targetNode, true)
							if accessible then
								if type(connection) == "table" then
									connection.cost = cost
									table.insert(validConnections, connection)
								else
									table.insert(validConnections, { node = connection, cost = cost })
								end
							else
								totalPruned = totalPruned + 1
							end
						else
							totalPruned = totalPruned + 1
						end
					end
					dir.connections = validConnections
					dir.count = #validConnections
				end
			end
		end
	end
	
	if totalPruned > 0 then
		local Log = Common.Log.new("AccessibilityChecker")
		Log:Info("Pruned " .. totalPruned .. " invalid connections")
	end
end

return AccessibilityChecker
