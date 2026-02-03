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
local profilerLoaded, Profiler = pcall(require, "Profiler")
if not profilerLoaded then
	-- Profiler not available, create dummy functions
	Profiler = {
		Begin = function() end,
		End = function() end,
		SetVisible = function() end,
		SetContext = function() end,
		Draw = function() end,
	}
end

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
local DEBUG_TRACES = true -- Disabled for production
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

local TraceHull = DEBUG_TRACES and traceHullWrapper or engine.TraceHull

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Common.Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)
	direction.z = direction.z - surfaceNormal.z * dotProduct

	return Common.Normalize(direction)
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

-- MAIN FUNCTION - Two-phase: verify path, then trace
function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors)
	Profiler.Begin("CanSkip")

	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	-- ============ PHASE 1: Verify path through nodes ============
	Profiler.Begin("VerifyPath")

	local currentPos = startPos
	local currentNode = startNode
	local waypoints = {} -- Waypoints for Phase 2

	-- Get starting ground Z
	local startZ, startNormal = getGroundZFromQuad(startPos, startNode)
	if startZ then
		currentPos = Vector3(startPos.x, startPos.y, startZ)
	end

	-- Add start waypoint
	table.insert(waypoints, {
		pos = currentPos,
		node = startNode,
		normal = startNormal
	})

	-- Traverse to destination (no traces - just verify path exists)
	for iteration = 1, MAX_ITERATIONS do
		-- Check if goal reached
		local goalInNode = goalPos.x >= currentNode._minX and goalPos.x <= currentNode._maxX
			and goalPos.y >= currentNode._minY and goalPos.y <= currentNode._maxY

		if goalInNode then
			-- Add goal as final waypoint
			table.insert(waypoints, {
				pos = goalPos,
				node = currentNode,
				normal = nil
			})
			Profiler.End("VerifyPath")
			break
		end
			-- Calculate surface-aligned direction for final trace
			local toGoal = goalPos - lastTraceEnd
			local horizDir = Vector3(toGoal.x, toGoal.y, 0)
			horizDir = Common.Normalize(horizDir)

			-- Get ground normal at last trace position
			local groundZ, groundNormal = getGroundZFromQuad(lastTraceEnd, currentNode)

			-- Adjust direction to follow surface - only Z changes
			local traceDir = horizDir
			if groundNormal then
				traceDir = adjustDirectionToSurface(horizDir, groundNormal)
			end

			-- Calculate trace end point along surface-aligned direction
			local traceDist = (goalPos - lastTraceEnd):Length()
			local traceEnd = lastTraceEnd + traceDir * traceDist

			-- Trace from last trace end to destination along surface
			Profiler.Begin("FinalTrace")
			local finalTrace = TraceHull(
				lastTraceEnd + STEP_HEIGHT_Vector,
				traceEnd + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_SHOT_HULL
			)
			Profiler.End("FinalTrace")
			if finalTrace.fraction < 0.99 then
				if DEBUG_TRACES then
					print("[IsNavigable] FAIL: Entity blocking path to destination")
				end
				Profiler.End("Iteration")
				Profiler.End("CanSkip")
				return false
			end

			-- Reached destination node - traversal successful
			if DEBUG_TRACES then
				print(
					string.format(
						"[IsNavigable] SUCCESS: Reached destination node (hills=%d, caves=%d)",
						#hills,
						#caves
					)
				)
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return true
		end

		-- Find where we exit current node toward goal
		local toGoal = goalPos - currentPos
		-- Horizontal direction to destination (only X/Y matters for heading)
		local horizDir = Vector3(toGoal.x, toGoal.y, 0)
		horizDir = Common.Normalize(horizDir)

		-- Get ground normal at current position
		local groundZ, groundNormal = getGroundZFromQuad(currentPos, currentNode)

		-- Adjust direction to follow surface - only Z changes based on slope
		local dir = horizDir
		if groundNormal then
			dir = adjustDirectionToSurface(horizDir, groundNormal)
		end

		Profiler.Begin("FindExit")
		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, dir, currentNode)
		Profiler.End("FindExit")

		if not exitPoint or not exitDir then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return false
		end

		if DEBUG_TRACES then
			local dirNames = { [1] = "N", [2] = "E", [3] = "S", [4] = "W" }
			print(
				string.format(
					"[IsNavigable] Exit via %s at (%.1f, %.1f)",
					dirNames[exitDir] or "?",
					exitPoint.x,
					exitPoint.y
				)
			)
		end

		-- No trace to exit - we trust navmesh is walkable

		-- Find neighbor - optimized linear search from appropriate end
		Profiler.Begin("FindNeighbor")
		local neighborNode = nil
		local OVERLAP_TOLERANCE = 5.0

		if currentNode.c and currentNode.c[exitDir] then
			local dirData = currentNode.c[exitDir]

			if dirData.connections then
				local connCount = #dirData.connections

				-- Determine search direction: if exit near min boundary, search forward; if near max, search backward
				local searchForward = true
				if exitDir == 2 or exitDir == 4 then -- East/West (X axis)
					local midX = (currentNode._minX + currentNode._maxX) * 0.5
					searchForward = exitPoint.x < midX
				else -- North/South (Y axis)
					local midY = (currentNode._minY + currentNode._maxY) * 0.5
					searchForward = exitPoint.y < midY
				end

				-- Search connections from appropriate end
				local start, finish, step = 1, connCount, 1
				if not searchForward then
					start, finish, step = connCount, 1, -1
				end

				for i = start, finish, step do
					local connection = dirData.connections[i]
					local targetId = (type(connection) == "table") and (connection.node or connection.id) or connection
					local candidate = nodes[targetId]

					if candidate and candidate._minX and candidate._maxX and candidate._minY and candidate._maxY then
						-- Area node - check bounds overlap (optionally using door bounds)
						local checkNode = candidate

						if respectDoors then
							-- Find door between currentNode and candidate
							for _, conn in ipairs(dirData.connections) do
								local tid = (type(conn) == "table") and (conn.node or conn.id) or conn
								local door = nodes[tid]
								if door and not door._minX and door.c then
									-- Door found, check if it connects to candidate
									for _, ddir in pairs(door.c) do
										if ddir.connections then
											for _, dconn in ipairs(ddir.connections) do
												local did = (type(dconn) == "table") and (dconn.node or dconn.id)
													or dconn
												if did == candidate.id then
													checkNode = door
													break
												end
											end
										end
										if checkNode == door then
											break
										end
									end
									if checkNode == door then
										break
									end
								end
							end
						end

						local inX = exitPoint.x >= (checkNode._minX - OVERLAP_TOLERANCE)
							and exitPoint.x <= (checkNode._maxX + OVERLAP_TOLERANCE)
						local inY = exitPoint.y >= (checkNode._minY - OVERLAP_TOLERANCE)
							and exitPoint.y <= (checkNode._maxY + OVERLAP_TOLERANCE)

						if DEBUG_TRACES then
							print(
								string.format(
									"[IsNavigable] Check area=%d via %s, inX=%s, inY=%s",
									candidate.id,
									(checkNode == candidate and "area" or "door"),
									tostring(inX),
									tostring(inY)
								)
							)
						end

						if inX and inY then
							neighborNode = candidate
							if DEBUG_TRACES then
								print(string.format("[IsNavigable] Found neighbor area %d", candidate.id))
							end
							break
						end
					elseif candidate then
						-- Door node - traverse through to find area on other side
						if DEBUG_TRACES then
							print(
								string.format("[IsNavigable]   Conn %d: Door %s, traversing...", i, tostring(targetId))
							)
						end

						if candidate.c then
							for _, doorDirData in pairs(candidate.c) do
								if doorDirData.connections then
									for _, doorConn in ipairs(doorDirData.connections) do
										local areaId = (type(doorConn) == "table") and (doorConn.node or doorConn.id)
											or doorConn
										local areaNode = nodes[areaId]

										if areaId ~= currentNode.id and areaNode and areaNode._minX then
											local inX = exitPoint.x >= (areaNode._minX - OVERLAP_TOLERANCE)
												and exitPoint.x <= (areaNode._maxX + OVERLAP_TOLERANCE)
											local inY = exitPoint.y >= (areaNode._minY - OVERLAP_TOLERANCE)
												and exitPoint.y <= (areaNode._maxY + OVERLAP_TOLERANCE)

											if DEBUG_TRACES then
												print(
													string.format(
														"[IsNavigable]     Door leads to area=%d, inX=%s, inY=%s",
														areaId,
														tostring(inX),
														tostring(inY)
													)
												)
											end

											if inX and inY then
												neighborNode = areaNode
												if DEBUG_TRACES then
													print(
														string.format(
															"[IsNavigable] Found neighbor area %d via door",
															areaNode.id
														)
													)
												end
												break
											end
										end
									end
									if neighborNode then
										break
									end
								end
								if neighborNode then
									break
								end
							end
						end
					end
				end
			end
		else
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] No connections in exit direction %d", exitDir))
			end
		end

		Profiler.End("FindNeighbor")

		if not neighborNode then
			if DEBUG_TRACES then
				print(
					string.format(
						"[IsNavigable] FAIL: No neighbor found at exit (%.1f, %.1f)",
						exitPoint.x,
						exitPoint.y
					)
				)
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return false
		end

		-- Entry point is exitPoint clamped to neighbor bounds
		Profiler.Begin("EntryClamp")
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))
		Profiler.End("EntryClamp")

		-- Ground snap using quad geometry (no engine call)
		Profiler.Begin("GroundCalc")
		local groundZ, groundNormal = getGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)
		Profiler.End("GroundCalc")

		if not groundZ then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No ground geometry at entry to node %d", neighborNode.id))
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return false
		end

		local entryPos = Vector3(entryX, entryY, groundZ)

		-- Track elevation changes for hill/cave detection
		local heightDiff = groundZ - lastHeight

		if heightDiff > HILL_THRESHOLD then
			-- Climbing - track highest point
			if not lastWasClimbing then
				-- Started climbing - trace from last trace end to this point along surface
				local toTarget = currentPos - lastTraceEnd
				local horizDir = Vector3(toTarget.x, toTarget.y, 0)
				horizDir = Common.Normalize(horizDir)

				-- Get ground normal and adjust direction
				local _, surfNormal = getGroundZFromQuad(lastTraceEnd, currentNode)
				local traceDir = horizDir
				if surfNormal then
					traceDir = adjustDirectionToSurface(horizDir, surfNormal)
				end

				-- Calculate surface-aligned trace target
				local traceDist = (currentPos - lastTraceEnd):Length()
				local traceTarget = lastTraceEnd + traceDir * traceDist

				Profiler.Begin("StartToHillTrace")
				local startTrace = TraceHull(
					lastTraceEnd + STEP_HEIGHT_Vector,
					traceTarget + STEP_HEIGHT_Vector,
					PLAYER_HULL.Min,
					PLAYER_HULL.Max,
					MASK_SHOT_HULL
				)
				Profiler.End("StartToHillTrace")
				if startTrace.fraction < 0.99 then
					if DEBUG_TRACES then
						print(string.format("[IsNavigable] FAIL: Entity blocking path to hill"))
					end
					Profiler.End("Iteration")
					Profiler.End("CanSkip")
					return false
				end
				lastTraceEnd = currentPos - STEP_HEIGHT_Vector
				lastWasClimbing = true
			end
			if groundZ > highestHeight then
				highestHeight = groundZ
			end
		elseif heightDiff < -HILL_THRESHOLD then
			-- Descending
			if lastWasClimbing and highestHeight > lastHeight + HILL_THRESHOLD then
				-- Was climbing and now descending - save hill peak
				local hillPeak = Vector3(currentPos.x, currentPos.y, highestHeight)
				table.insert(hills, hillPeak)
				if DEBUG_TRACES then
					print(string.format("[IsNavigable] Hill detected at Z=%.1f", highestHeight))
				end
				lastTraceEnd = hillPeak
			end
			lastWasClimbing = false

			-- Check if descending into cave
			if lastHeight - groundZ > HILL_THRESHOLD then
				local cavePoint = Vector3(entryX, entryY, groundZ)
				-- Trace from last trace end to this cave along surface
				local toCave = cavePoint - lastTraceEnd
				local caveHorizDir = Vector3(toCave.x, toCave.y, 0)
				caveHorizDir = Common.Normalize(caveHorizDir)

				-- Get ground normal and adjust direction
				local _, caveNormal = getGroundZFromQuad(lastTraceEnd, currentNode)
				local caveTraceDir = caveHorizDir
				if caveNormal then
					caveTraceDir = adjustDirectionToSurface(caveHorizDir, caveNormal)
				end

				-- Calculate surface-aligned cave trace target
				local caveTraceDist = (cavePoint - lastTraceEnd):Length()
				local caveTraceTarget = lastTraceEnd + caveTraceDir * caveTraceDist

				Profiler.Begin("HillToCaveTrace")
				local caveTrace = TraceHull(
					lastTraceEnd + STEP_HEIGHT_Vector,
					caveTraceTarget + STEP_HEIGHT_Vector,
					PLAYER_HULL.Min,
					PLAYER_HULL.Max,
					MASK_SHOT_HULL
				)
				Profiler.End("HillToCaveTrace")
				if caveTrace.fraction < 0.99 then
					if DEBUG_TRACES then
						print(
							string.format(
								"[IsNavigable] FAIL: Entity blocking path to cave at %.2f",
								caveTrace.fraction
							)
						)
					end
					Profiler.End("Iteration")
					Profiler.End("CanSkip")
					return false
				end
				lastTraceEnd = cavePoint - STEP_HEIGHT_Vector
				table.insert(caves, cavePoint)
				if DEBUG_TRACES then
					print(string.format("[IsNavigable] Cave detected at Z=%.1f", groundZ))
				end
			end
		end

		lastHeight = groundZ

		if DEBUG_TRACES then
			print(string.format("[IsNavigable] Crossed to node %d (Z=%.1f)", neighborNode.id, groundZ))
		end

		currentPos = entryPos
		currentNode = neighborNode
		Profiler.End("Iteration")
	end

	if DEBUG_TRACES then
		print(string.format("[IsNavigable] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
	end
	Profiler.End("CanSkip")

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
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_TRACES = enabled
end

return Navigable
