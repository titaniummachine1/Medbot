---@alias ConnectionObj { node: integer, cost: number, left: Vector3|nil, middle: Vector3|nil, right: Vector3|nil }
---@alias ConnectionDir { count: integer, connections: ConnectionObj[] }
---@alias Node { pos: Vector3, id: integer, c: { [1]: ConnectionDir, [2]: ConnectionDir, [3]: ConnectionDir, [4]: ConnectionDir } }
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

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local AStar = require("MedBot.Algorithms.A-Star")
--local DStar = require("MedBot.Algorithms.DStar")
--local DStar = require("MedBot.Utils.DStar")
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
	Node.AddConnection(nodeA, nodeB)
	Node.AddConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end
	Node.RemoveConnection(nodeA, nodeB)
	Node.RemoveConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	-- Use Node module's implementation to avoid duplication
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
	-- Also clear door/center/goal waypoints to avoid stale movement/visuals
	G.Navigation.waypoints = {}
	G.Navigation.currentWaypointIndex = 1
	-- Clear path traversal history used by stuck analysis
	G.Navigation.pathHistory = {}
end

-- Set the current path
---@param path Node[]
function Navigation.SetCurrentPath(path)
	if not path then
		Log:Error("Failed to set path, it's nil")
		return
	end
	G.Navigation.path = path
	-- Use weak values to avoid strong retention of node objects (nodes table holds strong refs)
	pcall(setmetatable, G.Navigation.path, { __mode = "v" })
	G.Navigation.currentNodeIndex = 1 -- Start from the first node (start) and work towards goal
	-- Build door-aware waypoint list for precise movement and visuals
	--ProfilerBegin and ProfilerEnd are not available here, so rely on caller's profiling
	Navigation.BuildDoorWaypointsFromPath()
	-- Reset traversal history on new path
	G.Navigation.pathHistory = {}
end

-- Remove the current node from the path (we've reached it)
function Navigation.RemoveCurrentNode()
	G.Navigation.currentNodeTicks = 0
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Remove the first node (current node we just reached)
		local reached = table.remove(G.Navigation.path, 1)
		-- Track reached nodes from last to first
		if reached then
			G.Navigation.pathHistory = G.Navigation.pathHistory or {}
			table.insert(G.Navigation.pathHistory, 1, reached)
			-- Bound history size
			if #G.Navigation.pathHistory > 32 then
				table.remove(G.Navigation.pathHistory)
			end
		end
		-- currentNodeIndex stays at 1 since we always target the first node in the remaining path
		G.Navigation.currentNodeIndex = 1
		-- Rebuild door waypoints to reflect new leading edge
		Navigation.BuildDoorWaypointsFromPath()
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

-- Build flexible waypoints: choose optimal door points, skip centers when direct door-to-door is shorter
function Navigation.BuildDoorWaypointsFromPath()
	-- reuse existing table to avoid churn
	if not G.Navigation.waypoints then
		G.Navigation.waypoints = {}
	else
		for i = #G.Navigation.waypoints, 1, -1 do
			G.Navigation.waypoints[i] = nil
		end
	end
	G.Navigation.currentWaypointIndex = 1
	local path = G.Navigation.path
	if not path or #path == 0 then
		return
	end

	for i = 1, #path - 1 do
		local a, b = path[i], path[i + 1]
		if a and b and a.pos and b.pos then
			-- Get door entry for current edge
			local entry = Node.GetConnectionEntry(a, b)
			local doorPoint = nil

			if entry and (entry.left or entry.middle or entry.right) then
				-- Choose best door point based on distance to destination
				local bestPoint = nil
				local bestDistance = math.huge

				for _, point in ipairs({ entry.left, entry.middle, entry.right }) do
					if point then
						local distance = (point - b.pos):Length()
						if distance < bestDistance then
							bestDistance = distance
							bestPoint = point
						end
					end
				end

				doorPoint = bestPoint
			else
				-- Fallback: use Node helper for door target
				doorPoint = Node.GetDoorTargetPoint(a, b)
			end

			if doorPoint then
				-- Check if we should skip area center for direct door-to-door navigation
				local shouldSkipCenter = false
				if i < #path - 1 then -- Not the last edge
					local nextArea = path[i + 2]
					if nextArea then
						local nextEntry = Node.GetConnectionEntry(b, nextArea)
						local nextDoorPoint = nil

						if nextEntry and (nextEntry.left or nextEntry.middle or nextEntry.right) then
							-- Choose optimal next door position based on distance to current door
							local nextDoorPositions = {}
							if nextEntry.left then
								table.insert(nextDoorPositions, nextEntry.left)
							end
							if nextEntry.middle then
								table.insert(nextDoorPositions, nextEntry.middle)
							end
							if nextEntry.right then
								table.insert(nextDoorPositions, nextEntry.right)
							end

							if #nextDoorPositions > 0 then
								local bestNextPos = nextDoorPositions[1]
								local bestNextDist = (nextDoorPositions[1] - doorPoint):Length()

								for j = 2, #nextDoorPositions do
									local dist = (nextDoorPositions[j] - doorPoint):Length()
									if dist < bestNextDist then
										bestNextPos = nextDoorPositions[j]
										bestNextDist = dist
									end
								end
								nextDoorPoint = bestNextPos
							end
						else
							nextDoorPoint = Node.GetDoorTargetPoint(b, nextArea)
						end

						if nextDoorPoint then
							-- Compare distances: door->center->nextDoor vs door->nextDoor
							local viaCenterDist = (doorPoint - b.pos):Length() + (b.pos - nextDoorPoint):Length()
							local directDist = (doorPoint - nextDoorPoint):Length()

							-- Skip center if direct path is shorter by meaningful margin
							-- Also skip if both doors are in same area (always skip center for same area)
							if directDist < viaCenterDist * 0.9 or (a.id and b.id and a.id == b.id) then
								shouldSkipCenter = true
							end
						end
					end
				end

				-- Add door waypoint
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = a.id,
					toId = b.id,
					pos = doorPoint,
				})

				-- Add center waypoint only if not skipping
				if not shouldSkipCenter then
					table.insert(G.Navigation.waypoints, {
						pos = b.pos,
						kind = "center",
						areaId = b.id,
					})
				end
			end
		end
	end

	-- Append final precise goal position if available
	local goalPos = G.Navigation.goalPos
	if goalPos then
		table.insert(G.Navigation.waypoints, { pos = goalPos, kind = "goal" })
	end
end

function Navigation.GetCurrentWaypoint()
	local wpList = G.Navigation.waypoints
	local idx = G.Navigation.currentWaypointIndex or 1
	if wpList and idx and wpList[idx] then
		return wpList[idx]
	end
	return nil
end

function Navigation.AdvanceWaypoint()
	local wpList = G.Navigation.waypoints
	local idx = G.Navigation.currentWaypointIndex or 1
	if not (wpList and wpList[idx]) then
		return
	end
	local current = wpList[idx]
	-- If we reached a center of the next area, advance the area path too
	if current.kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
		-- path[1] is previous area; popping it moves us into the new area
		Navigation.RemoveCurrentNode()
	end
	G.Navigation.currentWaypointIndex = idx + 1
end

function Navigation.SkipWaypoints(count)
	local wpList = G.Navigation.waypoints
	if not wpList then
		return
	end
	local idx = (G.Navigation.currentWaypointIndex or 1) + (count or 1)
	if idx < 1 then
		idx = 1
	end
	if idx > #wpList + 1 then
		idx = #wpList + 1
	end
	-- If we skip over a center, reflect area progression
	local current = G.Navigation.waypoints[G.Navigation.currentWaypointIndex or 1]
	if current and current.kind ~= "center" then
		for j = (G.Navigation.currentWaypointIndex or 1), math.min(idx - 1, #wpList) do
			if wpList[j].kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
				Navigation.RemoveCurrentNode()
			end
		end
	end
	G.Navigation.currentWaypointIndex = idx
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

-- WalkTo functionality has been moved to MovementController.walkTo
-- Please use MovementController.walkTo directly

---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetClosestNode(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetClosestNode")
		return nil
	end
	local n = Node.GetClosestNode(pos)
	if not n then
		return nil
	end
	return n
end

-- Main pathfinding function - FIXED TO USE DUAL A* SYSTEM
---@param startNode Node
---@param goalNode Node
function Navigation.FindPath(startNode, goalNode)
	if not startNode or not startNode.pos then
		Log:Error("Navigation.FindPath: invalid start node")
		return Navigation
	end
	if not goalNode or not goalNode.pos then
		Log:Error("Navigation.FindPath: invalid goal node")
		return Navigation
	end

	local horizontalDistance = math.abs(goalNode.pos.x - startNode.pos.x) + math.abs(goalNode.pos.y - startNode.pos.y)
	local verticalDistance = math.abs(goalNode.pos.z - startNode.pos.z)

	-- Try A* pathfinding as primary algorithm (more reliable than D*)
	local success, path = pcall(AStar.NormalPath, startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodesSimple)

	if not success then
		Log:Error("A* pathfinding crashed: %s", tostring(path))
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false

		-- Add circuit breaker penalty for this failed connection
		if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
			G.CircuitBreaker.addConnectionFailure(startNode, goalNode)
		end
		return Navigation
	end

	G.Navigation.path = path

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Error("Failed to find path from %d to %d!", startNode.id, goalNode.id)
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false

		-- Add circuit breaker penalty for this failed connection
		if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
			G.CircuitBreaker.addConnectionFailure(startNode, goalNode)
		end
	else
		Log:Info("Path found from %d to %d with %d nodes", startNode.id, goalNode.id, #G.Navigation.path)
		Navigation.pathFound = true
		Navigation.pathFailed = false
		pcall(setmetatable, G.Navigation.path, { __mode = "v" })
		-- Refresh waypoints to reflect current door usage
		Navigation.BuildDoorWaypointsFromPath()
		-- Reset traversed-node history for new path
		G.Navigation.pathHistory = {}
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

	-- Hierarchical pathfinding removed - using simplified system

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
