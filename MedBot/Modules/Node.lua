--##########################################################################
--  Node.lua  ·  MedBot Navigation / Hierarchical path-finding
--  2025-05-24  fully re-worked thin-area grid + robust inter-area linking
--##########################################################################

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local SourceNav = require("MedBot.Utils.SourceNav")
local isWalkable = require("MedBot.Modules.ISWalkable")

local Log = Common.Log.new("Node") -- default Verbose in dev-build
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

--==========================================================================
--  CONSTANTS
--==========================================================================
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local GRID = 24 -- 24-unit fine grid

--==========================================================================
--  NAV-FILE LOADING (unchanged)
--==========================================================================
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
	for _, area in pairs(navData.areas) do
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

	for _, cornerA in pairs(cornersA) do
		for _, cornerB in pairs(cornersB) do
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

--- Remove invalid connections between nodes (expensive validation at setup time)
---@param nodes table All navigation nodes
local function pruneInvalidConnections(nodes)
	local prunedCount = 0
	local totalChecked = 0

	Log:Info("Starting connection cleanup (expensive validation at setup time)...")

	for nodeId, node in pairs(nodes) do
		if not node or not node.c then
			goto continue
		end

		-- Check all directions using pairs
		for dir, connectionDir in pairs(node.c) do
			if connectionDir and connectionDir.connections then
				local validConnections = {}

				-- Use pairs to iterate through connections
				for _, targetNodeId in pairs(connectionDir.connections) do
					totalChecked = totalChecked + 1
					local targetNode = nodes[targetNodeId]

					if targetNode then
						-- Use expensive accessibility check for thorough validation at setup
						if isNodeAccessible(node, targetNode) then
							table.insert(validConnections, targetNodeId)
						else
							prunedCount = prunedCount + 1
							Log:Debug("Pruned inaccessible connection: %d -> %d", nodeId, targetNodeId)
						end
					else
						-- Remove connections to non-existent nodes
						prunedCount = prunedCount + 1
						Log:Debug("Pruned connection to non-existent node: %d -> %d", nodeId, targetNodeId)
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

------------------------------------------------------------------------
--  Utility  ·  bilinear Z on the area-plane
------------------------------------------------------------------------
local function bilinearZ(x, y, nw, ne, se, sw)
	local w, h = se.x - nw.x, se.y - nw.y
	if w == 0 or h == 0 then
		return nw.z
	end
	local u, v = (x - nw.x) / w, (y - nw.y) / h
	u, v = math.max(0, math.min(1, u)), math.max(0, math.min(1, v))
	local zN = nw.z * (1 - u) + ne.z * u
	local zS = sw.z * (1 - u) + se.z * u
	return zN * (1 - v) + zS * v
end

------------------------------------------------------------------------
--  Fine-grid generation   (thin-area aware + ring & dir tags)
------------------------------------------------------------------------
local function generateAreaPoints(area)
	------------------------------------------------------------
	-- cache bounds
	------------------------------------------------------------
	area.minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	area.maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	area.minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
	area.maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)

	local gx = math.floor((area.maxX - area.minX) / GRID) + 1
	local gy = math.floor((area.maxY - area.minY) / GRID) + 1
	if gx == 0 or gy == 0 then -- degenerate
		return {
			{
				id = 1,
				gridX = 0,
				gridY = 0,
				pos = area.pos,
				neighbors = {},
				parentArea = area.id,
				ring = 0,
				isEdge = true,
				isInner = false,
				dirTags = {},
			},
		}
	end

	------------------------------------------------------------
	-- build raw grid
	------------------------------------------------------------
	local raw = {}
	for ix = 0, gx - 1 do
		for iy = 0, gy - 1 do
			local x = area.minX + ix * GRID
			local y = area.minY + iy * GRID
			raw[#raw + 1] = {
				gridX = ix,
				gridY = iy,
				pos = Vector3(x, y, bilinearZ(x, y, area.nw, area.ne, area.se, area.sw)),
				neighbors = {},
				parentArea = area.id,
			}
		end
	end

	------------------------------------------------------------
	-- peel border IF we still have something inside afterwards
	------------------------------------------------------------
	local keepFull = (gx <= 2) or (gy <= 2)
	local points = {}
	if keepFull then
		points = raw
	else
		for _, p in ipairs(raw) do
			if not (p.gridX == 0 or p.gridX == gx - 1 or p.gridY == 0 or p.gridY == gy - 1) then
				points[#points + 1] = p
			end
		end
		if #points == 0 then -- pathological L-shape → revert
			points, keepFull = raw, true
		end
	end

	------------------------------------------------------------
	-- ring metric + edge / inner flags + directional tags
	------------------------------------------------------------
	local minGX, maxGX, minGY, maxGY = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(points) do
		minGX, maxGX = math.min(minGX, p.gridX), math.max(maxGX, p.gridX)
		minGY, maxGY = math.min(minGY, p.gridY), math.max(maxGY, p.gridY)
	end
	for i, p in ipairs(points) do
		p.id = i
		p.ring = math.min(p.gridX - minGX, maxGX - p.gridX, p.gridY - minGY, maxGY - p.gridY)
		p.isEdge = (p.ring == 0 or p.ring == 1) -- 1-st/2-nd order
		p.isInner = (p.ring >= 2)
		p.dirTags = {}
	end
	------------------------------------------------------------
	-- dirTags computed against the ring-2 rectangle
	------------------------------------------------------------
	local innerMinGX, innerMaxGX = math.huge, -math.huge
	local innerMinGY, innerMaxGY = math.huge, -math.huge
	for _, p in ipairs(points) do
		if p.isInner then
			innerMinGX, innerMaxGX = math.min(innerMinGX, p.gridX), math.max(innerMaxGX, p.gridX)
			innerMinGY, innerMaxGY = math.min(innerMinGY, p.gridY), math.max(innerMaxGY, p.gridY)
		end
	end
	for _, p in ipairs(points) do
		if innerMinGX <= innerMaxGX then
			if p.gridX < innerMinGX then
				p.dirTags[#p.dirTags + 1] = "W"
			end
			if p.gridX > innerMaxGX then
				p.dirTags[#p.dirTags + 1] = "E"
			end
			if p.gridY < innerMinGY then
				p.dirTags[#p.dirTags + 1] = "S"
			end
			if p.gridY > innerMaxGY then
				p.dirTags[#p.dirTags + 1] = "N"
			end
		end
	end

	------------------------------------------------------------
	-- NEW: build edge buckets and dirMask for fast lookups
	------------------------------------------------------------
	area.edgeSets = { N = {}, S = {}, E = {}, W = {} }
	for _, p in ipairs(points) do
		local m = 0
		if p.gridY == maxGY then
			m = m | Node.DIR.N
			area.edgeSets.N[#area.edgeSets.N + 1] = p
		end
		if p.gridY == minGY then
			m = m | Node.DIR.S
			area.edgeSets.S[#area.edgeSets.S + 1] = p
		end
		if p.gridX == maxGX then
			m = m | Node.DIR.E
			area.edgeSets.E[#area.edgeSets.E + 1] = p
		end
		if p.gridX == minGX then
			m = m | Node.DIR.W
			area.edgeSets.W[#area.edgeSets.W + 1] = p
		end
		p.dirMask = m
	end

	------------------------------------------------------------
	-- orthogonal neighbours, fallback diagonal if isolated
	------------------------------------------------------------
	local function addLink(a, b)
		local d = (a.pos - b.pos):Length()
		a.neighbors[#a.neighbors + 1] = { point = b, cost = d, isInterArea = false }
	end
	local idx = {} -- quick lookup
	for _, p in ipairs(points) do
		idx[p.gridX .. "," .. p.gridY] = p
	end
	local added = 0
	for _, p in ipairs(points) do
		local n = idx[p.gridX .. "," .. (p.gridY + 1)]
		local s = idx[p.gridX .. "," .. (p.gridY - 1)]
		local e = idx[(p.gridX + 1) .. "," .. p.gridY]
		local w = idx[(p.gridX - 1) .. "," .. p.gridY]
		if n then
			addLink(p, n)
			added = added + 1
		end
		if s then
			addLink(p, s)
			added = added + 1
		end
		if e then
			addLink(p, e)
			added = added + 1
		end
		if w then
			addLink(p, w)
			added = added + 1
		end
		if #p.neighbors == 0 then -- stranded corner → diag
			local ne = idx[(p.gridX + 1) .. "," .. (p.gridY + 1)]
			local nw = idx[(p.gridX - 1) .. "," .. (p.gridY + 1)]
			local se = idx[(p.gridX + 1) .. "," .. (p.gridY - 1)]
			local sw = idx[(p.gridX - 1) .. "," .. (p.gridY - 1)]
			if ne then
				addLink(p, ne)
				added = added + 1
			end
			if nw then
				addLink(p, nw)
				added = added + 1
			end
			if se then
				addLink(p, se)
				added = added + 1
			end
			if sw then
				addLink(p, sw)
				added = added + 1
			end
		end
	end

	Log:Debug("Area %d grid %dx%d  kept %d pts  links %d", area.id, gx, gy, #points, added)

	-- Cache grid extents for edge detection
	area.gridMinX, area.gridMaxX, area.gridMinY, area.gridMaxY = minGX, maxGX, minGY, maxGY

	return points
end

--==========================================================================
--  Area point cache helpers  (unchanged API)
--==========================================================================
function Node.GenerateAreaPoints(id)
	local nodes = G.Navigation.nodes
	if not (nodes and nodes[id]) then
		return
	end
	local area = nodes[id]
	if area.finePoints then
		return area.finePoints
	end
	area.finePoints = generateAreaPoints(area)
	return area.finePoints
end
function Node.GetAreaPoints(id)
	return Node.GenerateAreaPoints(id)
end

--==========================================================================
--  Touching-boxes helper
--==========================================================================
local function neighbourSide(a, b, eps)
	eps = eps or 1.0
	local overlapY = (a.minY <= b.maxY + eps) and (b.minY <= a.maxY + eps)
	local overlapX = (a.minX <= b.maxX + eps) and (b.minX <= a.maxX + eps)
	if overlapY and math.abs(a.maxX - b.minX) < eps then
		return "E", "W"
	end
	if overlapY and math.abs(b.maxX - a.minX) < eps then
		return "W", "E"
	end
	if overlapX and math.abs(a.maxY - b.minY) < eps then
		return "N", "S"
	end
	if overlapX and math.abs(b.maxY - a.minY) < eps then
		return "S", "N"
	end
	return nil
end

local function edgePoints(area, side)
	-- return precomputed bucket for the side
	return area.edgeSets[side] or {}
end

local function link(a, b)
	local d = (a.pos - b.pos):Length()
	a.neighbors[#a.neighbors + 1] = { point = b, cost = d, isInterArea = true }
	b.neighbors[#b.neighbors + 1] = { point = a, cost = d, isInterArea = true }
end

local function connectPair(areaA, areaB)
	local sideA, sideB = neighbourSide(areaA, areaB, 5.0)
	if not sideA then
		return 0
	end
	local edgeA, edgeB = edgePoints(areaA, sideA), edgePoints(areaB, sideB)
	-- reject pure corner contact
	if #edgeA == 1 and #edgeB == 1 then
		return 0
	end
	if #edgeA == 0 or #edgeB == 0 then
		return 0
	end

	-- robust one-to-one inter-area linking with accessibility filtering
	local P = (#edgeA <= #edgeB) and edgeA or edgeB
	local Qfull = (#edgeA <= #edgeB) and edgeB or edgeA
	-- copy Q for matching
	local remaining = {}
	for i = 1, #Qfull do
		remaining[i] = Qfull[i]
	end
	local c = 0
	-- for each p, pick closest accessible q
	if sideA == "N" or sideA == "S" then
		-- sort by X proximity when matching
		for _, p in ipairs(P) do
			-- build sorted candidate list
			local candidates = {}
			for i, q in ipairs(remaining) do
				candidates[#candidates + 1] = { i = i, delta = math.abs(q.pos.x - p.pos.x) }
			end
			table.sort(candidates, function(a, b)
				return a.delta < b.delta
			end)
			-- select first accessible candidate
			local selIdx
			for _, cand in ipairs(candidates) do
				local q = remaining[cand.i]
				if isNodeAccessible(p, q) then
					selIdx = cand.i
					break
				end
			end
			if selIdx then
				link(p, remaining[selIdx])
				table.remove(remaining, selIdx)
				c = c + 1
			end
		end
	else
		-- sort by Y proximity when matching
		for _, p in ipairs(P) do
			local candidates = {}
			for i, q in ipairs(remaining) do
				candidates[#candidates + 1] = { i = i, delta = math.abs(q.pos.y - p.pos.y) }
			end
			table.sort(candidates, function(a, b)
				return a.delta < b.delta
			end)
			local selIdx
			for _, cand in ipairs(candidates) do
				local q = remaining[cand.i]
				if isNodeAccessible(p, q) then
					selIdx = cand.i
					break
				end
			end
			if selIdx then
				link(p, remaining[selIdx])
				table.remove(remaining, selIdx)
				c = c + 1
			end
		end
	end
	return c
end

--- Build hierarchical data structure for HPA* pathfinding
---@param processedAreas table Areas with their fine points and connections
local function buildHierarchicalStructure(processedAreas)
	-- Initialize hierarchical structure in globals
	if not G.Navigation.hierarchical then
		G.Navigation.hierarchical = {}
	end

	G.Navigation.hierarchical.areas = {}
	G.Navigation.hierarchical.edgePoints = {} -- Global registry of edge points for fast lookup

	local totalEdgePoints = 0
	local totalInterConnections = 0

	-- Process each area and build the hierarchical structure
	for areaId, data in pairs(processedAreas) do
		local areaInfo = {
			id = areaId,
			area = data.area,
			points = data.points,
			edgePoints = {}, -- Points on the boundary of this area
			internalPoints = {}, -- Points inside this area
			interAreaConnections = {}, -- Connections to other areas
		}

		-- Categorize points as edge or internal
		for _, point in pairs(data.points) do
			if point.isEdge then
				table.insert(areaInfo.edgePoints, point)
				-- Add to global edge point registry with area reference
				G.Navigation.hierarchical.edgePoints[point.id .. "_" .. areaId] = {
					point = point,
					areaId = areaId,
				}
				totalEdgePoints = totalEdgePoints + 1
			else
				table.insert(areaInfo.internalPoints, point)
			end

			-- Count inter-area connections
			for _, neighbor in pairs(point.neighbors) do
				if neighbor.isInterArea then
					totalInterConnections = totalInterConnections + 1
					-- Store inter-area connection info
					table.insert(areaInfo.interAreaConnections, {
						fromPoint = point,
						toPoint = neighbor.point,
						toArea = neighbor.point.parentArea,
						cost = neighbor.cost,
					})
				end
			end
		end

		G.Navigation.hierarchical.areas[areaId] = areaInfo
		Log:Debug(
			"Area %d: %d edge points, %d internal points, %d inter-area connections",
			areaId,
			#areaInfo.edgePoints,
			#areaInfo.internalPoints,
			#areaInfo.interAreaConnections
		)
	end

	Log:Info(
		"Built hierarchical structure: %d total edge points, %d inter-area connections",
		totalEdgePoints,
		totalInterConnections
	)
end

--==========================================================================
--  Hierarchical network generation  (Fixed to use actual nav connections)
--==========================================================================
function Node.GenerateHierarchicalNetwork(maxAreas)
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	local processed, areas = {}, 0
	for id, _ in pairs(nodes) do
		if maxAreas and areas >= maxAreas then
			break
		end
		processed[id] = { area = nodes[id], points = Node.GenerateAreaPoints(id) }
		areas = areas + 1
	end
	Log:Info("Pass-1 fine points ready in %d areas", areas)

	------------------------------------------------------------
	-- PASS-2: Connect fine points between actually adjacent areas
	------------------------------------------------------------
	local totalConnections = 0
	for areaId, data in pairs(processed) do
		local area = data.area

		-- Get actually adjacent areas using nav mesh connections
		local adjacentAreas = Node.GetAdjacentNodesSimple(area, nodes)

		for _, adjacentArea in ipairs(adjacentAreas) do
			-- Only connect if the adjacent area was also processed
			if processed[adjacentArea.id] then
				local connections = connectPair(area, adjacentArea)
				totalConnections = totalConnections + connections
				Log:Debug("Connected %d fine points between areas %d and %d", connections, areaId, adjacentArea.id)
			end
		end
	end

	Log:Info("Pass-2 connected %d fine-point edges between adjacent areas", totalConnections)

	------------------------------------------------------------
	-- PASS-3: Build HPA* structure
	------------------------------------------------------------
	buildHierarchicalStructure(processed)
end

--==========================================================================
--  PUBLIC (everything else unchanged)
--==========================================================================

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
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
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
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, v in pairs(cDir.connections) do
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
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, v in pairs(cDir.connections) do
				if v == nodeB.id then
					cDir.connections[i] = { node = v, cost = cost }
					break
				end
			end
		end
	end
end

--- Get adjacent nodes with accessibility checks (expensive, for pathfinding)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of accessible adjacent nodes
--- NOTE: This function is EXPENSIVE due to accessibility checks.
--- Use GetAdjacentNodesSimple for pathfinding after setup validation is complete.
function Node.GetAdjacentNodes(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for _, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, cid in ipairs(cDir.connections) do
				local targetNode = nodes[cid]
				if targetNode and targetNode.pos then
					-- Use centralized accessibility check (EXPENSIVE)
					if isNodeAccessible(node, targetNode) then
						table.insert(adjacent, targetNode)
					end
				end
			end
		end
	end
	return adjacent
end

--- Get adjacent nodes without accessibility checks (fast, for finding connections)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of connected adjacent nodes
--- NOTE: This function is FAST and should be used for pathfinding.
--- Assumes connections are already validated during setup time.
function Node.GetAdjacentNodesSimple(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for _, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, cid in ipairs(cDir.connections) do
				local targetNode = nodes[cid]
				if targetNode and targetNode.pos then
					table.insert(adjacent, targetNode)
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
		elseif not navData then
			Log:Error("Failed to load nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		end
	end

	local navNodes = processNavData(navData)
	Node.SetNodes(navNodes)

	-- Fix: Count nodes properly for hash table
	local nodeCount = 0
	for _ in pairs(navNodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Successfully loaded %d navigation nodes", nodeCount)

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

		-- Automatically generate hierarchical network after loading nav file
		local nodes = Node.GetNodes()
		if nodes and next(nodes) then
			Log:Info("Auto-generating hierarchical network...")
			Node.GenerateHierarchicalNetwork() -- Process all areas
		else
			Log:Warn("No nodes loaded, skipping hierarchical network generation")
		end
	else
		Log:Info("No valid map loaded, initializing empty navigation nodes")
		-- Initialize empty nodes table to prevent crashes when no map is loaded
		Node.SetNodes({})
	end
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
	for _, point in pairs(points) do
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

--- Get hierarchical pathfinding data (for HPA* algorithm)
---@return table|nil Hierarchical structure or nil if not available
function Node.GetHierarchicalData()
	return G.Navigation.hierarchical
end

--- Get closest edge point in an area to a given position (for HPA* pathfinding)
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest edge point or nil if not found
function Node.GetClosestEdgePoint(areaId, position)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return nil
	end

	local areaInfo = G.Navigation.hierarchical.areas[areaId]
	local closest, minDist = nil, math.huge

	for _, edgePoint in pairs(areaInfo.edgePoints) do
		local dist = (edgePoint.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = edgePoint
		end
	end

	return closest
end

--- Get all inter-area connections from a specific area (for HPA* pathfinding)
---@param areaId number The area ID
---@return table[] Array of inter-area connections
function Node.GetInterAreaConnections(areaId)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return {}
	end

	return G.Navigation.hierarchical.areas[areaId].interAreaConnections or {}
end

return Node
