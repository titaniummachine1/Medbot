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

--- Generate a grid of fine-grained points within a nav area for detailed local pathfinding
---@param area table The nav area to generate points for
---@param stepSize number? Grid step size in units (default: 32)
---@param edgeBuffer number? Distance from edges (default: 16)
---@return table[] Array of point objects with pos, neighbors, and id
local function generateAreaPoints(area, stepSize, edgeBuffer)
	stepSize = stepSize or 32 -- Smaller step size for better accuracy
	edgeBuffer = edgeBuffer or 16
	
	if not area.nw or not area.se then
		-- Fallback to center point if corners are missing
		return {{pos = area.pos, neighbors = {}, id = 1}}
	end
	
	local points = {}
	local nw, se = area.nw, area.se
	
	-- Calculate dimensions of the area
	local dimX = math.abs(se.x - nw.x) - 2 * edgeBuffer
	local dimY = math.abs(se.y - nw.y) - 2 * edgeBuffer
	
	-- Skip if area is too small
	if dimX <= 0 or dimY <= 0 then
		return {{pos = area.pos, neighbors = {}, id = 1}}
	end
	
	-- Calculate starting points
	local startX = nw.x + edgeBuffer
	local startY = nw.y + edgeBuffer
	
	-- Calculate number of steps
	local stepsX = math.floor(dimX / stepSize)
	local stepsY = math.floor(dimY / stepSize)
	
	-- Center the grid
	local extraSpaceX = dimX - stepsX * stepSize
	local extraSpaceY = dimY - stepsY * stepSize
	
	startX = startX + extraSpaceX / 2
	startY = startY + extraSpaceY / 2
	
	-- Generate points
	for i = 0, stepsX do
		for j = 0, stepsY do
			local pointX = startX + i * stepSize
			local pointY = startY + j * stepSize
			local pointZ = nw.z -- Assume flat area, could be improved with ground tracing
			
			table.insert(points, {
				pos = Vector3(pointX, pointY, pointZ),
				neighbors = {},
				id = #points + 1,
				parentArea = area.id
			})
		end
	end
	
	-- Assign neighbors to each point
	for i, pointA in ipairs(points) do
		for j, pointB in ipairs(points) do
			if i ~= j then
				local distance = (pointA.pos - pointB.pos):Length()
				if distance <= (stepSize * 1.5) then -- Allow diagonal connections
					table.insert(pointA.neighbors, {point = pointB, cost = distance})
				end
			end
		end
	end
	
	-- If no points generated, add center point
	if #points == 0 then
		table.insert(points, {pos = area.pos, neighbors = {}, id = 1, parentArea = area.id})
	end
	
	return points
end

--- Generate fine-grained points for a specific nav area and cache them
---@param areaId number The area ID to generate points for
---@return table[]|nil Array of points or nil if area not found
function Node.GenerateAreaPoints(areaId)
	local nodes = Node.GetNodes()
	if not nodes or not nodes[areaId] then
		return nil
	end
	
	local area = nodes[areaId]
	if not area.finePoints then
		area.finePoints = generateAreaPoints(area)
		Log:Info("Generated %d fine points for area %d", #area.finePoints, areaId)
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

return Node
