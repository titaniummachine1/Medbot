--##########################################################################
--  DoorGeometry.lua  ·  Door geometry generation from nav area edges
--##########################################################################

local Common = require("MedBot.Core.Common")

local DoorGeometry = {}

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72

local Log = Common.Log.new("DoorGeometry")

-- ========================================================================
-- GEOMETRY HELPERS
-- ========================================================================

-- Linear interpolation between two Vector3 points
local function lerpVec(a, b, t)
	return Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

-- Scalar lerp
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Convert dirId (nav mesh NESW index) to direction vector
-- Source Engine format: connectionData[4] in NESW order
local function dirIdToVector(dirId)
	if dirId == 1 then
		return 0, -1
	end -- North
	if dirId == 2 then
		return 1, 0
	end -- East
	if dirId == 3 then
		return 0, 1
	end -- South
	if dirId == 4 then
		return -1, 0
	end -- West
	return 0, 0 -- Invalid
end

-- Get the two corners of an area that face the given direction
local function getFacingEdgeCorners(area, dirX, dirY)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end

	if dirX == 1 then
		return area.ne, area.se
	end -- East
	if dirX == -1 then
		return area.sw, area.nw
	end -- West
	if dirY == 1 then
		return area.se, area.sw
	end -- South
	if dirY == -1 then
		return area.nw, area.ne
	end -- North

	return nil, nil
end

-- Compute scalar overlap on an axis and return segment [a1,a2] overlapped with [b1,b2]
local function overlap1D(a1, a2, b1, b2)
	if a1 > a2 then
		a1, a2 = a2, a1
	end
	if b1 > b2 then
		b1, b2 = b2, b1
	end
	local left = math.max(a1, b1)
	local right = math.min(a2, b2)
	if right <= left then
		return nil
	end
	return left, right
end

-- Determine which area owns the door based on edge heights
local function calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)
	local aZmax = math.max(a0.z, a1.z)
	local bZmax = math.max(b0.z, b1.z)

	if aZmax > bZmax + 0.5 then
		return "A", areaA.id
	elseif bZmax > aZmax + 0.5 then
		return "B", areaB.id
	else
		return "TIE", math.max(areaA.id, areaB.id)
	end
end

-- ========================================================================
-- DOOR GEOMETRY CALCULATION
-- ========================================================================

-- Calculate edge overlap and door geometry
local function calculateDoorGeometry(areaA, areaB, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(areaA, dirX, dirY)
	local b0, b1 = getFacingEdgeCorners(areaB, -dirX, -dirY)
	if not (a0 and a1 and b0 and b1) then
		return nil
	end

	local owner, ownerId = calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)

	return {
		a0 = a0,
		a1 = a1,
		b0 = b0,
		b1 = b1,
		owner = owner,
		ownerId = ownerId,
	}
end

-- Create door geometry for connection between two areas
function DoorGeometry.CreateDoorForAreas(areaA, areaB, dirId)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		return nil
	end

	-- Convert dirId from connection to direction vector
	local dirX, dirY = dirIdToVector(dirId)

	local geometry = calculateDoorGeometry(areaA, areaB, dirX, dirY)
	if not geometry then
		return nil
	end

	local a0, a1, b0, b1 = geometry.a0, geometry.a1, geometry.b0, geometry.b1

	-- Pick higher Z border as base (door stays at owner's boundary)
	local aMaxZ = math.max(a0.z, a1.z)
	local bMaxZ = math.max(b0.z, b1.z)
	local baseEdge0, baseEdge1
	if bMaxZ > aMaxZ + 0.5 then
		baseEdge0, baseEdge1 = b0, b1 -- Use B's edge (B is owner)
	else
		baseEdge0, baseEdge1 = a0, a1 -- Use A's edge (A is owner)
	end

	-- Determine shared axis: vertical edge (Y varies) or horizontal edge (X varies)
	local axis, constAxis
	if dirX ~= 0 then
		-- East/West connection → vertical shared edge → Y axis varies
		axis = "y"
		constAxis = "x"
	else
		-- North/South connection → horizontal shared edge → X axis varies
		axis = "x"
		constAxis = "y"
	end

	-- Pure 1D overlap on shared axis (common boundary)
	local aMin = math.min(a0[axis], a1[axis])
	local aMax = math.max(a0[axis], a1[axis])
	local bMin = math.min(b0[axis], b1[axis])
	local bMax = math.max(b0[axis], b1[axis])

	local overlapMin = math.max(aMin, bMin)
	local overlapMax = math.min(aMax, bMax)

	-- If overlap too small, create center-only door at center of smaller area's edge
	if overlapMax - overlapMin < HITBOX_WIDTH then
		-- Determine which area has smaller edge
		local aEdgeLen = aMax - aMin
		local bEdgeLen = bMax - bMin

		-- Use center of smaller edge for better door placement
		local centerPoint
		if aEdgeLen <= bEdgeLen then
			centerPoint = lerpVec(a0, a1, 0.5) -- A has smaller edge
		else
			centerPoint = lerpVec(b0, b1, 0.5) -- B has smaller edge
		end

		return {
			left = nil,
			middle = centerPoint,
			right = nil,
			owner = geometry.ownerId,
			needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
		}
	end

	-- Get area bounds on the door's varying axis
	local areaBoundsA = { min = aMin, max = aMax }
	local areaBoundsB = { min = bMin, max = bMax }

	-- Build door points ON the owner's edge line (stays on edge even if sloped)
	local function pointOnEdge(axisVal)
		-- Calculate interpolation factor along varying axis
		local t = (baseEdge1[axis] - baseEdge0[axis]) ~= 0
				and ((axisVal - baseEdge0[axis]) / (baseEdge1[axis] - baseEdge0[axis]))
			or 0.5
		t = math.max(0, math.min(1, t))

		-- Interpolate ALL components to stay on the edge line
		local pos = Vector3(
			lerp(baseEdge0.x, baseEdge1.x, t),
			lerp(baseEdge0.y, baseEdge1.y, t),
			lerp(baseEdge0.z, baseEdge1.z, t)
		)

		return pos
	end

	local overlapLeft = pointOnEdge(overlapMin)
	local overlapRight = pointOnEdge(overlapMax)

	-- STEP 1: Apply boundary clamping FIRST (shearing - stay within common area)
	local commonMin = math.max(areaBoundsA.min, areaBoundsB.min)
	local commonMax = math.min(areaBoundsA.max, areaBoundsB.max)

	-- Clamp left endpoint to common bounds and snap back to edge line
	local leftCoord = overlapLeft[axis]
	local rightCoord = overlapRight[axis]

	if leftCoord < commonMin then
		overlapLeft = pointOnEdge(commonMin) -- Recalculate to stay on edge
	elseif leftCoord > commonMax then
		overlapLeft = pointOnEdge(commonMax) -- Recalculate to stay on edge
	end

	-- Clamp right endpoint to common bounds and snap back to edge line
	if rightCoord < commonMin then
		overlapRight = pointOnEdge(commonMin) -- Recalculate to stay on edge
	elseif rightCoord > commonMax then
		overlapRight = pointOnEdge(commonMax) -- Recalculate to stay on edge
	end

	-- Calculate door width and middle point
	local finalWidth = (overlapRight - overlapLeft):Length2D()
	if finalWidth < HITBOX_WIDTH then
		-- Too narrow after clamping, use center of smaller area's edge
		local aEdgeLen = aMax - aMin
		local bEdgeLen = bMax - bMin

		local centerPoint
		if aEdgeLen <= bEdgeLen then
			centerPoint = lerpVec(a0, a1, 0.5) -- A has smaller edge
		else
			centerPoint = lerpVec(b0, b1, 0.5) -- B has smaller edge
		end

		return {
			left = nil,
			middle = centerPoint,
			right = nil,
			owner = geometry.ownerId,
			needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
		}
	end

	local middle = lerpVec(overlapLeft, overlapRight, 0.5)

	-- STEP 2: Wall avoidance - shrink door by 24 units from wall corners on door axis
	local WALL_CLEARANCE = 24

	-- Get current door bounds on varying axis
	local leftCoordFinal = overlapLeft[axis]
	local rightCoordFinal = overlapRight[axis]
	local minDoor = math.min(leftCoordFinal, rightCoordFinal)
	local maxDoor = math.max(leftCoordFinal, rightCoordFinal)

	-- Track how much to shrink from each side
	local shrinkFromMin = 0
	local shrinkFromMax = 0

	-- Check all wall corners from both areas
	for _, area in ipairs({ areaA, areaB }) do
		if area.wallCorners then
			for _, wallCorner in ipairs(area.wallCorners) do
				-- Get coordinates on both axes
				local cornerVaryingCoord = wallCorner[axis] -- Door varies on this axis

				-- Calculate closest point on door edge line to this corner
				local edgePoint = pointOnEdge(cornerVaryingCoord)

				-- FIRST: Check if wall corner is near the door edge line
				-- Calculate distance from corner to its projection on the edge
				local distToEdge = (wallCorner - edgePoint):Length2D()
				if distToEdge > WALL_CLEARANCE then
					goto continue_corner -- Corner is too far away from door edge
				end

				-- SECOND: Check distance to door endpoints on the VARYING axis
				local distToMin = math.abs(cornerVaryingCoord - minDoor)
				local distToMax = math.abs(cornerVaryingCoord - maxDoor)

				-- Shrink from min side if wall corner is within 24 units of it
				if distToMin < WALL_CLEARANCE then
					shrinkFromMin = math.max(shrinkFromMin, WALL_CLEARANCE - distToMin)
				end

				-- Shrink from max side if wall corner is within 24 units of it
				if distToMax < WALL_CLEARANCE then
					shrinkFromMax = math.max(shrinkFromMax, WALL_CLEARANCE - distToMax)
				end

				::continue_corner::
			end
		end
	end

	-- Apply shrinking to door endpoints and snap back to edge line
	if shrinkFromMin > 0 then
		local newCoord
		if leftCoordFinal < rightCoordFinal then
			newCoord = leftCoordFinal + shrinkFromMin
		else
			newCoord = leftCoordFinal - shrinkFromMin
		end
		overlapLeft = pointOnEdge(newCoord) -- Snap to edge line after shrinking
	end

	if shrinkFromMax > 0 then
		local newCoord
		if rightCoordFinal > leftCoordFinal then
			newCoord = rightCoordFinal - shrinkFromMax
		else
			newCoord = rightCoordFinal + shrinkFromMax
		end
		overlapRight = pointOnEdge(newCoord) -- Snap to edge line after shrinking
	end

	-- Recalculate width after wall avoidance
	local finalWidthAfterWalls = (overlapRight - overlapLeft):Length2D()

	-- Check if this is a narrow passage (< 48 units = bottleneck)
	local isNarrowPassage = finalWidthAfterWalls < (HITBOX_WIDTH * 2)

	return {
		left = isNarrowPassage and nil or overlapLeft,
		middle = middle, -- Always create middle door
		right = isNarrowPassage and nil or overlapRight,
		owner = geometry.ownerId,
		needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
	}
end

return DoorGeometry
