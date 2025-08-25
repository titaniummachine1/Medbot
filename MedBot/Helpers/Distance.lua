--[[ Distance Calculation Helpers ]]
-- Centralized distance calculations for performance and consistency

local Distance = {}

-- Constants
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local HITBOX_WIDTH = 48

-- Fast 2D distance using engine's optimized Length2D()
function Distance.Fast2D(posA, posB)
    return (posA - posB):Length2D()
end

-- 3D distance using engine's optimized Length()
function Distance.Fast3D(posA, posB)
    return (posA - posB):Length()
end

-- Manhattan distance (for rough culling/sorting)
function Distance.Manhattan2D(posA, posB)
    return math.abs(posA.x - posB.x) + math.abs(posA.y - posB.y)
end

-- Manhattan 3D distance
function Distance.Manhattan3D(posA, posB)
    return math.abs(posA.x - posB.x) + math.abs(posA.y - posB.y) + math.abs(posA.z - posB.z)
end

-- Squared distance (avoids sqrt for comparisons)
function Distance.Squared2D(posA, posB)
    local dx = posA.x - posB.x
    local dy = posA.y - posB.y
    return dx*dx + dy*dy
end

function Distance.Squared3D(posA, posB)
    local dx = posA.x - posB.x
    local dy = posA.y - posB.y
    local dz = posA.z - posB.z
    return dx*dx + dy*dy + dz*dz
end

-- Height difference (Z-axis only)
function Distance.HeightDiff(posA, posB)
    return math.abs(posA.z - posB.z)
end

-- Point to line segment distance (2D)
function Distance.PointToSegment2D(px, py, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local wx, wy = px - ax, py - ay
    local vv = vx * vx + vy * vy
    
    if vv == 0 then
        return math.sqrt(wx * wx + wy * wy)
    end
    
    local t = math.max(0, math.min(1, (wx * vx + wy * vy) / vv))
    local cx, cy = ax + t * vx, ay + t * vy
    local dx, dy = px - cx, py - cy
    return math.sqrt(dx * dx + dy * dy)
end

-- Check if within render radius (optimized for frequent calls)
function Distance.WithinRadius(pos, centerPos, radius)
    return Distance.Fast3D(pos, centerPos) <= radius
end

-- Check if within squared radius (faster for comparisons)
function Distance.WithinRadiusSquared(pos, centerPos, radiusSquared)
    return Distance.Squared3D(pos, centerPos) <= radiusSquared
end

-- Navigation-specific distance checks
function Distance.IsWalkableHeight(posA, posB)
    local heightDiff = Distance.HeightDiff(posA, posB)
    return heightDiff <= STEP_HEIGHT
end

function Distance.IsJumpableHeight(posA, posB)
    local heightDiff = Distance.HeightDiff(posA, posB)
    return heightDiff > STEP_HEIGHT and heightDiff <= MAX_JUMP
end

-- Wall clearance check (24 units from corners)
function Distance.HasWallClearance(doorPos, cornerPos)
    return Distance.Fast3D(doorPos, cornerPos) >= 24
end

return Distance
