local isWalkable = {}
local G = require("MedBot.Utils.Globals")
local Common = require("MedBot.Common")

-- Constants based on standstill dummy's robust implementation
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) } -- Player collision hull
local STEP_HEIGHT = 18 -- Maximum height the player can step up
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250 -- Maximum distance the player can fall without taking fall damage
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE

local UP_VECTOR = Vector3(0, 0, 1)
local MAX_SURFACE_ANGLE = 45 -- Maximum angle for ground surfaces
local MAX_ITERATIONS = 37 -- Maximum number of iterations to prevent infinite loops

-- Helper function to get local player for speed calculation
local function getLocalPlayer()
	return entities.GetLocalPlayer()
end

-- Helper function to get min step size based on player speed
local function getMinStepSize()
	local pLocal = getLocalPlayer()
	if pLocal then
		local maxSpeed = pLocal:GetPropFloat("m_flMaxspeed") or 450
		return maxSpeed * globals.TickInterval()
	end
	return 7.5 -- Fallback value (450 * 1/66)
end

-- Helper function to check if we should hit an entity (ignore local player)
local function shouldHitEntity(entity)
	local pLocal = getLocalPlayer()
	return entity ~= pLocal -- Ignore self (the player being simulated)
end

-- Normalize a vector
local function Normalize(vec)
	local length = vec:Length()
	if length == 0 then
		return vec
	end
	return vec / length
end

-- Calculate horizontal Manhattan distance between two points
local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Perform a hull trace to check for obstructions between two points
local function performTraceHull(startPos, endPos)
	return engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	-- Check if the surface is within the maximum allowed angle for adjustment
	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)

	-- Adjust the z component of the direction in place
	direction.z = direction.z - surfaceNormal.z * dotProduct

	-- Normalize the direction after adjustment
	return Normalize(direction)
end

-- Main function to check if the path between the current position and the node is walkable.
-- Uses robust algorithm from standstill dummy to prevent walking over walls
-- Respects Walkable Mode setting: "Step" = 18-unit steps only, "Jump" = 72-unit duck jumps allowed
function isWalkable.Path(startPos, endPos)
	-- Get walkable mode from menu (default to "Step" for conservative behavior)
	local walkableMode = G.Menu.Main.WalkableMode or "Step"
	local maxStepHeight = walkableMode == "Jump" and 72 or STEP_HEIGHT -- 72 for duck jumps, 18 for steps
	local maxStepVector = Vector3(0, 0, maxStepHeight)
	local stepFraction = maxStepHeight / MAX_FALL_DISTANCE

	-- Quick height check first
	local totalHeightDiff = endPos.z - startPos.z
	if totalHeightDiff > maxStepHeight then
		return false -- Too high for current mode
	end

	local blocked = false
	local currentPos = startPos
	local MIN_STEP_SIZE = getMinStepSize()

	-- Adjust start position to ground level
	local startGroundTrace = performTraceHull(startPos + maxStepVector, startPos - MAX_FALL_DISTANCE_Vector)

	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(endPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, endPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		-- Calculate distance to goal and update direction
		local distanceToGoal = (currentPos - endPos):Length()
		local direction = lastDirection

		-- Calculate next position
		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check - this prevents walking through walls
		local wallTrace = performTraceHull(lastPos + maxStepVector, NextPos + maxStepVector)
		currentPos = wallTrace.endpos

		if wallTrace.fraction == 0 then
			blocked = true -- Path is blocked by a wall
		end

		-- Ground collision with segmentation - ensures we always have ground beneath us
		local totalDistance = (currentPos - lastPos):Length()
		local numSegments = math.max(1, math.floor(totalDistance / MIN_STEP_SIZE))

		for seg = 1, numSegments do
			local t = seg / numSegments
			local segmentPos = lastPos + (currentPos - lastPos) * t
			local segmentTop = segmentPos + maxStepVector
			local segmentBottom = segmentPos - MAX_FALL_DISTANCE_Vector

			local groundTrace = performTraceHull(segmentTop, segmentBottom)

			if groundTrace.fraction == 1 then
				return false -- No ground beneath; path is unwalkable
			end

			-- Check if obstacle is within acceptable height for current mode
			local obstacleHeight = (segmentBottom - groundTrace.endpos).z
			if obstacleHeight > maxStepHeight then
				return false -- Obstacle too high for current mode
			end

			if groundTrace.fraction > stepFraction or seg == numSegments then
				-- Adjust position to ground
				direction = adjustDirectionToSurface(direction, groundTrace.plane)
				currentPos = groundTrace.endpos
				blocked = false
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, endPos)
		if blocked or currentDistance > MaxDistance then -- if target is unreachable
			return false
		elseif currentDistance < 24 then -- within range
			local verticalDist = math.abs(endPos.z - currentPos.z)
			if verticalDist < maxStepHeight then -- within vertical range for current mode
				return true -- Goal is within reach; path is walkable
			else -- unreachable
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
