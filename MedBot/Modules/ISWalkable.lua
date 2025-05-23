local isWalkable = {}
local G = require("MedBot.Utils.Globals")

local Jump_Height = 72 --duck jump height
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max

local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable
local GRAVITY = 800 -- Gravity in units per second squared
local MIN_STEP_SIZE = 5 -- Minimum step size in units
local preferredSteps = 10 --prefered number oif steps for simulations


-- Function to convert degrees to radians
local function degreesToRadians(degrees)
    return degrees * math.pi / 180
end

-- Checks for an obstruction between two points using a hull trace.
local function performHullTrace(startPos, endPos)
    return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, MASK_PLAYERSOLID_BRUSHONLY)
end

-- Precomputed up vector and max slope angle in radians
local MAX_SLOPE_ANGLE_RAD = degreesToRadians(MAX_SLOPE_ANGLE)

-- Function to adjust direction based on ground normal
local function adjustDirectionToGround(direction, groundNormal)
    local angleBetween = math.acos(groundNormal:Dot(UP_VECTOR))
    if angleBetween <= MAX_SLOPE_ANGLE_RAD then
        return (direction:Cross(UP_VECTOR):Cross(groundNormal)):Normalized()
    end
    return direction -- If the slope is too steep, keep the original direction
end

-- Main function to check if the path between the current position and the node is walkable.
function isWalkable.Path(startPos, endPos)
    local direction = (endPos - startPos):Normalized()
    local totalDistance = (endPos - startPos):Length()
    local stepSize = math.max(MIN_STEP_SIZE, totalDistance / preferredSteps)
    local currentPosition = startPos
    local requiredFraction = STEP_HEIGHT / Jump_Height

    while (endPos - currentPosition):Length() > stepSize do
        local nextPosition = currentPosition + direction * stepSize
        local forwardTraceResult = performHullTrace(currentPosition, nextPosition)

        if forwardTraceResult.fraction < 1 then
            local collisionPosition = forwardTraceResult.endpos
            local forwardPosition = collisionPosition + direction * 1
            local upPosition = forwardPosition + Vector3(0, 0, Jump_Height)
            local traceDownResult = performHullTrace(upPosition, forwardPosition)

            -- Determine if we can step up or jump over the obstacle
            local canMove = traceDownResult.fraction >= requiredFraction or (traceDownResult.fraction > 0 and G.Menu.Movement.Smart_Jump)
            currentPosition = canMove and traceDownResult.endpos or currentPosition

            -- If we couldn't step up or jump over, the path is blocked
            if not canMove or currentPosition == collisionPosition then
                return false
            end
        else
            currentPosition = nextPosition
        end

        -- Simulate falling
        local fallDistance = (stepSize / 450) * GRAVITY
        local fallPosition = currentPosition - Vector3(0, 0, fallDistance)
        local groundTraceResult = performHullTrace(currentPosition, fallPosition)
        currentPosition = groundTraceResult.endpos

        -- Adjust direction to align with the ground
        direction = adjustDirectionToGround((endPos - currentPosition):Normalized(), groundTraceResult.plane)
    end

    return true -- Path is walkable
end

return isWalkable