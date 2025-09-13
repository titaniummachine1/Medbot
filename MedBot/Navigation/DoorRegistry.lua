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
	if not doorData then
		return false
	end

	local doorId = getDoorId(areaIdA, areaIdB)
	doors[doorId] = {
		left = doorData.left,
		middle = doorData.middle,
		right = doorData.right,
		needJump = doorData.needJump,
		owner = doorData.owner,
	}
	return true
end

-- Get door geometry for area pair
function DoorRegistry.GetDoor(areaIdA, areaIdB)
	local doorId = getDoorId(areaIdA, areaIdB)
	return doors[doorId]
end

-- Get optimal door point for pathfinding (closest to destination)
function DoorRegistry.GetDoorTarget(areaIdA, areaIdB, destinationPos)
	local door = DoorRegistry.GetDoor(areaIdA, areaIdB)
	if not door then
		return nil
	end

	-- If no destination specified, use middle
	if not destinationPos then
		return door.middle
	end

	-- Choose closest door position to destination
	local doorPositions = {}
	if door.left then
		table.insert(doorPositions, door.left)
	end
	if door.middle then
		table.insert(doorPositions, door.middle)
	end
	if door.right then
		table.insert(doorPositions, door.right)
	end

	if #doorPositions == 0 then
		return nil
	end

	local bestPos = doorPositions[1]
	local bestDist = (doorPositions[1] - destinationPos):Length()

	for i = 2, #doorPositions do
		local dist = (doorPositions[i] - destinationPos):Length()
		if dist < bestDist then
			bestPos = doorPositions[i]
			bestDist = dist
		end
	end

	return bestPos
end

-- Clear all doors (for map changes)
function DoorRegistry.Clear()
	doors = {}
	Log:Info("Door registry cleared")
end

-- Get door count for debugging
function DoorRegistry.GetDoorCount()
	local count = 0
	for _ in pairs(doors) do
		count = count + 1
	end
	return count
end

return DoorRegistry
