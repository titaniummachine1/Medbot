-- Optimized Node-Based Path Validator for Door/Portal Skipping
-- Uses ray-AABB intersection and height interpolation instead of constant trace-downs
local Navigable = {}
local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local UP_VECTOR = Vector3(0, 0, 1)
local MAX_SURFACE_ANGLE = 45
local MAX_NODES_TO_SKIP = 10

-- Debug mode (set at load time)
local DEBUG_TRACES = false

-- Trace wrappers for debug
local TraceHullFunc
local TraceLineFunc

-- Debug storage
local hullTraces = {}
local lineTraces = {}
local currentTickLogged = -1

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		lineTraces = {}
		currentTickLogged = currentTick
	end
	local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask, filter)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos, tick = currentTick })
	return result
end

local function traceLineWrapper(startPos, endPos, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		lineTraces = {}
		currentTickLogged = currentTick
	end
	local result = engine.TraceLine(startPos, endPos, mask, filter)
	table.insert(lineTraces, { startPos = startPos, endPos = result.endpos, tick = currentTick })
	return result
end

if DEBUG_TRACES then
	TraceHullFunc = traceHullWrapper
	TraceLineFunc = traceLineWrapper
else
	TraceHullFunc = engine.TraceHull
	TraceLineFunc = engine.TraceLine
end

-- Filter function
local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

-- Get height at position within node using bilinear interpolation of corner heights
local function getHeightAtPositionInNode(pos, node)
	if not node.nw or not node.ne or not node.sw or not node.se then
		return node.pos.z
	end

	local x = math.max(0, math.min(1, (pos.x - node._minX) / (node._maxX - node._minX)))
	local y = math.max(0, math.min(1, (pos.y - node._minY) / (node._maxY - node._minY)))

	local topHeight = node.nw.z * (1 - x) + node.ne.z * x
	local bottomHeight = node.sw.z * (1 - x) + node.se.z * x

	return topHeight * (1 - y) + bottomHeight * y
end

-- Ray-AABB intersection for axis-aligned node
-- Returns: hit point (Vector3 or nil), distance, exit face (1=N, 2=S, 3=E, 4=W or nil)
local function rayAABBIntersect(rayOrigin, rayDir, node)
	local tmin = -math.huge
	local tmax = math.huge
	local exitFace = nil

	-- X axis
	if rayDir.x ~= 0 then
		local tx1 = (node._minX - rayOrigin.x) / rayDir.x
		local tx2 = (node._maxX - rayOrigin.x) / rayDir.x
		if tx1 > tx2 then
			tx1, tx2 = tx2, tx1
		end
		tmin = math.max(tmin, tx1)
		tmax = math.min(tmax, tx2)
		exitFace = (rayDir.x > 0) and 3 or 4 -- E or W
	elseif rayOrigin.x < node._minX or rayOrigin.x > node._maxX then
		return nil, 0, nil
	end

	-- Y axis
	if rayDir.y ~= 0 then
		local ty1 = (node._minY - rayOrigin.y) / rayDir.y
		local ty2 = (node._maxY - rayOrigin.y) / rayDir.y
		if ty1 > ty2 then
			ty1, ty2 = ty2, ty1
		end
		tmin = math.max(tmin, ty1)
		tmax = math.min(tmax, ty2)
		if tmin == ty1 then
			exitFace = (rayDir.y > 0) and 1 or 2 -- N or S
		end
	elseif rayOrigin.y < node._minY or rayOrigin.y > node._maxY then
		return nil, 0, nil
	end

	if tmax < 0 or tmin > tmax then
		return nil, 0, nil
	end

	local t = (tmin < 0) and tmax or tmin
	if t < 0 then
		return nil, 0, nil
	end

	return rayOrigin + rayDir * t, t, exitFace
end

-- Check if point is on valid connection between two nodes
local function isPointOnConnection(point, fromNode, toNode)
	if not fromNode.c then
		return false
	end

	for dirId, dir in pairs(fromNode.c) do
		if dir.connections then
			for _, conn in ipairs(dir.connections) do
				local targetId = type(conn) == "table" and conn.node or conn
				if targetId == toNode.id then
					-- Check if point is within door bounds if door exists
					if dir.door then
						local door = dir.door
						if
							point.x >= door.minX
							and point.x <= door.maxX
							and point.y >= door.minY
							and point.y <= door.maxY
						then
							return true
						end
					else
						-- No door, assume connection is at shared edge
						return true
					end
				end
			end
		end
	end
	return false
end

-- Normalize vector
local function Normalize(vec)
	return vec / vec:Length()
end

-- Main function: Check if we can skip from startPos to goalPos through connected nodes
function Navigable.CanSkip(startPos, goalPos, startNode)
	if not startNode then
		return false
	end

	local nodes = G.Navigation.nodes
	if not nodes then
		return false
	end

	-- Trace down at start to get initial ground height
	local startGroundTrace = TraceHullFunc(
		startPos + STEP_HEIGHT_Vector,
		startPos - MAX_FALL_DISTANCE_Vector,
		PLAYER_HULL.Min,
		PLAYER_HULL.Max,
		MASK_PLAYERSOLID,
		shouldHitEntity
	)
	local currentPos = startGroundTrace.endpos
	local currentNode = startNode
	local direction = Normalize(goalPos - startPos)

	for step = 1, MAX_NODES_TO_SKIP do
		-- Check if we reached goal node
		local goalNode = G.Navigation and G.Navigation.GetAreaAtPosition and G.Navigation.GetAreaAtPosition(goalPos)
		if not goalNode then
			-- Fallback: find node containing goalPos
			for _, node in pairs(nodes) do
				if
					not node.isDoor
					and goalPos.x >= node._minX
					and goalPos.x <= node._maxX
					and goalPos.y >= node._minY
					and goalPos.y <= node._maxY
				then
					goalNode = node
					break
				end
			end
		end

		if currentNode == goalNode then
			-- Final trace to goal
			local distToGoal = (currentPos - goalPos):Length()
			if distToGoal < 1 then
				return true
			end

			local finalTrace = TraceHullFunc(
				currentPos + STEP_HEIGHT_Vector,
				goalPos + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)
			return finalTrace.fraction > 0.9
		end

		-- Find exit point from current node
		local exitPoint, dist, exitFace = rayAABBIntersect(currentPos, direction, currentNode)
		if not exitPoint then
			return false
		end

		-- Get interpolated height at exit point
		local exitHeight = getHeightAtPositionInNode(exitPoint, currentNode)
		local exitPos = Vector3(exitPoint.x, exitPoint.y, exitHeight)

		-- Trace forward to exit point
		local forwardTrace = TraceHullFunc(
			currentPos + STEP_HEIGHT_Vector,
			exitPos + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)

		if forwardTrace.fraction < 1.0 then
			return false -- Blocked
		end

		-- Find which node we're entering through the connection
		local nextNode = nil
		if currentNode.c then
			for dirId, dir in pairs(currentNode.c) do
				if dir.connections then
					for _, conn in ipairs(dir.connections) do
						local targetId = type(conn) == "table" and conn.node or conn
						local targetNode = nodes[targetId]
						if targetNode and not targetNode.isDoor then
							-- Check if exit point is on this connection
							if isPointOnConnection(exitPos, currentNode, targetNode) then
								nextNode = targetNode
								break
							end
						end
					end
				end
				if nextNode then
					break
				end
			end
		end

		if not nextNode then
			return false -- No valid connection
		end

		-- Trace down at entry point of new node to validate ground
		local entryGroundTrace = TraceHullFunc(
			exitPos + STEP_HEIGHT_Vector,
			exitPos - MAX_FALL_DISTANCE_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)

		if entryGroundTrace.fraction == 1.0 then
			return false -- No ground
		end

		-- Update position and node
		currentPos = entryGroundTrace.endpos
		currentNode = nextNode
		direction = Normalize(goalPos - currentPos)
	end

	return false -- Exceeded max nodes
end

-- Debug visualization
function Navigable.DrawDebugTraces()
	if not DEBUG_TRACES then
		return
	end

	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end

	for _, trace in ipairs(lineTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(255, 255, 255, 255)
			local w2s_start = client.WorldToScreen(trace.startPos)
			local w2s_end = client.WorldToScreen(trace.endPos)
			if w2s_start and w2s_end then
				draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
			end
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_TRACES = enabled
end

return Navigable
