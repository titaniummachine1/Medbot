--[[
Door System - Black Box API for Door Generation and Management
Provides a simple, extensible interface for all door-related operations.
Prioritizes readability and maintainability over performance.

API:
- DoorSystem.GenerateDoorsForAreas(area1, area2) - Generate doors between areas
- DoorSystem.ProcessConnectionDoors(connection) - Process doors for a connection
- DoorSystem.GetDoorById(id) - Get door by ID
- DoorSystem.RegisterProcessor(name, processor) - Add custom door processing
]]

local DoorSystem = {}

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local DoorGenerator = require("MedBot.Navigation.DoorGenerator")
local DoorRegistry = require("MedBot.Navigation.DoorRegistry")

local Log = Common.Log.new("DoorSystem")

-- Processing pipeline for extensible door operations
local processors = {}

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Generate doors for a connection between two areas
---@param area1 table First area
---@param area2 table Second area
---@return table|nil Generated door data, or nil if no door created
function DoorSystem.GenerateDoorsForAreas(area1, area2)
    if not area1 or not area2 then
        Log:Warn("GenerateDoorsForAreas: Missing area data")
        return nil
    end

    -- Generate door geometry
    local door = DoorGenerator.CreateDoorForAreas(area1, area2)
    if not door then
        return nil
    end

    -- Register the door
    DoorRegistry.RegisterDoor(door)

    -- Run processing pipeline
    DoorSystem._RunProcessors(door, "postGenerate")

    return door
end

---Process doors for an existing connection
---@param connection table Connection data with door information
function DoorSystem.ProcessConnectionDoors(connection)
    if not connection or not connection.doors then
        return
    end

    for _, doorId in ipairs(connection.doors) do
        local door = DoorRegistry.GetDoor(doorId)
        if door then
            DoorSystem._RunProcessors(door, "process")
        end
    end
end

---Get door by ID
---@param id any Door identifier
---@return table|nil Door data or nil if not found
function DoorSystem.GetDoorById(id)
    return DoorRegistry.GetDoor(id)
end

---Register a custom door processor
---@param name string Processor name for identification
---@param processor table Processor with process function
function DoorSystem.RegisterProcessor(name, processor)
    if not processor or type(processor.process) ~= "function" then
        Log:Warn("RegisterProcessor: Invalid processor for '%s'", name)
        return
    end

    processors[name] = processor
    Log:Info("Registered door processor: %s", name)
end

---Get all registered doors
---@return table Array of all doors
function DoorSystem.GetAllDoors()
    return DoorRegistry.GetAllDoors()
end

---Clear all doors (for cleanup/reset)
function DoorSystem.ClearAllDoors()
    DoorRegistry.ClearAllDoors()
    Log:Info("Cleared all doors")
end

-- ============================================================================
-- INTERNAL METHODS
-- ============================================================================

---Run processing pipeline for a door
---@param door table Door data
---@param stage string Processing stage ("postGenerate", "process", etc.)
function DoorSystem._RunProcessors(door, stage)
    for name, processor in pairs(processors) do
        if processor[stage] then
            local success, err = pcall(processor[stage], door)
            if not success then
                Log:Warn("Processor '%s' failed in stage '%s': %s", name, stage, err)
            end
        end
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

---Initialize the door system
function DoorSystem.Initialize()
    Log:Info("Door System initialized")
end

return DoorSystem
