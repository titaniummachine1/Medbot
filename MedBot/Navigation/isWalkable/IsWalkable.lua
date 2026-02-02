-- Path Validation Module - Uses trace hulls to check if path A→B is walkable
-- This is NOT movement execution, just validation logic
-- Ported from A_standstillDummy.lua (working reference implementation)
local PathValidator = {}
local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local MaxSpeed = 450
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval()
local MAX_SURFACE_ANGLE = 45
local MAX_ITERATIONS = 37

-- Debug mode: set at load time, never changes
local DEBUG_TRACES = false

-- Debug storage
local hullTraces = {}
local lineTraces = {}
local currentTickLogged = -1

-- Trace functions (set at load based on DEBUG_TRACES)
local TraceHullFunc
local TraceLineFunc

-- Wrap trace hull to log positions for debug visualization
local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()

	if currentTick > currentTickLogged then
		hullTraces = {}
		lineTraces = {}
		currentTickLogged = currentTick
	end

	local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask, filter)

	table.insert(hullTraces, {
		startPos = startPos,
		endPos = result.endpos,
		tick = currentTick,
	})

	return result
end

-- Wrap trace line to log positions for debug visualization
local function traceLineWrapper(startPos, endPos, mask, filter)
	local currentTick = globals.TickCount()

	if currentTick > currentTickLogged then
		hullTraces = {}
		lineTraces = {}
		currentTickLogged = currentTick
	end

	local result = engine.TraceLine(startPos, endPos, mask, filter)

	table.insert(lineTraces, {
		startPos = startPos,
		endPos = result.endpos,
		tick = currentTick,
	})

	return result
end

-- Initialize trace functions based on debug mode at load time
if DEBUG_TRACES then
	TraceHullFunc = traceHullWrapper
	TraceLineFunc = traceLineWrapper
else
	TraceHullFunc = engine.TraceHull
	TraceLineFunc = engine.TraceLine
end

-- Filter function for traces
local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

local function Normalize(vec)
	return vec / vec:Length()
end

local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Adjust the direction vector to align with the surface normal
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

-- Main walkability check - ported from A_standstillDummy.lua
function PathValidator.IsWalkable(startPos, goalPos)
	-- Clear trace tables for debugging
	hullTraces = {}
	lineTraces = {}
	local blocked = false

	-- Initialize variables
	local currentPos = startPos

	-- Adjust start position to ground level
	local startGroundTrace = TraceHullFunc(
		startPos + STEP_HEIGHT_Vector,
		startPos - MAX_FALL_DISTANCE_Vector,
		PLAYER_HULL.Min,
		PLAYER_HULL.Max,
		MASK_PLAYERSOLID,
		shouldHitEntity
	)

	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(goalPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, goalPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		-- Calculate distance to goal and update direction
		local distanceToGoal = (currentPos - goalPos):Length()
		local direction = lastDirection

		-- Calculate next position
		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check
		local wallTrace = TraceHullFunc(
			lastPos + STEP_HEIGHT_Vector,
			NextPos + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)
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

			local groundTrace = TraceHullFunc(
				segmentTop,
				segmentBottom,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)

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
		if blocked or currentDistance > MaxDistance then
			return false
		elseif currentDistance < 24 then
			local verticalDist = math.abs(goalPos.z - currentPos.z)
			if verticalDist < 24 then
				return true -- Goal is within reach; path is walkable
			else
				return false -- Goal is too far vertically; path is unwalkable
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	return false -- Max iterations reached without finding a path
end

-- Debug visualization - call once per frame
function PathValidator.DrawDebugTraces()
	if not DEBUG_TRACES then
		return
	end

	-- Draw hull traces as blue arrows
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end

	-- Draw line traces as white lines
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

-- Toggle debug (for runtime switching if needed)
function PathValidator.SetDebug(enabled)
	DEBUG_TRACES = enabled
end

return PathValidator
