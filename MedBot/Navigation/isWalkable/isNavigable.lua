--[[
    Grid Traversal Path Validator (Amanatides & Woo adapted for NavMesh)
    Steps through nodes mathematically, checking only boundaries
]]
local Navigable = {}
local G = require("MedBot.Core.Globals")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_ITERATIONS = 15

-- Direction mappings
local DIR = { N = 1, S = 2, E = 3, W = 4 }

-- Debug
local DEBUG_TRACES = true
local hullTraces = {}
local currentTickLogged = -1

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		currentTickLogged = currentTick
	end
	local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask, filter)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

local TraceHull = DEBUG_TRACES and traceHullWrapper or engine.TraceHull

local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

-- Find which wall of node the ray hits first
-- Returns: distance (t), intersectPos, dirId (1=N, 2=S, 3=E, 4=W)
local function getNodeExit(startPos, dir, node)
	local tMin = math.huge
	local exitDir = nil
	local tolerance = 2 -- Small tolerance for bounds checks

	-- Check X planes (West/East walls)
	if dir.x ~= 0 then
		local wallX = (dir.x > 0) and node._maxX or node._minX
		local tX = (wallX - startPos.x) / dir.x

		if tX > 0.001 and tX < tMin then
			local hitY = startPos.y + dir.y * tX
			if hitY >= (node._minY - tolerance) and hitY <= (node._maxY + tolerance) then
				tMin = tX
				exitDir = (dir.x > 0) and DIR.E or DIR.W
			end
		end
	end

	-- Check Y planes (South/North walls)
	if dir.y ~= 0 then
		local wallY = (dir.y > 0) and node._maxY or node._minY
		local tY = (wallY - startPos.y) / dir.y

		if tY > 0.001 and tY < tMin then
			local hitX = startPos.x + dir.x * tY
			if hitX >= (node._minX - tolerance) and hitX <= (node._maxX + tolerance) then
				tMin = tY
				exitDir = (dir.y > 0) and DIR.N or DIR.S
			end
		end
	end

	if tMin == math.huge then
		return nil, nil, nil
	end

	local intersectPos = startPos + (dir * tMin)
	return tMin, intersectPos, exitDir
end

-- Check if intersection point lies within neighbor bounds on cross-axis
local function isInsidePortal(intersectPos, dirId, neighborNode)
	if dirId == DIR.E or dirId == DIR.W then
		return intersectPos.y >= neighborNode._minY and intersectPos.y <= neighborNode._maxY
	else
		return intersectPos.x >= neighborNode._minX and intersectPos.x <= neighborNode._maxX
	end
end

-- Find neighbor node in given direction
local function getNeighborInDirection(node, dirId, nodes)
	if not node.c or not node.c[dirId] then
		return nil
	end

	local dirData = node.c[dirId]
	if not dirData.connections then
		return nil
	end

	for _, conn in ipairs(dirData.connections) do
		local targetId = type(conn) == "table" and conn.node or conn
		local targetNode = nodes[targetId]
		if targetNode and not targetNode.isDoor then
			return targetNode
		end
	end

	return nil
end

-- Check if position is inside node bounds (horizontal only)
local function isInNode(pos, node)
	assert(node, "isInNode: node required")
	assert(node._minX, "isInNode: node missing bounds")
	assert(node._minY, "isInNode: node missing bounds")
	assert(node._maxX, "isInNode: node missing bounds")
	assert(node._maxY, "isInNode: node missing bounds")

	return pos.x >= node._minX and pos.x <= node._maxX and pos.y >= node._minY and pos.y <= node._maxY
end

-- MAIN FUNCTION
function Navigable.CanSkip(startPos, goalPos, startNode)
	assert(startNode, "CanSkip: startNode required")
	assert(startNode.c, "CanSkip: startNode has no connections")
	assert(startNode._minX, "CanSkip: startNode missing bounds")

	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	if not nodes then
		return false
	end

	-- Clamp startPos to be inside node bounds (with small margin)
	local currentPos = Vector3(
		math.max(startNode._minX + 1, math.min(startNode._maxX - 1, startPos.x)),
		math.max(startNode._minY + 1, math.min(startNode._maxY - 1, startPos.y)),
		startPos.z
	)

	local currentNode = startNode
	local visited = {}

	for i = 1, MAX_ITERATIONS do
		if visited[currentNode.id] then
			return false
		end
		visited[currentNode.id] = true

		-- Recalculate direction from current position to goal
		local toGoal = goalPos - currentPos
		local totalDist = toGoal:Length()

		if totalDist < 1 then
			return true
		end

		local dir = toGoal / totalDist

		-- Check if goal is inside current node
		if isInNode(goalPos, currentNode) then
			local trace = TraceHull(
				currentPos + STEP_HEIGHT_Vector,
				goalPos + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)
			return trace.fraction > 0.99
		end

		-- Get exit point from current node
		local t, exitPoint, exitDir = getNodeExit(currentPos, dir, currentNode)

		if not t then
			local distToGoal = (goalPos - currentPos):Length()
			if distToGoal < totalDist * 0.1 then
				local trace = TraceHull(
					currentPos + STEP_HEIGHT_Vector,
					goalPos + STEP_HEIGHT_Vector,
					PLAYER_HULL.Min,
					PLAYER_HULL.Max,
					MASK_PLAYERSOLID,
					shouldHitEntity
				)
				return trace.fraction > 0.99
			end
			print(
				string.format(
					"[IsNavigable] FAIL: No exit found from node %d at (%.1f, %.1f, %.1f) towards (%.1f, %.1f, %.1f)",
					currentNode.id,
					currentPos.x,
					currentPos.y,
					currentPos.z,
					goalPos.x,
					goalPos.y,
					goalPos.z
				)
			)
			return false
		end

		-- Check if goal is closer than the wall
		local distToExit = (exitPoint - currentPos):Length()
		local distToGoal = (goalPos - currentPos):Length()

		if distToExit >= distToGoal then
			local trace = TraceHull(
				currentPos + STEP_HEIGHT_Vector,
				goalPos + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)
			return trace.fraction > 0.99
		end

		-- Find neighbor in exit direction
		local neighborNode = getNeighborInDirection(currentNode, exitDir, nodes)

		if not neighborNode then
			print(
				string.format(
					"[IsNavigable] FAIL: No neighbor in direction %d from node %d at exit (%.1f, %.1f)",
					exitDir,
					currentNode.id,
					exitPoint.x,
					exitPoint.y
				)
			)
			return false
		end

		-- Verify portal overlap
		if not isInsidePortal(exitPoint, exitDir, neighborNode) then
			print(
				string.format(
					"[IsNavigable] FAIL: Exit point (%.1f, %.1f) not inside portal to neighbor %d",
					exitPoint.x,
					exitPoint.y,
					neighborNode.id
				)
			)
			return false
		end

		-- Trace within current node to exit point (check for obstacles)
		local wallTrace = TraceHull(
			currentPos + STEP_HEIGHT_Vector,
			exitPoint + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)

		if wallTrace.fraction < 0.99 then
			print(
				string.format(
					"[IsNavigable] FAIL: Hit obstacle at fraction %.2f in node %d before reaching portal",
					wallTrace.fraction,
					currentNode.id
				)
			)
			return false
		end

		-- Project exitPoint to closest point on neighbor's border
		-- This is the entry point into the neighbor node
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))
		local entryPos = Vector3(entryX, entryY, exitPoint.z)

		-- Trace down at entry point to find ground height
		local groundTrace = TraceHull(
			entryPos + STEP_HEIGHT_Vector,
			entryPos - Vector3(0, 0, 100),
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)

		if groundTrace.fraction == 1 then
			print(
				string.format(
					"[IsNavigable] FAIL: No ground found at entry (%.1f, %.1f) into node %d - gap/cliff",
					entryPos.x,
					entryPos.y,
					neighborNode.id
				)
			)
			return false
		end

		-- Update position to grounded entry point and advance to neighbor
		currentPos = groundTrace.endpos
		currentNode = neighborNode

		-- Continue loop - will recalculate direction and find next exit
	end

	print(
		string.format(
			"[IsNavigable] FAIL: Max iterations (%d) exceeded, stopped at node %d",
			MAX_ITERATIONS,
			currentNode.id
		)
	)
	return false
end

-- Debug
function Navigable.DrawDebugTraces()
	if not DEBUG_TRACES then
		return
	end
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			local Common = require("MedBot.Core.Common")
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_TRACES = enabled
end

return Navigable
