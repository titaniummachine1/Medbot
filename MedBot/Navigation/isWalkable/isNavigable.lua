--[[
    Lightweight Node-Based Path Validator
    Steps through portals/doors in greedy direction with minimal traces
]]
local Navigable = {}
local G = require("MedBot.Core.Globals")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local UP_VECTOR = Vector3(0, 0, 1)
local MAX_NODES_TO_CHECK = 15

-- Debug
local DEBUG_TRACES = false
local hullTraces = {}
local currentTickLogged = -1

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
    local currentTick = globals.TickCount()
    if currentTick > currentTickLogged then
        hullTraces = {}
        currentTickLogged = currentTick
    end
    local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask, filter)
    if DEBUG_TRACES then
        table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
    end
    return result
end

local TraceHull = engine.TraceHull

-- Filter
local function shouldHitEntity(entity)
    local pLocal = G.pLocal and G.pLocal.entity
    return entity ~= pLocal
end

-- Get directional ID towards goal
local function getDirectionToGoal(node, goalPos)
    local dx = goalPos.x - node.pos.x
    local dy = goalPos.y - node.pos.y
    
    local Node = require("MedBot.Navigation.Node")
    
    -- Determine primary direction
    if math.abs(dx) > math.abs(dy) then
        return dx > 0 and Node.DIR.E or Node.DIR.W
    else
        return dy > 0 and Node.DIR.N or Node.DIR.S
    end
end

-- Simple point-in-rect check
local function pointInRect(px, py, minX, maxX, minY, maxY)
    return px >= minX and px <= maxX and py >= minY and py <= maxY
end

-- Main function: Greedy portal stepping
function Navigable.CanSkip(startPos, goalPos, startNode)
    assert(startNode, "CanSkip: startNode required")
    assert(startNode.c, "CanSkip: startNode has no connections")
    
    local Node = require("MedBot.Navigation.Node")
    local nodes = G.Navigation.nodes
    if not nodes then
        return false
    end
    
    -- Quick bounds check - if goal is way outside navmesh, early out
    local goalNode = Node.GetAreaAtPosition and Node.GetAreaAtPosition(goalPos)
    if not goalNode then
        -- Try simple bounds check
        local found = false
        for _, node in pairs(nodes) do
            if not node.isDoor and pointInRect(goalPos.x, goalPos.y, node._minX, node._maxX, node._minY, node._maxY) then
                found = true
                break
            end
        end
        if not found then
            return false -- Goal not in any node
        end
    end
    
    -- Single hull trace from start to goal at step height
    local traceResult = TraceHull(
        startPos + STEP_HEIGHT_Vector,
        goalPos + STEP_HEIGHT_Vector,
        PLAYER_HULL.Min,
        PLAYER_HULL.Max,
        MASK_PLAYERSOLID,
        shouldHitEntity
    )
    
    if traceResult.fraction > 0.99 then
        return true -- Direct line clear
    end
    
    -- Greedy stepping through portals
    local currentNode = startNode
    local visited = {} -- Prevent cycles
    
    for step = 1, MAX_NODES_TO_CHECK do
        if visited[currentNode.id] then
            return false -- Cycle detected
        end
        visited[currentNode.id] = true
        
        -- Check if we're at goal node
        if pointInRect(goalPos.x, goalPos.y, currentNode._minX, currentNode._maxX, currentNode._minY, currentNode._maxY) then
            -- Final trace to goal from current position
            local currentPos = Vector3(currentNode.pos.x, currentNode.pos.y, currentNode.pos.z)
            local finalTrace = TraceHull(
                currentPos + STEP_HEIGHT_Vector,
                goalPos + STEP_HEIGHT_Vector,
                PLAYER_HULL.Min,
                PLAYER_HULL.Max,
                MASK_PLAYERSOLID,
                shouldHitEntity
            )
            return finalTrace.fraction > 0.9
        end
        
        -- Get best direction towards goal
        local bestDir = getDirectionToGoal(currentNode, goalPos)
        
        -- Try connections in priority: best direction first, then others
        local triedDirs = { [bestDir] = true }
        local connectionsToTry = {}
        
        -- Add best direction first
        if currentNode.c[bestDir] and currentNode.c[bestDir].connections then
            table.insert(connectionsToTry, { dir = bestDir, data = currentNode.c[bestDir] })
        end
        
        -- Add other directions
        for dirId, dirData in pairs(currentNode.c) do
            if not triedDirs[dirId] and dirData.connections then
                table.insert(connectionsToTry, { dir = dirId, data = dirData })
            end
        end
        
        -- Try each connection
        local foundNext = false
        for _, connInfo in ipairs(connectionsToTry) do
            local dirData = connInfo.data
            
            for _, conn in ipairs(dirData.connections) do
                local targetId = type(conn) == "table" and conn.node or conn
                local targetNode = nodes[targetId]
                
                if targetNode and not targetNode.isDoor and not visited[targetId] then
                    -- Quick direction check - must be towards goal
                    local toTarget = targetNode.pos - currentNode.pos
                    local toGoal = goalPos - currentNode.pos
                    
                    -- Dot product check: target must be in general direction of goal
                    if toTarget:Dot(toGoal) > -100 then -- Allow some perpendicular
                        currentNode = targetNode
                        foundNext = true
                        break
                    end
                end
            end
            
            if foundNext then
                break
            end
        end
        
        if not foundNext then
            return false -- Dead end
        end
    end
    
    return false -- Exceeded max steps
end

-- Debug visualization
function Navigable.DrawDebugTraces()
    if not DEBUG_TRACES then
        return
    end
    
    for _, trace in ipairs(hullTraces) do
        if trace.startPos and trace.endPos then
            draw.Color(0, 50, 255, 255)
            local Common = require("MedBot.Core.Common")
            Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
        end
    end
end

function Navigable.SetDebug(enabled)
    DEBUG_TRACES = enabled
end

return Navigable
