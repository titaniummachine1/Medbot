local Common = require("MedBot.Core.Common")
local EdgeCalculator = require("MedBot.Navigation.EdgeCalculator")

local AxisCalculator = {}

local Log = Common.Log.new("AxisCalculator")

-- Get direction from areaA to areaB
function AxisCalculator.GetDirection(posA, posB)
	if not (posA and posB) then
		return { axis = "x", isPositive = true }
	end

	local dx = posB.x - posA.x
	local dy = posB.y - posA.y

	if math.abs(dx) > math.abs(dy) then
		-- East/West: horizontal movement, vertical edge
		return {
			axis = "x",
			isPositive = dx > 0,
			edgeAxis = "y", -- The axis along which the edge varies
		}
	else
		-- North/South: vertical movement, horizontal edge
		return {
			axis = "y",
			isPositive = dy > 0,
			edgeAxis = "x", -- The axis along which the edge varies
		}
	end
end

-- Get opposite direction
function AxisCalculator.GetOppositeDirection(direction)
	return {
		axis = direction.axis,
		isPositive = not direction.isPositive,
		edgeAxis = direction.edgeAxis,
	}
end

-- Get the two corners that form the edge facing the neighbor
function AxisCalculator.GetEdgeCorners(area, direction)
	if not (area and direction) then
		Log:Debug("GetEdgeCorners: area or direction is nil")
		return nil, nil
	end

	-- Check if area has corner properties
	if not (area.nw and area.ne and area.se and area.sw) then
		Log:Debug("GetEdgeCorners: area %d missing corner properties: nw=%s, ne=%s, se=%s, sw=%s",
			area.id or "unknown", tostring(area.nw), tostring(area.ne), tostring(area.se), tostring(area.sw))
		return nil, nil
	end

	-- Determine which edge to use based on direction
	if direction.axis == "x" then
		-- East/West: use left or right edge
		if direction.isPositive then
			-- Moving east: use right edge (ne, se)
			return area.ne, area.se
		else
			-- Moving west: use left edge (nw, sw)
			return area.nw, area.sw
		end
	else
		-- North/South: use top or bottom edge
		if direction.isPositive then
			-- Moving north: use top edge (nw, ne)
			return area.nw, area.ne
		else
			-- Moving south: use bottom edge (sw, se)
			return area.sw, area.se
		end
	end
end

-- Calculate overlap between two ranges
function AxisCalculator.CalculateOverlap(a0, a1, b0, b1)
	-- Sort each pair
	local aMin, aMax = math.min(a0, a1), math.max(a0, a1)
	local bMin, bMax = math.min(b0, b1), math.max(b0, b1)

	-- Calculate overlap
	local overlapMin = math.max(aMin, bMin)
	local overlapMax = math.min(aMax, bMax)

	-- Check if there's actually an overlap
	if overlapMin < overlapMax then
		return overlapMin, overlapMax
	else
		return nil, nil -- No overlap
	end
end

-- Clamp endpoints away from wall corners
function AxisCalculator.ClampEndpoints(left, right, wallCorners, direction, minWidth)
	if not (left and right and wallCorners) then
		return left, right
	end

	-- Get the axis along which the door varies (the edge axis)
	local varyAxis = direction.edgeAxis or (direction.axis == "x" and "y" or "x")
	local varyCoord = (varyAxis == "x") and left.x or left.y

	-- Find wall corners that might interfere
	local clampedLeft = left
	local clampedRight = right
	local leftChanged = false
	local rightChanged = false

	for _, corner in ipairs(wallCorners) do
		local cornerCoord = (varyAxis == "x") and corner.x or corner.y

		-- Check if corner is within the door range and close to edge
		if cornerCoord >= varyCoord - minWidth and cornerCoord <= varyCoord + minWidth then
			-- Corner is near our door edge, clamp away from it
			if cornerCoord < varyCoord then
				-- Corner is to the left of door start
				clampedLeft = left + (right - left):Normalized() * minWidth
				leftChanged = true
			elseif cornerCoord > varyCoord then
				-- Corner is to the right of door end
				clampedRight = right - (right - left):Normalized() * minWidth
				rightChanged = true
			end
		end
	end

	return clampedLeft, clampedRight
end

return AxisCalculator
