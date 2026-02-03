--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]
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

	-- Vector normalization speed test
	local testVector = Vector3(3, 4, 0)

	while iteration < MAX_ITERATIONS do
		Profiler.Begin("Iteration")
		iteration = iteration + 1

		-- Direction to goal from current position
		local toGoal = goalPos - currentPos
		local distToGoal = toGoal:Length()

		-- Vector normalization speed test (runs every iteration)
		local testVector = Vector3(3, 4, 0)

		-- Method 1: Divide
		Profiler.Begin("VecTest_Divide")
		local result1 = testVector / testVector:Length()
		Profiler.End("VecTest_Divide")

		-- Method 2: VectorDivide
		Profiler.Begin("VecTest_VectorDivide")
		local result2 = vector.Divide(testVector, testVector:Length())
		Profiler.End("VecTest_VectorDivide")

		-- Method 3: Normalize (fresh copy)
		Profiler.Begin("VecTest_Normalize")
		local result3 = Vector3(testVector.x, testVector.y, testVector.z)
		result3:Normalize()
		Profiler.End("VecTest_Normalize")

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

		-- Find neighbor node using directional connections (1D bounds check on shared axis)
		Profiler.Begin("FindNeighbor")
		local neighborNode = nil

		-- Check all connections - use 1D bounds check on shared axis like door system
		if currentNode.c then
			for dirId, dirData in pairs(currentNode.c) do
				if dirData.connections then
					for _, connection in ipairs(dirData.connections) do
						local targetId = connection.node or (type(connection) == "number" and connection)
						local targetNode = nodes[targetId]
						if targetNode and not targetNode.isDoor then
							-- 1D bounds check on shared axis based on direction
							-- North/South (dirId 1/3): shared axis is X (horizontal)
							-- East/West (dirId 2/4): shared axis is Y (vertical)
							local onSharedAxis = false
							if dirId == 1 or dirId == 3 then
								-- North or South connection - check X axis only
								onSharedAxis = exitPoint.x >= targetNode._minX and exitPoint.x <= targetNode._maxX
							elseif dirId == 2 or dirId == 4 then
								-- East or West connection - check Y axis only
								onSharedAxis = exitPoint.y >= targetNode._minY and exitPoint.y <= targetNode._maxY
							end

							if onSharedAxis then
								neighborNode = targetNode
								if DEBUG_TRACES then
									print(
										string.format(
											"[IsNavigable] Found neighbor %d via direction %d at exit (%.1f, %.1f)",
											targetNode.id,
											dirId,
											exitPoint.x,
											exitPoint.y
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
