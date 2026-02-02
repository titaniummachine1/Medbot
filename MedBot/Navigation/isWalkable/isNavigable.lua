--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]
local Navigable = {}
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local Common = require("MedBot.Core.Common")

-- Profiler integration (loaded externally)
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

-- Get neighbor node in the given direction from current node
local function getNeighborInDirection(currentNode, exitDir)
	Profiler.Begin("IsNavigable.getNeighborInDirection")

	if not currentNode.c or not currentNode.c[exitDir] then
		Profiler.End("IsNavigable.getNeighborInDirection")
		return nil
	end

	local dirData = currentNode.c[exitDir]
	if not dirData.connections or #dirData.connections == 0 then
		Profiler.End("IsNavigable.getNeighborInDirection")
		return nil
	end

	-- Get first connection (typically only one per direction)
	local conn = dirData.connections[1]
	local neighborId = type(conn) == "table" and conn.node or conn

	local nodes = G.Navigation and G.Navigation.nodes
	if not nodes then
		Profiler.End("IsNavigable.getNeighborInDirection")
		return nil
	end

	local neighbor = nodes[neighborId]
	Profiler.End("IsNavigable.getNeighborInDirection")
	return neighbor
end

-- Simple bounds check for goal position
local function isPositionInNode(pos, node)
	if not node or node.isDoor then
		return false
	end
	return pos.x >= node._minX and pos.x <= node._maxX and pos.y >= node._minY and pos.y <= node._maxY
end

-- Direction constants
local DIR_NORTH = 1
local DIR_SOUTH = 2
local DIR_EAST = 4
local DIR_WEST = 8

-- Find where ray exits node bounds
local function findNodeExit(startPos, dir, node)
	Profiler.Begin("IsNavigable.findNodeExit")
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY
	local exitDir

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
			exitDir = DIR_EAST
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
			exitDir = DIR_WEST
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
			exitDir = DIR_NORTH
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
			exitDir = DIR_SOUTH
		end
	end

	if tMin == math.huge then
		Profiler.End("IsNavigable.findNodeExit")
		return nil
	end

	Profiler.End("IsNavigable.findNodeExit")
	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- MAIN FUNCTION - Trace to borders
function Navigable.CanSkip(startPos, goalPos, startNode)
	Profiler.Begin("IsNavigable.CanSkip")

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
		Profiler.Begin("IsNavigable.Iteration")
		iteration = iteration + 1

		-- Direction to goal from current position
		Profiler.Begin("IsNavigable.CalculateDirection")
		local toGoal = goalPos - currentPos
		local distToGoal = toGoal:Length()
		Profiler.End("IsNavigable.CalculateDirection")

		if distToGoal < 50 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] SUCCESS: Within 50 units of goal"))
			end
			Profiler.End("IsNavigable.Iteration")
			Profiler.End("IsNavigable.CanSkip")
			return true
		end

		local dir = toGoal / distToGoal

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

		-- Check if goal is in current node
		Profiler.Begin("IsNavigable.GoalCheck")
		local goalInCurrentNode = isPositionInNode(goalPos, currentNode)
		Profiler.End("IsNavigable.GoalCheck")

		if goalInCurrentNode then
			-- Final trace to goal
			Profiler.Begin("IsNavigable.FinalTrace")
			local finalTrace = TraceHull(
				currentPos + STEP_HEIGHT_Vector,
				goalPos + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)
			Profiler.End("IsNavigable.FinalTrace")

			if finalTrace.fraction > 0.99 then
				if DEBUG_TRACES then
					print("[IsNavigable] SUCCESS: Direct trace to goal in same node")
				end
				Profiler.End("IsNavigable.Iteration")
				Profiler.End("IsNavigable.CanSkip")
				return true
			else
				if DEBUG_TRACES then
					print(
						string.format("[IsNavigable] FAIL: Blocked at %.2f in same node as goal", finalTrace.fraction)
					)
				end
				Profiler.End("IsNavigable.Iteration")
				Profiler.End("IsNavigable.CanSkip")
				return false
			end
		end

		-- Find where we exit current node
		Profiler.Begin("IsNavigable.FindExit")
		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, dir, currentNode)
		Profiler.End("IsNavigable.FindExit")

		if not exitPoint then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			Profiler.End("IsNavigable.Iteration")
			Profiler.End("IsNavigable.CanSkip")
			return false
		end

		-- Trace to exit point
		Profiler.Begin("IsNavigable.ExitTrace")
		local exitTrace = TraceHull(
			currentPos + STEP_HEIGHT_Vector,
			exitPoint + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)
		Profiler.End("IsNavigable.ExitTrace")

		if exitTrace.fraction < 0.99 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: Hit obstacle at %.2f before border", exitTrace.fraction))
			end
			Profiler.End("IsNavigable.Iteration")
			Profiler.End("IsNavigable.CanSkip")
			return false
		end

		-- Get neighbor directly from connection list
		Profiler.Begin("IsNavigable.FindNeighbor")
		local neighborNode = getNeighborInDirection(currentNode, exitDir)
		Profiler.End("IsNavigable.FindNeighbor")

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
			Profiler.End("IsNavigable.Iteration")
			Profiler.End("IsNavigable.CanSkip")
			return false
		end

		-- Entry point is exitPoint clamped to neighbor bounds
		Profiler.Begin("IsNavigable.EntryClamp")
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))
		local entryPos = Vector3(entryX, entryY, exitPoint.z)
		Profiler.End("IsNavigable.EntryClamp")

		-- Ground snap at entry
		Profiler.Begin("IsNavigable.GroundTrace")
		local groundTrace = TraceHull(
			entryPos + STEP_HEIGHT_Vector,
			entryPos - Vector3(0, 0, 100),
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)
		Profiler.End("IsNavigable.GroundTrace")

		if groundTrace.fraction == 1 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No ground at entry to node %d", neighborNode.id))
			end
			Profiler.End("IsNavigable.Iteration")
			Profiler.End("IsNavigable.CanSkip")
			return false
		end

		if DEBUG_TRACES then
			print(string.format("[IsNavigable] Crossed to node %d", neighborNode.id))
		end

		currentPos = groundTrace.endpos
		currentNode = neighborNode
		Profiler.End("IsNavigable.Iteration")
	end

	if DEBUG_TRACES then
		print(string.format("[IsNavigable] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
	end
	Profiler.End("IsNavigable.CanSkip")
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
