--##########################################################################
--  DoorRegistry.lua  ·  Centralized door lookup system
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local DoorRegistry = {}
local Log = Common.Log.new("DoorRegistry")

-- Central door storage: doorId -> {left, middle, right, needJump, owner}
local doors = {}

-- Generate unique door ID for area pair (order-independent)
local function getDoorId(areaIdA, areaIdB)
    local minId = math.min(areaIdA, areaIdB)
    local maxId = math.max(areaIdA, areaIdB)
    return minId .. "_" .. maxId
end

-- Store door geometry in central registry
function DoorRegistry.RegisterDoor(areaIdA, areaIdB, doorData)
    if not doorData then return false end
    
    local doorId = getDoorId(areaIdA, areaIdB)
    doors[doorId] = {
        left = doorData.left,
        middle = doorData.middle,
        right = doorData.right,
        needJump = doorData.needJump,
        owner = doorData.owner
    }
    return true
end

-- Get door geometry for area pair
function DoorRegistry.GetDoor(areaIdA, areaIdB)
    local doorId = getDoorId(areaIdA, areaIdB)
    return doors[doorId]
end

-- Get door middle point for pathfinding
function DoorRegistry.GetDoorTarget(areaIdA, areaIdB)
    local door = DoorRegistry.GetDoor(areaIdA, areaIdB)
    return door and door.middle or nil
end

-- Clear all doors (for map changes)
function DoorRegistry.Clear()
    doors = {}
    Log:Info("Door registry cleared")
end

-- Get door count for debugging
function DoorRegistry.GetDoorCount()
    local count = 0
    for _ in pairs(doors) do count = count + 1 end
    return count
end

return DoorRegistry
