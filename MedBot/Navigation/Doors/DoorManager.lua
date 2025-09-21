--##########################################################################
--  DoorSystem.lua  ·  Unified door generation system (reworked from scratch)
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local AxisCalculator = require("MedBot.Navigation.AxisCalculator")

local DoorSystem = {}

local Log = Common.Log.new("DoorSystem")

-- Door storage: areaId -> door data
local doors = {}

-- Generate unique door key for area pair
local function getDoorKey(areaA, areaB)
	local minId = math.min(areaA.id, areaB.id)
	local maxId = math.max(areaA.id, areaB.id)
	return minId .. "_" .. maxId
end

-- Calculate which area is higher (owns the door)
local function getHigherArea(areaA, areaB)
	if not (areaA and areaB and areaA.nw and areaB.nw) then
		return areaA, areaB
	end

	-- Calculate average heights
	local heightA = (areaA.nw.z + areaA.ne.z + areaA.se.z + areaA.sw.z) / 4
	local heightB = (areaB.nw.z + areaB.ne.z + areaB.se.z + areaB.sw.z) / 4

	if heightA > heightB + 0.1 then
		return areaA, areaB
	elseif heightB > heightA + 0.1 then
		return areaB, areaA
	else
		-- Tie: use higher ID as owner
		return (areaA.id > areaB.id) and areaA or areaB, (areaA.id > areaB.id) and areaB or areaA
	end
end

-- Create door geometry for two connected areas
local function createDoorForAreas(areaA, areaB)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		Log:Warn("createDoorForAreas: Invalid areas")
		return nil
	end

	-- Determine direction and owner
	local direction = AxisCalculator.GetDirection(areaA.pos, areaB.pos)
	local ownerArea, targetArea = getHigherArea(areaA, areaB)

	-- Get owner's edge corners
	local edgeStart, edgeEnd = AxisCalculator.GetEdgeCorners(ownerArea, direction)
	if not (edgeStart and edgeEnd) then
		Log:Warn("createDoorForAreas: Cannot get edge corners")
		return nil
	end

	-- Simple door: center of edge with left/right offsets
	local center = Vector3((edgeStart.x + edgeEnd.x) / 2, (edgeStart.y + edgeEnd.y) / 2, (edgeStart.z + edgeEnd.z) / 2)

	-- Calculate perpendicular offset for left/right
	local edgeVec = edgeEnd - edgeStart
	local length = edgeVec:Length2D()
	local perpendicular = length > 0 and Common.Normalize(Vector3(-edgeVec.y, edgeVec.x, 0)) * 16 or Vector3(16, 0, 0)

	local door = {
		owner = ownerArea.id,
		left = center - perpendicular,
		middle = center,
		right = center + perpendicular,
		needJump = math.abs(ownerArea.pos.z - targetArea.pos.z) > 18, -- STEP_HEIGHT
	}

	return door
end

-- Generate doors for all connections
function DoorSystem.GenerateAllDoors()
	Log:Info("Starting door generation...")

	local nodes = G.Navigation.nodes
	if not nodes then
		Log:Error("No navigation nodes available")
		return
	end

	-- Clear existing doors
	doors = {}
	local doorCount = 0

	-- Process every connection in every node
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for _, connection in ipairs(dir.connections) do
						local targetId = type(connection) == "table" and connection.node or connection
						local targetNode = nodes[targetId]

						if targetNode then
							local doorKey = getDoorKey(node, targetNode)

							-- Only create door once per pair (when node.id < targetId to avoid duplicates)
							if node.id < targetId and not doors[doorKey] then
								local door = createDoorForAreas(node, targetNode)
								if door then
									doors[doorKey] = door
									doorCount = doorCount + 1

									-- Store door data in both connection directions
									if type(connection) ~= "table" then
										connection = { node = targetId, cost = 1 }
										dir.connections[_] = connection
									end
									connection.left = door.left
									connection.middle = door.middle
									connection.right = door.right
									connection.needJump = door.needJump
									connection.owner = door.owner

									-- Mirror to reverse connection
									for revDirId, revDir in pairs(targetNode.c or {}) do
										if revDir.connections then
											for revIdx, revConn in ipairs(revDir.connections) do
												local revTargetId = type(revConn) == "table" and revConn.node or revConn
												if revTargetId == node.id then
													if type(revConn) ~= "table" then
														revConn = { node = node.id, cost = 1 }
														revDir.connections[revIdx] = revConn
													end
													revConn.left = door.left
													revConn.middle = door.middle
													revConn.right = door.right
													revConn.needJump = door.needJump
													revConn.owner = door.owner
													break
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Generated " .. doorCount .. " doors for all connections")
end

-- Get door for area pair
function DoorSystem.GetDoor(areaA, areaB)
	local doorKey = getDoorKey(areaA, areaB)
	return doors[doorKey]
end

-- Get optimal door target point (closest to destination)
function DoorSystem.GetDoorTarget(areaA, areaB, destination)
	local door = DoorSystem.GetDoor(areaA, areaB)
	if not door then
		return nil
	end

	if not destination then
		return door.middle
	end

	-- Find closest door point to destination
	local points = { door.left, door.middle, door.right }
	local closest = door.middle
	local minDist = (door.middle - destination):Length()

	for _, point in ipairs(points) do
		if point then
			local dist = (point - destination):Length()
			if dist < minDist then
				minDist = dist
				closest = point
			end
		end
	end

	return closest
end

-- Clear all doors
function DoorSystem.Clear()
	doors = {}
	Log:Info("Door system cleared")
end

-- Get door count for debugging
function DoorSystem.GetDoorCount()
	local count = 0
	for _ in pairs(doors) do
		count = count + 1
	end
	return count
end

return DoorSystem
