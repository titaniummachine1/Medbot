--##########################################################################
--  Phase4_Doors.lua  ·  Door generation, wall corners, and advanced connections
--##########################################################################

local Common = require("MedBot.Core.Common")
local WallCornerGenerator = require("MedBot.Navigation.WallCornerGenerator")
local DoorBuilder = require("MedBot.Navigation.Doors.DoorBuilder")

local Phase4_Doors = {}

local Log = Common.Log.new("Phase4_Doors")

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Execute advanced parsing: wall corners and door generation
--- Assumes nodes are already in G.Navigation.nodes (basic setup complete)
--- @return boolean success
function Phase4_Doors.Execute()
    Log:Info("Starting Phase 4: Advanced parsing (doors + wall corners)")

    -- Step 1: Detect wall corners (uses G.Navigation.nodes internally)
    local success = pcall(function()
        WallCornerGenerator.DetectWallCorners()
    end)

    if not success then
        Log:Error("Wall corner detection failed")
        -- Continue anyway - doors can work without corners
    else
        Log:Info("Wall corners detected")
    end

    -- Step 2: Build doors for connections (modifies G.Navigation.nodes)
    success = pcall(function()
        DoorBuilder.BuildDoorsForConnections()
    end)

    if not success then
        Log:Error("Door building failed")
        return false
    end

    Log:Info("Phase 4 complete: Doors and connections built")
    return true
end

return Phase4_Doors
