--##########################################################################
--  ConnectionBuilder.lua  ·  Facade for door system (delegates to Doors/)
--##########################################################################
--  This module now delegates to the modular door system in Doors/ subfolder.
--  Kept for backward compatibility with existing code.
--##########################################################################

local DoorBuilder = require("MedBot.Navigation.Doors.DoorBuilder")

local ConnectionBuilder = {}

-- Delegate all functions to DoorBuilder module
ConnectionBuilder.NormalizeConnections = DoorBuilder.NormalizeConnections
ConnectionBuilder.BuildDoorsForConnections = DoorBuilder.BuildDoorsForConnections
ConnectionBuilder.BuildDoorToDoorConnections = DoorBuilder.BuildDoorToDoorConnections
ConnectionBuilder.GetConnectionEntry = DoorBuilder.GetConnectionEntry
ConnectionBuilder.GetDoorTargetPoint = DoorBuilder.GetDoorTargetPoint

return ConnectionBuilder
