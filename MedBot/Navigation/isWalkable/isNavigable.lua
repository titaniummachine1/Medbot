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

-- Debug
local DEBUG_TRACES = false -- Disabled for production
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

-- Find where ray exits node bounds
-- Returns: exitPoint, exitDist, exitDir (1=N, 2=E, 3=S, 4=W)
local function findNodeExit(startPos, dir, node)
	Profiler.Begin("findNodeExit")
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
		Profiler.End("findNodeExit")
		return nil, nil, nil
	end

	Profiler.End("findNodeExit")
	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- MAIN FUNCTION - Trace to borders
function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors)
	Profiler.Begin("CanSkip")

	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	if DEBUG_TRACES then
		print(
			string.format(
				"[IsNavigable] START: From (%.1f, %.1f) to (%.1f, %.1f)",
				startPos.x,
				startPos.y,
				goalPos.x,
				goalPos.y
			)
		)
	end

	local currentPos = startPos
	local currentNode = startNode
	local iteration = 0
	local MAX_ITERATIONS = 20

	while iteration < MAX_ITERATIONS do
		Profiler.Begin("Iteration")
		iteration = iteration + 1

		-- Direction to goal from current position
		local toGoal = goalPos - currentPos
		local distToGoal = toGoal:Length()

		-- Normalize direction for navigation
		local dir = distToGoal > 0.001 and Common.Normalize(toGoal) or Vector3(1, 0, 0)

		if distToGoal < 50 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] SUCCESS: Within 50 units of goal"))
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return true
		end

		if DEBUG_TRACES then
			print(
				string.format(
					"[IsNavigable] Iter %d: node=%d, pos=(%.1f,%.1f), distToGoal=%.1f",
					iteration,
					currentNode.id,
					currentPos.x,
					currentPos.y,
					distToGoal
				)
			)
		end

		-- Check if goal is in current node (fast direct bounds check)
		Profiler.Begin("GoalCheck")
		local goalInCurrentNode = goalPos.x >= currentNode._minX
			and goalPos.x <= currentNode._maxX
			and goalPos.y >= currentNode._minY
			and goalPos.y <= currentNode._maxY
		Profiler.End("GoalCheck")

		if goalInCurrentNode then
			Profiler.Begin("FinalTrace")
			local finalTrace = TraceHull(
				currentPos + STEP_HEIGHT_Vector,
				goalPos + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID
			)
			Profiler.End("FinalTrace")

			if finalTrace.fraction > 0.99 then
				if DEBUG_TRACES then
					print("[IsNavigable] SUCCESS: Direct trace to goal in same node")
				end
				Profiler.End("Iteration")
				Profiler.End("CanSkip")
				return true
			else
				if DEBUG_TRACES then
					print(
						string.format("[IsNavigable] FAIL: Blocked at %.2f in same node as goal", finalTrace.fraction)
					)
				end
				Profiler.End("Iteration")
				Profiler.End("CanSkip")
				return false
			end
		end

		-- Find where we exit current node
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

		-- Trace to exit point
		Profiler.Begin("ExitTrace")
		local exitTrace = TraceHull(
			currentPos + STEP_HEIGHT_Vector,
			exitPoint + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
		)
		Profiler.End("ExitTrace")

		if exitTrace.fraction < 0.99 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: Hit obstacle at %.2f before border", exitTrace.fraction))
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return false
		end

		-- Find neighbor - ONLY check connections in exit direction
		Profiler.Begin("FindNeighbor")
		local neighborNode = nil
		local OVERLAP_TOLERANCE = 5.0

		if currentNode.c and currentNode.c[exitDir] then
			local dirData = currentNode.c[exitDir]
			if DEBUG_TRACES then
				print(
					string.format(
						"[IsNavigable] Checking dir %d: %d connections",
						exitDir,
						dirData.connections and #dirData.connections or 0
					)
				)
			end

			if dirData.connections then
				for i, connection in ipairs(dirData.connections) do
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
		local entryPos = Vector3(entryX, entryY, exitPoint.z)
		Profiler.End("EntryClamp")

		-- Ground snap at entry
		Profiler.Begin("GroundTrace")
		local groundTrace = TraceHull(
			entryPos + STEP_HEIGHT_Vector,
			entryPos - Vector3(0, 0, 100),
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,

		)
		Profiler.End("GroundTrace")

		-- TEMPORARY: Compare TraceLine vs TraceHull for ground
		Profiler.Begin("GroundTraceLine")
		local groundTraceLine = engine.TraceLine(
			entryPos + STEP_HEIGHT_Vector,
			entryPos - Vector3(0, 0, 100),
			MASK_PLAYERSOLID,
		)
		Profiler.End("GroundTraceLine")

		if groundTrace.fraction == 1 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No ground at entry to node %d", neighborNode.id))
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return false
		end

		if DEBUG_TRACES then
			print(string.format("[IsNavigable] Crossed to node %d", neighborNode.id))
		end

		currentPos = groundTrace.endpos
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
