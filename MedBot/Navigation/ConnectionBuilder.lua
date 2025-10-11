--##########################################################################
--  ConnectionBuilder.lua  ·  Connection and door building
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local ConnectionBuilder = {}

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local CLEARANCE_OFFSET = 34

local Log = Common.Log.new("ConnectionBuilder")

-- Inline helper: Linear interpolation between two Vector3 points
local function lerpVec(a, b, t)
	return Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

function ConnectionBuilder.NormalizeConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						dir.connections[i] = ConnectionUtils.NormalizeEntry(connection)
					end
				end
			end
		end
	end
	Log:Info("Normalized all connections to enriched format")
end

-- Determine direction with primary and secondary axis options
local function determineDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	local absDx = math.abs(dx)
	local absDy = math.abs(dy)

	-- Primary direction based on larger axis
	local primaryDirX, primaryDirY
	local secondaryDirX, secondaryDirY

	if absDx >= absDy then
		-- Primary: X axis (East/West)
		primaryDirX = (dx > 0) and 1 or -1
		primaryDirY = 0
		-- Secondary: Y axis (North/South)
		secondaryDirX = 0
		secondaryDirY = (dy > 0) and 1 or -1
	else
		-- Primary: Y axis (North/South)
		primaryDirX = 0
		primaryDirY = (dy > 0) and 1 or -1
		-- Secondary: X axis (East/West)
		secondaryDirX = (dx > 0) and 1 or -1
		secondaryDirY = 0
	end

	return primaryDirX, primaryDirY, secondaryDirX, secondaryDirY
end

local function getFacingEdgeCorners(area, dirX, dirY, _)
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

local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Clamp door endpoints away from wall corners using axis-based distance
local function clampDoorAwayFromWalls(overlapLeft, overlapRight, areaA, areaB, varyingAxis)
	local WALL_CLEARANCE = 24

	-- Determine which axis the door varies along (door direction)
	local doorVector = overlapRight - overlapLeft
	local doorAxis = varyingAxis or (math.abs(doorVector.x) > math.abs(doorVector.y) and "x" or "y")

	-- Get min/max on door axis
	local leftCoord = overlapLeft[doorAxis]
	local rightCoord = overlapRight[doorAxis]
	local minCoord = math.min(leftCoord, rightCoord)
	local maxCoord = math.max(leftCoord, rightCoord)

	-- Track clamping adjustments
	local clampFromLeft = 0 -- How much to shrink from left
	local clampFromRight = 0 -- How much to shrink from right

	-- Check wall corners from both areas
	for _, area in ipairs({ areaA, areaB }) do
		if area.wallCorners then
			for _, wallCorner in ipairs(area.wallCorners) do
				local cornerCoord = wallCorner[doorAxis]

				-- Check if wall corner is within door range on the varying axis
				if cornerCoord >= minCoord - WALL_CLEARANCE and cornerCoord <= maxCoord + WALL_CLEARANCE then
					-- Wall corner is near the door, check which side
					if cornerCoord < minCoord then
						-- Wall corner is to the left, need to clamp left endpoint right
						local requiredShift = (minCoord - cornerCoord)
						if requiredShift < WALL_CLEARANCE then
							clampFromLeft = math.max(clampFromLeft, WALL_CLEARANCE - requiredShift)
						end
					elseif cornerCoord > maxCoord then
						-- Wall corner is to the right, need to clamp right endpoint left
						local requiredShift = (cornerCoord - maxCoord)
						if requiredShift < WALL_CLEARANCE then
							clampFromRight = math.max(clampFromRight, WALL_CLEARANCE - requiredShift)
						end
					else
						-- Wall corner is INSIDE door range - clamp away from it
						local distFromLeft = cornerCoord - minCoord
						local distFromRight = maxCoord - cornerCoord
						if distFromLeft < WALL_CLEARANCE then
							clampFromLeft = math.max(clampFromLeft, WALL_CLEARANCE - distFromLeft + 1)
						end
						if distFromRight < WALL_CLEARANCE then
							clampFromRight = math.max(clampFromRight, WALL_CLEARANCE - distFromRight + 1)
						end
					end
				end
			end
		end
	end

	-- Apply clamping by adjusting coordinates
	local clampedLeft = Vector3(overlapLeft.x, overlapLeft.y, overlapLeft.z)
	local clampedRight = Vector3(overlapRight.x, overlapRight.y, overlapRight.z)

	if clampFromLeft > 0 then
		if leftCoord < rightCoord then
			clampedLeft[doorAxis] = leftCoord + clampFromLeft
		else
			clampedLeft[doorAxis] = leftCoord - clampFromLeft
		end
	end

	if clampFromRight > 0 then
		if rightCoord > leftCoord then
			clampedRight[doorAxis] = rightCoord - clampFromRight
		else
			clampedRight[doorAxis] = rightCoord + clampFromRight
		end
	end

	-- Ensure door doesn't become too small
	local finalWidth = (clampedRight - clampedLeft):Length2D()
	if finalWidth < HITBOX_WIDTH then
		return overlapLeft, overlapRight -- Revert if too small
	end

	return clampedLeft, clampedRight
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

-- Get closest corner from neighbor's facing edge to area center
local function getClosestNeighborCorner(neighbor, dirX, dirY, areaCenter)
	local b0, b1 = getFacingEdgeCorners(neighbor, -dirX, -dirY, areaCenter)
	if not (b0 and b1) then
		return nil
	end

	-- Return corner closest to area center
	local dist0 = (b0 - areaCenter):Length2D()
	local dist1 = (b1 - areaCenter):Length2D()
	return (dist0 < dist1) and b0 or b1
end

-- Check if corner lies on area boundary for given direction
local function cornerLiesOnBoundary(corner, area, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(area, dirX, dirY, corner)
	if not (a0 and a1) then
		return false, 0
	end

	-- Determine shared axis
	local axis
	if dirX ~= 0 then
		axis = "y" -- East/West → Y varies
	else
		axis = "x" -- North/South → X varies
	end

	-- Check if corner lies within boundary range on shared axis
	local aMin = math.min(a0[axis], a1[axis])
	local aMax = math.max(a0[axis], a1[axis])
	local cornerCoord = corner[axis]

	local tolerance = 1.0
	if cornerCoord >= aMin - tolerance and cornerCoord <= aMax + tolerance then
		-- Corner is on boundary, calculate distance from boundary edge
		local distFromMin = math.abs(cornerCoord - aMin)
		local distFromMax = math.abs(cornerCoord - aMax)
		return true, math.min(distFromMin, distFromMax)
	end

	return false, math.huge
end

-- Get edge length for an area in a given direction
local function getEdgeLength(area, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(area, dirX, dirY, area.pos)
	if not (a0 and a1) then
		return math.huge
	end
	return (a1 - a0):Length2D()
end

-- Get area diagonal size (min to max corner distance)
local function getAreaDiagonal(area)
	if not (area.nw and area.ne and area.se and area.sw) then
		return 0
	end

	local minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	local maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	local minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
	local maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)

	local dx = maxX - minX
	local dy = maxY - minY
	return math.sqrt(dx * dx + dy * dy)
end

-- Get 3 closest corners from smaller area to bigger area center, sorted by distance
local function get3ClosestCorners(area, centerPos)
	if not (area.nw and area.ne and area.se and area.sw) then
		return nil, nil, nil
	end

	local corners = { area.nw, area.ne, area.se, area.sw }
	local distances = {}

	for i, corner in ipairs(corners) do
		local dist = (corner - centerPos):Length2D()
		table.insert(distances, { corner = corner, dist = dist, index = i })
	end

	-- Sort by distance
	table.sort(distances, function(a, b)
		return a.dist < b.dist
	end)

	return distances[1].corner, distances[2].corner, distances[3].corner
end

-- Check if point lies within edge bounds on shared axis
local function pointWithinEdgeBounds(point, area, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(area, dirX, dirY, point)
	if not (a0 and a1) then
		return false
	end

	local axis = (dirX ~= 0) and "y" or "x"
	local aMin = math.min(a0[axis], a1[axis])
	local aMax = math.max(a0[axis], a1[axis])
	local pointCoord = point[axis]

	local tolerance = 1.0
	return pointCoord >= aMin - tolerance and pointCoord <= aMax + tolerance
end

-- Calculate distance from point to edge boundary on shared axis
local function distanceFromEdgeBoundary(point, area, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(area, dirX, dirY, point)
	if not (a0 and a1) then
		return math.huge
	end

	local axis = (dirX ~= 0) and "y" or "x"
	local aMin = math.min(a0[axis], a1[axis])
	local aMax = math.max(a0[axis], a1[axis])
	local pointCoord = point[axis]

	-- Return smallest distance to boundary edge
	if pointCoord < aMin then
		return math.abs(pointCoord - aMin)
	elseif pointCoord > aMax then
		return math.abs(pointCoord - aMax)
	else
		return 0 -- Point is within bounds
	end
end

-- Test guess direction from perspective of BIGGER edge (checking if smaller edge lies on it)
local function testGuessDirection(biggerEdgeArea, smallerEdgeArea, dirX, dirY)
	-- Get 3 closest corners from smaller edge area to bigger edge area center
	local middleCorner, secondClosest, thirdClosest = get3ClosestCorners(smallerEdgeArea, biggerEdgeArea.pos)
	if not (middleCorner and secondClosest and thirdClosest) then
		return false, nil, nil, nil
	end

	-- Check if middle corner lies on boundary
	local middleOnBoundary = pointWithinEdgeBounds(middleCorner, biggerEdgeArea, dirX, dirY)
	if not middleOnBoundary then
		return false, middleCorner, secondClosest, thirdClosest
	end

	-- Get shared axis
	local axis = (dirX ~= 0) and "y" or "x"

	-- Check if 2nd closest is parallel to edge (shares same axis position as middle)
	local middleCoord = middleCorner[axis]
	local secondCoord = secondClosest[axis]
	local secondParallel = math.abs(secondCoord - middleCoord) < 1.0

	if not secondParallel then
		-- 2nd closest is NOT parallel, check if it lies on boundary
		if pointWithinEdgeBounds(secondClosest, biggerEdgeArea, dirX, dirY) then
			return true, nil, nil, nil
		end
	end

	-- Also check 3rd closest if 2nd was parallel
	local thirdCoord = thirdClosest[axis]
	local thirdParallel = math.abs(thirdCoord - middleCoord) < 1.0

	if not thirdParallel then
		if pointWithinEdgeBounds(thirdClosest, biggerEdgeArea, dirX, dirY) then
			return true, nil, nil, nil
		end
	end

	return false, middleCorner, secondClosest, thirdClosest
end

-- Phantom edge test: create phantom edge 1 unit away in edge direction
local function testPhantomEdge(biggerEdgeArea, middleCorner, secondClosest, thirdClosest, dirX, dirY)
	if not (middleCorner and secondClosest and thirdClosest) then
		return false
	end

	local axis = (dirX ~= 0) and "y" or "x"
	local perpAxis = (axis == "x") and "y" or "x"

	-- Get edge direction along perpendicular axis
	local edgeDir = secondClosest[perpAxis] - middleCorner[perpAxis]
	if math.abs(edgeDir) < 0.1 then
		edgeDir = thirdClosest[perpAxis] - middleCorner[perpAxis]
	end

	-- Normalize direction to +1 or -1
	local dirSign = (edgeDir > 0) and 1 or -1

	-- Create phantom corners 1 unit away
	local phantomSecond = Vector3(secondClosest.x, secondClosest.y, secondClosest.z)
	local phantomThird = Vector3(thirdClosest.x, thirdClosest.y, thirdClosest.z)

	phantomSecond[perpAxis] = phantomSecond[perpAxis] + dirSign
	phantomThird[perpAxis] = phantomThird[perpAxis] + dirSign

	-- Check which phantom lies on boundary
	if pointWithinEdgeBounds(phantomSecond, biggerEdgeArea, dirX, dirY) then
		return true
	end
	if pointWithinEdgeBounds(phantomThird, biggerEdgeArea, dirX, dirY) then
		return true
	end

	return false
end

-- Calculate edge overlap between two areas along a specific axis
local function calculateEdgeOverlap(areaA, areaB, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(areaA, dirX, dirY, areaB.pos)
	local b0, b1 = getFacingEdgeCorners(areaB, -dirX, -dirY, areaA.pos)

	if not (a0 and a1 and b0 and b1) then
		return 0
	end

	local axis = (dirX ~= 0) and "y" or "x"

	local aMin = math.min(a0[axis], a1[axis])
	local aMax = math.max(a0[axis], a1[axis])
	local bMin = math.min(b0[axis], b1[axis])
	local bMax = math.max(b0[axis], b1[axis])

	-- Calculate overlap
	local overlapMin = math.max(aMin, bMin)
	local overlapMax = math.min(aMax, bMax)

	if overlapMax > overlapMin then
		return overlapMax - overlapMin
	end

	return 0
end

-- Final fallback: compare edge overlaps to determine shared edge
local function resolveStalemateByOverlap(areaA, areaB, primaryDirX, primaryDirY, secondaryDirX, secondaryDirY)
	-- Calculate overlap for both directions
	local primaryOverlap = calculateEdgeOverlap(areaA, areaB, primaryDirX, primaryDirY)
	local secondaryOverlap = calculateEdgeOverlap(areaA, areaB, secondaryDirX, secondaryDirY)

	-- Pick direction with most overlap (favor primary in tie)
	if secondaryOverlap > primaryOverlap then
		return secondaryDirX, secondaryDirY
	end
	return primaryDirX, primaryDirY
end

-- Validate shared edge direction from BIGGER edge perspective with fallback logic
local function validateSharedEdge(areaA, areaB, primaryDirX, primaryDirY, secondaryDirX, secondaryDirY)
	-- Get edge lengths for both directions
	local edgeLengthA_primary = getEdgeLength(areaA, primaryDirX, primaryDirY)
	local edgeLengthB_primary = getEdgeLength(areaB, -primaryDirX, -primaryDirY)

	local edgeLengthA_secondary = getEdgeLength(areaA, secondaryDirX, secondaryDirY)
	local edgeLengthB_secondary = getEdgeLength(areaB, -secondaryDirX, -secondaryDirY)

	-- Only test from BIGGER edge perspective for each direction
	-- Skip if our edge is smaller (let the bigger edge handle it)
	local primarySuccess, primaryMiddle, primarySecond, primaryThird = false, nil, nil, nil
	local secondarySuccess, secondaryMiddle, secondarySecond, secondaryThird = false, nil, nil, nil

	-- Test PRIMARY guess from bigger edge perspective
	if edgeLengthA_primary >= edgeLengthB_primary then
		-- areaA has bigger primary edge
		primarySuccess, primaryMiddle, primarySecond, primaryThird =
			testGuessDirection(areaA, areaB, primaryDirX, primaryDirY)
	elseif edgeLengthB_primary > edgeLengthA_primary then
		-- areaB has bigger primary edge
		primarySuccess, primaryMiddle, primarySecond, primaryThird =
			testGuessDirection(areaB, areaA, -primaryDirX, -primaryDirY)
	end

	if primarySuccess then
		return primaryDirX, primaryDirY
	end

	-- Test SECONDARY guess from bigger edge perspective
	if edgeLengthA_secondary >= edgeLengthB_secondary then
		-- areaA has bigger secondary edge
		secondarySuccess, secondaryMiddle, secondarySecond, secondaryThird =
			testGuessDirection(areaA, areaB, secondaryDirX, secondaryDirY)
	elseif edgeLengthB_secondary > edgeLengthA_secondary then
		-- areaB has bigger secondary edge
		secondarySuccess, secondaryMiddle, secondarySecond, secondaryThird =
			testGuessDirection(areaB, areaA, -secondaryDirX, -secondaryDirY)
	end

	if secondarySuccess then
		return secondaryDirX, secondaryDirY
	end

	-- FALLBACK 1: Try phantom edge test for primary
	if primaryMiddle and primarySecond and primaryThird then
		local biggerAreaPrimary = (edgeLengthA_primary >= edgeLengthB_primary) and areaA or areaB
		local testPrimaryDirX = (biggerAreaPrimary == areaA) and primaryDirX or -primaryDirX
		local testPrimaryDirY = (biggerAreaPrimary == areaA) and primaryDirY or -primaryDirY

		if
			testPhantomEdge(
				biggerAreaPrimary,
				primaryMiddle,
				primarySecond,
				primaryThird,
				testPrimaryDirX,
				testPrimaryDirY
			)
		then
			return primaryDirX, primaryDirY
		end
	end

	-- FALLBACK 2: Try phantom edge test for secondary
	if secondaryMiddle and secondarySecond and secondaryThird then
		local biggerAreaSecondary = (edgeLengthA_secondary >= edgeLengthB_secondary) and areaA or areaB
		local testSecondaryDirX = (biggerAreaSecondary == areaA) and secondaryDirX or -secondaryDirX
		local testSecondaryDirY = (biggerAreaSecondary == areaA) and secondaryDirY or -secondaryDirY

		if
			testPhantomEdge(
				biggerAreaSecondary,
				secondaryMiddle,
				secondarySecond,
				secondaryThird,
				testSecondaryDirX,
				testSecondaryDirY
			)
		then
			return secondaryDirX, secondaryDirY
		end
	end

	-- FALLBACK 3: Compare edge overlaps (most expensive but guaranteed to work)
	return resolveStalemateByOverlap(areaA, areaB, primaryDirX, primaryDirY, secondaryDirX, secondaryDirY)
end

-- Calculate edge overlap and door geometry
local function calculateDoorGeometry(areaA, areaB, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(areaA, dirX, dirY, areaB.pos)
	local b0, b1 = getFacingEdgeCorners(areaB, -dirX, -dirY, areaA.pos)
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

local function createDoorForAreas(areaA, areaB)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		return nil
	end

	-- Get primary and secondary direction options
	local primaryDirX, primaryDirY, secondaryDirX, secondaryDirY = determineDirection(areaA.pos, areaB.pos)

	-- Validate and pick correct shared edge direction
	local dirX, dirY = validateSharedEdge(areaA, areaB, primaryDirX, primaryDirY, secondaryDirX, secondaryDirY)

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

	-- If overlap too small, create center-only door at midpoint between areas
	if overlapMax - overlapMin < HITBOX_WIDTH then
		local centerPoint = lerpVec(a0, a1, 0.5)
		Common.DebugLog("Info", "Door %d->%d: No overlap, using center-only door", areaA.id, areaB.id)
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
		-- Too narrow after clamping, use center-only door
		local centerPoint = lerpVec(overlapLeft, overlapRight, 0.5)
		Common.DebugLog("Info", "Door %d->%d: Too narrow after clamping, using center-only door", areaA.id, areaB.id)
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

function ConnectionBuilder.BuildDoorsForConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local doorsBuilt = 0
	local processedPairs = {} -- Track processed area pairs to avoid duplicates
	local doorNodes = {} -- Store created door nodes

	-- Find all unique area-to-area connections
	-- Count total connections first for debugging
	local totalConnections = 0
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					totalConnections = totalConnections + #dir.connections
				end
			end
		end
	end
	Log:Info("Total area connections found: %d", totalConnections)

	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then -- Only process actual areas
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode and not targetNode.isDoor then
							-- Create unique pair key (sorted to avoid duplicates)
							local pairKey = nodeId < targetId and (nodeId .. "_" .. targetId)
								or (targetId .. "_" .. nodeId)

							if not processedPairs[pairKey] then
								processedPairs[pairKey] = true

								-- Find reverse direction (if exists) in ORIGINAL area graph
								local revDir = nil
								local hasReverse = false
								if targetNode.c then
									for tDirId, tDir in pairs(targetNode.c) do
										if tDir.connections then
											for _, tConn in ipairs(tDir.connections) do
												if ConnectionUtils.GetNodeId(tConn) == nodeId then
													hasReverse = true
													revDir = tDirId
													Log:Debug(
														"Connection %s->%s: Found reverse (bidirectional)",
														nodeId,
														targetId
													)
													break
												end
											end
											if hasReverse then
												break
											end
										end
									end
								end

								if not hasReverse then
									Log:Debug("Connection %s->%s: No reverse found (one-way)", nodeId, targetId)
								end

								-- Create SHARED doors (use canonical ordering for IDs)
								local door = createDoorForAreas(node, targetNode)
								if door then
									local fwdDir = dirId

									-- Use smaller nodeId first for canonical door IDs
									local doorPrefix = (nodeId < targetId) and (nodeId .. "_" .. targetId)
										or (targetId .. "_" .. nodeId)

									-- Calculate which SIDE of area the door is on (based on position, not connection direction)
									local function getDoorSide(doorPos, areaPos)
										local dx = doorPos.x - areaPos.x
										local dy = doorPos.y - areaPos.y

										-- Determine which axis has larger difference
										if math.abs(dx) > math.abs(dy) then
											-- Door is on East or West side
											return (dx > 0) and 4 or 8 -- East=4, West=8
										else
											-- Door is on North or South side
											return (dy > 0) and 2 or 1 -- South=2, North=1
										end
									end

									-- Create door nodes with bidirectional connections (if applicable)
									if door.left then
										local doorId = doorPrefix .. "_left"
										local doorSide = getDoorSide(door.left, node.pos)
										doorNodes[doorId] = {
											id = doorId,
											pos = door.left,
											isDoor = true,
											areaId = nodeId, -- Store both area associations
											targetAreaId = targetId,
											direction = doorSide, -- Store which SIDE of area this door is on (N/S/E/W)
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										-- Add reverse connection if bidirectional
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end

									if door.middle then
										local doorId = doorPrefix .. "_middle"
										local doorSide = getDoorSide(door.middle, node.pos)
										doorNodes[doorId] = {
											id = doorId,
											pos = door.middle,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											direction = doorSide, -- Store which SIDE of area this door is on (N/S/E/W)
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end

									if door.right then
										local doorId = doorPrefix .. "_right"
										local doorSide = getDoorSide(door.right, node.pos)
										doorNodes[doorId] = {
											id = doorId,
											pos = door.right,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											direction = doorSide, -- Store which SIDE of area this door is on (N/S/E/W)
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Add door nodes to graph
	for doorId, doorNode in pairs(doorNodes) do
		nodes[doorId] = doorNode
	end

	-- Build door-to-door connections FIRST (while area graph is intact)
	ConnectionBuilder.BuildDoorToDoorConnections()

	-- THEN replace area-to-area connections with area-to-door connections
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					local newConnections = {}

					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode and not targetNode.isDoor then
							-- Find door nodes - try both orderings (canonical pair key)
							local doorPrefix1 = nodeId .. "_" .. targetId
							local doorPrefix2 = targetId .. "_" .. nodeId
							local foundDoors = false

							-- Try both possible door ID patterns
							for _, prefix in ipairs({ doorPrefix1, doorPrefix2 }) do
								for suffix in pairs({ _left = true, _middle = true, _right = true }) do
									local doorId = prefix .. suffix
									if nodes[doorId] then
										table.insert(newConnections, doorId)
										foundDoors = true
									end
								end
								if foundDoors then
									break
								end -- Found doors with this prefix
							end

							-- If no doors found, keep original connection
							if not foundDoors then
								table.insert(newConnections, connection)
							end
						else
							-- Keep non-area connections
							table.insert(newConnections, connection)
						end
					end

					dir.connections = newConnections
					dir.count = #newConnections
				end
			end
		end
	end

	Log:Info("Built " .. doorsBuilt .. " door nodes for connections")
end

-- Determine spatial direction between two positions
local function calculateSpatialDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y

	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 4 or 8 -- East or West
	else
		return (dy > 0) and 2 or 1 -- South or North
	end
end

-- Create optimized door-to-door connections
function ConnectionBuilder.BuildDoorToDoorConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local connectionsAdded = 0
	local doorsByArea = {}

	-- Group doors by area for efficient lookup
	-- Only add door to an area if it connects BACK to that area (not one-way exit)
	for doorId, doorNode in pairs(nodes) do
		if doorNode.isDoor and doorNode.c then
			-- Check which areas this door connects TO
			for _, dir in pairs(doorNode.c) do
				if dir.connections then
					for _, conn in ipairs(dir.connections) do
						local connectedAreaId = ConnectionUtils.GetNodeId(conn)
						-- Add door to the area it connects to
						if not doorsByArea[connectedAreaId] then
							doorsByArea[connectedAreaId] = {}
						end
						table.insert(doorsByArea[connectedAreaId], doorNode)
					end
				end
			end
		end
	end

	-- Helper to calculate which side a door is on relative to an area
	local function getDoorSideForArea(doorPos, areaId)
		local area = nodes[areaId]
		if not area or not area.pos then
			return nil
		end

		local dx = doorPos.x - area.pos.x
		local dy = doorPos.y - area.pos.y

		if math.abs(dx) > math.abs(dy) then
			return (dx > 0) and 4 or 8 -- East=4, West=8
		else
			return (dy > 0) and 2 or 1 -- South=2, North=1
		end
	end

	-- Connect doors within each area (respecting one-way connections)
	for areaId, doors in pairs(doorsByArea) do
		for i = 1, #doors do
			local doorA = doors[i]

			for j = 1, #doors do
				if i ~= j then
					local doorB = doors[j]

					-- Calculate which side each door is on RELATIVE TO THIS AREA
					local sideA = getDoorSideForArea(doorA.pos, areaId)
					local sideB = getDoorSideForArea(doorB.pos, areaId)

					-- ONLY connect doors on DIFFERENT sides to avoid wall collisions
					if sideA and sideB and sideA ~= sideB then
						-- Check if BOTH doors are bidirectional (not one-way drops)
						-- One-way doors (dirCount == 1) should not participate in door-to-door
						local doorAIsBidirectional = false
						local doorBIsBidirectional = false

						if doorA.c then
							local dirCount = 0
							for _ in pairs(doorA.c) do
								dirCount = dirCount + 1
							end
							doorAIsBidirectional = (dirCount >= 2)
						end

						if doorB.c then
							local dirCount = 0
							for _ in pairs(doorB.c) do
								dirCount = dirCount + 1
							end
							doorBIsBidirectional = (dirCount >= 2)
						end

						-- Only create door-to-door if BOTH doors are bidirectional
						if doorAIsBidirectional and doorBIsBidirectional then
							local spatialDirAtoB = calculateSpatialDirection(doorA.pos, doorB.pos)

							if not doorA.c[spatialDirAtoB] then
								doorA.c[spatialDirAtoB] = { connections = {}, count = 0 }
							end

							-- Add A→B connection
							local alreadyConnected = false
							for _, conn in ipairs(doorA.c[spatialDirAtoB].connections) do
								if ConnectionUtils.GetNodeId(conn) == doorB.id then
									alreadyConnected = true
									break
								end
							end

							if not alreadyConnected then
								table.insert(doorA.c[spatialDirAtoB].connections, doorB.id)
								doorA.c[spatialDirAtoB].count = #doorA.c[spatialDirAtoB].connections
								connectionsAdded = connectionsAdded + 1
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Added " .. connectionsAdded .. " door-to-door connections for path optimization")
end

function ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then
		return nil
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				if targetId == nodeB.id then
					-- Return connection info if it's a table, otherwise just the ID
					if type(connection) == "table" then
						return connection
					else
						-- For door connections (strings), return basic info
						return {
							nodeId = connection,
							isDoorConnection = true,
						}
					end
				end
			end
		end
	end
	return nil
end

function ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then
		return nil
	end

	-- Find door nodes that connect areaA to areaB
	local nodes = G.Navigation.nodes
	if not nodes then
		return areaB.pos
	end

	-- Look for door nodes that have areaA as source and areaB as target
	local doorBaseId = areaA.id .. "_" .. areaB.id
	local doorPositions = {}

	-- Check all three door positions (left, middle, right)
	for _, suffix in ipairs({ "_left", "_middle", "_right" }) do
		local doorId = doorBaseId .. suffix
		local doorNode = nodes[doorId]
		if doorNode and doorNode.pos then
			table.insert(doorPositions, doorNode.pos)
		end
	end

	if #doorPositions > 0 then
		-- Find closest door position to destination
		local bestPos = doorPositions[1]
		local bestDist = (doorPositions[1] - areaB.pos):Length()

		for i = 2, #doorPositions do
			local dist = (doorPositions[i] - areaB.pos):Length()
			if dist < bestDist then
				bestPos = doorPositions[i]
				bestDist = dist
			end
		end

		return bestPos
	end

	return areaB.pos
end

return ConnectionBuilder
