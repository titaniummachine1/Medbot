-- Path Validation Module - Uses trace hulls to check if path A→B is walkable
-- This is NOT movement execution, just validation logic
-- Uses the expensive but accurate algorithm from A_standstillDummy.lua
-- Only called during stuck detection, so performance cost is acceptable
local isWalkable = {}
local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")

-- Constants
local pLocal = entities.GetLocalPlayer()
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) } -- Player collision hull
local MaxSpeed = (pLocal and pLocal:GetPropFloat("m_flMaxspeed")) or 450 -- Default to 450 if max speed not available
local gravity = client.GetConVar("sv_gravity") or 800 -- Gravity or default one
local STEP_HEIGHT = (pLocal and pLocal:GetPropFloat("localdata", "m_flStepSize")) or 18 -- Maximum height the player can step up
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250 -- Maximum distance the player can fall without taking fall damage
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE

local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval() -- Minimum step size to consider for ground checks

local MAX_SURFACE_ANGLE = 45 -- Maximum angle for ground surfaces
local MAX_ITERATIONS = 37 -- Maximum number of iterations to prevent infinite loops

-- Debug visualization function for trace hulls (like A_standstillDummy)
function isWalkable.DrawDebugTraces()
	if not DEBUG_TRACES then
		return
	end

	if not hullTraces then
		print("ISWalkable: hullTraces is nil!")
		return
	end

	if #hullTraces == 0 then
		print("ISWalkable: hullTraces is empty")
		return
	end

	print("ISWalkable: Drawing " .. #hullTraces .. " hull traces")

	-- Draw all hull traces as blue arrow lines
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255) -- Blue for hull traces
			isWalkable.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end

	-- Draw all line traces as white lines
	for _, trace in ipairs(lineTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(255, 255, 255, 255) -- White for line traces
			local w2s_start = client.WorldToScreen(trace.startPos)
			local w2s_end = client.WorldToScreen(trace.endPos)
			if w2s_start and w2s_end then
				draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
			end
		end
	end
end

-- Arrow line drawing function (simplified from A_standstillDummy)
function isWalkable.DrawArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	-- If invert is true, swap start_pos and end_pos
	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	-- Calculate direction from start to end
	local direction = end_pos - start_pos

	-- Check if arrow size is too small
	local min_acceptable_length = arrowhead_length + (arrowhead_width / 2)
	if direction:Length() < min_acceptable_length then
		-- Draw a regular line if arrow size is too small
		local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
		if w2s_start and w2s_end then
			draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		end
		return
	end

	-- Normalize the direction vector
	local normalized_direction = isWalkable.Normalize(direction)

	-- Calculate the arrow base position
	local arrow_base = end_pos - normalized_direction * arrowhead_length

	-- Calculate the perpendicular vector for the arrow width
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	-- Convert world positions to screen positions
	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	-- Draw the line from start to the base of the arrow
	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])

	-- Draw the sides of the arrowhead
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])

	-- Draw the base of the arrowhead
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- Vector normalization function
function isWalkable.Normalize(vec)
	return vec / vec:Length()
end

-- Toggle debug visualization on/off
function isWalkable.ToggleDebug()
	DEBUG_TRACES = not DEBUG_TRACES
	print("ISWalkable debug traces: " .. (DEBUG_TRACES and "ENABLED" or "DISABLED"))
end

-- Get current debug state
function isWalkable.IsDebugEnabled()
	return DEBUG_TRACES
end

-- Clear debug traces (call this before each ISWalkable check)
function isWalkable.ClearDebugTraces()
	hullTraces = {}
	lineTraces = {}
end

-- Traces tables for debugging
local hullTraces = {}
local lineTraces = {}

-- Debug flag (set to true to enable trace visualization)
local DEBUG_TRACES = true -- TEMPORARILY ENABLED FOR TESTING

local function shouldHitEntity(entity)
	return entity ~= pLocal -- Ignore self (the player being simulated)
end

-- Normalize a vector
local function Normalize(vec)
	return vec / vec:Length()
end
local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Perform a hull trace to check for obstructions between two points
local function performTraceHull(startPos, endPos)
	local result =
		engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	-- Check if the surface is within the maximum allowed angle for adjustment
	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)

	-- Adjust the z component of the direction in place
	direction.z = direction.z - surfaceNormal.z * dotProduct

	-- Normalize the direction after adjustment
	return normalize(direction)
end

-- Main function to check walkability
-- Uses the expensive but accurate algorithm from A_standstillDummy.lua
-- Only called during stuck detection, so performance cost is acceptable
function isWalkable.Path(startPos, goalPos, overrideMode)
	-- Clear trace tables for debugging (like A_standstillDummy)
	hullTraces = {}
	lineTraces = {}

	print("ISWalkable: Path called from " .. tostring(startPos) .. " to " .. tostring(goalPos))

	-- Initialize variables
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
		-- Calculate distance to goal and update direction
		local distanceToGoal = (currentPos - goalPos):Length()
		local direction = lastDirection

		-- Calculate next position
		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check
		local wallTrace = performTraceHull(lastPos + STEP_HEIGHT_Vector, NextPos + STEP_HEIGHT_Vector)
		currentPos = wallTrace.endpos

		if wallTrace.fraction == 0 then
			return false -- Path is blocked by a wall - immediately fail
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
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, goalPos)
		if currentDistance > MaxDistance then --if target is unreachable
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

return isWalkable
