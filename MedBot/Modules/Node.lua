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

--- Check if two nodes are accessible using optimized three-tier approach
---@param nodeA table First node
---@param nodeB table Second node
---@return boolean True if nodes are accessible to each other
local function isNodeAccessible(nodeA, nodeB)
	-- First pass: Fast center Z distance check
	local centerZDiff = math.abs(nodeA.pos.z - nodeB.pos.z)
	if centerZDiff <= 72 then
		return true -- Fast path: nodes are close enough in height
	end

	-- Second pass: Check if any corners touch (stairs/ramp scenario)
	local cornersA = getNodeCorners(nodeA)
	local cornersB = getNodeCorners(nodeB)

	for _, cornerA in ipairs(cornersA) do
		for _, cornerB in ipairs(cornersB) do
			local cornerZDiff = math.abs(cornerA.z - cornerB.z)
			if cornerZDiff <= 72 then
				return true -- Medium path: corners are within range
			end
		end
	end

	-- Third pass: Expensive walkability check (only if previous checks failed)
	return isWalkable.Path(nodeA.pos, nodeB.pos)
end

--- Remove invalid connections between nodes (optimized version)
---@param nodes table All navigation nodes
local function pruneInvalidConnections(nodes)
	local prunedCount = 0
	local totalChecked = 0
	local fastPassCount = 0
	local mediumPassCount = 0
	local slowPassCount = 0
	local aggressiveness = G.Menu.Main.CleanupAggressiveness or 1

	Log:Info("Starting optimized connection cleanup (aggressiveness: %d)...", aggressiveness)

	for nodeId, node in pairs(nodes) do
		if not node or not node.c then
			goto continue
		end

		-- Check all directions (1-4)
		for dir = 1, 4 do
			local connectionDir = node.c[dir]
			if connectionDir and connectionDir.connections then
				local validConnections = {}

				-- Use ipairs to iterate through connections
				for _, targetNodeId in ipairs(connectionDir.connections) do
					totalChecked = totalChecked + 1
					local targetNode = nodes[targetNodeId]

					if targetNode then
						-- Use optimized accessibility check
						local centerZDiff = math.abs(node.pos.z - targetNode.pos.z)
						local isValid = false

						if centerZDiff <= 72 then
							-- Fast path: center Z distance is acceptable
							isValid = true
							fastPassCount = fastPassCount + 1
						elseif aggressiveness >= 1 then
							-- Check corners for stairs/ramps (only if aggressiveness >= 1)
							local cornersA = getNodeCorners(node)
							local cornersB = getNodeCorners(targetNode)
							local cornerMatch = false

							for _, cornerA in ipairs(cornersA) do
								for _, cornerB in ipairs(cornersB) do
									local cornerZDiff = math.abs(cornerA.z - cornerB.z)
									if cornerZDiff <= 72 then
										cornerMatch = true
										break
									end
								end
								if cornerMatch then
									break
								end
							end

							if cornerMatch then
								-- Medium path: corners are within range
								isValid = true
								mediumPassCount = mediumPassCount + 1
							elseif aggressiveness >= 2 then
								-- Slow path: expensive walkability check (only if aggressiveness >= 2)
								isValid = isWalkable.Path(node.pos, targetNode.pos)
								slowPassCount = slowPassCount + 1
								if not isValid then
									Log:Debug(
										"Pruned connection: Node %d -> Node %d (not walkable)",
										nodeId,
										targetNodeId
									)
								end
							else
								-- Skip expensive check, assume valid
								isValid = true
							end
						else
							-- Skip all checks beyond fast pass, assume valid
							isValid = true
						end

						-- Keep valid connections
						if isValid then
							table.insert(validConnections, targetNodeId)
						else
							prunedCount = prunedCount + 1
						end
					else
						-- Remove connections to non-existent nodes
						prunedCount = prunedCount + 1
						Log:Debug("Pruned connection: Node %d -> Node %d (target not found)", nodeId, targetNodeId)
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
	Log:Info("Performance: Fast=%d, Medium=%d, Slow=%d checks", fastPassCount, mediumPassCount, slowPassCount)
end

--[[ Public Module Functions ]]

function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes[id]
end

function Node.GetClosestNode(pos)
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

--- Removes a node entirely along with its connections
function Node.RemoveNode(nodeId)
	local nodes = G.Navigation.nodes
	local node = nodes[nodeId]
	if not node then
		return
	end
	-- remove all connections to this node
	for dir = 1, 4 do
		local cDir = node.c[dir]
		if cDir and cDir.connections then
			for _, nid in ipairs(cDir.connections) do
				local neighbor = nodes[nid]
				if neighbor then
					Node.RemoveConnection(node, neighbor)
				end
			end
		end
	end
	-- delete the node
	nodes[nodeId] = nil
end

--- Fixes node position and corners; removes node if no ground found
---@param nodeId integer
---@return table?|nil fixed node or nil if removed
function Node.FixNode(nodeId)
	local nodes = G.Navigation.nodes
	local node = nodes[nodeId]
	if not node or not node.pos then
		return nil
	end
	-- Hull trace to find ground surface
	local trace = traceHullDown(node.pos)
	if trace.fraction == 0 then
		-- no valid ground, remove node entirely
		Node.RemoveNode(nodeId)
		return nil
	end
	-- update center position
	node.pos = trace.endpos
	node.z = trace.endpos.z
	-- adjust two known corners via line trace
	for _, key in ipairs({ "nw", "se" }) do
		local c = node[key]
		if c then
			local world = Vector3(c.x, c.y, c.z)
			local lineTrace = traceLineDown(world)
			node[key] = (lineTrace.fraction < 1) and lineTrace.endpos or world
		end
	end
	-- recompute remaining corners
	local normal = getGroundNormal(node.pos)
	local height = math.abs(node.se.z - node.nw.z)
	local rem = calculateRemainingCorners(node.nw, node.se, normal, height)
	node.ne, node.sw = rem[1], rem[2]
	node.fixed = true
	return node
end

function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	for dir = 1, 4 do
		local cDir = nodes[nodeA.id].c[dir]
		if cDir and cDir.connections then
			-- Check if connection already exists
			local exists = false
			for _, existingId in ipairs(cDir.connections) do
				if existingId == nodeB.id then
					exists = true
					break
				end
			end
			if not exists then
				print("Adding connection between " .. nodeA.id .. " and " .. nodeB.id)
				table.insert(cDir.connections, nodeB.id)
				cDir.count = cDir.count + 1
			end
		end
	end
	for dir = 1, 4 do
		local cDir = nodes[nodeB.id].c[dir]
		if cDir and cDir.connections then
			-- Check if reverse connection already exists
			local exists = false
			for _, existingId in ipairs(cDir.connections) do
				if existingId == nodeA.id then
					exists = true
					break
				end
			end
			if not exists then
				print("Adding reverse connection between " .. nodeB.id .. " and " .. nodeA.id)
				table.insert(cDir.connections, nodeA.id)
				cDir.count = cDir.count + 1
			end
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	for dir = 1, 4 do
		local cDir = nodes[nodeA.id].c[dir]
		if cDir and cDir.connections then
			for i, v in ipairs(cDir.connections) do
				if v == nodeB.id then
					print("Removing connection between " .. nodeA.id .. " and " .. nodeB.id)
					table.remove(cDir.connections, i)
					cDir.count = cDir.count - 1
					break
				end
			end
		end
	end
	for dir = 1, 4 do
		local cDir = nodes[nodeB.id].c[dir]
		if cDir and cDir.connections then
			for i, v in ipairs(cDir.connections) do
				if v == nodeA.id then
					print("Removing reverse connection between " .. nodeB.id .. " and " .. nodeA.id)
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
	for dir = 1, 4 do
		local cDir = nodes[nodeA.id].c[dir]
		if cDir and cDir.connections then
			for i, v in ipairs(cDir.connections) do
				if v == nodeB.id then
					print("Adding cost between " .. nodeA.id .. " and " .. nodeB.id)
					cDir.connections[i] = { node = v, cost = cost }
					break
				end
			end
		end
	end
	for dir = 1, 4 do
		local cDir = nodes[nodeB.id].c[dir]
		if cDir and cDir.connections then
			for i, v in ipairs(cDir.connections) do
				if v == nodeA.id then
					print("Adding cost between " .. nodeB.id .. " and " .. nodeA.id)
					cDir.connections[i] = { node = v, cost = cost }
					break
				end
			end
		end
	end
end

function Node.GetAdjacentNodes(node, nodes)
	local adjacent = {}
	-- Check all directions using ipairs for connections
	for d = 1, 4 do
		local cDir = node.c[d]
		if cDir and cDir.connections then
			for _, cid in ipairs(cDir.connections) do -- Use ipairs instead of hardcoded loop
				local nnodes = nodes[cid]
				if nnodes then
					local h = (nnodes.nw.x - node.se.x)
							* (node.nw.x - nnodes.se.x)
							* (nnodes.nw.y - node.se.y)
							* (node.nw.y - nnodes.se.y)
						<= 0
					local v = (nnodes.pos.z >= (node.pos.z - 70) and nnodes.pos.z <= (node.pos.z + 70))
					if h and v then
						local sp = { x = node.pos.x, y = node.pos.y, z = node.pos.z + 72 }
						local ep = { x = nnodes.pos.x, y = nnodes.pos.y, z = nnodes.pos.z }
						local tr = engine.TraceLine(Vector3(sp.x, sp.y, sp.z), Vector3(ep.x, ep.y, ep.z), TRACE_MASK)
						if tr.fraction == 1 then
							table.insert(adjacent, nnodes)
						end
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
		generateNavFile()
		navData, err = tryLoadNavFile(full)
		if not navData then
			Log:Error("Failed to load or parse generated nav file: " .. err)
			return
		end
	elseif not navData then
		Log:Error(err)
		return
	end
	local navNodes = processNavData(navData)
	Node.SetNodes(navNodes)

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		pruneInvalidConnections(navNodes)
	else
		Log:Info("Connection cleanup is disabled in settings")
	end
end

function Node.LoadNavFile()
	local mf = engine.GetMapName()
	Node.LoadFile(string.gsub(mf, ".bsp", ".nav"))
end

function Node.Setup()
	if engine.GetMapName() then
		Node.LoadNavFile()
	end
end

return Node
