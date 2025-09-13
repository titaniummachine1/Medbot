--##########################################################################
--  ConnectionBuilder.lua  ·  Connection and door building
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local EdgeCalculator = require("MedBot.Navigation.EdgeCalculator")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local ConnectionBuilder = {}

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local CLEARANCE_OFFSET = 34

local Log = Common.Log.new("ConnectionBuilder")

function ConnectionBuilder.NormalizeConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						dir.connections[i] = ConnectionUtils.NormalizeEntry(connection)
					end
				end
			end
		end
	end
	Log:Info("Normalized all connections to enriched format")
end

local function determineDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 1 or -1, 0
	else
		return 0, (dy > 0) and 1 or -1
	end
end

local function getFacingEdgeCorners(area, dirX, dirY, _)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end

	if dirX == 1 then
		return area.ne, area.se
	end -- East
	if dirX == -1 then
		return area.sw, area.nw
	end -- West
	if dirY == 1 then
		return area.se, area.sw
	end -- South
	if dirY == -1 then
		return area.nw, area.ne
	end -- North

	return nil, nil
end

-- Compute scalar overlap on an axis and return segment [a1,a2] overlapped with [b1,b2]
local function overlap1D(a1, a2, b1, b2)
	if a1 > a2 then
		a1, a2 = a2, a1
	end
	if b1 > b2 then
		b1, b2 = b2, b1
	end
	local left = math.max(a1, b1)
	local right = math.min(a2, b2)
	if right <= left then
		return nil
	end
	return left, right
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function clampDoorAwayFromWalls(overlapLeft, overlapRight, areaA, areaB)
	local Common = require("MedBot.Core.Common")
	local WALL_CLEARANCE = 24

	-- Determine the door's axis (X or Y) based on which coordinate varies more
	local doorVector = overlapRight - overlapLeft
	local isXAxisDoor = math.abs(doorVector.x) > math.abs(doorVector.y)

	-- Store original positions
	local clampedLeft = overlapLeft
	local clampedRight = overlapRight

	-- Check wall corners from both areas
	for _, area in ipairs({ areaA, areaB }) do
		if area.wallCorners then
			for _, wallCorner in ipairs(area.wallCorners) do
				-- Calculate 2D distance to both door endpoints
				local leftDist2D = Common.Distance2D(
					Vector3(clampedLeft.x, clampedLeft.y, 0),
					Vector3(wallCorner.x, wallCorner.y, 0)
				)
				local rightDist2D = Common.Distance2D(
					Vector3(clampedRight.x, clampedRight.y, 0),
					Vector3(wallCorner.x, wallCorner.y, 0)
				)

				-- Only clamp if corner is too close to either endpoint
				if leftDist2D < WALL_CLEARANCE or rightDist2D < WALL_CLEARANCE then
					if isXAxisDoor then
						-- Door is horizontal (varies on X-axis), clamp on X-axis
						if wallCorner.x < clampedLeft.x and leftDist2D < WALL_CLEARANCE then
							-- Corner is to the left of door's left endpoint, move left endpoint right
							clampedLeft = Vector3(
								wallCorner.x + WALL_CLEARANCE,
								clampedLeft.y,
								clampedLeft.z
							)
						elseif wallCorner.x > clampedRight.x and rightDist2D < WALL_CLEARANCE then
							-- Corner is to the right of door's right endpoint, move right endpoint left
							clampedRight = Vector3(
								wallCorner.x - WALL_CLEARANCE,
								clampedRight.y,
								clampedRight.z
							)
						end
					else
						-- Door is vertical (varies on Y-axis), clamp on Y-axis
						if wallCorner.y < clampedLeft.y and leftDist2D < WALL_CLEARANCE then
							-- Corner is below door's left endpoint, move left endpoint up
							clampedLeft = Vector3(
								clampedLeft.x,
								wallCorner.y + WALL_CLEARANCE,
								clampedLeft.z
							)
						elseif wallCorner.y > clampedRight.y and rightDist2D < WALL_CLEARANCE then
							-- Corner is above door's right endpoint, move right endpoint down
							clampedRight = Vector3(
								clampedRight.x,
								wallCorner.y - WALL_CLEARANCE,
								clampedRight.z
							)
						end
					end
				end
			end
		end
	end

	-- Ensure doors don't get too small after clamping
	local finalWidth = (clampedRight - clampedLeft):Length2D()
	if finalWidth < HITBOX_WIDTH then
		-- If door became too small, revert to original positions
		return overlapLeft, overlapRight
	end

	return clampedLeft, clampedRight
end

-- Determine which area owns the door based on edge heights
local function calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)
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

-- Calculate edge overlap and door geometry
local function calculateDoorGeometry(areaA, areaB, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(areaA, dirX, dirY, areaB.pos)
	local b0, b1 = getFacingEdgeCorners(areaB, -dirX, -dirY, areaA.pos)
	if not (a0 and a1 and b0 and b1) then
		return nil
	end

	local owner, ownerId = calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)

	return {
		a0 = a0,
		a1 = a1,
		b0 = b0,
		b1 = b1,
		owner = owner,
		ownerId = ownerId,
	}
end

local function createDoorForAreas(areaA, areaB)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		return nil
	end

	local dirX, dirY = determineDirection(areaA.pos, areaB.pos)
	local geometry = calculateDoorGeometry(areaA, areaB, dirX, dirY)
	if not geometry then
		return nil
	end

	local owner = geometry.owner
	local a0, a1, b0, b1 = geometry.a0, geometry.a1, geometry.b0, geometry.b1

	-- Determine 1D overlap along edge axis and reconstruct points on OWNER edge
	local oL, oR, edgeConst, axis -- axis: "x" or "y" varying
	if dirX ~= 0 then
		-- East/West: vertical edge, y varies, x constant
		oL, oR = overlap1D(a0.y, a1.y, b0.y, b1.y)
		axis = "y"
		edgeConst = owner == "B" and b0.x or a0.x
	else
		-- North/South: horizontal edge, x varies, y constant
		oL, oR = overlap1D(a0.x, a1.x, b0.x, b1.x)
		axis = "x"
		edgeConst = owner == "B" and b0.y or a0.y
	end
	if not oL then
		return nil
	end

	-- Helper to get endpoint pair on chosen owner edge
	local e0, e1 = (owner == "B" and b0 or a0), (owner == "B" and b1 or a1)
	local function pointOnOwnerEdge(val)
		-- compute t along owner edge based on axis coordinate
		local denom = (axis == "x") and (e1.x - e0.x) or (e1.y - e0.y)
		local t = denom ~= 0 and ((val - ((axis == "x") and e0.x or e0.y)) / denom) or 0
		t = math.max(0, math.min(1, t))
		local x = (axis == "x") and val or edgeConst
		local y = (axis == "y") and val or edgeConst
		local z = lerp(e0.z, e1.z, t)
		return Vector3(x, y, z)
	end

	local overlapLeft = pointOnOwnerEdge(oL)
	local overlapRight = pointOnOwnerEdge(oR)

	-- Clamp door away from wall corners
	overlapLeft, overlapRight = clampDoorAwayFromWalls(overlapLeft, overlapRight, areaA, areaB)

	local middle = EdgeCalculator.LerpVec(overlapLeft, overlapRight, 0.5)

	-- Validate width on the edge axis only (2D length) - after clamping
	local clampedWidth = (overlapRight - overlapLeft):Length()
	if clampedWidth < HITBOX_WIDTH then
		return nil
	end

	return {
		left = overlapLeft,
		middle = middle,
		right = overlapRight,
		owner = geometry.ownerId,
		needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
	}
end

function ConnectionBuilder.BuildDoorsForConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	-- First pass: clear any existing door data from connections
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
	end

	-- First pass: clear any existing door flags
	for _, node in pairs(nodes) do
		node.isDoor = false
	end

	local doorsBuilt = 0
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode then
							-- Always try to create doors, even for existing connections
							local door = createDoorForAreas(node, targetNode)
							if door then
								-- Mark both nodes as doors
								node.isDoor = true
								targetNode.isDoor = true

								-- Ensure connection is a table before populating
								if type(connection) ~= "table" then
									local norm = ConnectionUtils.NormalizeEntry(connection)
									dir.connections[i] = norm
									connection = norm
								end

								-- Populate on owner side
								if door.owner == node.id then
									connection.left = door.left
									connection.middle = door.middle
									connection.right = door.right
									connection.needJump = door.needJump
									connection.owner = door.owner
									doorsBuilt = doorsBuilt + 1
									Log:Debug("Built door for connection %d -> %d (owner: %d)", nodeId, targetId, door.owner)
								end

								-- Mirror onto reverse connection so both directions share the same geometry
								if nodes[targetId] and nodes[targetId].c then
									for _, tdir in pairs(nodes[targetId].c) do
										if tdir.connections then
											for rIndex, revConn in ipairs(tdir.connections) do
												local backId = ConnectionUtils.GetNodeId(revConn)
												if backId == node.id then
													if type(revConn) ~= "table" then
														-- normalize inline if raw id, and write back
														local norm = ConnectionUtils.NormalizeEntry(revConn)
														tdir.connections[rIndex] = norm
														revConn = norm
													end
													revConn.left = door.left
													revConn.middle = door.middle
													revConn.right = door.right
													revConn.needJump = door.needJump
													revConn.owner = door.owner
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

	Log:Info("Built " .. doorsBuilt .. " doors for connections")
end

function ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then
		return nil
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				if targetId == nodeB.id then
					return connection
				end
			end
		end
	end
	return nil
end

function ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then
		return nil
	end

	local connection = ConnectionBuilder.GetConnectionEntry(areaA, areaB)
	if connection then
		-- Choose optimal door position based on distance to destination
		local doorPositions = {}
		if connection.left then
			table.insert(doorPositions, connection.left)
		end
		if connection.middle then
			table.insert(doorPositions, connection.middle)
		end
		if connection.right then
			table.insert(doorPositions, connection.right)
		end

		if #doorPositions > 0 then
			-- Find closest door position to destination
			local bestPos = doorPositions[1]
			local bestDist = (doorPositions[1] - areaB.pos):Length()

			for i = 2, #doorPositions do
				local dist = (doorPositions[i] - areaB.pos):Length()
				if dist < bestDist then
					bestPos = doorPositions[i]
					bestDist = dist
				end
			end

			return bestPos
		end
	end

	return areaB.pos
end

return ConnectionBuilder
