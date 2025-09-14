--[[
Path Optimizer - Prevents rubber-banding with smart windowing
Handles node skipping and direct path optimization
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local ISWalkable = require("MedBot.Navigation.ISWalkable")
local WorkManager = require("MedBot.WorkManager")

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

-- Skip if next node is walkable (simplified with work manager cooldown)
function PathOptimizer.skipIfNextWalkable(origin, path)
    if not path or #path < 2 then
        return false
    end

    local nextNode = path[2]
    if not nextNode or not nextNode.pos then
        return false
    end

    -- Check if we can walk directly to the next node
    local walkMode = G.Menu.Main.WalkableMode or "Smooth"
    if ISWalkable.Path(origin, nextNode.pos, walkMode) then
        Log:Debug("Next node %d is walkable, skipping current node", nextNode.id or 0)

        -- Skip to next node
        Navigation.RemoveCurrentNode()
        Navigation.ResetTickTimer()
        return true
    end

    return false
end

-- Optimize path by trying different skip strategies with work manager
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

    -- Use work manager for node skipping cooldown (same as unstuck logic)
    if not WorkManager.attemptWork(3, "node_skip") then -- 3 tick cooldown (~50ms)
        return false
    end

    -- Skip to next node if it's walkable
    if PathOptimizer.skipIfNextWalkable(origin, path) then
        return true
    end

    return false
end

return PathOptimizer
