--##########################################################################
--  AxisCalculator.lua  ·  Reusable axis-based calculations for edges and boundaries
--##########################################################################

local Common = require("MedBot.Core.Common")

local AxisCalculator = {}

-- Direction constants
AxisCalculator.DIRECTIONS = {
    NORTH = {x = 0, y = -1, name = "north", axis = "y", primary = "y"},
    SOUTH = {x = 0, y = 1, name = "south", axis = "y", primary = "y"},
    EAST = {x = 1, y = 0, name = "east", axis = "x", primary = "x"},
    WEST = {x = -1, y = 0, name = "west", axis = "x", primary = "x"}
}

-- Get direction from position delta
function AxisCalculator.GetDirection(fromPos, toPos)
    local dx = toPos.x - fromPos.x
    local dy = toPos.y - fromPos.y

    if math.abs(dx) >= math.abs(dy) then
        return (dx > 0) and AxisCalculator.DIRECTIONS.EAST or AxisCalculator.DIRECTIONS.WEST
    else
        return (dy > 0) and AxisCalculator.DIRECTIONS.SOUTH or AxisCalculator.DIRECTIONS.NORTH
    end
end

-- Get the two corners that form the edge for a given direction
function AxisCalculator.GetEdgeCorners(area, direction)
    if not (area and area.nw and area.ne and area.se and area.sw) then
        return nil, nil
    end

    if direction == AxisCalculator.DIRECTIONS.NORTH then
        return area.nw, area.ne
    elseif direction == AxisCalculator.DIRECTIONS.SOUTH then
        return area.se, area.sw
    elseif direction == AxisCalculator.DIRECTIONS.EAST then
        return area.ne, area.se
    elseif direction == AxisCalculator.DIRECTIONS.WEST then
        return area.sw, area.nw
    end

    return nil, nil
end

-- Get the facing boundary of a neighbor (opposite direction)
function AxisCalculator.GetFacingBoundary(neighbor, direction)
    if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
        return nil
    end

    if direction == AxisCalculator.DIRECTIONS.NORTH then
        return {neighbor.sw, neighbor.se} -- South boundary
    elseif direction == AxisCalculator.DIRECTIONS.SOUTH then
        return {neighbor.nw, neighbor.ne} -- North boundary
    elseif direction == AxisCalculator.DIRECTIONS.EAST then
        return {neighbor.sw, neighbor.nw} -- West boundary
    elseif direction == AxisCalculator.DIRECTIONS.WEST then
        return {neighbor.se, neighbor.ne} -- East boundary
    end

    return nil
end

-- Calculate 1D overlap between two segments on a given axis
function AxisCalculator.CalculateOverlap(a1, a2, b1, b2)
    if a1 > a2 then a1, a2 = a2, a1 end
    if b1 > b2 then b1, b2 = b2, b1 end

    local left = math.max(a1, b1)
    local right = math.min(a2, b2)

    if right <= left then
        return nil
    end

    return left, right
end

-- Interpolate position along an edge at parameter t [0,1]
function AxisCalculator.InterpolateEdgePoint(edgeStart, edgeEnd, t, constantAxis)
    t = math.max(0, math.min(1, t))

    local x, y, z

    if constantAxis == "x" then
        -- Y varies, X is constant
        x = edgeStart.x
        y = edgeStart.y + (edgeEnd.y - edgeStart.y) * t
        z = edgeStart.z + (edgeEnd.z - edgeStart.z) * t
    else
        -- X varies, Y is constant
        x = edgeStart.x + (edgeEnd.x - edgeStart.x) * t
        y = edgeStart.y
        z = edgeStart.z + (edgeEnd.z - edgeStart.z) * t
    end

    return Vector3(x, y, z)
end

-- Clamp a point away from obstacles on a specific axis
function AxisCalculator.ClampPointOnAxis(point, obstacles, direction, clearance)
    local clampedPoint = {x = point.x, y = point.y, z = point.z}

    for _, obstacle in ipairs(obstacles) do
        local dist = Common.Distance2D(point, Vector3(obstacle.x, obstacle.y, 0))

        if dist < clearance then
            if direction.axis == "x" then
                -- Clamp on X axis (horizontal movement)
                if obstacle.x < point.x then
                    clampedPoint.x = obstacle.x + clearance
                else
                    clampedPoint.x = obstacle.x - clearance
                end
            else
                -- Clamp on Y axis (vertical movement)
                if obstacle.y < point.y then
                    clampedPoint.y = obstacle.y + clearance
                else
                    clampedPoint.y = obstacle.y - clearance
                end
            end
        end
    end

    return Vector3(clampedPoint.x, clampedPoint.y, clampedPoint.z)
end

-- Clamp two endpoints away from obstacles
function AxisCalculator.ClampEndpoints(leftPoint, rightPoint, obstacles, direction, clearance)
    local clampedLeft = leftPoint
    local clampedRight = rightPoint

    for _, obstacle in ipairs(obstacles) do
        local leftDist = Common.Distance2D(clampedLeft, Vector3(obstacle.x, obstacle.y, 0))
        local rightDist = Common.Distance2D(clampedRight, Vector3(obstacle.x, obstacle.y, 0))

        if leftDist < clearance or rightDist < clearance then
            if direction.axis == "x" then
                if obstacle.x < clampedLeft.x and leftDist < clearance then
                    clampedLeft = Vector3(obstacle.x + clearance, clampedLeft.y, clampedLeft.z)
                elseif obstacle.x > clampedRight.x and rightDist < clearance then
                    clampedRight = Vector3(obstacle.x - clearance, clampedRight.y, clampedRight.z)
                end
            else
                if obstacle.y < clampedLeft.y and leftDist < clearance then
                    clampedLeft = Vector3(clampedLeft.x, obstacle.y + clearance, clampedLeft.z)
                elseif obstacle.y > clampedRight.y and rightDist < clearance then
                    clampedRight = Vector3(clampedRight.x, obstacle.y - clearance, clampedRight.z)
                end
            end
        end
    end

    return clampedLeft, clampedRight
end

-- Check if point lies on a boundary segment within max distance
function AxisCalculator.PointLiesOnBoundary(point, boundaryStart, boundaryEnd, maxDistance)
    local distance = AxisCalculator.PointToLineSegmentDistance(point, boundaryStart, boundaryEnd)
    return distance <= maxDistance
end

-- Calculate distance from point to line segment (2D, ignores Z)
function AxisCalculator.PointToLineSegmentDistance(point, lineStart, lineEnd)
    local dx = lineEnd.x - lineStart.x
    local dy = lineEnd.y - lineStart.y
    local length = Vector3(dx, dy, 0):Length2D()

    if length == 0 then
        -- Line segment is a point
        local point2D = Vector3(point.x, point.y, 0)
        local start2D = Vector3(lineStart.x, lineStart.y, 0)
        return Common.Distance2D(point2D, start2D)
    end

    -- Calculate projection parameter
    local t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / (length * length)
    t = math.max(0, math.min(1, t))

    -- Calculate closest point on line segment
    local closestX = lineStart.x + t * dx
    local closestY = lineStart.y + t * dy

    -- Final distance calculation
    local point2D = Vector3(point.x, point.y, 0)
    local closest2D = Vector3(closestX, closestY, 0)
    return Common.Distance2D(point2D, closest2D)
end

-- Group connections by direction for an area
function AxisCalculator.GroupConnectionsByDirection(area, nodes)
    local connections = {
        north = {}, south = {}, east = {}, west = {}
    }

    if not area.c then
        return connections
    end

    for dirId, dir in pairs(area.c) do
        if dir.connections then
            for _, connection in ipairs(dir.connections) do
                local targetId = (type(connection) == "table") and connection.node or connection
                local neighbor = nodes[targetId]
                if neighbor then
                    local direction = AxisCalculator.GetDirection(area.pos, neighbor.pos)
                    table.insert(connections[direction.name], neighbor)
                end
            end
        end
    end

    return connections
end

-- Get the opposite direction
function AxisCalculator.GetOppositeDirection(direction)
    if direction == AxisCalculator.DIRECTIONS.NORTH then
        return AxisCalculator.DIRECTIONS.SOUTH
    elseif direction == AxisCalculator.DIRECTIONS.SOUTH then
        return AxisCalculator.DIRECTIONS.NORTH
    elseif direction == AxisCalculator.DIRECTIONS.EAST then
        return AxisCalculator.DIRECTIONS.WEST
    elseif direction == AxisCalculator.DIRECTIONS.WEST then
        return AxisCalculator.DIRECTIONS.EAST
    end
end

return AxisCalculator
