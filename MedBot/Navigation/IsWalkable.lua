-- Path Validation Module - Uses trace hulls to check if path A→B is walkable
-- This is NOT movement execution, just validation logic
-- Uses the expensive but accurate algorithm from A_standstillDummy.lua
-- Only called during stuck detection, so performance cost is acceptable
local PathValidator = {}
local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")

-- Constants (static defaults - player properties don't change during session)
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) } -- Player collision hull
local MaxSpeed = 450 -- Default max speed (TF2 scout speed)
local gravity = client.GetConVar("sv_gravity") or 800 -- Gravity or default one
local STEP_HEIGHT = 18 -- Maximum height the player can step up
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250 -- Maximum distance the player can fall without taking fall damage
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE

local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval() -- Minimum step size to consider for ground checks

local MAX_SURFACE_ANGLE = 45 -- Maximum angle for ground surfaces
local MAX_ITERATIONS = 37 -- Maximum number of iterations to prevent infinite loops

-- Debug flag (set to true to enable trace visualization)
local DEBUG_TRACES = (G.Menu.Visuals and G.Menu.Visuals.Debug_Mode) or false -- follow global debug setting by default

-- Traces tables for debugging (MUST be declared before DrawDebugTraces function)
local hullTraces = {}
local lineTraces = {}
local validationResults = {} -- Store multiple validation results (start, end, result, time)

local POSITION_TOLERANCE = 8 -- Units tolerance when reusing recent validation result

local lastValidation = {
	tick = -math.huge,
	start = nil,
	goal = nil,
	result = nil,
}

local function copyVectorComponents(vec)
	return { x = vec.x, y = vec.y, z = vec.z }
end

local function vectorsClose(vec, cached)
	if not vec or not cached then
		return false
	end
	return math.abs(vec.x - cached.x) <= POSITION_TOLERANCE
		and math.abs(vec.y - cached.y) <= POSITION_TOLERANCE
		and math.abs(vec.z - cached.z) <= POSITION_TOLERANCE
end

local function cacheValidationResult(tick, startPos, goalPos, result)
	lastValidation.tick = tick
	lastValidation.start = copyVectorComponents(startPos)
	lastValidation.goal = copyVectorComponents(goalPos)
	lastValidation.result = result
end

-- Calculate tick interval at runtime
local function getTraceExpireTime()
	return globals.TickInterval() * 4 -- Keep traces for 4 ticks
end

-- Debug visualization function for trace hulls
function PathValidator.DrawDebugTraces()
	if G.Menu.Visuals and G.Menu.Visuals.Debug_Mode ~= nil then
		DEBUG_TRACES = G.Menu.Visuals.Debug_Mode
	end
	if not DEBUG_TRACES then
		return
	end

	local currentTime = globals.RealTime()
	local expireTime = getTraceExpireTime()

	-- Remove expired validation results
	local i = 1
	while i <= #validationResults do
		if (currentTime - validationResults[i].time) > expireTime then
			table.remove(validationResults, i)
		else
			i = i + 1
		end
	end

	-- Draw all hull traces as BLUE arrows (background layer)
	if hullTraces and #hullTraces > 0 then
		for _, trace in ipairs(hullTraces) do
			if trace.startPos and trace.endPos then
				draw.Color(0, 50, 255, 255) -- Blue for hull traces
				Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
			end
		end
	end

	-- Draw all line traces as white lines (middle layer)
	if lineTraces and #lineTraces > 0 then
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

	-- Draw ALL validation result arrows LAST (foreground layer - GREEN = walkable, RED = blocked)
	for _, validation in ipairs(validationResults) do
		if validation.startPos and validation.endPos then
			if validation.result then
				draw.Color(0, 255, 0, 255) -- Green for walkable
			else
				draw.Color(255, 0, 0, 255) -- Red for blocked
			end
			Common.DrawArrowLine(validation.startPos, validation.endPos, 10, 20, false)
		end
	end
end

-- Toggle debug visualization on/off
function PathValidator.ToggleDebug()
	local newState = not DEBUG_TRACES
	DEBUG_TRACES = newState
	if G.Menu.Visuals then
		G.Menu.Visuals.Debug_Mode = newState
	end
	print("PathValidator debug mode: " .. (newState and "ENABLED" or "DISABLED"))
end

-- Get current debug state
function PathValidator.IsDebugEnabled()
	return DEBUG_TRACES
end

-- Clear debug traces (call this before each ISWalkable check)
function PathValidator.ClearDebugTraces()
	hullTraces = {}
	lineTraces = {}
	validationResults = {}
end

local function shouldHitEntity(entity)
	-- Use fresh player reference from globals (updated every tick)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal -- Ignore self (the player being simulated)
end

local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Perform a hull trace to check for obstructions between two points
local function performTraceHull(startPos, endPos)
	local result =
		engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)

	local currentTime = globals.RealTime()
	local expireTime = getTraceExpireTime()

	-- Before adding new trace, remove old ones (older than 4 ticks)
	local i = 1
	while i <= #hullTraces do
		if (currentTime - hullTraces[i].time) > expireTime then
			table.remove(hullTraces, i)
		else
			i = i + 1
		end
	end

	-- Add new trace
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos, time = currentTime })
	return result
end

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Common.Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	-- Check if the surface is within the maximum allowed angle for adjustment
	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)

	-- Adjust the z component of the direction in place
	direction.z = direction.z - surfaceNormal.z * dotProduct

	-- Normalize the direction after adjustment
	return Common.Normalize(direction)
end

-- Main function to check walkability
-- Uses the expensive but accurate algorithm from A_standstillDummy.lua
-- Only called during stuck detection, so performance cost is acceptable
function PathValidator.Path(startPos, goalPos, overrideMode)
	-- Don't clear traces - accumulate them over time
	-- Old traces are removed in DrawDebugTraces based on timestamp

	if G.Menu.Visuals and G.Menu.Visuals.Debug_Mode ~= nil then
		DEBUG_TRACES = G.Menu.Visuals.Debug_Mode
	end

	local currentTick = globals.TickCount()
	if (currentTick - lastValidation.tick) < 11 then
		if vectorsClose(startPos, lastValidation.start) and vectorsClose(goalPos, lastValidation.goal) then
			return lastValidation.result
		end
	end

	local checkTime = globals.RealTime() -- Record when check happened

	if DEBUG_TRACES then
		print(
			string.format(
				"PathValidator: Checking path from (%.0f,%.0f,%.0f) to (%.0f,%.0f,%.0f)",
				startPos.x,
				startPos.y,
				startPos.z,
				goalPos.x,
				goalPos.y,
				goalPos.z
			)
		)
	end

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

		-- Calculate next position with incremental steps instead of full distance
		-- This allows gradual progress even if full path has obstacles
		local stepDistance = math.min(distanceToGoal, MIN_STEP_SIZE * 2) -- Max 2 step sizes per iteration
		local NextPos = lastPos + direction * stepDistance

		-- Forward collision check
		local wallTrace = performTraceHull(lastPos + STEP_HEIGHT_Vector, NextPos + STEP_HEIGHT_Vector)
		currentPos = wallTrace.endpos

		if wallTrace.fraction == 0 then
			-- Instead of immediately failing, try to navigate around the obstacle
			-- by taking a smaller step or adjusting direction
			local smallerStep = stepDistance * 0.5
			local alternativePos = lastPos + direction * smallerStep
			local altWallTrace = performTraceHull(lastPos + STEP_HEIGHT_Vector, alternativePos + STEP_HEIGHT_Vector)

			if altWallTrace.fraction == 0 then
				-- Store validation result BEFORE returning
				table.insert(validationResults, {
					startPos = startPos,
					endPos = goalPos,
					result = false,
					time = checkTime,
				})
				cacheValidationResult(currentTick, startPos, goalPos, false)
				return false -- Still blocked after smaller step - truly unwalkable
			else
				currentPos = altWallTrace.endpos -- Use the smaller step that worked
			end
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
				-- Store validation result BEFORE returning
				table.insert(validationResults, {
					startPos = startPos,
					endPos = goalPos,
					result = false,
					time = checkTime,
				})
				cacheValidationResult(currentTick, startPos, goalPos, false)
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
			-- Store validation result BEFORE returning
			table.insert(validationResults, {
				startPos = startPos,
				endPos = goalPos,
				result = false,
				time = checkTime,
			})
			cacheValidationResult(currentTick, startPos, goalPos, false)
			return false
		elseif currentDistance < 24 then --within range
			local verticalDist = math.abs(goalPos.z - currentPos.z)
			if verticalDist < 24 then --within vertical range
				-- Store validation result BEFORE returning (SUCCESS)
				table.insert(validationResults, {
					startPos = startPos,
					endPos = goalPos,
					result = true,
					time = checkTime,
				})
				cacheValidationResult(currentTick, startPos, goalPos, true)
				return true -- Goal is within reach; path is walkable
			else --unreachable
				-- Store validation result BEFORE returning
				table.insert(validationResults, {
					startPos = startPos,
					endPos = goalPos,
					result = false,
					time = checkTime,
				})
				cacheValidationResult(currentTick, startPos, goalPos, false)
				return false -- Goal is too far vertically; path is unwalkable
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	-- Store validation result BEFORE returning (max iterations)
	table.insert(validationResults, {
		startPos = startPos,
		endPos = goalPos,
		result = false,
		time = checkTime,
	})
	cacheValidationResult(currentTick, startPos, goalPos, false)
	return false -- Max iterations reached without finding a path
end

-- Simple wrapper function for checking if a position is walkable from another position
function PathValidator.IsWalkable(fromPos, toPos)
	return PathValidator.Path(fromPos, toPos)
end

return PathValidator
