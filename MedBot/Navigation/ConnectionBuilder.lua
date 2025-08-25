--##########################################################################
--  ConnectionBuilder.lua  ·  Connection and door building
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local EdgeCalculator = require("MedBot.Navigation.EdgeCalculator")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local ConnectionBuilder = {}

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local CLEARANCE_OFFSET = 34

local Log = Common.Log.new("ConnectionBuilder")

function ConnectionBuilder.NormalizeConnections()
	local nodes = G.Navigation.nodes
	if not nodes then return end
	
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						dir.connections[i] = ConnectionUtils.NormalizeEntry(connection)
					end
				end
			end
		end
	end
	Log:Info("Normalized all connections to enriched format")
end

local function determineDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 1 or -1, 0
	else
		return 0, (dy > 0) and 1 or -1
	end
end

local function getFacingEdgeCorners(area, dirX, dirY, otherPos)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end
	
	if dirX == 1 then return area.ne, area.se end     -- East
	if dirX == -1 then return area.sw, area.nw end    -- West  
	if dirY == 1 then return area.se, area.sw end     -- South
	if dirY == -1 then return area.nw, area.ne end    -- North
	
	return nil, nil
end

local function createDoorForAreas(areaA, areaB)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		return nil
	end
	
	local dirX, dirY = determineDirection(areaA.pos, areaB.pos)
	local leftA, rightA = getFacingEdgeCorners(areaA, dirX, dirY, areaB.pos)
	local leftB, rightB = getFacingEdgeCorners(areaB, -dirX, -dirY, areaA.pos)
	
	if not (leftA and rightA and leftB and rightB) then
		return nil
	end
	
	-- Simple overlap calculation
	local overlapLeft = Vector3(
		math.max(leftA.x, leftB.x),
		math.max(leftA.y, leftB.y),
		math.max(leftA.z, leftB.z)
	)
	local overlapRight = Vector3(
		math.min(rightA.x, rightB.x),
		math.min(rightA.y, rightB.y),
		math.min(rightA.z, rightB.z)
	)
	
	local width = EdgeCalculator.Distance3D(overlapLeft, overlapRight)
	if width < HITBOX_WIDTH then
		return nil
	end
	
	local middle = EdgeCalculator.LerpVec(overlapLeft, overlapRight, 0.5)
	
	return {
		left = overlapLeft,
		middle = middle,
		right = overlapRight,
		needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT
	}
end

function ConnectionBuilder.BuildDoorsForConnections()
	local nodes = G.Navigation.nodes
	if not nodes then return end
	
	local doorsBuilt = 0
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]
						
						if targetNode and type(connection) == "table" then
							local door = createDoorForAreas(node, targetNode)
							if door then
								connection.left = door.left
								connection.middle = door.middle
								connection.right = door.right
								connection.needJump = door.needJump
								doorsBuilt = doorsBuilt + 1
							end
						end
					end
				end
			end
		end
	end
	
	Log:Info("Built " .. doorsBuilt .. " doors for connections")
end

function ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then return nil end
	
	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				if targetId == nodeB.id then
					return connection
				end
			end
		end
	end
	return nil
end

function ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then return nil end
	
	local connection = ConnectionBuilder.GetConnectionEntry(areaA, areaB)
	if connection and connection.middle then
		return connection.middle
	end
	
	return areaB.pos
end

return ConnectionBuilder
