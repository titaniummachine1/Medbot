--[[ Imports ]]
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local PathValidator = require("MedBot.Navigation.IsWalkable")
local MathUtils = require("MedBot.Utils.MathUtils")

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Log = Common.Log.new("Visuals")

-- Flood-fill algorithm to collect nodes within connection depth from player
local function collectNodesByConnectionDepth(playerPos, maxDepth)
	local nodes = G.Navigation.nodes
	if not nodes then
		return {}
	end

	-- Get closest area to player (fast center-distance check, not expensive containment check)
	local startNode = Node.GetClosestNode(playerPos)
	if not startNode then
		return {}
	end

	local visited = {}
	local toVisit = {}
	local result = {}

	-- Initialize with start node at depth 0
	toVisit[1] = { node = startNode, depth = 0 }
	visited[startNode.id] = true
	result[startNode.id] = { node = startNode, depth = 0 }

	local currentIndex = 1
	local maxNodes = 1000 -- Safety limit to prevent infinite loops

	while currentIndex <= #toVisit and #result < maxNodes do
		local current = toVisit[currentIndex]
		local node = current.node
		local depth = current.depth

		-- Stop if we've reached maximum depth
		if depth >= maxDepth then
			break
		end

		-- Get adjacent nodes
		local adjacentNodes = Node.GetAdjacentNodesOnly(node, nodes)
		for _, adjacentNode in ipairs(adjacentNodes) do
			if not visited[adjacentNode.id] then
				visited[adjacentNode.id] = true
				result[adjacentNode.id] = { node = adjacentNode, depth = depth + 1 }

				-- Add to visit queue for next depth level
				table.insert(toVisit, { node = adjacentNode, depth = depth + 1 })
			end
		end

		currentIndex = currentIndex + 1
	end

	return result
end

--[[ Functions ]]
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	-- Recompute corners every call to ensure correct size; caching caused wrong sizes
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

local UP_VECTOR = Vector3(0, 0, 1)

-- 1×1 white texture for filled polygons
local white_texture_fill = draw.CreateTextureRGBA(string.char(0xff, 0xff, 0xff, 0xff), 1, 1)

-- fillPolygon(vertices: {{x,y}}, r,g,b,a): filled convex polygon
local function fillPolygon(vertices, r, g, b, a)
	draw.Color(r, g, b, a)
	local n = #vertices
	local cords, rev = {}, {}
	local sum = 0
	local v1x, v1y = vertices[1][1], vertices[1][2]
	local function cross(a, b)
		return (b[1] - a[1]) * (v1y - a[2]) - (b[2] - a[2]) * (v1x - a[1])
	end
	for i, v in ipairs(vertices) do
		cords[i] = { v[1], v[2], 0, 0 }
		rev[n - i + 1] = cords[i]
		local nxt = vertices[i % n + 1]
		sum = sum + cross(v, nxt)
	end
	draw.TexturedPolygon(white_texture_fill, (sum < 0 and rev or cords), true)
end

-- Easy color configuration for area rendering
local AREA_FILL_COLOR = { 55, 255, 155, 12 } -- r, g, b, a for filled area
local AREA_OUTLINE_COLOR = { 255, 255, 255, 77 } -- r, g, b, a for area outline

local function OnDraw()
	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 0, 0, 255)

	local me = entities.GetLocalPlayer()
	if not me then
		return
	end
	-- Master enable switch for visuals
	if not G.Menu.Visuals.EnableVisuals then
		return
	end

	local p = me:GetAbsOrigin()

	-- Collect visible nodes using flood-fill from player position
	local connectionDepth = G.Menu.Visuals.connectionDepth or 10
	local allReachableNodes = collectNodesByConnectionDepth(p, connectionDepth)

	-- Filter to only nodes within the actual depth limit (not just reachable through flood-fill)
	local filteredNodes = {}
	for id, entry in pairs(allReachableNodes) do
		if entry.depth <= connectionDepth then
			local node = entry.node
			local scr = client.WorldToScreen(node.pos)
			if scr then
				filteredNodes[id] = { node = node, screen = scr, depth = entry.depth }
			end
		end
	end

	local currentY = 120
	-- Draw memory usage if enabled in config
	if G.Menu.Visuals.memoryUsage then
		draw.SetFont(Fonts.Verdana) -- Ensure font is set before drawing text
		draw.Color(255, 255, 255, 200)
		-- Get current memory usage directly for real-time display
		local currentMemKB = collectgarbage("count")
		local memMB = currentMemKB / 1024
		draw.Text(10, currentY, string.format("Memory: %.2f MB", memMB))
		currentY = currentY + 20
	end
	G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
	if G.Navigation.currentNodeIndex == nil then
		return
	end

	-- Agent visualization removed - back to simple node skipping
	-- No complex agent visualization needed for distance-based skipping

	-- Show connections between nav nodes with triangle visualization for doors
	if G.Menu.Visuals.showConnections then
		local drawnDoorTriangles = {} -- Track which door groups we've drawn
		local doorConvergencePoints = {} -- Store convergence points (direction to area center)
		local CONVERGENCE_OFFSET = 7 -- Units in front of middle door point

		-- Helper: Check if connection is bidirectional (area→door AND door→area)
		local function isBidirectional(areaNode, doorBaseId)
			local doorMiddle = G.Navigation.nodes[doorBaseId .. "_middle"]
			if not doorMiddle or not doorMiddle.c then
				return false
			end

			-- Check if door has connection back to area
			for _, d in pairs(doorMiddle.c) do
				if d.connections then
					for _, c in ipairs(d.connections) do
						local aid = (type(c) == "table") and c.node or c
						if aid == areaNode.id then
							return true
						end
					end
				end
			end
			return false
		end

		-- First pass: Draw door triangles (area→door connections) and store convergence
		for id, entry in pairs(filteredNodes) do
			local node = entry.node

			-- Only process area nodes (not doors)
			if not node.isDoor then
				for dir = 1, 4 do
					local cDir = node.c[dir]
					if cDir and cDir.connections then
						for _, conn in ipairs(cDir.connections) do
							local nid = (type(conn) == "table") and conn.node or conn
							local doorNode = G.Navigation.nodes and G.Navigation.nodes[nid]

							-- Only draw if connected to a door and door is visible
							if doorNode and doorNode.isDoor and filteredNodes[nid] then
								-- Extract door base ID
								local doorBaseId = doorNode.id:match("^(.+)_[^_]+$")
								if doorBaseId and not drawnDoorTriangles[doorBaseId .. "_to_" .. id] then
									drawnDoorTriangles[doorBaseId .. "_to_" .. id] = true

									-- Get all door points
									local leftNode = G.Navigation.nodes[doorBaseId .. "_left"]
									local middleNode = G.Navigation.nodes[doorBaseId .. "_middle"]
									local rightNode = G.Navigation.nodes[doorBaseId .. "_right"]

									local areaPos = node.pos + UP_VECTOR

									if middleNode and middleNode.pos then
										local middlePos = middleNode.pos + UP_VECTOR

										-- Check if connection is bidirectional
										local bidirectional = isBidirectional(node, doorBaseId)

										-- For one-way, find the target area this connection leads to
										local targetAreaPos = nil
										if not bidirectional and doorNode.c then
											for _, d in pairs(doorNode.c) do
												if d.connections then
													for _, c in ipairs(d.connections) do
														local aid = (type(c) == "table") and c.node or c
														if aid ~= node.id then -- Not the source area
															local targetArea = G.Navigation.nodes[aid]
															if targetArea and not targetArea.isDoor then
																targetAreaPos = targetArea.pos + UP_VECTOR
																break
															end
														end
													end
												end
												if targetAreaPos then
													break
												end
											end
										end

										-- Choose color: RED for one-directional, YELLOW for bidirectional
										local r, g, b, a = 255, 255, 0, 160 -- Default yellow
										if not bidirectional then
											r, g, b, a = 255, 50, 50, 140 -- Red for one-way
										end

										-- For one-way connections, draw red line from source area center to door middle
										if not bidirectional then
											draw.Color(r, g, b, a)
											local sa = client.WorldToScreen(areaPos)
											local sm = client.WorldToScreen(middlePos)
											if sa and sm then
												draw.Line(sa[1], sa[2], sm[1], sm[2])
											end
										end

										-- Check if door has sides or just middle
										local hasLeftRight = (leftNode and leftNode.pos)
											or (rightNode and rightNode.pos)

										if hasLeftRight then
											-- For one-way: triangle points to TARGET area, for two-way: points to SOURCE area
											local triangleTargetPos = bidirectional and areaPos
												or (targetAreaPos or areaPos)

											-- Calculate convergence point in front of middle (direction to triangle target)
											local dirToTarget = Common.Normalize(triangleTargetPos - middlePos)
											local convergencePos = middlePos + dirToTarget * CONVERGENCE_OFFSET

											-- Store convergence point only for bidirectional (D2D needs both ways)
											if bidirectional then
												local key = doorBaseId .. "_to_" .. id
												doorConvergencePoints[key] = convergencePos
											end

											-- Draw triangle: left→convergence, right→convergence (color based on direction)
											draw.Color(r, g, b, a)

											if leftNode and leftNode.pos then
												local leftPos = leftNode.pos + UP_VECTOR
												local s1 = client.WorldToScreen(leftPos)
												local s2 = client.WorldToScreen(convergencePos)
												if s1 and s2 then
													draw.Line(s1[1], s1[2], s2[1], s2[2])
												end
											end

											if rightNode and rightNode.pos then
												local rightPos = rightNode.pos + UP_VECTOR
												local s1 = client.WorldToScreen(rightPos)
												local s2 = client.WorldToScreen(convergencePos)
												if s1 and s2 then
													draw.Line(s1[1], s1[2], s2[1], s2[2])
												end
											end

											-- Draw line from convergence point to triangle target (source for bidirectional, target for one-way)
											local sc = client.WorldToScreen(convergencePos)
											local st = client.WorldToScreen(triangleTargetPos)
											if sc and st then
												draw.Line(sc[1], sc[2], st[1], st[2])
											end
										else
											-- Narrow door - for one-way use target area, for two-way use source area
											local narrowTargetPos = bidirectional and areaPos
												or (targetAreaPos or areaPos)

											-- Store middle as convergence only for bidirectional
											if bidirectional then
												local key = doorBaseId .. "_to_" .. id
												doorConvergencePoints[key] = middlePos
											end

											draw.Color(r, g, b, a)
											local sm = client.WorldToScreen(middlePos)
											local st = client.WorldToScreen(narrowTargetPos)
											if sm and st then
												draw.Line(sm[1], sm[2], st[1], st[2])
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

		-- Second pass: Draw door-to-door using SAME convergence points (area center direction)
		if G.Menu.Visuals.showD2D then
			local drawnDoorPairs = {}

			for id, entry in pairs(filteredNodes) do
				local doorNode1 = entry.node

				if doorNode1.isDoor then
					local doorBase1 = doorNode1.id:match("^(.+)_[^_]+$")

					for dir = 1, 4 do
						local cDir = doorNode1.c[dir]
						if cDir and cDir.connections then
							for _, conn in ipairs(cDir.connections) do
								local nid = (type(conn) == "table") and conn.node or conn
								local doorNode2 = G.Navigation.nodes and G.Navigation.nodes[nid]

								if doorNode2 and doorNode2.isDoor and filteredNodes[nid] then
									local doorBase2 = doorNode2.id:match("^(.+)_[^_]+$")

									-- Create unique pair key (sorted to avoid duplicates)
									local pairKey = (doorBase1 < doorBase2) and (doorBase1 .. "_" .. doorBase2)
										or (doorBase2 .. "_" .. doorBase1)

									if not drawnDoorPairs[pairKey] then
										drawnDoorPairs[pairKey] = true

										-- Find which areas each door connects to (find shared area)
										-- Door1 connects to areaA and areaB, Door2 connects to areaC and areaD
										-- We want the side of each door facing the SHARED area
										local sharedAreaId = nil

										-- Get all area connections for both doors
										local areas1 = {}
										local areas2 = {}

										if doorNode1.c then
											for _, d in pairs(doorNode1.c) do
												if d.connections then
													for _, c in ipairs(d.connections) do
														local aid = (type(c) == "table") and c.node or c
														local areaNode = G.Navigation.nodes[aid]
														if areaNode and not areaNode.isDoor then
															areas1[aid] = true
														end
													end
												end
											end
										end

										if doorNode2.c then
											for _, d in pairs(doorNode2.c) do
												if d.connections then
													for _, c in ipairs(d.connections) do
														local aid = (type(c) == "table") and c.node or c
														local areaNode = G.Navigation.nodes[aid]
														if areaNode and not areaNode.isDoor then
															areas2[aid] = true
														end
													end
												end
											end
										end

										-- Find shared area
										for aid, _ in pairs(areas1) do
											if areas2[aid] then
												sharedAreaId = aid
												break
											end
										end

										if sharedAreaId then
											-- Use convergence points facing the shared area
											local key1 = doorBase1 .. "_to_" .. sharedAreaId
											local key2 = doorBase2 .. "_to_" .. sharedAreaId
											local convergence1 = doorConvergencePoints[key1]
											local convergence2 = doorConvergencePoints[key2]

											if convergence1 and convergence2 then
												draw.Color(100, 200, 255, 120) -- Light blue for door-to-door

												local s1 = client.WorldToScreen(convergence1)
												local s2 = client.WorldToScreen(convergence2)
												if s1 and s2 then
													draw.Line(s1[1], s1[2], s2[1], s2[2])
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

	-- Draw corner connections from node-level data (if enabled)
	if G.Menu.Visuals.showCornerConnections then
		local wallCornerCount = 0
		local allCornerCount = 0

		for id, entry in pairs(filteredNodes) do
			local node = entry.node

			-- Draw wall corners (orange squares)
			if node.wallCorners then
				for _, cornerPoint in ipairs(node.wallCorners) do
					wallCornerCount = wallCornerCount + 1
					local cornerScreen = client.WorldToScreen(cornerPoint)
					if cornerScreen then
						draw.Color(255, 165, 0, 200) -- Orange for wall corners
						draw.FilledRect(
							cornerScreen[1] - 3,
							cornerScreen[2] - 3,
							cornerScreen[1] + 3,
							cornerScreen[2] + 3
						)
					end
				end
			end
		end
	end

	-- Draw Doors as cyan lines between door points (elevated 1 unit)
	if G.Menu.Visuals.showDoors then
		local drawnDoors = {} -- Track drawn door groups to avoid duplicates
		local UP_OFFSET = Vector3(0, 0, 1)

		for id, entry in pairs(filteredNodes) do
			local doorNode = entry.node
			if doorNode and doorNode.isDoor then
				-- Extract door base ID (e.g., "4229_4231" from "4229_4231_left")
				local doorId = doorNode.id
				local doorBaseId = doorId:match("^(.+)_[^_]+$") -- Remove last suffix

				if doorBaseId and not drawnDoors[doorBaseId] then
					drawnDoors[doorBaseId] = true

					-- Find all 3 door points (left, middle, right) for this door
					local doorPoints = {}
					for _, suffix in ipairs({ "_left", "_middle", "_right" }) do
						local pointId = doorBaseId .. suffix
						local pointNode = G.Navigation.nodes[pointId]
						if pointNode and pointNode.pos then
							table.insert(doorPoints, pointNode.pos + UP_OFFSET)
						end
					end

					-- Draw cyan line between min and max points
					if #doorPoints >= 2 then
						-- Find min and max points (leftmost and rightmost)
						local minPoint = doorPoints[1]
						local maxPoint = doorPoints[1]

						for _, pt in ipairs(doorPoints) do
							if (pt - doorPoints[1]):Length() > (maxPoint - doorPoints[1]):Length() then
								maxPoint = pt
							end
						end

						local screen1 = client.WorldToScreen(minPoint)
						local screen2 = client.WorldToScreen(maxPoint)

						if screen1 and screen2 then
							draw.Color(0, 255, 255, 200) -- Cyan for doors
							draw.Line(screen1[1], screen1[2], screen2[1], screen2[2])
						end
					end
				end
			end
		end
	end

	-- Fill and outline areas using fixed corners from Navigation
	if G.Menu.Visuals.showAreas then
		for id, entry in pairs(filteredNodes) do
			local node = entry.node
			-- Skip door nodes - they don't have area corners
			if not node.isDoor then
				-- Collect the four corner vectors from the node
				local worldCorners = { node.nw, node.ne, node.se, node.sw }
				if worldCorners[1] and worldCorners[2] and worldCorners[3] and worldCorners[4] then
					local scr = {}
					local ok = true
					for i, corner in ipairs(worldCorners) do
						local s = client.WorldToScreen(corner)
						if not s then
							ok = false
							break
						end
						scr[i] = { s[1], s[2] }
					end
					-- Only draw if all corners are visible on screen
					if ok then
						-- filled polygon
						fillPolygon(scr, table.unpack(AREA_FILL_COLOR))
						-- outline
						draw.Color(table.unpack(AREA_OUTLINE_COLOR))
						for i = 1, 4 do
							local a = scr[i]
							local b = scr[i % 4 + 1]
							draw.Line(a[1], a[2], b[1], b[2])
						end
					end
				end
			end
		end
	end

	-- Draw node IDs if enabled
	if G.Menu.Visuals.showNodeIds then
		draw.SetFont(Fonts.Verdana)
		for id, entry in pairs(filteredNodes) do
			local node = entry.node
			if not node.isDoor then -- Only show IDs for area nodes, not door nodes
				local scr = client.WorldToScreen(node.pos + UP_VECTOR)
				if scr then
					draw.Color(255, 255, 255, 255)
					draw.Text(scr[1], scr[2], tostring(node.id))
				end
			end
		end
	end

	-- Fine points removed
	if false then
		-- Track drawn inter-area connections to avoid duplicates
		local drawnInterConnections = {}
		local drawnIntraConnections = {}

		for id, entry in pairs(filteredNodes) do
			local points = Node.GetAreaPoints(id)
			if points then
				-- First pass: draw connections if enabled
				for _, point in ipairs(points) do
					local screenPos = client.WorldToScreen(point.pos)
					if screenPos then
						for _, neighbor in ipairs(point.neighbors) do
							local neighborScreenPos = client.WorldToScreen(neighbor.point.pos)
							if neighborScreenPos then
								if neighbor.isInterArea and G.Menu.Visuals.showInterConnections then
									-- Orange for inter-area connections
									local connectionKey = string.format(
										"%d_%d-%d_%d",
										point.parentArea,
										point.id,
										neighbor.point.parentArea,
										neighbor.point.id
									)
									if not drawnInterConnections[connectionKey] then
										draw.Color(255, 165, 0, 180) -- Orange for inter-area connections
										draw.Line(
											screenPos[1],
											screenPos[2],
											neighborScreenPos[1],
											neighborScreenPos[2]
										)
										drawnInterConnections[connectionKey] = true
									end
								elseif not neighbor.isInterArea then
									-- Intra-area connections with different colors based on type
									local connectionKey = string.format(
										"%d_%d-%d_%d",
										math.min(point.id, neighbor.point.id),
										point.parentArea,
										math.max(point.id, neighbor.point.id),
										neighbor.point.parentArea
									)
									if not drawnIntraConnections[connectionKey] then
										if
											point.isEdge
											and neighbor.point.isEdge
											and G.Menu.Visuals.showEdgeConnections
										then
											draw.Color(0, 150, 255, 140) -- Bright blue for edge-to-edge connections
											draw.Line(
												screenPos[1],
												screenPos[2],
												neighborScreenPos[1],
												neighborScreenPos[2]
											)
											drawnIntraConnections[connectionKey] = true
										elseif G.Menu.Visuals.showIntraConnections then
											draw.Color(0, 100, 200, 60) -- Blue for regular intra-area connections
											draw.Line(
												screenPos[1],
												screenPos[2],
												neighborScreenPos[1],
												neighborScreenPos[2]
											)
											drawnIntraConnections[connectionKey] = true
										end
									end
								end
							end
						end
					end
				end

				-- Second pass: draw points (so they appear on top of lines) - REMOVED: Using wall corners only
				-- for _, point in ipairs(points) do
				--     local screenPos = client.WorldToScreen(point.pos)
				--     if screenPos then
				--         -- Color-code points: yellow for edge points, blue for regular points
				--         if point.isEdge then
				--             draw.Color(255, 255, 0, 220) -- Yellow for edge points
				--             draw.FilledRect(screenPos[1] - 2, screenPos[2] - 2, screenPos[1] + 2, screenPos[2] + 2)
				--         else
				--             draw.Color(0, 150, 255, 180) -- Light blue for regular points
				--             draw.FilledRect(screenPos[1] - 1, screenPos[2] - 1, screenPos[1] + 1, screenPos[2] + 1)
				--         end
				--     end
				-- end
			end
		end

		-- Show fine point statistics for areas with points
		local finePointStats = {}
		for id, entry in pairs(filteredNodes) do
			local points = Node.GetAreaPoints(id)
			if points and #points > 1 then -- Only count areas with multiple points
				local edgeCount = 0
				local interConnections = 0
				local intraConnections = 0
				local isolatedPoints = 0
				for _, point in ipairs(points) do
					if point.isEdge then
						edgeCount = edgeCount + 1
					end
					if #point.neighbors == 0 then
						isolatedPoints = isolatedPoints + 1
					end
					for _, neighbor in ipairs(point.neighbors) do
						if neighbor.isInterArea then
							interConnections = interConnections + 1
						else
							intraConnections = intraConnections + 1
						end
					end
				end
				table.insert(finePointStats, {
					id = id,
					totalPoints = #points,
					edgePoints = edgeCount,
					interConnections = interConnections,
					intraConnections = intraConnections,
					isolatedPoints = isolatedPoints,
				})
			end
		end
	end

	-- Draw SmartJump simulation visualization (controlled by menu)
	if
		G.Menu.Visuals.showSmartJump
		and G.SmartJump
		and G.SmartJump.SimulationPath
		and type(G.SmartJump.SimulationPath) == "table"
		and #G.SmartJump.SimulationPath > 1
	then
		-- Draw simulation path lines like AutoPeek's LineDrawList
		local pathCount = #G.SmartJump.SimulationPath
		for i = 1, pathCount - 1 do
			local startPos = G.SmartJump.SimulationPath[i]
			local endPos = G.SmartJump.SimulationPath[i + 1]

			-- Guard clause: ensure positions are valid Vector3 objects
			if startPos and endPos then
				local startScreen = client.WorldToScreen(startPos)
				local endScreen = client.WorldToScreen(endPos)

				if startScreen and endScreen then
					-- Color gradient like AutoPeek (brighter at end)
					local brightness = math.floor(100 + (155 * (i / pathCount)))
					draw.Color(brightness, brightness, 255, 200) -- Blue gradient
					draw.Line(startScreen[1], startScreen[2], endScreen[1], endScreen[2])
				end
			end
		end

		-- Draw jump landing position if available (controlled by menu)
		if G.Menu.Visuals.showSmartJump and G.SmartJump and G.SmartJump.JumpPeekPos and G.SmartJump.PredPos then
			local jumpPos = G.SmartJump.JumpPeekPos
			local predPos = G.SmartJump.PredPos
			local jumpScreen = client.WorldToScreen(jumpPos)
			local predScreen = client.WorldToScreen(predPos)

			if jumpScreen and predScreen then
				draw.Color(255, 255, 0, 180) -- Yellow jump arc
				draw.Line(predScreen[1], predScreen[2], jumpScreen[1], jumpScreen[2])
			end
		end
	end

	-- Draw only the actual-followed path using door-aware waypoints, with a live target arrow
	if G.Menu.Visuals.drawPath then
		local wps = G.Navigation.waypoints
		if wps and #wps > 0 then
			-- Only draw waypoints from current position onward (don't show past waypoints)
			local currentIdx = G.Navigation.currentWaypointIndex or 1
			if currentIdx < 1 then
				currentIdx = 1
			end

			-- Draw segments from current waypoint to the end
			for i = currentIdx, #wps - 1 do
				local a, b = wps[i], wps[i + 1]
				local aPos = a.pos
				local bPos = b.pos
				if not aPos and a.kind == "door" and a.points and #a.points > 0 then
					aPos = a.points[math.ceil(#a.points / 2)]
				end
				if not bPos and b.kind == "door" and b.points and #b.points > 0 then
					bPos = b.points[math.ceil(#b.points / 2)]
				end
				if aPos and bPos then
					draw.Color(255, 255, 255, 255) -- white route
					Common.DrawArrowLine(aPos, bPos, 18, 12, false)
				end
			end
		end
	end

	-- Draw direct white arrow from player to current target (the position we're walking to)
	if G.Menu.Visuals.drawPath then
		local localPos = G.pLocal and G.pLocal.Origin
		local targetPos = G.Navigation.currentTargetPos
		if localPos and targetPos then
			draw.Color(255, 255, 255, 220) -- White arrow to current target
			Common.DrawArrowLine(localPos, targetPos, 18, 12, false)
		end
	end

	-- Draw wall corners (orange points)
	if G.Menu.Visuals.showCornerConnections then
		for id, entry in pairs(filteredNodes) do
			local node = entry.node
			if node.wallCorners then
				for _, cornerPoint in ipairs(node.wallCorners) do
					local cornerScreen = client.WorldToScreen(cornerPoint)
					if cornerScreen then
						-- Draw orange square for wall corners
						draw.Color(255, 165, 0, 200) -- Orange for wall corners
						draw.FilledRect(
							cornerScreen[1] - 3,
							cornerScreen[2] - 3,
							cornerScreen[1] + 3,
							cornerScreen[2] + 3
						)
					end
				end
			end
		end
	end

	-- Draw PathValidator debug traces if enabled
	PathValidator.DrawDebugTraces()
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals
