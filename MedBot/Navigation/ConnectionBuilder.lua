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
				local leftDist2D = Common.Distance2D(clampedLeft, Vector3(wallCorner.x, wallCorner.y, 0))
				local rightDist2D = Common.Distance2D(clampedRight, Vector3(wallCorner.x, wallCorner.y, 0))

				-- Only clamp if corner is too close to either endpoint
				if leftDist2D < WALL_CLEARANCE or rightDist2D < WALL_CLEARANCE then
					if isXAxisDoor then
						-- Door is horizontal (varies on X-axis), clamp on X-axis
						if wallCorner.x < clampedLeft.x and leftDist2D < WALL_CLEARANCE then
							-- Corner is to the left of door's left endpoint, move left endpoint right
							clampedLeft.x = wallCorner.x + WALL_CLEARANCE
						elseif wallCorner.x > clampedRight.x and rightDist2D < WALL_CLEARANCE then
							-- Corner is to the right of door's right endpoint, move right endpoint left
							clampedRight.x = wallCorner.x - WALL_CLEARANCE
						end
					else
						-- Door is vertical (varies on Y-axis), clamp on Y-axis
						if wallCorner.y < clampedLeft.y and leftDist2D < WALL_CLEARANCE then
							-- Corner is below door's left endpoint, move left endpoint up
							clampedLeft.y = wallCorner.y + WALL_CLEARANCE
						elseif wallCorner.y > clampedRight.y and rightDist2D < WALL_CLEARANCE then
							-- Corner is above door's right endpoint, move right endpoint down
							clampedRight.y = wallCorner.y - WALL_CLEARANCE
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

	local doorsBuilt = 0
	local processedPairs = {} -- Track processed area pairs to avoid duplicates
	local doorNodes = {} -- Store created door nodes
	
	-- Find all unique area-to-area connections
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then -- Only process actual areas
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]
						
						if targetNode and not targetNode.isDoor then
							-- Create unique pair key (sorted to avoid duplicates)
							local pairKey = nodeId < targetId 
								and (nodeId .. "_" .. targetId) 
								or (targetId .. "_" .. nodeId)
							
							if not processedPairs[pairKey] then
								processedPairs[pairKey] = true
								
								-- Find reverse direction (if exists)
								local revDir = nil
								local hasReverse = false
								if targetNode.c then
									for tDirId, tDir in pairs(targetNode.c) do
										if tDir.connections then
											for _, tConn in ipairs(tDir.connections) do
												if ConnectionUtils.GetNodeId(tConn) == nodeId then
													hasReverse = true
													revDir = tDirId
													break
												end
											end
											if hasReverse then break end
										end
									end
								end
								
								-- Create SHARED doors (use canonical ordering for IDs)
								local door = createDoorForAreas(node, targetNode)
								if door then
									local fwdDir = dirId
									
									-- Use smaller nodeId first for canonical door IDs
									local doorPrefix = (nodeId < targetId) and (nodeId .. "_" .. targetId) or (targetId .. "_" .. nodeId)
									
									-- Create door nodes with bidirectional connections (if applicable)
									if door.left then
										local doorId = doorPrefix .. "_left"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.left,
											isDoor = true,
											areaId = nodeId, -- Store both area associations
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = {targetId}, count = 1 }
											}
										}
										-- Add reverse connection if bidirectional
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = {nodeId}, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end

									if door.middle then
										local doorId = doorPrefix .. "_middle"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.middle,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = {targetId}, count = 1 }
											}
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = {nodeId}, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end

									if door.right then
										local doorId = doorPrefix .. "_right"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.right,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = {targetId}, count = 1 }
											}
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = {nodeId}, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end
								end
							end
						end
					end
				end
			end
		end
	end
	
	-- Add door nodes to graph
	for doorId, doorNode in pairs(doorNodes) do
		nodes[doorId] = doorNode
	end
	
	-- Replace area-to-area connections with area-to-door connections
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					local newConnections = {}
					
					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]
						
						if targetNode and not targetNode.isDoor then
							-- Find door nodes - try both orderings (canonical pair key)
							local doorPrefix1 = nodeId .. "_" .. targetId
							local doorPrefix2 = targetId .. "_" .. nodeId
							local foundDoors = false
							
							-- Try both possible door ID patterns
							for _, prefix in ipairs({doorPrefix1, doorPrefix2}) do
								for suffix in pairs({_left=true, _middle=true, _right=true}) do
									local doorId = prefix .. suffix
									if nodes[doorId] then
										table.insert(newConnections, doorId)
										foundDoors = true
									end
								end
								if foundDoors then break end -- Found doors with this prefix
							end
							
							-- If no doors found, keep original connection
							if not foundDoors then
								table.insert(newConnections, connection)
							end
						else
							-- Keep non-area connections
							table.insert(newConnections, connection)
						end
					end
					
					dir.connections = newConnections
					dir.count = #newConnections
				end
			end
		end
	end

	-- Create door-to-door connections
	ConnectionBuilder.BuildDoorToDoorConnections()

	Log:Info("Built " .. doorsBuilt .. " door nodes for connections")
end

-- Determine spatial direction between two positions
local function calculateSpatialDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	
	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 4 or 8 -- East or West
	else
		return (dy > 0) and 2 or 1 -- South or North
	end
end

-- Create optimized door-to-door connections
function ConnectionBuilder.BuildDoorToDoorConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local connectionsAdded = 0
	local doorsByArea = {}

	-- Group doors by area for efficient lookup (doors belong to both connected areas)
	for doorId, doorNode in pairs(nodes) do
		if doorNode.isDoor then
			-- Add to both areas this door connects
			if doorNode.areaId then
				if not doorsByArea[doorNode.areaId] then
					doorsByArea[doorNode.areaId] = {}
				end
				table.insert(doorsByArea[doorNode.areaId], doorNode)
			end
			if doorNode.targetAreaId and doorNode.targetAreaId ~= doorNode.areaId then
				if not doorsByArea[doorNode.targetAreaId] then
					doorsByArea[doorNode.targetAreaId] = {}
				end
				table.insert(doorsByArea[doorNode.targetAreaId], doorNode)
			end
		end
	end

	-- Connect doors within each area (bidirectionally)
	for areaId, doors in pairs(doorsByArea) do
		for i = 1, #doors do
			local doorA = doors[i]
			
			for j = i + 1, #doors do -- Only process each pair once
				local doorB = doors[j]
				
				-- Only connect doors on different sides (different direction)
				if doorA.direction ~= doorB.direction then
					-- Calculate spatial directions (bidirectional)
					local spatialDirAtoB = calculateSpatialDirection(doorA.pos, doorB.pos)
					local spatialDirBtoA = calculateSpatialDirection(doorB.pos, doorA.pos)
					
					-- Initialize connection tables if needed
					if not doorA.c then doorA.c = {} end
					if not doorA.c[spatialDirAtoB] then
						doorA.c[spatialDirAtoB] = { connections = {}, count = 0 }
					end
					
					if not doorB.c then doorB.c = {} end
					if not doorB.c[spatialDirBtoA] then
						doorB.c[spatialDirBtoA] = { connections = {}, count = 0 }
					end

					-- Add A→B connection
					local alreadyConnectedAtoB = false
					for _, conn in ipairs(doorA.c[spatialDirAtoB].connections) do
						if ConnectionUtils.GetNodeId(conn) == doorB.id then
							alreadyConnectedAtoB = true
							break
						end
					end
					
					if not alreadyConnectedAtoB then
						table.insert(doorA.c[spatialDirAtoB].connections, doorB.id)
						doorA.c[spatialDirAtoB].count = #doorA.c[spatialDirAtoB].connections
						connectionsAdded = connectionsAdded + 1
					end
					
					-- Add B→A connection (reverse)
					local alreadyConnectedBtoA = false
					for _, conn in ipairs(doorB.c[spatialDirBtoA].connections) do
						if ConnectionUtils.GetNodeId(conn) == doorA.id then
							alreadyConnectedBtoA = true
							break
						end
					end
					
					if not alreadyConnectedBtoA then
						table.insert(doorB.c[spatialDirBtoA].connections, doorA.id)
						doorB.c[spatialDirBtoA].count = #doorB.c[spatialDirBtoA].connections
						connectionsAdded = connectionsAdded + 1
					end
				end
			end
		end
	end

	Log:Info("Added " .. connectionsAdded .. " door-to-door connections for path optimization")
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
					-- Return connection info if it's a table, otherwise just the ID
					if type(connection) == "table" then
						return connection
					else
						-- For door connections (strings), return basic info
						return {
							nodeId = connection,
							isDoorConnection = true
						}
					end
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

	-- Find door nodes that connect areaA to areaB
	local nodes = G.Navigation.nodes
	if not nodes then
		return areaB.pos
	end

	-- Look for door nodes that have areaA as source and areaB as target
	local doorBaseId = areaA.id .. "_" .. areaB.id
	local doorPositions = {}

	-- Check all three door positions (left, middle, right)
	for _, suffix in ipairs({"_left", "_middle", "_right"}) do
		local doorId = doorBaseId .. suffix
		local doorNode = nodes[doorId]
		if doorNode and doorNode.pos then
			table.insert(doorPositions, doorNode.pos)
		end
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

	return areaB.pos
end

return ConnectionBuilder
