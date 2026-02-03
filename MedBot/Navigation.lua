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
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local NodeSkipper = require("MedBot.Bot.NodeSkipper")
local isNavigable = require("MedBot.Navigation.isWalkable.isNavigable")
local Lib = Common.Lib
local Log = Lib.Utils.Logger.new("MedBot")
Log.Level = 0

-- Constants
local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local DROP_HEIGHT = 144 -- Define your constants outside the function
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local TICK_RATE = 66
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable

-- Add a connection between two nodes
function Navigation.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		Log:Warn("AddConnection: One or both nodes are nil")
		return
	end
	Node.AddConnection(nodeA, nodeB)
	Node.AddConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		Log:Warn("RemoveConnection: One or both nodes are nil")
		return
	end
	Node.RemoveConnection(nodeA, nodeB)
	Node.RemoveConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		Log:Warn("AddCostToConnection: One or both nodes are nil")
		return
	end

	-- Use Node module's implementation to avoid duplication
	Node.AddCostToConnection(nodeA, nodeB, cost)
end

-- ========================================================================
-- SETUP & INITIALIZATION
-- ========================================================================

function Navigation.Setup()
	if engine.GetMapName() then
		Node.Setup()
		Navigation.ClearPath()
	end
end

-- ========================================================================
-- NODE QUERIES
-- ========================================================================

-- Get a node by ID
---@param nodeId integer
---@return table|nil
function Navigation.GetNode(nodeId)
	if not nodeId then
		Log:Warn("GetNode: nodeId is nil")
		return nil
	end

	return Node.GetNodeByID(nodeId)
end

-- Get adjacent nodes for a given node ID (areas only, no doors)
---@param nodeId integer
---@return integer[]
function Navigation.GetAdjacentNodes(nodeId)
	if not nodeId then
		Log:Warn("GetAdjacentNodes: nodeId is nil")
		return {}
	end

	local node = Node.GetNodeByID(nodeId)
	if not node then
		Log:Warn("GetAdjacentNodes: node %d not found", nodeId)
		return {}
	end

	-- Get adjacent nodes with the nodes table
	local neighbors = Node.GetAdjacentNodesSimple(node, G.Navigation.nodes)

	-- Extract node IDs
	local adjacentIds = {}
	for _, neighbor in ipairs(neighbors) do
		if neighbor.node and neighbor.node.id then
			table.insert(adjacentIds, neighbor.node.id)
		end
	end

	return adjacentIds
end

-- ========================================================================
-- PATH QUERIES
-- ========================================================================

-- Get the current path
---@return Node[]|nil
function Navigation.GetCurrentPath()
	return G.Navigation.path
end

-- ========================================================================
-- PATH MANAGEMENT
-- ========================================================================

-- Clear the current path
function Navigation.ClearPath()
	G.Navigation.path = {}
	G.Navigation.currentNodeIndex = 1
	-- Also clear door/center/goal waypoints to avoid stale movement/visuals
	G.Navigation.waypoints = {}
	G.Navigation.currentWaypointIndex = 1
	-- Clear path traversal history used by stuck analysis
	G.Navigation.pathHistory = {}
	-- Reset node skipping state
	NodeSkipper.Reset()
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
	-- Reset node skipping state for new path
	local NodeSkipper = require("MedBot.Bot.NodeSkipper")
	NodeSkipper.Reset()
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

-- Function to reset the current node ticks
function Navigation.ResetTickTimer()
	G.Navigation.currentNodeTicks = 0
end

function Navigation.ResetNodeSkipping()
	NodeSkipper.Reset()
end

-- ========================================================================
-- NODE VALIDATION & CHECKS
-- ========================================================================

-- Check if next node is walkable from current position
function Navigation.CheckNextNodeWalkable(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		Log:Debug(
			"CheckNextNodeWalkable: Invalid node data - currentNode=%s, nextNode=%s",
			tostring(currentNode and currentNode.id),
			tostring(nextNode and nextNode.id)
		)
		return false
	end

	-- Use isNavigable instead of IsWalkable
	local currentArea = Node.GetAreaAtPosition(currentPos)
	if not currentArea then
		Log:Debug("CheckNextNodeWalkable: Could not find current area")
		return false
	end

	local success, canWalk = pcall(isNavigable.CanSkip, currentPos, nextNode.pos, currentArea, false)

	if success and canWalk then
		Log:Debug("Next node %d is walkable from current position", nextNode.id)
		return true
	else
		Log:Debug("Next node %d is not walkable from current position", nextNode.id)
		return false
	end
end

-- Check if next node is closer than current node
function Navigation.CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		Log:Debug(
			"CheckNextNodeCloser: Invalid node data - currentNode=%s, nextNode=%s",
			tostring(currentNode and currentNode.id),
			tostring(nextNode and nextNode.id)
		)
		return false
	end

	local distanceToCurrent = Common.Distance2D(currentPos, currentNode.pos)
	local distanceToNext = Common.Distance2D(currentPos, nextNode.pos)

	if distanceToNext < distanceToCurrent then
		Log:Debug("Next node %d is closer (%.2f < %.2f)", nextNode.id, distanceToNext, distanceToCurrent)
		return true
	else
		Log:Debug(
			"Current node %d is closer or equal (%.2f >= %.2f)",
			currentNode.id,
			distanceToCurrent,
			distanceToNext
		)
		return false
	end
end

-- ========================================================================
-- WAYPOINT BUILDING
-- ========================================================================

-- Build waypoints from mixed area/door path
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
		local currentNode = path[i]
		local nextNode = path[i + 1]

		if currentNode and nextNode and currentNode.pos and nextNode.pos then
			-- Handle different node type transitions
			if currentNode.isDoor and nextNode.isDoor then
				-- Door to Door: move directly to next door position
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = currentNode.id,
					toId = nextNode.id,
					pos = nextNode.pos,
				})
			elseif not currentNode.isDoor and nextNode.isDoor then
				-- Area to Door: move to door position
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = currentNode.id,
					toId = nextNode.id,
					pos = nextNode.pos,
				})
			elseif currentNode.isDoor and not nextNode.isDoor then
				-- Door to Area: first move to door position, then to area center
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = currentNode.id,
					toId = nextNode.id,
					pos = currentNode.pos, -- Move to current door position first
				})
				table.insert(G.Navigation.waypoints, {
					pos = nextNode.pos,
					kind = "center",
					areaId = nextNode.id,
				})
			else
				-- Area to Area: move to next area center
				table.insert(G.Navigation.waypoints, {
					pos = nextNode.pos,
					kind = "center",
					areaId = nextNode.id,
				})
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

	-- FIXED: Reset timer when reaching ANY waypoint on path, not just center
	-- This ensures node skipping timer resets when reaching any point on the path
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Reset the node timer when we reach any waypoint
		Navigation.ResetTickTimer()
		-- Reset node skipping cooldowns when reaching waypoints
		-- SCRAPPED: Don't reset cooldowns on waypoint reach - let agent-based system run on its own schedule
		-- local NodeSkipper = require("MedBot.Bot.NodeSkipper")
		-- NodeSkipper.ResetWalkabilityCooldown()
		-- If we reached a center of the next area, advance the area path too
		-- if current.kind == "center" then
		-- 	-- path[1] is previous area; popping it moves us into the new area
		-- 	Navigation.RemoveCurrentNode()
		-- end
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

	-- FIXED: Reset timer when skipping ANY waypoints on path
	-- This ensures node skipping timer resets when skipping any points on the path
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Reset the node timer when we skip waypoints
		Navigation.ResetTickTimer()
		-- If we skip over a center, reflect area progression
		local current = G.Navigation.waypoints[G.Navigation.currentWaypointIndex or 1]
		if current and current.kind ~= "center" then
			for j = (G.Navigation.currentWaypointIndex or 1), math.min(idx - 1, #wpList) do
				if wpList[j].kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
					Navigation.RemoveCurrentNode()
				end
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

-- Get area at position using multi-point distance check (more precise than GetClosestNode)
---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetAreaAtPosition(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetAreaAtPosition")
		return nil
	end
	local n = Node.GetAreaAtPosition(pos)
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
		-- Reset node skipping agents for new path
		G.Navigation.skipAgents = nil
		-- Refresh waypoints to reflect current door usage
		Navigation.BuildDoorWaypointsFromPath()
		-- Apply PathOptimizer for menu-controlled optimization
		-- REMOVED: All path optimization now handled by NodeSkipper.CheckContinuousSkip
		-- Reset traversed-node history for new path
		G.Navigation.pathHistory = {}
	end

	return Navigation
end

return Navigation
