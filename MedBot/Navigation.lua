---@alias Connection { count: integer, connections: integer[] }
---@alias Node { x: number, y: number, z: number, id: integer, c: { [1]: Connection, [2]: Connection, [3]: Connection, [4]: Connection } }
---@class Pathfinding
---@field pathFound boolean
---@field pathFailed boolean

--[[
PERFORMANCE OPTIMIZATION STRATEGY:
- Heavy validation (accessibility checks) happens at setup time via pruneInvalidConnections()
- Pathfinding uses Node.GetAdjacentNodesSimple() for speed (no expensive trace checks)
- Invalid connections are removed during setup, so pathfinding can trust remaining connections
- This moves computational load to beginning rather than during gameplay
]]

local Navigation = {}

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Node = require("MedBot.Modules.Node")
local AStar = require("MedBot.Utils.A-Star")
local Lib = Common.Lib
local Log = Lib.Utils.Logger.new("MedBot")
Log.Level = 0

-- Constants
local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local DROP_HEIGHT = 144 -- Define your constants outside the function
local Jump_Height = 72 --duck jump height
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable
local GRAVITY = 800 -- Gravity in units per second squared
local MIN_STEP_SIZE = 5 -- Minimum step size in units
local preferredSteps = 10 --prefered number oif steps for simulations
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local TICK_RATE = 66

local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)

-- Add a connection between two nodes
function Navigation.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	local nodes = G.Navigation.nodes

	for dir = 1, 4 do
		local conDir = nodes[nodeA.id].c[dir]
		if conDir and conDir.connections then
			-- Check if connection already exists
			local exists = false
			for _, existingId in ipairs(conDir.connections) do
				if existingId == nodeB.id then
					exists = true
					break
				end
			end
			if not exists then
				print("Adding connection between " .. nodeA.id .. " and " .. nodeB.id)
				table.insert(conDir.connections, nodeB.id)
				conDir.count = conDir.count + 1
			end
		end
	end

	for dir = 1, 4 do
		local conDir = nodes[nodeB.id].c[dir]
		if conDir and conDir.connections then
			-- Check if reverse connection already exists
			local exists = false
			for _, existingId in ipairs(conDir.connections) do
				if existingId == nodeA.id then
					exists = true
					break
				end
			end
			if not exists then
				print("Adding reverse connection between " .. nodeB.id .. " and " .. nodeA.id)
				table.insert(conDir.connections, nodeA.id)
				conDir.count = conDir.count + 1
			end
		end
	end
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	local nodes = G.Navigation.nodes

	for dir = 1, 4 do
		local conDir = nodes[nodeA.id].c[dir]
		if conDir and conDir.connections then
			for i, con in ipairs(conDir.connections) do
				if con == nodeB.id then
					print("Removing connection between " .. nodeA.id .. " and " .. nodeB.id)
					table.remove(conDir.connections, i)
					conDir.count = conDir.count - 1
					break
				end
			end
		end
	end

	for dir = 1, 4 do
		local conDir = nodes[nodeB.id].c[dir]
		if conDir and conDir.connections then
			for i, con in ipairs(conDir.connections) do
				if con == nodeA.id then
					print("Removing reverse connection between " .. nodeB.id .. " and " .. nodeA.id)
					table.remove(conDir.connections, i)
					conDir.count = conDir.count - 1
					break
				end
			end
		end
	end
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	-- Use Node module's implementation to avoid duplication
	local Node = require("MedBot.Modules.Node")
	Node.AddCostToConnection(nodeA, nodeB, cost)
end

--[[
-- Perform a trace hull down from the given position to the ground
---@param position Vector3 The start position of the trace
---@param hullSize table The size of the hull
---@return Vector3 The normal of the ground at that point
local function traceHullDown(position, hullSize)
	local endPos = position - Vector3(0, 0, DROP_HEIGHT) -- Adjust the distance as needed
	local traceResult = engine.TraceHull(position, endPos, hullSize.min, hullSize.max, MASK_PLAYERSOLID_BRUSHONLY)
	return traceResult.plane -- Directly using the plane as the normal
end

-- Perform a trace line down from the given position to the ground
---@param position Vector3 The start position of the trace
---@return Vector3 The hit position
local function traceLineDown(position)
	local endPos = position - Vector3(0, 0, DROP_HEIGHT)
	local traceResult = engine.TraceLine(position, endPos, TRACE_MASK)
	return traceResult.endpos
end

-- Calculate the remaining two corners based on the adjusted corners and ground normal
---@param corner1 Vector3 The first adjusted corner
---@param corner2 Vector3 The second adjusted corner
---@param normal Vector3 The ground normal
---@param height number The height of the rectangle
---@return table The remaining two corners
local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()

	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)

	local function rotateAroundNormal(vector, angle)
		local cosTheta = math.cos(angle)
		local sinTheta = math.sin(angle)
		return Vector3(
			(cosTheta + (1 - cosTheta) * normal.x ^ 2) * vector.x
				+ ((1 - cosTheta) * normal.x * normal.y - normal.z * sinTheta) * vector.y
				+ ((1 - cosTheta) * normal.x * normal.z + normal.y * sinTheta) * vector.z,
			((1 - cosTheta) * normal.x * normal.y + normal.z * sinTheta) * vector.x
				+ (cosTheta + (1 - cosTheta) * normal.y ^ 2) * vector.y
				+ ((1 - cosTheta) * normal.y * normal.z - normal.x * sinTheta) * vector.z,
			((1 - cosTheta) * normal.x * normal.z - normal.y * sinTheta) * vector.x
				+ ((1 - cosTheta) * normal.y * normal.z + normal.x * sinTheta) * vector.y
				+ (cosTheta + (1 - cosTheta) * normal.z ^ 2) * vector.z
		)
	end

	local rotatedHeightVector = rotateAroundNormal(heightVector, math.pi / 2)

	local corner3 = corner1 + rotatedHeightVector * (height / widthLength)
	local corner4 = corner2 + rotatedHeightVector * (height / widthLength)

	return { corner3, corner4 }
end

-- Fixes a node by adjusting its height based on TraceHull and TraceLine results
-- Moves the node 18 units up and traces down to find a new valid position
---@param nodeId integer The index of the node in the Nodes table
---@return Node The fixed node
function Navigation.FixNode(nodeId)
	local nodes = G.Navigation.nodes
	local node = nodes[nodeId]
	if not node or not node.pos then
		print("Invalid node " .. tostring(nodeId) .. ", skipping FixNode")
		return nil
	end
	if node.fixed then
		return node
	end

	local upVector = Vector3(0, 0, 72)
	local downVector = Vector3(0, 0, -72)
	-- Fix center position
	local traceCenter = engine.TraceHull(node.pos + upVector, node.pos + downVector, HULL_MIN, HULL_MAX, TRACE_MASK)
	if traceCenter and traceCenter.fraction > 0 then
		node.pos = traceCenter.endpos
		node.z = traceCenter.endpos.z
	else
		node.pos = node.pos + upVector
		node.z = node.z + 72
	end
	-- Fix two known corners (nw, se) via line traces
	for _, cornerKey in ipairs({ "nw", "se" }) do
		local c = node[cornerKey]
		if c then
			local world = Vector3(c.x, c.y, c.z)
			local trace = engine.TraceLine(world + upVector, world + downVector, TRACE_MASK)
			if trace and trace.fraction < 1 then
				node[cornerKey] = trace.endpos
			else
				node[cornerKey] = world + upVector
			end
		end
	end
	-- Compute remaining corners
	local normal = getGroundNormal(node.pos)
	local height = math.abs(node.se.z - node.nw.z)
	local rem = calculateRemainingCorners(node.nw, node.se, normal, height)
	node.ne = rem[1]
	node.sw = rem[2]
	node.fixed = true
	return node
end

-- Adjust all nodes by fixing their positions and adding missing corners.
function Navigation.FixAllNodes()
	local nodes = Navigation.GetNodes()
	for id in pairs(nodes) do
		Navigation.FixNode(id)
	end
end
]]

function Navigation.Setup()
	if engine.GetMapName() then
		Node.Setup()
		Navigation.ClearPath()
	end
end

-- Get the current path
---@return Node[]|nil
function Navigation.GetCurrentPath()
	return G.Navigation.path
end

-- Clear the current path
function Navigation.ClearPath()
	G.Navigation.path = {}
	G.Navigation.currentNodeIndex = 1
end

-- Set the current path
---@param path Node[]
function Navigation.SetCurrentPath(path)
	if not path then
		Log:Error("Failed to set path, it's nil")
		return
	end
	G.Navigation.path = path
	G.Navigation.currentNodeIndex = 1 -- Start from the first node (start) and work towards goal
end

-- Remove the current node from the path (we've reached it)
function Navigation.RemoveCurrentNode()
	G.Navigation.currentNodeTicks = 0
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Remove the first node (current node we just reached)
		table.remove(G.Navigation.path, 1)
		-- currentNodeIndex stays at 1 since we always target the first node in the remaining path
		G.Navigation.currentNodeIndex = 1
	end
end

-- Function to increment the current node ticks
function Navigation.increment_ticks()
	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
end

-- Function to increment the current node ticks
function Navigation.ResetTickTimer()
	G.Navigation.currentNodeTicks = 0
end

-- Function to convert degrees to radians
local function degreesToRadians(degrees)
	return degrees * math.pi / 180
end

-- Checks for an obstruction between two points using a hull trace.
local function isPathClear(startPos, endPos)
	local traceResult = engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, MASK_PLAYERSOLID_BRUSHONLY)
	return traceResult
end

-- Checks if the ground is stable at a given position.
local function isGroundStable(position)
	local groundTraceResult = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START,
		position + GROUND_TRACE_OFFSET_END,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	return groundTraceResult.fraction < 1
end

-- Function to get the ground normal at a given position
local function getGroundNormal(position)
	local groundTraceResult = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START,
		position + GROUND_TRACE_OFFSET_END,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	return groundTraceResult.plane
end

-- Precomputed up vector and max slope angle in radians
local MAX_SLOPE_ANGLE_RAD = degreesToRadians(MAX_SLOPE_ANGLE)

-- Function to adjust direction based on ground normal
local function adjustDirectionToGround(direction, groundNormal)
	local angleBetween = math.acos(groundNormal:Dot(UP_VECTOR))
	if angleBetween <= MAX_SLOPE_ANGLE_RAD then
		local newDirection = direction:Cross(UP_VECTOR):Cross(groundNormal)
		return Common.Normalize(newDirection)
	end
	return direction -- If the slope is too steep, keep the original direction
end

-- Main function to check if the path between the current position and the node is walkable.
function Navigation.isWalkable(startPos, endPos)
	local direction = Common.Normalize(endPos - startPos)
	local totalDistance = (endPos - startPos):Length()
	local stepSize = math.max(MIN_STEP_SIZE, totalDistance / preferredSteps)
	local currentPosition = startPos
	local distanceCovered = 0
	local requiredFraction = STEP_HEIGHT / Jump_Height

	while distanceCovered < totalDistance do
		stepSize = math.min(stepSize, totalDistance - distanceCovered)
		local nextPosition = currentPosition + direction * stepSize

		-- Check if the next step is clear
		local pathClearResult = isPathClear(currentPosition, nextPosition)
		if pathClearResult.fraction < 1 then
			-- We'll collide, get end position of the trace
			local collisionPosition = pathClearResult.endpos

			-- Move 1 unit forward, then up by the jump height, then trace down
			local forwardPosition = collisionPosition + direction * 1
			local upPosition = forwardPosition + Vector3(0, 0, Jump_Height)
			local traceDownResult = isPathClear(upPosition, forwardPosition)

			-- Determine if we can step up or jump over the obstacle
			local canStepUp = traceDownResult.fraction >= requiredFraction
			local canJumpOver = traceDownResult.fraction > 0 and (G.Menu.Movement.Smart_Jump ~= false)

			-- Update the current position based on step up or jump over
			currentPosition = (canStepUp or canJumpOver) and traceDownResult.endpos or currentPosition

			-- If we couldn't step up or jump over, the path is blocked
			if traceDownResult.fraction == 0 or currentPosition == collisionPosition then
				return false
			end
		else
			currentPosition = nextPosition
		end

		-- Check if the ground is stable
		if not isGroundStable(currentPosition) then
			-- Simulate falling
			currentPosition = currentPosition - Vector3(0, 0, (stepSize / 450) * GRAVITY)
		else
			-- Adjust direction to align with the ground
			direction = adjustDirectionToGround(direction, getGroundNormal(currentPosition))
		end

		distanceCovered = distanceCovered + stepSize
	end

	return true -- Path is walkable
end

-- Step-focused walkability check optimized for node skipping (18-unit steps, not high jumps)
function Navigation.isStepWalkable(startPos, endPos)
	local direction = Common.Normalize(endPos - startPos)
	local totalDistance = (endPos - startPos):Length()
	local stepSize = math.min(24, totalDistance / 5) -- Smaller steps for precision
	local currentPosition = startPos
	local maxStepHeight = 18 -- Only allow 18-unit steps, not full jumps

	-- Quick height check first
	local heightDiff = endPos.z - startPos.z
	if heightDiff > maxStepHeight then
		return false -- Too high to step up
	end

	local steps = math.max(3, math.ceil(totalDistance / stepSize))

	for i = 1, steps do
		local progress = i / steps
		local nextPosition = startPos + direction * (totalDistance * progress)

		-- Check if path is clear at this step
		local pathTrace = isPathClear(currentPosition, nextPosition)
		if pathTrace.fraction < 0.9 then
			-- Small obstacle, check if we can step over it
			local obstacleHeight = pathTrace.endpos.z - currentPosition.z
			if obstacleHeight > maxStepHeight then
				return false -- Obstacle too high to step over
			end

			-- Try stepping up by the obstacle height + small margin
			local stepUpHeight = math.min(maxStepHeight, obstacleHeight + 2)
			local stepUpPos = currentPosition + Vector3(0, 0, stepUpHeight)
			local stepOverTrace = isPathClear(stepUpPos, nextPosition + Vector3(0, 0, stepUpHeight))

			if stepOverTrace.fraction < 0.9 then
				return false -- Can't step over obstacle
			end
		end

		currentPosition = nextPosition
	end

	return true -- Path is step-walkable
end

-- Function to get forward speed by class
function Navigation.GetMaxSpeed(entity)
	return entity:GetPropFloat("m_flMaxspeed")
end

-- Function to compute the move direction
local function ComputeMove(pCmd, a, b)
	local diff = b - a
	if diff:Length() == 0 then
		return Vector3(0, 0, 0)
	end

	local x = diff.x
	local y = diff.y
	local vSilent = Vector3(x, y, 0)

	local ang = vSilent:Angles()
	local cYaw = pCmd:GetViewAngles().yaw
	local yaw = math.rad(ang.y - cYaw)
	local move = Vector3(math.cos(yaw), -math.sin(yaw), 0)

	local maxSpeed = Navigation.GetMaxSpeed(G.pLocal.entity) + 1
	return move * maxSpeed
end

-- Function to implement fast stop
local function FastStop(pCmd, pLocal)
	local velocity = pLocal:GetVelocity()
	velocity.z = 0
	local speed = velocity:Length2D()

	if speed < 1 then
		pCmd:SetForwardMove(0)
		pCmd:SetSideMove(0)
		return
	end

	local accel = 5.5
	local maxSpeed = Navigation.GetMaxSpeed(G.pLocal.entity)
	local playerSurfaceFriction = 1.0
	local max_accelspeed = accel * (1 / TICK_RATE) * maxSpeed * playerSurfaceFriction

	local wishspeed
	if speed - max_accelspeed <= -1 then
		wishspeed = max_accelspeed / (speed / (accel * (1 / TICK_RATE)))
	else
		wishspeed = max_accelspeed
	end

	local ndir = (velocity * -1):Angles()
	ndir.y = pCmd:GetViewAngles().y - ndir.y
	ndir = ndir:ToVector()

	pCmd:SetForwardMove(ndir.x * wishspeed)
	pCmd:SetSideMove(ndir.y * wishspeed)
end

-- Function to make the player walk to a destination smoothly and stop at the destination
function Navigation.WalkTo(pCmd, pLocal, pDestination)
	local localPos = pLocal:GetAbsOrigin()
	local distVector = pDestination - localPos
	local dist = distVector:Length()
	local currentSpeed = Navigation.GetMaxSpeed(pLocal)

	local distancePerTick = math.max(10, math.min(currentSpeed / TICK_RATE, 450)) --in case we tracvel faster then we are close to target

	if dist > distancePerTick then --if we are further away we walk normaly at max speed
		local result = ComputeMove(pCmd, localPos, pDestination)
		pCmd:SetForwardMove(result.x)
		pCmd:SetSideMove(result.y)
	else
		FastStop(pCmd, pLocal)
	end
end

---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node
function Navigation.GetClosestNode(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetClosestNode")
		return nil
	end
	return Node.GetClosestNode(pos)
end

-- Main pathfinding function - FIXED TO USE DUAL A* SYSTEM
---@param startNode Node
---@param goalNode Node
function Navigation.FindPath(startNode, goalNode)
	assert(startNode and startNode.pos, "Navigation.FindPath: startNode is nil or has no pos")
	assert(goalNode and goalNode.pos, "Navigation.FindPath: goalNode is nil or has no pos")

	local horizontalDistance = math.abs(goalNode.pos.x - startNode.pos.x) + math.abs(goalNode.pos.y - startNode.pos.y)
	local verticalDistance = math.abs(goalNode.pos.z - startNode.pos.z)

	-- HIERARCHICAL A* SYSTEM: Use A* for both area-to-area and fine-point pathfinding
	if G.Menu.Main.UseHierarchicalPathfinding and G.Navigation.hierarchical then
		Log:Info("Using hierarchical A* pathfinding (area pathfinding + fine point navigation)")

		-- Phase 1: A* pathfinding between areas
		local areaPath = AStar.NormalPath(startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodesSimple)

		if areaPath and #areaPath > 1 then
			-- Phase 2: A* pathfinding within areas using fine points
			local finalPath = {}

			for i = 1, #areaPath do
				local currentArea = areaPath[i]
				local areaInfo = G.Navigation.hierarchical.areas[currentArea.id]

				if areaInfo and areaInfo.points and #areaInfo.points > 0 then
					if i == 1 then
						-- First area: add fine points from start to area exit
						local startPoint = Node.GetClosestAreaPoint(currentArea.id, startNode.pos)
						if #areaPath > 1 then
							local nextArea = areaPath[i + 1]
							local exitPoint = Navigation.FindBestAreaExitPoint(currentArea, nextArea, areaInfo)
							if startPoint and exitPoint then
								local subPath = AStar.AStarOnFinePoints(startPoint, exitPoint, areaInfo.points)
								if subPath then
									for _, point in ipairs(subPath) do
										table.insert(finalPath, point)
									end
								end
							end
						else
							-- Only one area, path to goal
							local goalPoint = Node.GetClosestAreaPoint(currentArea.id, goalNode.pos)
							if startPoint and goalPoint then
								local subPath = AStar.AStarOnFinePoints(startPoint, goalPoint, areaInfo.points)
								if subPath then
									for _, point in ipairs(subPath) do
										table.insert(finalPath, point)
									end
								end
							end
						end
					elseif i == #areaPath then
						-- Last area: add fine points from area entry to goal
						local goalPoint = Node.GetClosestAreaPoint(currentArea.id, goalNode.pos)
						local prevArea = areaPath[i - 1]
						local entryPoint = Navigation.FindBestAreaEntryPoint(currentArea, prevArea, areaInfo)
						if entryPoint and goalPoint then
							local subPath = AStar.AStarOnFinePoints(entryPoint, goalPoint, areaInfo.points)
							if subPath then
								for _, point in ipairs(subPath) do
									table.insert(finalPath, point)
								end
							end
						end
					else
						-- Middle areas: path from entry to exit using fine points
						local prevArea = areaPath[i - 1]
						local nextArea = areaPath[i + 1]
						local entryPoint = Navigation.FindBestAreaEntryPoint(currentArea, prevArea, areaInfo)
						local exitPoint = Navigation.FindBestAreaExitPoint(currentArea, nextArea, areaInfo)
						if entryPoint and exitPoint then
							local subPath = AStar.AStarOnFinePoints(entryPoint, exitPoint, areaInfo.points)
							if subPath then
								for _, point in ipairs(subPath) do
									table.insert(finalPath, point)
								end
							end
						end
					end
				else
					-- No fine points available, use area center as fallback
					table.insert(finalPath, currentArea)
				end
			end

			if #finalPath > 0 then
				G.Navigation.path = finalPath
				Log:Info("Hierarchical A* path found: %d areas, %d fine points", #areaPath, #finalPath)
				Navigation.pathFound = true
				Navigation.pathFailed = false
				return Navigation
			end
		end

		Log:Warn("Hierarchical A* pathfinding failed, falling back to simple A*")
	end

	-- Fallback: Simple A* pathfinding on main nodes only
	G.Navigation.path = AStar.NormalPath(startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodesSimple)

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Error("Failed to find path from %d to %d!", startNode.id, goalNode.id)
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false
	else
		Log:Info("Simple A* path found from %d to %d with %d nodes", startNode.id, goalNode.id, #G.Navigation.path)
		Navigation.pathFound = true
		Navigation.pathFailed = false
	end

	return Navigation
end

-- A* internal navigation for smooth movement within larger areas
function Navigation.GetInternalPath(startPos, endPos, maxDistance)
	maxDistance = maxDistance or 200 -- Maximum distance to consider internal navigation

	local distance = (endPos - startPos):Length()
	if distance < 50 then
		return nil -- Too close, direct movement is fine
	end

	if distance > maxDistance then
		return nil -- Too far, use regular pathfinding
	end

	-- Check if we're in the same area and have hierarchical data
	if G.Navigation.hierarchical then
		local startArea, endArea = nil, nil

		-- Find which areas contain our start and end positions
		for areaId, areaInfo in pairs(G.Navigation.hierarchical.areas) do
			local areaNode = G.Navigation.nodes[areaId]
			if areaNode then
				local distToStart = (areaNode.pos - startPos):Length()
				local distToEnd = (areaNode.pos - endPos):Length()

				-- Check if positions are within reasonable distance of area center
				if distToStart < 150 then
					startArea = areaInfo
				end
				if distToEnd < 150 then
					endArea = areaInfo
				end
			end
		end

		-- If both positions are in the same area, use fine points for internal navigation
		if startArea and endArea and startArea.id == endArea.id then
			local Node = require("MedBot.Modules.Node")
			local AStar = require("MedBot.Utils.A-Star")

			-- Find closest fine points to start and end
			local startPoint = Node.GetClosestAreaPoint(startArea.id, startPos)
			local endPoint = Node.GetClosestAreaPoint(startArea.id, endPos)

			if startPoint and endPoint and startPoint.id ~= endPoint.id then
				-- Use A* on fine points for smooth internal navigation
				local finePath = AStar.AStarOnFinePoints(startPoint, endPoint, startArea.points)
				if finePath and #finePath > 2 then
					Log:Debug("Using A* internal navigation with %d fine points", #finePath)
					return finePath
				end
			end
		end
	end

	return nil -- No internal path available
end

-- Find the best exit point from an area towards another area
function Navigation.FindBestAreaExitPoint(currentArea, nextArea, areaInfo)
	if not areaInfo or not areaInfo.edgePoints or #areaInfo.edgePoints == 0 then
		return nil
	end

	local bestPoint = nil
	local minDistance = math.huge

	-- Find edge point closest to the next area
	for _, edgePoint in ipairs(areaInfo.edgePoints) do
		local distance = (edgePoint.pos - nextArea.pos):Length()
		if distance < minDistance then
			minDistance = distance
			bestPoint = edgePoint
		end
	end

	return bestPoint
end

-- Find the best entry point into an area from another area
function Navigation.FindBestAreaEntryPoint(currentArea, prevArea, areaInfo)
	if not areaInfo or not areaInfo.edgePoints or #areaInfo.edgePoints == 0 then
		return nil
	end

	local bestPoint = nil
	local minDistance = math.huge

	-- Find edge point closest to the previous area
	for _, edgePoint in ipairs(areaInfo.edgePoints) do
		local distance = (edgePoint.pos - prevArea.pos):Length()
		if distance < minDistance then
			minDistance = distance
			bestPoint = edgePoint
		end
	end

	return bestPoint
end

return Navigation
