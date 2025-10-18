--##########################################################################
--  DoorBuilder.lua  ·  Door system orchestration and connection management
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local DoorGeometry = require("MedBot.Navigation.Doors.DoorGeometry")

local DoorBuilder = {}

local Log = Common.Log.new("DoorBuilder")

-- ========================================================================
-- CONNECTION NORMALIZATION
-- ========================================================================

function DoorBuilder.NormalizeConnections()
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

-- ========================================================================
-- DOOR BUILDING
-- ========================================================================

function DoorBuilder.BuildDoorsForConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local doorsBuilt = 0
	local processedPairs = {} -- Track processed area pairs to avoid duplicates
	local doorNodes = {} -- Store created door nodes

	-- Find all unique area-to-area connections
	-- Count total connections first for debugging
	local totalConnections = 0
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					totalConnections = totalConnections + #dir.connections
				end
			end
		end
	end
	Log:Info("Total area connections found: %d", totalConnections)

	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then -- Only process actual areas
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode and not targetNode.isDoor then
							-- Create unique pair key (sorted to avoid duplicates)
							local pairKey = nodeId < targetId and (nodeId .. "_" .. targetId)
								or (targetId .. "_" .. nodeId)

							if not processedPairs[pairKey] then
								processedPairs[pairKey] = true

								-- Find reverse direction (if exists) in ORIGINAL area graph
								local revDir = nil
								local hasReverse = false
								if targetNode.c then
									for tDirId, tDir in pairs(targetNode.c) do
										if tDir.connections then
											for _, tConn in ipairs(tDir.connections) do
												if ConnectionUtils.GetNodeId(tConn) == nodeId then
													hasReverse = true
													revDir = tDirId
													if G.Menu.Main.Debug then
														Log:Debug(
															"Connection %s->%s: Found reverse (bidirectional)",
															nodeId,
															targetId
														)
													end
													break
												end
											end
											if hasReverse then
												break
											end
										end
									end
								end

								if not hasReverse then
									if G.Menu.Main.Debug then
										Log:Debug("Connection %s->%s: No reverse found (one-way)", nodeId, targetId)
									end
								end

								-- Create SHARED doors (use canonical ordering for IDs)
								local door = DoorGeometry.CreateDoorForAreas(node, targetNode, dirId)
								if door then
									local fwdDir = dirId

									-- Use smaller nodeId first for canonical door IDs
									local doorPrefix = (nodeId < targetId) and (nodeId .. "_" .. targetId)
										or (targetId .. "_" .. nodeId)

									-- Create door nodes with bidirectional connections (if applicable)
									if door.left then
										local doorId = doorPrefix .. "_left"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.left,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										-- Add reverse connection if bidirectional
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
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
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
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
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
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

	-- Build door-to-door connections FIRST (while area graph is intact)
	DoorBuilder.BuildDoorToDoorConnections()

	-- THEN replace area-to-area connections with area-to-door connections
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
							for _, prefix in ipairs({ doorPrefix1, doorPrefix2 }) do
								for suffix in pairs({ _left = true, _middle = true, _right = true }) do
									local doorId = prefix .. suffix
									if nodes[doorId] then
										table.insert(newConnections, doorId)
										foundDoors = true
									end
								end
								if foundDoors then
									break
								end -- Found doors with this prefix
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

	Log:Info("Built " .. doorsBuilt .. " door nodes for connections")
end

-- ========================================================================
-- DOOR-TO-DOOR CONNECTIONS
-- ========================================================================

-- Determine spatial direction between two positions using NESW indices
-- Returns dirId (1=North, 2=East, 3=South, 4=West) compatible with nav mesh format
local function calculateSpatialDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y

	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 2 or 4 -- East=2, West=4
	else
		return (dy > 0) and 3 or 1 -- South=3, North=1
	end
end

-- Create optimized door-to-door connections
function DoorBuilder.BuildDoorToDoorConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local connectionsAdded = 0
	local doorsByArea = {}

	-- Group doors by area for efficient lookup
	-- Only add door to an area if it connects BACK to that area (not one-way exit)
	for doorId, doorNode in pairs(nodes) do
		if doorNode.isDoor and doorNode.c then
			-- Check which areas this door connects TO
			for _, dir in pairs(doorNode.c) do
				if dir.connections then
					for _, conn in ipairs(dir.connections) do
						local connectedAreaId = ConnectionUtils.GetNodeId(conn)
						-- Add door to the area it connects to
						if not doorsByArea[connectedAreaId] then
							doorsByArea[connectedAreaId] = {}
						end
						table.insert(doorsByArea[connectedAreaId], doorNode)
					end
				end
			end
		end
	end

	-- Helper to calculate which side a door is on relative to an area
	local function getDoorSideForArea(doorPos, areaId)
		local area = nodes[areaId]
		if not area or not area.pos then
			return nil
		end

		local dx = doorPos.x - area.pos.x
		local dy = doorPos.y - area.pos.y

		if math.abs(dx) > math.abs(dy) then
			return (dx > 0) and 4 or 8 -- East=4, West=8
		else
			return (dy > 0) and 2 or 1 -- South=2, North=1
		end
	end

	-- Connect doors within each area (respecting one-way connections)
	for areaId, doors in pairs(doorsByArea) do
		for i = 1, #doors do
			local doorA = doors[i]

			for j = 1, #doors do
				if i ~= j then
					local doorB = doors[j]

					-- Calculate which side each door is on RELATIVE TO THIS AREA
					local sideA = getDoorSideForArea(doorA.pos, areaId)
					local sideB = getDoorSideForArea(doorB.pos, areaId)

					-- ONLY connect doors on DIFFERENT sides to avoid wall collisions
					if sideA and sideB and sideA ~= sideB then
						-- Check if BOTH doors are bidirectional (not one-way drops)
						-- One-way doors (dirCount == 1) should not participate in door-to-door
						local doorAIsBidirectional = false
						local doorBIsBidirectional = false

						if doorA.c then
							local dirCount = 0
							for _ in pairs(doorA.c) do
								dirCount = dirCount + 1
							end
							doorAIsBidirectional = (dirCount >= 2)
						end

						if doorB.c then
							local dirCount = 0
							for _ in pairs(doorB.c) do
								dirCount = dirCount + 1
							end
							doorBIsBidirectional = (dirCount >= 2)
						end

						-- Only create door-to-door if BOTH doors are bidirectional
						if doorAIsBidirectional and doorBIsBidirectional then
							local spatialDirAtoB = calculateSpatialDirection(doorA.pos, doorB.pos)

							if not doorA.c[spatialDirAtoB] then
								doorA.c[spatialDirAtoB] = { connections = {}, count = 0 }
							end

							-- Add A→B connection
							local alreadyConnected = false
							for _, conn in ipairs(doorA.c[spatialDirAtoB].connections) do
								if ConnectionUtils.GetNodeId(conn) == doorB.id then
									alreadyConnected = true
									break
								end
							end

							if not alreadyConnected then
								table.insert(doorA.c[spatialDirAtoB].connections, doorB.id)
								doorA.c[spatialDirAtoB].count = #doorA.c[spatialDirAtoB].connections
								connectionsAdded = connectionsAdded + 1
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Added " .. connectionsAdded .. " door-to-door connections for path optimization")
end

-- ========================================================================
-- UTILITY FUNCTIONS
-- ========================================================================

function DoorBuilder.GetConnectionEntry(nodeA, nodeB)
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
							isDoorConnection = true,
						}
					end
				end
			end
		end
	end
	return nil
end

function DoorBuilder.GetDoorTargetPoint(areaA, areaB)
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
	for _, suffix in ipairs({ "_left", "_middle", "_right" }) do
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

return DoorBuilder
