--##########################################################################
--  DoorGenerator.lua  ·  Unified door generation system (consolidated)
--##########################################################################

local Log = Common.Log.new("DoorGenerator")

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72

--##########################################################################
--  UNIFIED DOOR CREATION LOGIC
--##########################################################################

-- Main door generation function that consolidates both DoorManager and ConnectionBuilder logic
function DoorGenerator.CreateDoorForAreas(areaA, areaB)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		return nil
	end

	-- Step 1: Get consistent direction calculation
	local direction = AxisCalculator.GetDirection(areaA.pos, areaB.pos)
	Log:Debug(
		"Direction from %d to %d: axis=%s, isPositive=%s",
		areaA.id,
		areaB.id,
		direction.axis,
		tostring(direction.isPositive)
	)

	local ownerCorners = AxisCalculator.GetEdgeCorners(areaA, direction)
	local targetCorners = AxisCalculator.GetEdgeCorners(areaB, AxisCalculator.GetOppositeDirection(direction))

	if not (ownerCorners and targetCorners) then
		Log:Warn("CreateDoorForAreas: Cannot get edge corners")
		return nil
	end

	-- Step 3: Determine door ownership based on height and get the correct corners
	local ownerArea, targetArea = DoorGenerator.GetHigherArea(areaA, areaB)

	-- Get corners for the actual owner area (the higher one)
	local ownerCorners = AxisCalculator.GetEdgeCorners(ownerArea, direction)
	local targetCorners = AxisCalculator.GetEdgeCorners(targetArea, AxisCalculator.GetOppositeDirection(direction))

	if not (ownerCorners and targetCorners) then
		Log:Warn("CreateDoorForAreas: Cannot get edge corners for owner/target")
		return nil
	end

	-- Step 4: Calculate 1D overlap along the edge axis (FIXED: consistent axis handling)
	local geometry = DoorGenerator.CalculateDoorGeometry(ownerArea, targetArea, ownerCorners, targetCorners, direction)
	if not geometry then
		return nil
	end

	-- Step 5: Create door geometry with wall corner clamping (FIXED: proper axis orientation)
	local door = DoorGenerator.CreateDoorGeometry(geometry, ownerArea, targetArea, direction)
	if not door then
		Log:Debug("CreateDoorForAreas: Failed to create door geometry for %d -> %d", areaA.id, areaB.id)
		return nil
	end

	-- Step 6: Validate and return
	door.owner = ownerArea.id
	door.needJump = math.abs(ownerArea.pos.z - targetArea.pos.z) > STEP_HEIGHT

	Log:Debug("Created door: %d -> %d (owner: %d)", areaA.id, areaB.id, door.owner)
	return door
end

--##########################################################################
--  DOOR GEOMETRY CALCULATION (Consolidated from ConnectionBuilder)
--##########################################################################

function DoorGenerator.GetHigherArea(areaA, areaB)
	if not (areaA and areaB and areaA.nw and areaB.nw) then
		return areaA, areaB
	end

	-- Calculate average heights (more stable than edge corners)
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

function DoorGenerator.CalculateDoorGeometry(ownerArea, targetArea, ownerCorners, targetCorners, direction)
	local a0, a1 = ownerCorners -- Owner edge corners
	local b0, b1 = targetCorners -- Target edge corners
	if not (a0 and a1 and b0 and b1) then
		return nil
	end

	local owner, ownerId = DoorGenerator.DetermineDoorOwner(a0, a1, b0, b1, ownerArea, targetArea)

	return {
		a0 = a0,
		a1 = a1,
		b0 = b0,
		b1 = b1,
		owner = owner,
		ownerId = ownerId,
	}
end

function DoorGenerator.DetermineDoorOwner(a0, a1, b0, b1, areaA, areaB)
	local aZmax = math.max(a0.z, a1.z)
	local bZmax = math.max(b0.z, b1.z)

	if aZmax > bZmax + 0.5 then
		return "A", areaA.id
	elseif bZmax > aZmax + 0.5 then
		return "B", areaB.id
	else
		return "TIE", math.max(areaA.id, areaB.id)
	end
end

function DoorGenerator.CreateDoorGeometry(geometry, ownerArea, targetArea, direction)
	local a0, a1, b0, b1 = geometry.a0, geometry.a1, geometry.b0, geometry.b1
	local owner = geometry.owner

	-- Determine 1D overlap along edge axis and reconstruct points on OWNER edge
	local oL, oR, edgeConst, axis = DoorGenerator.CalculateOverlapCoordinates(a0, a1, b0, b1, owner, direction)

	if not oL then
		return nil
	end

	-- Helper to get endpoint pair on chosen owner edge
	local e0, e1 = (owner == "B" and b0 or a0), (owner == "B" and b1 or a1)

	-- Convert 1D coordinates back to 3D points on owner edge
	local overlapLeft = DoorGenerator.PointOnOwnerEdge(e0, e1, oL, axis, edgeConst)
	local overlapRight = DoorGenerator.PointOnOwnerEdge(e0, e1, oR, axis, edgeConst)

	-- Clamp door away from wall corners (FIXED: proper axis handling)
	local wallCorners = DoorGenerator.GetWallCorners(ownerArea)
	local clampedLeft, clampedRight =
		AxisCalculator.ClampEndpoints(overlapLeft, overlapRight, wallCorners, direction, HITBOX_WIDTH)

	-- Validate width on the edge axis only (2D length)
	local clampedWidth = (clampedRight - clampedLeft):Length2D()
	if clampedWidth < HITBOX_WIDTH then
		return nil
	end

	local middle = EdgeCalculator.LerpVec(clampedLeft, clampedRight, 0.5)

	return {
		left = clampedLeft,
		middle = middle,
		right = clampedRight,
	}
end

function DoorGenerator.CalculateOverlapCoordinates(a0, a1, b0, b1, owner, direction)
	local oL, oR -- overlap coordinates on the edge axis

	if direction.axis == "x" then
		-- East/West: vertical edge, y varies, x constant
		oL, oR = AxisCalculator.CalculateOverlap(a0.y, a1.y, b0.y, b1.y)
		return oL, oR, (owner == "B" and b0.x or a0.x), "y"
	else
		-- North/South: horizontal edge, x varies, y constant
		oL, oR = AxisCalculator.CalculateOverlap(a0.x, a1.x, b0.x, b1.x)
		return oL, oR, (owner == "B" and b0.y or a0.y), "x"
	end
end

function DoorGenerator.PointOnOwnerEdge(e0, e1, val, axis, edgeConst)
	-- Compute t along owner edge based on axis coordinate
	local denom = (axis == "x") and (e1.x - e0.x) or (e1.y - e0.y)
	local t = denom ~= 0 and ((val - ((axis == "x") and e0.x or e0.y)) / denom) or 0
	t = math.max(0, math.min(1, t))

	local x = (axis == "x") and val or edgeConst
	local y = (axis == "y") and val or edgeConst
	local z = MathUtils.Lerp(e0.z, e1.z, t)

	return Vector3(x, y, z)
end

function DoorGenerator.GetWallCorners(area)
	local corners = {}
	if area.wallCorners then
		for _, corner in ipairs(area.wallCorners) do
			table.insert(corners, corner)
		end
	end
	return corners
end

--##########################################################################
--  INTEGRATION FUNCTIONS (Bridge to existing systems)
--##########################################################################

-- Generate doors for all connections (replaces both DoorManager.GenerateAllDoors and ConnectionBuilder.BuildDoorsForConnections)
function DoorGenerator.GenerateAllDoors()
	Log:Info("Starting unified door generation...")

	local nodes = G.Navigation.nodes
	if not nodes then
		Log:Error("No navigation nodes available")
		return 0
	end

	-- Clear existing door data from all systems
	DoorGenerator.ClearExistingDoorData(nodes)

	local doorsCreated = 0

	-- Process each node and its connections
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode and nodeId < targetId then -- Only process once per pair
							local door = DoorGenerator.CreateDoorForAreas(node, targetNode)
							if door then
								-- Store in unified registry
								local success = DoorGenerator.RegisterDoor(node.id, targetId, door)
								if success then
									doorsCreated = doorsCreated + 1
									DoorGenerator.ApplyDoorToConnection(node, targetNode, dir, connection, door)
								end
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Generated %d doors for all connections", doorsCreated)
	return doorsCreated
end

function DoorGenerator.ClearExistingDoorData(nodes)
	-- Clear DoorRegistry
	require("MedBot.Navigation.DoorRegistry").Clear()

	-- Clear connection door data
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						if type(connection) == "table" then
							connection.left = nil
							connection.middle = nil
							connection.right = nil
							connection.needJump = nil
							connection.owner = nil
						end
					end
				end
			end
		end
		node.isDoor = false
	end
end

function DoorGenerator.ApplyDoorToConnection(node, targetNode, dir, connection, door)
	-- Mark both nodes as doors
	node.isDoor = true
	targetNode.isDoor = true

	-- Ensure connection is a table before populating
	if type(connection) ~= "table" then
		connection = ConnectionUtils.NormalizeEntry(connection)
		-- Find the connection in the direction and replace it
		for i, conn in ipairs(dir.connections) do
			if conn == connection then -- This comparison might need adjustment
				dir.connections[i] = connection
				break
			end
		end
	end

	-- Populate door data on connection
	connection.left = door.left
	connection.middle = door.middle
	connection.right = door.right
	connection.needJump = door.needJump
	connection.owner = door.owner
end

--##########################################################################
--  DOOR REGISTRY INTEGRATION
--##########################################################################

-- Use DoorRegistry for centralized storage
function DoorGenerator.RegisterDoor(areaIdA, areaIdB, doorData)
	return require("MedBot.Navigation.DoorRegistry").RegisterDoor(areaIdA, areaIdB, doorData)
end

function DoorGenerator.GetDoor(areaIdA, areaIdB)
	return require("MedBot.Navigation.DoorRegistry").GetDoor(areaIdA, areaIdB)
end

function DoorGenerator.GetDoorTarget(areaIdA, areaIdB, destinationPos)
	return require("MedBot.Navigation.DoorRegistry").GetDoorTarget(areaIdA, areaIdB, destinationPos)
end

function DoorGenerator.GetDoorCount()
	return require("MedBot.Navigation.DoorRegistry").GetDoorCount()
end

return DoorGenerator
