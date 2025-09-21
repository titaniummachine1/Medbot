--[[
MedBot Math Utilities Module
Consolidated math functions used across the codebase
--]]

local MathUtils = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local DEG_TO_RAD = math.pi / 180
local RAD_TO_DEG = 180 / math.pi

-- ============================================================================
-- VECTOR MATH UTILITIES
-- ============================================================================

---Linear interpolation between two values
---@param a number Start value
---@param b number End value
---@param t number Interpolation factor (0-1)
---@return number Interpolated value
function MathUtils.Lerp(a, b, t)
    return a + (b - a) * t
end

---Linear interpolation between two Vector3 values
---@param a Vector3 Start vector
---@param b Vector3 End vector
---@param t number Interpolation factor (0-1)
---@return Vector3 Interpolated vector
function MathUtils.LerpVec(a, b, t)
    return Vector3(
        MathUtils.Lerp(a.x, b.x, t),
        MathUtils.Lerp(a.y, b.y, t),
        MathUtils.Lerp(a.z, b.z, t)
    )
end

---Clamp a value between min and max
---@param value number Value to clamp
---@param min number Minimum value
---@param max number Maximum value
---@return number Clamped value
function MathUtils.Clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

---Clamp a Vector3 between min and max values
---@param vec Vector3 Vector to clamp
---@param min number Minimum value
---@param max number Maximum value
---@return Vector3 Clamped vector
function MathUtils.ClampVec(vec, min, max)
    return Vector3(
        MathUtils.Clamp(vec.x, min, max),
        MathUtils.Clamp(vec.y, min, max),
        MathUtils.Clamp(vec.z, min, max)
    )
end

---Convert degrees to radians
---@param degrees number Angle in degrees
---@return number Angle in radians
function MathUtils.DegToRad(degrees)
    return degrees * DEG_TO_RAD
end

---Convert radians to degrees
---@param radians number Angle in radians
---@return number Angle in degrees
function MathUtils.RadToDeg(radians)
    return radians * RAD_TO_DEG
end

---Calculate 2D distance between two Vector3 points
---@param a Vector3 First point
---@param b Vector3 Second point
---@return number Distance between points
function MathUtils.Distance2D(a, b)
    local dx = b.x - a.x
    local dy = b.y - a.y
    return math.sqrt(dx * dx + dy * dy)
end

---Calculate 3D distance between two Vector3 points
---@param a Vector3 First point
---@param b Vector3 Second point
---@return number Distance between points
function MathUtils.Distance3D(a, b)
    local dx = b.x - a.x
    local dy = b.y - a.y
    local dz = b.z - a.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---Calculate squared 2D distance (more efficient when you only need comparison)
---@param a Vector3 First point
---@param b Vector3 Second point
---@return number Squared distance between points
function MathUtils.Distance2DSquared(a, b)
    local dx = b.x - a.x
    local dy = b.y - a.y
    return dx * dx + dy * dy
end

---Calculate squared 3D distance (more efficient when you only need comparison)
---@param a Vector3 First point
---@param b Vector3 Second point
---@return number Squared distance between points
function MathUtils.Distance3DSquared(a, b)
    local dx = b.x - a.x
    local dy = b.y - a.y
    local dz = b.z - a.z
    return dx * dx + dy * dy + dz * dz
end

---Rotate a vector around the Y axis by the given angle (in radians)
---@param vector Vector3 Vector to rotate
---@param angle number Rotation angle in radians
---@return Vector3 Rotated vector
function MathUtils.RotateVectorByYaw(vector, angle)
    local cos = math.cos(angle)
    local sin = math.sin(angle)
    return Vector3(
        cos * vector.x - sin * vector.y,
        sin * vector.x + cos * vector.y,
        vector.z
    )
end

---Get the angle between two vectors
---@param a Vector3 First vector
---@param b Vector3 Second vector
---@return number Angle in radians
function MathUtils.AngleBetweenVectors(a, b)
    local dot = a:Dot(b)
    local lenA = a:Length()
    local lenB = b:Length()
    if lenA == 0 or lenB == 0 then
        return 0
    end
    local cos = dot / (lenA * lenB)
    return math.acos(MathUtils.Clamp(cos, -1, 1))
end

---Get the angle between two vectors (in degrees)
---@param a Vector3 First vector
---@param b Vector3 Second vector
---@return number Angle in degrees
function MathUtils.AngleBetweenVectorsDeg(a, b)
    return MathUtils.RadToDeg(MathUtils.AngleBetweenVectors(a, b))
end

-- ============================================================================
-- GEOMETRY UTILITIES
-- ============================================================================

---Calculate the normal of a triangle given three points
---@param p1 Vector3 First point
---@param p2 Vector3 Second point
---@param p3 Vector3 Third point
---@return Vector3 Normal vector
function MathUtils.CalculateTriangleNormal(p1, p2, p3)
    local u = p2 - p1
    local v = p3 - p1
    return Vector3(
        u.y * v.z - u.z * v.y,
        u.z * v.x - u.x * v.z,
        u.x * v.y - u.y * v.x
    )
end

---Check if a point is inside a triangle
---@param point Vector3 Point to check
---@param tri1 Vector3 Triangle vertex 1
---@param tri2 Vector3 Triangle vertex 2
---@param tri3 Vector3 Triangle vertex 3
---@return boolean True if point is inside triangle
function MathUtils.IsPointInTriangle(point, tri1, tri2, tri3)
    local function sign(p1, p2, p3)
        return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    end

    local d1 = sign(point, tri1, tri2)
    local d2 = sign(point, tri2, tri3)
    local d3 = sign(point, tri3, tri1)

    local has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)

    return not (has_neg and has_pos)
end

---Calculate the area of a triangle
---@param p1 Vector3 Triangle vertex 1
---@param p2 Vector3 Triangle vertex 2
---@param p3 Vector3 Triangle vertex 3
---@return number Triangle area
function MathUtils.TriangleArea(p1, p2, p3)
    local a = MathUtils.Distance3D(p1, p2)
    local b = MathUtils.Distance3D(p2, p3)
    local c = MathUtils.Distance3D(p3, p1)
    local s = (a + b + c) / 2
    return math.sqrt(s * (s - a) * (s - b) * (s - c))
end

-- ============================================================================
-- INTERPOLATION AND EASING
-- ============================================================================

---Smooth step function (0-1 range)
---@param t number Input value (0-1)
---@return number Smooth stepped value
function MathUtils.SmoothStep(t)
    t = MathUtils.Clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

---Smooth step function with custom edges
---@param t number Input value
---@param edge0 number Lower edge
---@param edge1 number Upper edge
---@return number Smooth stepped value
function MathUtils.SmoothStepRange(t, edge0, edge1)
    local x = (t - edge0) / (edge1 - edge0)
    return MathUtils.SmoothStep(MathUtils.Clamp(x, 0, 1))
end

---Quadratic easing in (acceleration from zero velocity)
---@param t number Input value (0-1)
---@return number Eased value
function MathUtils.EaseInQuad(t)
    return t * t
end

---Quadratic easing out (deceleration to zero velocity)
---@param t number Input value (0-1)
---@return number Eased value
function MathUtils.EaseOutQuad(t)
    return t * (2 - t)
end

---Quadratic easing in-out
---@param t number Input value (0-1)
---@return number Eased value
function MathUtils.EaseInOutQuad(t)
    if t < 0.5 then
        return 2 * t * t
    else
        return -1 + (4 - 2 * t) * t
    end
end

-- ============================================================================
-- ARRAY AND TABLE UTILITIES
-- ============================================================================

---Find the minimum value in an array
---@param array number[] Array of numbers
---@return number Minimum value
function MathUtils.Min(array)
    local min = array[1]
    for i = 2, #array do
        if array[i] < min then
            min = array[i]
        end
    end
    return min
end

---Find the maximum value in an array
---@param array number[] Array of numbers
---@return number Maximum value
function MathUtils.Max(array)
    local max = array[1]
    for i = 2, #array do
        if array[i] > max then
            max = array[i]
        end
    end
    return max
end

---Calculate the average of an array
---@param array number[] Array of numbers
---@return number Average value
function MathUtils.Average(array)
    local sum = 0
    for _, value in ipairs(array) do
        sum = sum + value
    end
    return sum / #array
end

---Calculate the median of an array
---@param array number[] Array of numbers
---@return number Median value
function MathUtils.Median(array)
    local temp = {}
    for _, value in ipairs(array) do
        table.insert(temp, value)
    end
    table.sort(temp)

    local count = #temp
    if count % 2 == 0 then
        return (temp[count / 2] + temp[count / 2 + 1]) / 2
    else
        return temp[math.ceil(count / 2)]
    end
end

---Round a number to the nearest integer
---@param value number Value to round
---@return integer Rounded integer
function MathUtils.Round(value)
    return math.floor(value + 0.5)
end

---Round a number to specified decimal places
---@param value number Value to round
---@param decimals number Number of decimal places
---@return number Rounded number
function MathUtils.RoundTo(value, decimals)
    local mult = 10 ^ decimals
    return math.floor(value * mult + 0.5) / mult
end

return MathUtils
