--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]

local vectordivide = vector.Divide
local vectorLength = vector.Length

local Navigable = {}
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local FORWARD_STEP = 100 -- Max distance per forward trace
local HILL_THRESHOLD = 4 -- 0.5x step height for significant elevation changes

local MaxSpeed = 450
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval()
local MAX_SURFACE_ANGLE = 55
local MAX_ITERATIONS = 37

-- Debug
local DEBUG_MODE = false -- Set to true for debugging (enables traces)
local hullTraces = {}
local currentTickLogged = -1

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		currentTickLogged = currentTick
	end
	local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

local TraceHull = DEBUG_MODE and traceHullWrapper or engine.TraceHull

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Common.Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	-- Project horizontal direction onto sloped surface
	-- 1. Get right vector perpendicular to horizontal direction
	local right = direction:Cross(UP_VECTOR)
	if right:Length() < 0.0001 then
		-- Direction is straight up/down, return as-is
		return direction
	end
	right = Common.Normalize(right)

	-- 2. Get forward direction on surface (perpendicular to both right and surface normal)
	local forward = right:Cross(surfaceNormal)
	forward = Common.Normalize(forward)

	-- 3. Ensure forward points in same general direction as input
	if forward:Dot(direction) < 0 then
		forward = forward * -1
	end

	return forward
end

-- Find where ray exits node bounds
-- Returns: exitPoint, exitDist, exitDir (1=N, 2=E, 3=S, 4=W)
local function findNodeExit(startPos, dir, node)
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY
	local exitDir = nil

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
			exitDir = 2 -- East
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
			exitDir = 4 -- West
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
			exitDir = 3 -- South
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
			exitDir = 1 -- North
		end
	end

	if tMin == math.huge then
		return nil, nil, nil
	end
	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- Find neighbor area at exit point
local function getNeighborAreaAtExit(exitDir, currentNode, nodes)
	if not currentNode.c or not currentNode.c[exitDir] then
		print(string.format("[IsNavigable] No connections in direction %d from node %d", exitDir, currentNode.id))
		return nil
	end

	local dirData = currentNode.c[exitDir]
	if not dirData.connections then
		print(string.format("[IsNavigable] No connections array in direction %d from node %d", exitDir, currentNode.id))
		return nil
	end

	print(
		string.format(
			"[IsNavigable] Checking %d connections in direction %d from node %d",
			#dirData.connections,
			exitDir,
			currentNode.id
		)
	)

	for i = 1, #dirData.connections do
		local conn = dirData.connections[i]
		local targetId = (type(conn) == "table") and (conn.node or conn.id) or conn
		local candidate = nodes[targetId]

		if candidate and candidate._minX and candidate._maxX and candidate._minY and candidate._maxY then
			print(string.format("[IsNavigable] Found neighbor area %d", candidate.id))
			return candidate
		else
			print(string.format("[IsNavigable] Connection %d: %s is not a valid area node", i, tostring(targetId)))
		end
	end

	print(string.format("[IsNavigable] No valid area neighbors in direction %d from node %d", exitDir, currentNode.id))
	return nil
end

-- Calculate ground Z position from node quad geometry (no engine call)
local function getGroundZFromQuad(pos, node)
	if not (node.nw and node.ne and node.sw and node.se) then
		return nil, nil
	end

	local nw, ne, sw, se = node.nw, node.ne, node.sw, node.se

	-- Determine which triangle contains the point
	-- Split quad into: Triangle1(nw,ne,se) and Triangle2(nw,se,sw)
	local dx = pos.x - nw.x
	local dy = pos.y - nw.y
	local dx_ne = ne.x - nw.x
	local dy_se = se.y - nw.y

	local inTriangle1 = (dx / dx_ne + dy / dy_se) <= 1.0

	local v0, v1, v2
	if inTriangle1 then
		-- Triangle: nw, ne, se
		v0, v1, v2 = nw, ne, se
	else
		-- Triangle: nw, se, sw
		v0, v1, v2 = nw, se, sw
	end

	-- Barycentric interpolation for Z
	local denom = (v1.y - v2.y) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.y - v2.y)
	if math.abs(denom) < 0.0001 then
		return v0.z, Vector3(0, 0, 1) -- Degenerate triangle, use first vertex
	end

	local w0 = ((v1.y - v2.y) * (pos.x - v2.x) + (v2.x - v1.x) * (pos.y - v2.y)) / denom
	local w1 = ((v2.y - v0.y) * (pos.x - v2.x) + (v0.x - v2.x) * (pos.y - v2.y)) / denom
	local w2 = 1.0 - w0 - w1

	local z = w0 * v0.z + w1 * v1.z + w2 * v2.z

	-- Calculate normal from cross product
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local normal = edge1:Cross(edge2)
	normal = Common.Normalize(normal)
	if not normal then
		normal = Vector3(0, 0, 1)
	end

	return z, normal
end

-- MAIN FUNCTION - Two phases: 1) validate path through nodes, 2) trace with surface pitch
function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors)
	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	-- ============ PHASE 1: Validate path through nodes ============
	local currentPos = startPos
	local currentNode = startNode
	local waypoints = {}

	-- Add start waypoint
	table.insert(waypoints, {
		pos = currentPos,
		node = startNode,
		normal = nil,
	})

	-- Traverse node path (MAX_ITERATIONS prevents infinite loops)
	for iteration = 1, MAX_ITERATIONS do
		-- Get horizontal direction to goal
		local toGoal = goalPos - currentPos
		local horizDir = Vector3(toGoal.x, toGoal.y, 0)
		horizDir = Common.Normalize(horizDir)

		-- Find exit point from current node
		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, horizDir, currentNode)
		if not exitPoint or not exitDir then
			print(
				string.format(
					"[IsNavigable] FAIL: No exit found from node %d at (%.1f, %.1f, %.1f)",
					currentNode.id,
					currentPos.x,
					currentPos.y,
					currentPos.z
				)
			)
			return false
		end

		print(
			string.format(
				"[IsNavigable] Exit via %s at (%.1f, %.1f) from node %d",
				({ [1] = "N", [2] = "E", [3] = "S", [4] = "W" })[exitDir],
				exitPoint.x,
				exitPoint.y,
				currentNode.id
			)
		)

		-- Find neighbor area at exit point
		local neighborNode = getNeighborAreaAtExit(exitDir, currentNode, nodes)
		if not neighborNode then
			return false
		end

		-- Calculate entry position in neighbor node
		local entryX = math.max(neighborNode._minX, math.min(neighborNode._maxX, exitPoint.x))
		local entryY = math.max(neighborNode._minY, math.min(neighborNode._maxY, exitPoint.y))
		local groundZ, groundNormal = getGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)

		if not groundZ then
			return false
		end

		local entryPos = Vector3(entryX, entryY, groundZ)

		-- Add waypoint
		table.insert(waypoints, {
			pos = entryPos,
			node = neighborNode,
			normal = groundNormal,
		})

		-- Check if goal reached
		if
			neighborNode._minX <= goalPos.x
			and goalPos.x <= neighborNode._maxX
			and neighborNode._minY <= goalPos.y
			and goalPos.y <= neighborNode._maxY
		then
			break
		end

		currentPos = entryPos
		currentNode = neighborNode
	end

	-- Add goal as final waypoint
	table.insert(waypoints, {
		pos = goalPos,
		node = currentNode,
		normal = nil,
	})
	return true
end

-- Debug
function Navigable.DrawDebugTraces()
	if not DEBUG_MODE then
		return
	end
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_MODE = enabled
end

return Navigable
