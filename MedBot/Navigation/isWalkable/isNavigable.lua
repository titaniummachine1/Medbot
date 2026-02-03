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

-- Find where ray exits node bounds
local function findNodeExit(startPos, dir, node)
	Profiler.Begin("findNodeExit")
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
		end
	end

	if tMin == math.huge then
		Profiler.End("findNodeExit")
		return nil
	end

	Profiler.End("findNodeExit")
	return Vector3(exitX, exitY, startPos.z), tMin
end

-- MAIN FUNCTION - Trace to borders
function Navigable.CanSkip(startPos, goalPos, startNode)
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
				MASK_PLAYERSOLID,
				shouldHitEntity
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
		local exitPoint, exitDist = findNodeExit(currentPos, dir, currentNode)
		Profiler.End("FindExit")

		if not exitPoint then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			Profiler.End("Iteration")
			Profiler.End("CanSkip")
			return false
		end

		-- Trace to exit point
		Profiler.Begin("ExitTrace")
		local exitTrace = TraceHull(
			currentPos + STEP_HEIGHT_Vector,
			exitPoint + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
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

		-- Determine primary and secondary exit directions (for corner exits)
		local tolerance = 5.0
		local exitDirs = {}

		-- Check distance to each edge
		local distNorth = math.abs(exitPoint.y - currentNode._maxY)
		local distEast = math.abs(exitPoint.x - currentNode._maxX)
		local distSouth = math.abs(exitPoint.y - currentNode._minY)
		local distWest = math.abs(exitPoint.x - currentNode._minX)

		-- Add edges within tolerance as candidates
		if distNorth < tolerance then
			table.insert(exitDirs, { dir = 1, dist = distNorth, name = "NORTH" })
		end
		if distEast < tolerance then
			table.insert(exitDirs, { dir = 2, dist = distEast, name = "EAST" })
		end
		if distSouth < tolerance then
			table.insert(exitDirs, { dir = 3, dist = distSouth, name = "SOUTH" })
		end
		if distWest < tolerance then
			table.insert(exitDirs, { dir = 4, dist = distWest, name = "WEST" })
		end

		-- Sort by closest first
		table.sort(exitDirs, function(a, b)
			return a.dist < b.dist
		end)

		local primaryDir = exitDirs[1]
		local secondaryDir = exitDirs[2]

		if DEBUG_TRACES then
			if primaryDir then
				print(string.format("[IsNavigable] Primary exit: %s (dist=%.1f)", primaryDir.name, primaryDir.dist))
			end
			if secondaryDir then
				print(
					string.format("[IsNavigable] Secondary exit: %s (dist=%.1f)", secondaryDir.name, secondaryDir.dist)
				)
			end
		end

		-- Find neighbor node - try primary direction first, then secondary
		Profiler.Begin("FindNeighbor")
		local neighborNode = nil
		local foundVia = nil

		-- Helper function to check connections in a direction
		local function checkDirection(exitDir)
			if not exitDir or not currentNode.c or not currentNode.c[exitDir.dir] then
				if DEBUG_TRACES then
					print(
						string.format("[IsNavigable] No connections in %s direction", exitDir and exitDir.name or "nil")
					)
				end
				return nil
			end

			local dirData = currentNode.c[exitDir.dir]
			if not dirData.connections then
				if DEBUG_TRACES then
					print(string.format("[IsNavigable] No connections data in %s", exitDir.name))
				end
				return nil
			end

			if DEBUG_TRACES then
				print(
					string.format(
						"[IsNavigable] Checking %d connections in %s direction",
						#dirData.connections,
						exitDir.name
					)
				)
			end

			for i, connection in ipairs(dirData.connections) do
				if DEBUG_TRACES then
					print(
						string.format(
							"[IsNavigable]   Conn %d RAW: type=%s, connection.node=%s, connection.id=%s",
							i,
							type(connection),
							tostring(connection.node),
							tostring(connection.id)
						)
					)
					if type(connection) == "table" then
						local keys = {}
						for k, v in pairs(connection) do
							table.insert(keys, k .. "=" .. tostring(v))
						end
						print(string.format("[IsNavigable]     Keys: %s", table.concat(keys, ", ")))
					end
				end

				local targetId = connection.node or connection.id or (type(connection) == "number" and connection)
				local targetNode = nodes[targetId]

				if DEBUG_TRACES then
					print(
						string.format(
							"[IsNavigable]   Conn %d: targetId=%s, found=%s, isDoor=%s",
							i,
							tostring(targetId),
							tostring(targetNode ~= nil),
							tostring(targetNode and targetNode.isDoor or "n/a")
						)
					)
				end

				if targetNode and not targetNode.isDoor then
					-- 1D bounds check on shared axis
					local onSharedAxis = false
					local checkAxis, exitVal, minVal, maxVal

					if exitDir.dir == 1 or exitDir.dir == 3 then
						-- North or South - check X axis
						checkAxis = "X"
						exitVal = exitPoint.x
						minVal = targetNode._minX
						maxVal = targetNode._maxX
						onSharedAxis = exitVal >= minVal and exitVal <= maxVal
					elseif exitDir.dir == 2 or exitDir.dir == 4 then
						-- East or West - check Y axis
						checkAxis = "Y"
						exitVal = exitPoint.y
						minVal = targetNode._minY
						maxVal = targetNode._maxY
						onSharedAxis = exitVal >= minVal and exitVal <= maxVal
					end

					if DEBUG_TRACES then
						print(
							string.format(
								"[IsNavigable]   Conn %d: node=%d, %s bounds=[%.1f to %.1f], exit%s=%.1f, match=%s",
								i,
								targetNode.id,
								checkAxis,
								minVal,
								maxVal,
								checkAxis,
								exitVal,
								tostring(onSharedAxis)
							)
						)
					end

					if onSharedAxis then
						return targetNode, exitDir
					end
				elseif targetNode and targetNode.isDoor then
					if DEBUG_TRACES then
						print(string.format("[IsNavigable]   Conn %d: node=%d is DOOR, skipped", i, targetId))
					end
				end
			end
			return nil
		end

		-- Try primary direction first
		if primaryDir then
			neighborNode, foundVia = checkDirection(primaryDir)
		end

		-- If not found, try secondary direction
		if not neighborNode and secondaryDir then
			neighborNode, foundVia = checkDirection(secondaryDir)
		end

		if neighborNode and foundVia and DEBUG_TRACES then
			print(
				string.format(
					"[IsNavigable] Found neighbor %d via %s at exit (%.1f, %.1f)",
					neighborNode.id,
					foundVia.name,
					exitPoint.x,
					exitPoint.y
				)
			)
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
			shouldHitEntity
		)
		Profiler.End("GroundTrace")

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
