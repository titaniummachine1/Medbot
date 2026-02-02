--[[
    ISWalkable Test Suite
    Standalone testing module for ISWalkable optimization
    Mimics the visual toggle system from A_standstillDummy.lua
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local Fonts = { Verdana = draw.CreateFont("Verdana", 14, 510) }
local G = require("MedBot.Core.Globals")

-- Test state variables
local TestState = {
	enabled = false,
	startPos = nil,
	currentPos = nil,
	isWalkable = false,
	showVisuals = true,

	-- Benchmark data
	benchmarkRecords = {},
	MAX_RECORDS = 66,
	averageMemoryUsage = 0,
	averageTimeUsage = 0,

	-- Visual data
	hullTraces = {},
	lineTraces = {},
}

-- Constants
local MAX_SPEED = 450
local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local MAX_FALL_DISTANCE = 250
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MAX_SPEED * globals.TickInterval()
local MAX_SURFACE_ANGLE = 45
local MAX_ITERATIONS = 37

-- Benchmark functions
local function BenchmarkStart()
	collectgarbage("collect")
	local startMemory = collectgarbage("count")
	local startTime = os.clock()
	return startTime, startMemory
end

local function BenchmarkStop(startTime, startMemory)
	local stopTime = os.clock()
	collectgarbage("collect")
	local stopMemory = collectgarbage("count")

	local elapsedTime = math.max(stopTime - startTime, 0)
	local memoryDelta = math.abs(stopMemory - startMemory)

	table.insert(TestState.benchmarkRecords, 1, { time = elapsedTime, memory = memoryDelta })
	if #TestState.benchmarkRecords > TestState.MAX_RECORDS then
		table.remove(TestState.benchmarkRecords)
	end

	local totalTime, totalMemory = 0, 0
	for _, record in ipairs(TestState.benchmarkRecords) do
		totalTime = totalTime + record.time
		totalMemory = totalMemory + record.memory
	end

	TestState.averageTimeUsage = totalTime / #TestState.benchmarkRecords
	TestState.averageMemoryUsage = totalMemory / #TestState.benchmarkRecords
end

-- ISWalkable implementation (optimized version from dummy)
local function shouldHitEntity(entity)
	local pLocal = entities.GetLocalPlayer()
	return entity ~= pLocal
end

local function Normalize(vec)
	return vec / vec:Length()
end

local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

local function performTraceHull(startPos, endPos)
	local result =
		engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
	table.insert(TestState.hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)
	direction.z = direction.z - surfaceNormal.z * dotProduct
	return Normalize(direction)
end

-- Helper: Find closest navmesh node to a 2D position
local function getClosestNavmeshNode(pos, pathNodes)
	local closestNode = nil
	local closestDist = math.huge

	for _, node in ipairs(pathNodes) do
		local nodePos = Vector3(node.x, node.y, node.z)
		local dx = pos.x - nodePos.x
		local dy = pos.y - nodePos.y
		local dist2D = math.sqrt(dx * dx + dy * dy)

		if dist2D < closestDist then
			closestDist = dist2D
			closestNode = node
		end
	end

	return closestNode, closestDist
end

local function IsWalkable(startPos, goalPos)
	-- Clear trace tables for debugging
	TestState.hullTraces = {}
	TestState.lineTraces = {}
	local blocked = false

	local currentPos = startPos

	-- Adjust start position to ground level
	local startGroundTrace = performTraceHull(startPos + STEP_HEIGHT_Vector, startPos - MAX_FALL_DISTANCE_Vector)

	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(goalPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, goalPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		local distanceToGoal = (currentPos - goalPos):Length()
		local direction = lastDirection

		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check
		local wallTrace = performTraceHull(lastPos + STEP_HEIGHT_Vector, NextPos + STEP_HEIGHT_Vector)
		currentPos = wallTrace.endpos

		if wallTrace.fraction == 0 then
			blocked = true -- Path is blocked by a wall
		end

		-- Ground collision with segmentation
		local totalDistance = (currentPos - lastPos):Length()
		local numSegments = math.max(1, math.floor(totalDistance / MIN_STEP_SIZE))

		for seg = 1, numSegments do
			local t = seg / numSegments
			local segmentPos = lastPos + (currentPos - lastPos) * t
			local segmentTop = segmentPos + STEP_HEIGHT_Vector
			local segmentBottom = segmentPos - MAX_FALL_DISTANCE_Vector

			local groundTrace = performTraceHull(segmentTop, segmentBottom)

			if groundTrace.fraction == 1 then
				return false -- No ground beneath; path is unwalkable
			end

			if groundTrace.fraction > STEP_FRACTION or seg == numSegments then
				-- Adjust position to ground
				direction = adjustDirectionToSurface(direction, groundTrace.plane)
				currentPos = groundTrace.endpos
				blocked = false
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, goalPos)
		if blocked or currentDistance > MaxDistance then --if target is unreachable
			return false
		elseif currentDistance < 24 then --within range
			local verticalDist = math.abs(goalPos.z - currentPos.z)
			if verticalDist < 24 then --within vertical range
				return true -- Goal is within reach; path is walkable
			else --unreachable
				return false -- Goal is too far vertically; path is unwalkable
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	return false -- Max iterations reached without finding a path
end

-- Visual functions
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	local direction = end_pos - start_pos
	local min_acceptable_length = arrowhead_length + (arrowhead_width / 2)
	if direction:Length() < min_acceptable_length then
		local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
		if not (w2s_start and w2s_end) then
			return
		end
		draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		return
	end

	local normalized_direction = Normalize(direction)
	local arrow_base = end_pos - normalized_direction * arrowhead_length
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- Main test functions
local function OnCreateMove(Cmd)
	-- Check menu state
	if not G.Menu.Visuals.ISWalkableTest then
		TestState.enabled = false
		return
	end

	-- Set enabled and initialize startPos if needed
	if not TestState.enabled then
		TestState.enabled = true
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() and not TestState.startPos then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	TestState.currentPos = pLocal:GetAbsOrigin()

	-- Shift to reset position
	if input.IsButtonDown(KEY_LSHIFT) then
		TestState.startPos = TestState.currentPos
		return
	end

	-- Don't interfere with movement
	if Cmd:GetForwardMove() ~= 0 or Cmd:GetSideMove() ~= 0 then
		return
	end

	-- Only run test when F key is held
	if not input.IsButtonDown(KEY_F) then
		return
	end

	-- Only run test if we have both positions and they're far enough apart
	if TestState.startPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		local startTime, startMemory = BenchmarkStart()
		TestState.isWalkable = IsWalkable(TestState.currentPos, TestState.startPos)
		BenchmarkStop(startTime, startMemory)
	end
end

local function OnDraw()
	-- Check menu state first
	if not G.Menu.Visuals.ISWalkableTest then
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 255, 255, 255)

	-- Draw target position box
	if TestState.startPos then
		Draw3DBox(10, TestState.startPos)
	end

	-- Draw walkability test and arrow
	if TestState.startPos and TestState.currentPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		if TestState.isWalkable then
			draw.Color(0, 255, 0, 255)
		else
			draw.Color(255, 0, 0, 255)
		end
		ArrowLine(TestState.currentPos, TestState.startPos, 10, 20, false)
	end

	-- Draw benchmark info
	draw.Color(255, 255, 255, 255)
	draw.Text(20, 120, string.format("ISWalkable Test: %s", G.Menu.Visuals.ISWalkableTest and "ON" or "OFF"))
	draw.Text(20, 150, string.format("Memory usage: %.2f KB", TestState.averageMemoryUsage))
	draw.Text(20, 180, string.format("Time usage: %.2f ms", TestState.averageTimeUsage * 1000))
	draw.Text(20, 210, string.format("Result: %s", TestState.isWalkable and "WALKABLE" or "NOT WALKABLE"))
	draw.Text(20, 240, "Press SHIFT to set start | Hold F to test")

	-- Draw debug traces
	for _, trace in ipairs(TestState.lineTraces) do
		draw.Color(255, 255, 255, 255)
		local w2s_start, w2s_end = client.WorldToScreen(trace.startPos), client.WorldToScreen(trace.endPos)
		if w2s_start and w2s_end then
			draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		end
	end

	for _, trace in ipairs(TestState.hullTraces) do
		draw.Color(0, 50, 255, 255)
		ArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
	end
end

-- Toggle function
local function ToggleTest()
	TestState.enabled = not TestState.enabled
	if TestState.enabled then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
		print("ISWalkable Test Suite: ENABLED")
		client.Command('play "ui/buttonclick"', true)
	else
		print("ISWalkable Test Suite: DISABLED")
		client.Command('play "ui/buttonclick_release"', true)
	end
end

-- Public API
local ISWalkableTest = {
	Toggle = ToggleTest,
	IsEnabled = function()
		return TestState.enabled
	end,
	GetState = function()
		return TestState
	end,
}

-- Auto-register callbacks
callbacks.Register("CreateMove", "ISWalkableTest_CreateMove", OnCreateMove)
callbacks.Register("Draw", "ISWalkableTest_Draw", OnDraw)

-- Add to global for easy access
G.ISWalkableTest = ISWalkableTest

print("ISWalkable Test Suite loaded. Use G.ISWalkableTest.Toggle() to enable/disable.")

return ISWalkableTest
