--[[
Door Generator - Core Door Geometry Generation
Generates door geometry between navigation areas.
Focuses on clean, readable door creation algorithms.
]]

local DoorGenerator = {}

local Common = require("MedBot.Core.Common")
local MathUtils = require("MedBot.Utils.MathUtils")

local Log = Common.Log.new("DoorGenerator")

-- ============================================================================
-- DOOR GEOMETRY CALCULATION
-- ============================================================================

---Calculate door points on a single edge
---@param edge table Edge data with start/end points
---@param center Vector3 Center point for door
---@param width number Door width
---@return table Door points {left, middle, right}
function DoorGenerator.CalculateDoorPoints(edge, center, width)
    local edgeVector = edge.endPos - edge.startPos
    local edgeLength = edgeVector:Length()

    if edgeLength == 0 then
        return nil -- Invalid edge
    end

    -- Find closest point on edge to center
    local toCenter = center - edge.startPos
    local projection = toCenter:Dot(edgeVector) / (edgeLength * edgeLength)

    -- Clamp to edge bounds
    projection = MathUtils.Clamp(projection, 0, 1)

    -- Calculate door center on edge
    local doorCenter = edge.startPos + edgeVector * projection

    -- Calculate door extent along edge
    local halfWidth = width / 2
    local edgeDir = edgeVector:Normalized()
    local offset = edgeDir * halfWidth

    -- Ensure door stays within edge bounds
    local leftDist = (doorCenter - edge.startPos):Length()
    local rightDist = (edge.endPos - doorCenter):Length()

    if leftDist < halfWidth then
        offset = edgeDir * leftDist
    elseif rightDist < halfWidth then
        offset = edgeDir * -rightDist
    end

    return {
        left = doorCenter - offset,
        middle = doorCenter,
        right = doorCenter + offset
    }
end

---Create door geometry between two areas
---@param area1 table First area with corner data
---@param area2 table Second area with corner data
---@return table|nil Door data or nil if creation failed
function DoorGenerator.CreateDoorForAreas(area1, area2)
    if not area1 or not area2 then
        Log:Warn("CreateDoorForAreas: Missing area data")
        return nil
    end

    -- Find facing edges between areas
    local edge1, edge2 = DoorGenerator.FindFacingEdges(area1, area2)
    if not edge1 or not edge2 then
        return nil -- No facing edges found
    end

    -- Calculate door center
    local center = DoorGenerator.CalculateDoorCenter(edge1, edge2)

    -- Generate door points on both edges
    local doorPoints1 = DoorGenerator.CalculateDoorPoints(edge1, center, 32) -- Standard door width
    local doorPoints2 = DoorGenerator.CalculateDoorPoints(edge2, center, 32)

    if not doorPoints1 or not doorPoints2 then
        return nil
    end

    -- Create door data structure
    local door = {
        id = DoorGenerator.GenerateDoorId(area1, area2),
        owner = area1.id, -- Higher area owns the door
        left = doorPoints1.left,
        middle = doorPoints1.middle,
        right = doorPoints1.right,
        zMin = math.min(edge1.zMin or 0, edge2.zMin or 0),
        zMax = math.max(edge1.zMax or 0, edge2.zMax or 0),
        areas = {area1.id, area2.id},
        edge1 = edge1,
        edge2 = edge2
    }

    return door
end

---Find edges that face each other between two areas
---@param area1 table First area
---@param area2 table Second area
---@return table|nil, table|nil Facing edges or nil if not found
function DoorGenerator.FindFacingEdges(area1, area2)
    -- This would contain the logic to find which edges face each other
    -- Simplified for readability - actual implementation would check edge normals
    -- and proximity between areas

    -- Placeholder - actual implementation would be more complex
    local edge1 = DoorGenerator.GetAreaEdges(area1)[1] -- First edge of area1
    local edge2 = DoorGenerator.GetAreaEdges(area2)[1] -- First edge of area2

    return edge1, edge2
end

---Calculate center point for door between two edges
---@param edge1 table First edge
---@param edge2 table Second edge
---@return Vector3 Center point
function DoorGenerator.CalculateDoorCenter(edge1, edge2)
    -- Calculate midpoint between edge centers
    local edge1Center = (edge1.startPos + edge1.endPos) / 2
    local edge2Center = (edge2.startPos + edge2.endPos) / 2

    return (edge1Center + edge2Center) / 2
end

---Get edges for an area
---@param area table Area data
---@return table Array of edge data
function DoorGenerator.GetAreaEdges(area)
    -- Convert area corners to edges
    local edges = {}
    local corners = area.corners or {}

    for i = 1, #corners do
        local startCorner = corners[i]
        local endCorner = corners[i % #corners + 1]

        edges[#edges + 1] = {
            startPos = Vector3(startCorner.x, startCorner.y, startCorner.z),
            endPos = Vector3(endCorner.x, endCorner.y, endCorner.z),
            zMin = startCorner.z,
            zMax = endCorner.z
        }
    end

    return edges
end

---Generate unique door ID
---@param area1 table First area
---@param area2 table Second area
---@return string Unique door identifier
function DoorGenerator.GenerateDoorId(area1, area2)
    local id1 = math.min(area1.id, area2.id)
    local id2 = math.max(area1.id, area2.id)
    return string.format("door_%d_%d", id1, id2)
end

return DoorGenerator
