--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local SourceNav = require("MedBot.Utils.SourceNav") --[[ Imported by: MedBot.Navigation ]]
local isWalkable = require("MedBot.Modules.ISWalkable") --[[ Imported by: MedBot.Modules.Node ]]
local Log = Common.Log.new("Node")
Log.Level = 0

--[[ Module Declaration ]]
local Node = {}

--[[ Local Variables ]]
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)

--[[ Helper Functions ]]
local function tryLoadNavFile(navFilePath)
	local file = io.open(navFilePath, "rb")
	if not file then
		return nil, "File not found"
	end
	local content = file:read("*a")
	file:close()
	local navData = SourceNav.parse(content)
	if not navData or #navData.areas == 0 then
		return nil, "Failed to parse nav file or no areas found."
	end
	return navData
end

local function generateNavFile()
	client.RemoveConVarProtection("sv_cheats")
	client.RemoveConVarProtection("nav_generate")
	client.SetConVar("sv_cheats", "1")
	client.Command("nav_generate", true)
	Log:Info("Generating nav file. Please wait...")
	local delay = 10
	local startTime = os.time()
	repeat
	until os.time() - startTime > delay
end

local function processNavData(navData)
	local navNodes = {}
	for _, area in ipairs(navData.areas) do
		local cX = (area.north_west.x + area.south_east.x) / 2
		local cY = (area.north_west.y + area.south_east.y) / 2
		local cZ = (area.north_west.z + area.south_east.z) / 2
		local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
		local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
		local ne = Vector3(area.south_east.x, area.north_west.y, area.north_east_z)
		local sw = Vector3(area.north_west.x, area.south_east.y, area.south_west_z)
		navNodes[area.id] =
			{ pos = Vector3(cX, cY, cZ), id = area.id, c = area.connections, nw = nw, se = se, ne = ne, sw = sw }
	end
	return navNodes
end

local function traceHullDown(position)
	-- Trace hull from above down to find ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, TRACE_MASK)
end

local function traceLineDown(position)
	-- Line trace down to adjust corner to ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceLine(startPos, endPos, TRACE_MASK)
end

local function getGroundNormal(position)
	local trace =
		engine.TraceLine(position + GROUND_TRACE_OFFSET_START, position + GROUND_TRACE_OFFSET_END, MASK_BRUSH_ONLY)
	return trace.plane
end

local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()
	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)
	local function rotateAroundNormal(vector, angle)
		local cosT = math.cos(angle)
		local sinT = math.sin(angle)
		return Vector3(
			(cosT + (1 - cosT) * normal.x ^ 2) * vector.x
				+ ((1 - cosT) * normal.x * normal.y - normal.z * sinT) * vector.y
				+ ((1 - cosT) * normal.x * normal.z + normal.y * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.y + normal.z * sinT) * vector.x
				+ (cosT + (1 - cosT) * normal.y ^ 2) * vector.y
				+ ((1 - cosT) * normal.y * normal.z - normal.x * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.z - normal.y * sinT) * vector.x
				+ ((1 - cosT) * normal.y * normal.z + normal.x * sinT) * vector.y
				+ (cosT + (1 - cosT) * normal.z ^ 2) * vector.z
		)
	end
	local rot = rotateAroundNormal(heightVector, math.pi / 2)
	return { corner1 + rot * (height / widthLength), corner2 + rot * (height / widthLength) }
end

--- Get all corner positions of a node
---@param node table The node to get corners from
---@return Vector3[] Array of corner positions
local function getNodeCorners(node)
	local corners = {}
	if node.nw then
		table.insert(corners, node.nw)
	end
	if node.ne then
		table.insert(corners, node.ne)
	end
	if node.se then
		table.insert(corners, node.se)
	end
	if node.sw then
		table.insert(corners, node.sw)
	end
	-- Always include center position
	if node.pos then
		table.insert(corners, node.pos)
	end
	return corners
end

--- Check if two nodes are accessible using optimized three-tier fallback approach
--- Allows going down from any height, but restricts upward movement to 72 units
---@param nodeA table First node (source)
---@param nodeB table Second node (destination)
---@return boolean True if nodes are accessible to each other
local function isNodeAccessible(nodeA, nodeB)
	local heightDiff = nodeB.pos.z - nodeA.pos.z -- Positive = going up, negative = going down
	
	-- Always allow going downward (falling) regardless of height
	if heightDiff <= 0 then
		return true
	end
	
	-- For upward movement, check if it's within duck jump height (72 units)
	if heightDiff <= 72 then
		return true -- Fast path: upward movement is within jump height
	end

	-- If upward movement > 72 units, check corners for stairs/ramps
	local cornersA = getNodeCorners(nodeA)
	local cornersB = getNodeCorners(nodeB)

	for _, cornerA in ipairs(cornersA) do
		for _, cornerB in ipairs(cornersB) do
			local cornerHeightDiff = cornerB.z - cornerA.z
			-- Allow if any corner-to-corner connection is within jump height
			if cornerHeightDiff <= 72 then
				return true -- Medium path: corners indicate possible stairs/ramp
			end
		end
	end

	-- Third pass: Expensive walkability check (only if allowed and previous checks failed)
	if G.Menu.Main.AllowExpensiveChecks then
		return isWalkable.Path(nodeA.pos, nodeB.pos)
	end

	-- If expensive checks are disabled and previous checks failed, assume invalid
	return false
end

--- Remove invalid connections between nodes (simple version to prevent crashes)
---@param nodes table All navigation nodes
local function pruneInvalidConnections(nodes)
	local prunedCount = 0
	local totalChecked = 0

	Log:Info("Starting connection cleanup...")

	for nodeId, node in pairs(nodes) do
		if not node or not node.c then
			goto continue
		end

		-- Check all directions using ipairs
		for dir, connectionDir in ipairs(node.c) do
			if connectionDir and connectionDir.connections then
				local validConnections = {}

				-- Use ipairs to iterate through connections
				for _, targetNodeId in ipairs(connectionDir.connections) do
					totalChecked = totalChecked + 1
					local targetNode = nodes[targetNodeId]

					if targetNode then
						-- Use proper accessibility check that considers up/down movement
						if isNodeAccessible(node, targetNode) then
							table.insert(validConnections, targetNodeId)
						else
							prunedCount = prunedCount + 1
						end
					else
						-- Remove connections to non-existent nodes
						prunedCount = prunedCount + 1
					end
				end

				-- Update the connections array
				connectionDir.connections = validConnections
				connectionDir.count = #validConnections
			end
		end

		::continue::
	end

	Log:Info("Connection cleanup complete: %d/%d connections pruned", prunedCount, totalChecked)
end

--[[ Public Module Functions ]]

function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes and G.Navigation.nodes[id] or nil
end

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end
	local closest, dist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		local d = (node.pos - pos):Length()
		if d < dist then
			dist, closest = d, node
		end
	end
	return closest
end

--- Manually trigger connection cleanup (useful for debugging)
function Node.CleanupConnections()
	local nodes = Node.GetNodes()
	if nodes then
		pruneInvalidConnections(nodes)
	else
		Log:Warn("No nodes loaded for cleanup")
	end
end

function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified connection adding
	for dir, cDir in ipairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			table.insert(cDir.connections, nodeB.id)
			cDir.count = cDir.count + 1
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified connection removal
	for dir, cDir in ipairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, v in ipairs(cDir.connections) do
				if v == nodeB.id then
					table.remove(cDir.connections, i)
					cDir.count = cDir.count - 1
					break
				end
			end
		end
	end
end

function Node.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified cost addition
	for dir, cDir in ipairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, v in ipairs(cDir.connections) do
				if v == nodeB.id then
					cDir.connections[i] = { node = v, cost = cost }
					break
				end
			end
		end
	end
end

function Node.GetAdjacentNodes(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for d, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, cid in ipairs(cDir.connections) do
				local targetNode = nodes[cid]
				if targetNode and targetNode.pos then
					-- Use centralized accessibility check
					if isNodeAccessible(node, targetNode) then
						table.insert(adjacent, targetNode)
					end
				end
			end
		end
	end
	return adjacent
end

function Node.LoadFile(navFile)
	local full = "tf/" .. navFile
	local navData, err = tryLoadNavFile(full)
	if not navData and err == "File not found" then
		Log:Warn("Nav file not found, attempting to generate...")
		generateNavFile()
		navData, err = tryLoadNavFile(full)
		if not navData then
			Log:Error("Failed to load or parse generated nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		end
	elseif not navData then
		Log:Error("Failed to load nav file: %s", err or "unknown")
		-- Initialize empty nodes table to prevent crashes
		Node.SetNodes({})
		return false
	end

	local navNodes = processNavData(navData)
	Node.SetNodes(navNodes)
	Log:Info("Successfully loaded %d navigation nodes", table.getn and table.getn(navNodes) or 0)

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		pruneInvalidConnections(navNodes)
	else
		Log:Info("Connection cleanup is disabled in settings")
	end

	return true
end

function Node.LoadNavFile()
	local mf = engine.GetMapName()
	if mf and mf ~= "" then
		Node.LoadFile(string.gsub(mf, ".bsp", ".nav"))
	else
		Log:Warn("No map name available for nav file loading")
		Node.SetNodes({})
	end
end

function Node.Setup()
	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Log:Info("Setting up navigation for map: %s", mapName)
		Node.LoadNavFile()
	else
		Log:Info("No valid map loaded, initializing empty navigation nodes")
		-- Initialize empty nodes table to prevent crashes when no map is loaded
		Node.SetNodes({})
	end
end

--[[ Hierarchical Pathfinding Support ]]

--- Calculate Z coordinate on the plane defined by the 4 corners of the nav area
---@param x number X coordinate
---@param y number Y coordinate  
---@param nw Vector3 North-west corner
---@param ne Vector3 North-east corner
---@param se Vector3 South-east corner
---@param sw Vector3 South-west corner
---@return number Z coordinate on the plane
local function calculateZOnPlane(x, y, nw, ne, se, sw)
	-- Use bilinear interpolation to find Z on the plane defined by 4 corners
	local width = se.x - nw.x
	local height = se.y - nw.y
	
	if width == 0 or height == 0 then
		return nw.z -- Fallback to corner Z if area is degenerate
	end
	
	-- Normalize coordinates (0,0) to (1,1)
	local u = (x - nw.x) / width
	local v = (y - nw.y) / height
	
	-- Clamp to valid range
	u = math.max(0, math.min(1, u))
	v = math.max(0, math.min(1, v))
	
	-- Bilinear interpolation
	local z1 = nw.z * (1 - u) + ne.z * u  -- North edge interpolation
	local z2 = sw.z * (1 - u) + se.z * u  -- South edge interpolation
	local z = z1 * (1 - v) + z2 * v       -- Final interpolation
	
	return z
end

--- Check if a 2D line from point A to point B stays within the walkable areas (2D top-down view)
---@param pointA Vector3 Start point
---@param pointB Vector3 End point
---@param areaA table Source area
---@param areaB table Target area
---@return boolean True if line stays within walkable space
local function canConnect2D(pointA, pointB, areaA, areaB)
	-- For adjacent nav areas, be more permissive - if they're already connected in the nav mesh,
	-- they should be able to connect via fine points
	local samples = 3 -- Reduced samples for performance
	local stepX = (pointB.x - pointA.x) / samples
	local stepY = (pointB.y - pointA.y) / samples
	
	local validSamples = 0
	for i = 0, samples do
		local testX = pointA.x + i * stepX
		local testY = pointA.y + i * stepY
		
		-- Check if this sample point is within either area (2D)
		local inAreaA = isPointInArea2D(testX, testY, areaA)
		local inAreaB = isPointInArea2D(testX, testY, areaB)
		
		if inAreaA or inAreaB then
			validSamples = validSamples + 1
		end
	end
	
	-- If most samples are valid, allow the connection
	local validRatio = validSamples / (samples + 1)
	local isValid = validRatio >= 0.6 -- Allow connection if 60% of samples are within areas
	
	if not isValid then
		Log:Debug("2D connectivity check failed: only %.1f%% of samples were within areas", validRatio * 100)
	end
	
	return isValid
end

--- Check if a 2D point is within a nav area (top-down view)
---@param x number X coordinate
---@param y number Y coordinate
---@param area table Nav area with corners
---@return boolean True if point is inside area
local function isPointInArea2D(x, y, area)
	if not area.nw or not area.se then
		return false
	end
	
	-- Simple bounding box check (could be improved for rotated areas)
	return x >= area.nw.x and x <= area.se.x and y >= area.nw.y and y <= area.se.y
end

--- Generate a grid of fine-grained points within a nav area using fixed 24-unit spacing
---@param area table The nav area to generate points for
---@return table[] Array of point objects with pos, neighbors, id, and isEdge flag
local function generateAreaPoints(area)
	local GRID_SPACING = 24 -- Fixed 24-unit spacing as requested
	
	if not area.nw or not area.ne or not area.se or not area.sw then
		-- Fallback to center point if corners are missing
		Log:Warn("Area %d missing corners, using center point", area.id or 0)
		return {{pos = area.pos, neighbors = {}, id = 1, parentArea = area.id, isEdge = false}}
	end
	
	local points = {}
	local nw, ne, se, sw = area.nw, area.ne, area.se, area.sw
	
	-- Calculate actual area bounds (min/max coordinates)
	local minX = math.min(nw.x, ne.x, se.x, sw.x)
	local maxX = math.max(nw.x, ne.x, se.x, sw.x)
	local minY = math.min(nw.y, ne.y, se.y, sw.y)
	local maxY = math.max(nw.y, ne.y, se.y, sw.y)
	
	-- Calculate area dimensions
	local width = maxX - minX
	local height = maxY - minY
	
	-- Skip if area is too small for even one grid point
	if width < GRID_SPACING or height < GRID_SPACING then
		local centerZ = calculateZOnPlane(area.pos.x, area.pos.y, nw, ne, se, sw)
		Log:Debug("Area %d too small for 24-unit grid, using center point", area.id or 0)
		return {{pos = Vector3(area.pos.x, area.pos.y, centerZ), neighbors = {}, id = 1, parentArea = area.id, isEdge = false}}
	end
	
	-- Calculate number of grid points that fit perfectly
	local gridPointsX = math.floor(width / GRID_SPACING) + 1
	local gridPointsY = math.floor(height / GRID_SPACING) + 1
	
	-- Generate ALL points covering the whole plane with 24-unit spacing
	local allPoints = {}
	for i = 0, gridPointsX - 1 do
		for j = 0, gridPointsY - 1 do
			local pointX = minX + i * GRID_SPACING
			local pointY = minY + j * GRID_SPACING
			local pointZ = calculateZOnPlane(pointX, pointY, nw, ne, se, sw)
			
			table.insert(allPoints, {
				pos = Vector3(pointX, pointY, pointZ),
				neighbors = {},
				id = #allPoints + 1,
				parentArea = area.id,
				isEdge = false,
				gridX = i,
				gridY = j
			})
		end
	end
	
	-- FIRST PASS: Remove edge points (points on the boundary of the grid)
	for _, point in ipairs(allPoints) do
		local isOnBoundary = (point.gridX == 0 or point.gridX == gridPointsX - 1 or 
		                      point.gridY == 0 or point.gridY == gridPointsY - 1)
		if not isOnBoundary then
			table.insert(points, point)
		end
	end
	
	-- SECOND PASS: Mark new boundary points as edges for later calculations
	if #points > 1 then
		-- Find the new min/max grid coordinates after removing boundary
		local minGridX, maxGridX = math.huge, -math.huge
		local minGridY, maxGridY = math.huge, -math.huge
		
		for _, point in ipairs(points) do
			minGridX = math.min(minGridX, point.gridX)
			maxGridX = math.max(maxGridX, point.gridX)
			minGridY = math.min(minGridY, point.gridY)
			maxGridY = math.max(maxGridY, point.gridY)
		end
		
		-- Mark points that are now on the new boundary as edges
		for _, point in ipairs(points) do
			point.isEdge = (point.gridX == minGridX or point.gridX == maxGridX or 
			                point.gridY == minGridY or point.gridY == maxGridY)
		end
	end
	
	-- Re-assign IDs after filtering
	for i, point in ipairs(points) do
		point.id = i
	end
	
	-- If no points generated, add center point
	if #points == 0 then
		local centerZ = calculateZOnPlane(area.pos.x, area.pos.y, nw, ne, se, sw)
		table.insert(points, {pos = Vector3(area.pos.x, area.pos.y, centerZ), neighbors = {}, id = 1, parentArea = area.id, isEdge = false})
		Log:Debug("Added fallback center point for area %d", area.id or 0)
	end
	
	Log:Debug("Generated %d points for area %d (removed boundary, marked %d as edges)", 
		#points, area.id or 0, #points > 0 and (function()
			local edgeCount = 0
			for _, p in ipairs(points) do
				if p.isEdge then edgeCount = edgeCount + 1 end
			end
			return edgeCount
		end)() or 0)
	return points
end

--- Add internal connections within an area after points are generated
---@param points table[] Array of points in the area
local function addInternalConnections(points)
	local GRID_SPACING = 24
	local connectionsAdded = 0
	
	-- Add connections between ALL remaining points (not just adjacent grid points)
	for _, pointA in ipairs(points) do
		for _, pointB in ipairs(points) do
			if pointA.id ~= pointB.id then
				local distance = (pointA.pos - pointB.pos):Length()
				
				-- Connect to immediate neighbors and diagonals
				if distance <= GRID_SPACING * 1.5 then -- Allow for diagonal connections
					table.insert(pointA.neighbors, {point = pointB, cost = distance, isInterArea = false})
					connectionsAdded = connectionsAdded + 1
				end
			end
		end
	end
	
	-- Ensure all points have at least one connection (connectivity guarantee)
	for _, point in ipairs(points) do
		if #point.neighbors == 0 then
			-- Find the closest point and force a connection
			local closestPoint = nil
			local closestDistance = math.huge
			for _, otherPoint in ipairs(points) do
				if otherPoint.id ~= point.id then
					local distance = (point.pos - otherPoint.pos):Length()
					if distance < closestDistance then
						closestDistance = distance
						closestPoint = otherPoint
					end
				end
			end
			if closestPoint then
				table.insert(point.neighbors, {point = closestPoint, cost = closestDistance, isInterArea = false})
				table.insert(closestPoint.neighbors, {point = point, cost = closestDistance, isInterArea = false})
				connectionsAdded = connectionsAdded + 2
				Log:Debug("Force-connected isolated point %d to point %d in area %d", point.id, closestPoint.id, point.parentArea)
			end
		end
	end
	
	return connectionsAdded
end

--- Connect edge points between two adjacent areas using Manhattan distance for performance
---@param areaA table First area
---@param areaB table Second area
---@param pointsA table[] Fine points from area A
---@param pointsB table[] Fine points from area B
---@return number Number of connections created
local function connectAdjacentAreas(areaA, areaB, pointsA, pointsB)
	local connections = 0
	
	-- Get edge points from both areas
	local edgePointsA = {}
	local edgePointsB = {}
	
	for _, point in ipairs(pointsA) do
		if point.isEdge then
			table.insert(edgePointsA, point)
		end
	end
	
	for _, point in ipairs(pointsB) do
		if point.isEdge then
			table.insert(edgePointsB, point)
		end
	end
	
	Log:Debug("Area %d has %d edge points, Area %d has %d edge points", 
		areaA.id, #edgePointsA, areaB.id, #edgePointsB)
	
	if #edgePointsA == 0 or #edgePointsB == 0 then
		Log:Debug("One of the areas has no edge points, skipping connection")
		return 0
	end
	
	-- For each edge point in A, find closest edge point in B using Manhattan distance
	for _, pointA in ipairs(edgePointsA) do
		local closestB = nil
		local closestDistance = math.huge
		
		for _, pointB in ipairs(edgePointsB) do
			-- Use Manhattan distance for performance as requested
			local manhattanDist = math.abs(pointA.pos.x - pointB.pos.x) + math.abs(pointA.pos.y - pointB.pos.y)
			
			if manhattanDist < closestDistance then
				closestDistance = manhattanDist
				closestB = pointB
			end
		end
		
		if closestB then
			-- Use actual 3D distance for connection cost
			local distance3D = (pointA.pos - closestB.pos):Length()
			
			-- Add bidirectional connection
			table.insert(pointA.neighbors, {point = closestB, cost = distance3D, isInterArea = true})
			table.insert(closestB.neighbors, {point = pointA, cost = distance3D, isInterArea = true})
			connections = connections + 1
			
			Log:Debug("Created inter-area connection: Area %d Point %d <-> Area %d Point %d (distance: %.1f)", 
				pointA.parentArea, pointA.id, closestB.parentArea, closestB.id, distance3D)
		end
	end
	
	return connections
end

--- Generate fine-grained points for a specific nav area and cache them (no parameters for spacing)
---@param areaId number The area ID to generate points for
---@return table[]|nil Array of points or nil if area not found
function Node.GenerateAreaPoints(areaId)
	local nodes = Node.GetNodes()
	if not nodes or not nodes[areaId] then
		return nil
	end
	
	local area = nodes[areaId]
	if not area.finePoints then
		-- Generate points with fixed 24-unit spacing
		area.finePoints = generateAreaPoints(area)
		
		-- Add internal connections after point generation
		local connectionsAdded = addInternalConnections(area.finePoints)
		
		Log:Info("Generated %d fine points for area %d with %d internal connections", 
			#area.finePoints, areaId, connectionsAdded)
	end
	
	return area.finePoints
end

--- Get fine-grained points for an area, generating them if needed
---@param areaId number The area ID
---@return table[]|nil Array of points or nil if area not found
function Node.GetAreaPoints(areaId)
	local nodes = Node.GetNodes()
	if not nodes or not nodes[areaId] then
		return nil
	end
	
	local area = nodes[areaId]
	if not area.finePoints then
		return Node.GenerateAreaPoints(areaId)
	end
	
	return area.finePoints
end

--- Find the closest fine point within an area to a given position
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest point or nil if not found
function Node.GetClosestAreaPoint(areaId, position)
	local points = Node.GetAreaPoints(areaId)
	if not points then
		return nil
	end
	
	local closest, minDist = nil, math.huge
	for _, point in ipairs(points) do
		local dist = (point.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = point
		end
	end
	
	return closest
end

--- Clear cached fine points for all areas (useful when settings change)
function Node.ClearAreaPoints()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end
	
	local clearedCount = 0
	for _, area in pairs(nodes) do
		if area.finePoints then
			area.finePoints = nil
			clearedCount = clearedCount + 1
		end
	end
	
	Log:Info("Cleared fine points cache for %d areas", clearedCount)
end

--- Generate fine points for all areas and create inter-area connections with separate passes
---@param maxAreas number? Maximum number of areas to process (for performance)
function Node.GenerateHierarchicalNetwork(maxAreas)
	maxAreas = maxAreas or 50 -- Limit for performance
	local nodes = Node.GetNodes()
	if not nodes then
		Log:Warn("No nodes available for hierarchical network generation")
		return
	end
	
	Log:Info("=== Starting hierarchical network generation ===")
	local processedAreas = {}
	local areaCount = 0
	
	-- PASS 1: Generate fine points for each area with internal connections
	Log:Info("Pass 1: Generating points and internal connections...")
	for areaId, area in pairs(nodes) do
		if areaCount >= maxAreas then
			break
		end
		
		local points = Node.GenerateAreaPoints(areaId)
		if points and #points > 0 then
			processedAreas[areaId] = {area = area, points = points}
			areaCount = areaCount + 1
			Log:Debug("Processed area %d with %d points", areaId, #points)
		end
	end
	
	Log:Info("Generated fine points for %d areas", areaCount)
	
	-- PASS 2: Create inter-area connections between adjacent areas
	Log:Info("Pass 2: Creating inter-area connections...")
	local totalConnections = 0
	local checkedPairs = 0
	
	for areaIdA, dataA in pairs(processedAreas) do
		-- Check connections to adjacent areas - iterate through all 4 directions
		for dir = 1, 4 do
			local connectionDir = dataA.area.c[dir]
			if connectionDir and connectionDir.connections and #connectionDir.connections > 0 then
				for _, targetAreaId in ipairs(connectionDir.connections) do
					local dataB = processedAreas[targetAreaId]
					if dataB and targetAreaId ~= areaIdA then -- Avoid self-connections
						checkedPairs = checkedPairs + 1
						Log:Debug("Connecting area %d to area %d", areaIdA, targetAreaId)
						
						local connections = connectAdjacentAreas(dataA.area, dataB.area, dataA.points, dataB.points)
						totalConnections = totalConnections + connections
						
						if connections > 0 then
							Log:Info("✓ Connected areas %d <-> %d with %d fine point connections", areaIdA, targetAreaId, connections)
						else
							Log:Warn("✗ No connections created between areas %d <-> %d", areaIdA, targetAreaId)
						end
					end
				end
			end
		end
	end
	
	Log:Info("=== Network generation complete ===")
	Log:Info("Checked pairs: %d", checkedPairs)  
	Log:Info("Created %d inter-area fine point connections", totalConnections)
	
	-- Verify connections were actually created
	local verificationCount = 0
	for areaId, data in pairs(processedAreas) do
		for _, point in ipairs(data.points) do
			for _, neighbor in ipairs(point.neighbors) do
				if neighbor.isInterArea then
					verificationCount = verificationCount + 1
				end
			end
		end
	end
	Log:Info("Verification: Found %d inter-area connections in the data structure", verificationCount)
end

return Node


