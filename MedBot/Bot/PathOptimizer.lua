--[[
Path Optimizer - Prevents rubber-banding with smart windowing
Handles node skipping and direct path optimization
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local ISWalkable = require("MedBot.Navigation.ISWalkable")

local Log = Common.Log.new("PathOptimizer")
local PathOptimizer = {}

-- Skip entire path if goal is directly reachable
function PathOptimizer.skipToGoalIfWalkable(origin, goalPos, path)
    local DEADZONE = 24 -- units
    if not goalPos or not origin then
        return false
    end
    local dist = (goalPos - origin):Length()
    if dist < DEADZONE then
        Navigation.ClearPath()
        G.currentState = G.States.IDLE
        G.lastPathfindingTick = 0
        return true
    end
    -- Only skip if we have a multi-node path AND goal is directly reachable
    -- Never skip on CTF maps to avoid beelining to the wrong flag area
    local mapName = engine.GetMapName():lower()
    if path and #path > 1 and not mapName:find("ctf_") then
        local walkMode = G.Menu.Main.WalkableMode or "Smooth"
        if ISWalkable.Path(origin, goalPos, walkMode) then
            Navigation.ClearPath()
            -- Set a direct path with just the goal as the node
            G.Navigation.path = { { pos = goalPos } }
            G.lastPathfindingTick = 0
            Log:Info("Cleared complex path, moving directly to goal with %s mode (distance: %.1f)", walkMode, dist)
            return true
        end
    end
    return false
end

-- Skip if next node is closer to the player than the current node
function PathOptimizer.skipIfCloser(origin, path)
    if not path or #path < 2 then
        return false
    end
    local curNode, nextNode = path[1], path[2]
    if not (curNode and nextNode and curNode.pos and nextNode.pos) then
        return false
    end
    local distCur = (curNode.pos - origin):Length()
    local distNext = (nextNode.pos - origin):Length()
    if distNext < distCur then
        Navigation.RemoveCurrentNode()
        Navigation.ResetTickTimer()
        return true
    end
    return false
end

-- Skip if we can walk directly to the node after next
function PathOptimizer.skipIfWalkable(origin, path)
    if not path or #path < 3 then
        return false
    end
    local candidate = path[3]
    local walkMode = G.Menu.Main.WalkableMode or "Smooth"
    if #path == 3 then
        walkMode = "Aggressive"
    end
    if candidate and candidate.pos and ISWalkable.Path(origin, candidate.pos, walkMode) then
        Navigation.RemoveCurrentNode()
        Navigation.ResetTickTimer()
        return true
    end
    return false
end

-- Optimize path by trying different skip strategies
function PathOptimizer.optimize(origin, path, goalPos)
    if not G.Menu.Main.Skip_Nodes or not path or #path <= 1 then
        return false
    end

    -- Try to skip directly to the goal if we have a complex path
    if goalPos and #path > 1 then
        if PathOptimizer.skipToGoalIfWalkable(origin, goalPos, path) then
            return true
        end
    end

    -- Only run the heavier skip checks every few ticks to reduce CPU
    local now = globals.TickCount()
    if not G.lastNodeSkipTick then
        G.lastNodeSkipTick = 0
    end
    if (now - G.lastNodeSkipTick) >= 3 then -- run every 3 ticks (~50 ms)
        G.lastNodeSkipTick = now
        -- Skip only when safe with door semantics
        if PathOptimizer.skipIfCloser(origin, path) then
            return true
        elseif PathOptimizer.skipIfWalkable(origin, path) then
            return true
        end
    end

    return false
end

return PathOptimizer
