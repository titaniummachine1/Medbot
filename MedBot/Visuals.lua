--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

--[[ Functions ]]
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	if not corners then
		corners1 = {
			Vector3(-halfSize, -halfSize, -halfSize),
			Vector3(halfSize, -halfSize, -halfSize),
			Vector3(halfSize, halfSize, -halfSize),
			Vector3(-halfSize, halfSize, -halfSize),
			Vector3(-halfSize, -halfSize, halfSize),
			Vector3(halfSize, -halfSize, halfSize),
			Vector3(halfSize, halfSize, halfSize),
			Vector3(-halfSize, halfSize, halfSize),
		}
	end

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
	for _, cornerPos in ipairs(corners1) do
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

local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	-- If invert is true, swap start_pos and end_pos
	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	-- Calculate direction from start to end
	local direction = end_pos - start_pos
	local direction_length = direction:Length()
	if direction_length == 0 then
		return
	end

	-- Normalize the direction vector
	local normalized_direction = Common.Normalize(direction)

	-- Calculate the arrow base position by moving back from end_pos in the direction of start_pos
	local arrow_base = end_pos - normalized_direction * arrowhead_length

	-- Calculate the perpendicular vector for the arrow width
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	-- Convert world positions to screen positions
	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	-- Draw the line from start to the base of the arrow (not all the way to the end)
	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])

	-- Draw the sides of the arrowhead
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])

	-- Optionally, draw the base of the arrowhead to close it
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

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

-- maximum distance to render visuals (in world units)
local RENDER_DISTANCE = 800 -- fallback default; overridden by G.Menu.Visuals.renderDistance

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

	local myPos = me:GetAbsOrigin()
	local currentY = 120
	-- Precompute screen-visible nodes within render distance
	local visibleNodes = {}
	-- use menu-configured distance if present
	local maxDist = G.Menu.Visuals.renderDistance or RENDER_DISTANCE
	for id, node in pairs(G.Navigation.nodes or {}) do
		local dist = (myPos - node.pos):Length()
		if dist <= maxDist then
			local scr = client.WorldToScreen(node.pos)
			if scr then
				visibleNodes[id] = { node = node, screen = scr }
			end
		end
	end
	G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
	if G.Navigation.currentNodeIndex == nil then
		return
	end

	if G.Navigation.path then
		-- Visualizing agents
		local agent1Pos = G.Navigation.path[G.Navigation.FirstAgentNode]
			and G.Navigation.path[G.Navigation.FirstAgentNode].pos
		local agent2Pos = G.Navigation.path[G.Navigation.SecondAgentNode]
			and G.Navigation.path[G.Navigation.SecondAgentNode].pos

		if agent1Pos then
			local screenPos1 = client.WorldToScreen(agent1Pos)
			if screenPos1 then
				draw.Color(255, 255, 255, 255) -- White color for the first agent
				Draw3DBox(10, agent1Pos) -- Smaller size for the first agent
			end
		end
	end

	if agent2Pos then
		local screenPos2 = client.WorldToScreen(agent2Pos)
		if screenPos2 then
			draw.Color(0, 255, 0, 255) -- Green color for the second agent
			Draw3DBox(20, agent2Pos) -- Larger size for the second agent
		end
	end

	-- Show connections between nav nodes (colored by directionality)
	if G.Menu.Visuals.showConnections then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
			for dir = 1, 4 do
				local cDir = node.c[dir]
				if cDir and cDir.connections then
					for _, nid in ipairs(cDir.connections) do
						local otherEntry = visibleNodes[nid]
						if otherEntry then
							local s1, s2 = entry.screen, otherEntry.screen
							-- determine if other->id exists in its connections
							local bidir = false
							local otherNode = otherEntry.node
							for d2 = 1, 4 do
								local otherCDir = otherNode.c[d2]
								if otherCDir and otherCDir.connections then
									for _, backId in ipairs(otherCDir.connections) do
										if backId == id then
											bidir = true
											break
										end
									end
									if bidir then
										break
									end
								end
							end
							-- yellow for two-way, red for one-way
							if bidir then
								draw.Color(255, 255, 0, 100)
							else
								draw.Color(255, 0, 0, 70)
							end
							draw.Line(s1[1], s1[2], s2[1], s2[2])
						end
					end
				end
			end
		end
	end

	-- Fill and outline areas using fixed corners from Navigation
	if G.Menu.Visuals.showAreas then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
			-- Collect the four corner vectors from the node
			local worldCorners = { node.nw, node.ne, node.se, node.sw }
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

	-- Draw fine-grained points within areas (hierarchical pathfinding)
	if G.Menu.Visuals.showFinePoints and G.Menu.Main.UseHierarchicalPathfinding then
		local Node = require("MedBot.Modules.Node")
		
		-- Track drawn inter-area connections to avoid duplicates
		local drawnInterConnections = {}
		local drawnIntraConnections = {}
		
		for id, entry in pairs(visibleNodes) do
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
									local connectionKey = string.format("%d_%d-%d_%d", 
										point.parentArea, point.id, neighbor.point.parentArea, neighbor.point.id)
									if not drawnInterConnections[connectionKey] then
										draw.Color(255, 165, 0, 180) -- Orange for inter-area connections
										draw.Line(screenPos[1], screenPos[2], neighborScreenPos[1], neighborScreenPos[2])
										drawnInterConnections[connectionKey] = true
									end
								elseif not neighbor.isInterArea then
									-- Intra-area connections with different colors based on type
									local connectionKey = string.format("%d_%d-%d_%d", 
										math.min(point.id, neighbor.point.id), point.parentArea,
										math.max(point.id, neighbor.point.id), neighbor.point.parentArea)
									if not drawnIntraConnections[connectionKey] then
										if point.isEdge and neighbor.point.isEdge and G.Menu.Visuals.showEdgeConnections then
											draw.Color(0, 150, 255, 140) -- Bright blue for edge-to-edge connections
											draw.Line(screenPos[1], screenPos[2], neighborScreenPos[1], neighborScreenPos[2])
											drawnIntraConnections[connectionKey] = true
										elseif G.Menu.Visuals.showIntraConnections then
											draw.Color(0, 100, 200, 60) -- Blue for regular intra-area connections
											draw.Line(screenPos[1], screenPos[2], neighborScreenPos[1], neighborScreenPos[2])
											drawnIntraConnections[connectionKey] = true
										end
									end
								end
							end
						end
					end
				end
				
				-- Second pass: draw points (so they appear on top of lines)
				for _, point in ipairs(points) do
					local screenPos = client.WorldToScreen(point.pos)
					if screenPos then
						-- Color-code points: yellow for edge points, blue for regular points
						if point.isEdge then
							draw.Color(255, 255, 0, 220) -- Yellow for edge points
							draw.FilledRect(screenPos[1] - 2, screenPos[2] - 2, screenPos[1] + 2, screenPos[2] + 2)
						else
							draw.Color(0, 150, 255, 180) -- Light blue for regular points
							draw.FilledRect(screenPos[1] - 1, screenPos[2] - 1, screenPos[1] + 1, screenPos[2] + 1)
						end
					end
				end
			end
		end
		
		-- Show fine point statistics for areas with points
		local finePointStats = {}
		for id, entry in pairs(visibleNodes) do
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
					isolatedPoints = isolatedPoints
				})
			end
		end
		
		-- Display statistics on screen
		if #finePointStats > 0 then
			draw.Color(255, 255, 255, 255)
			local statY = currentY + 40
			draw.Text(20, statY, string.format("Fine Points: %d areas with detailed grids", #finePointStats))
			statY = statY + 15
			
			-- Show first few areas with stats
			for i = 1, math.min(3, #finePointStats) do
				local stat = finePointStats[i]
				local text = string.format("  Area %d: %d points (%d edge, %d intra, %d inter, %d isolated)", 
					stat.id, stat.totalPoints, stat.edgePoints, stat.intraConnections, stat.interConnections, stat.isolatedPoints)
				draw.Text(20, statY, text)
				statY = statY + 12
			end
			
			if #finePointStats > 3 then
				draw.Text(20, statY, string.format("  ... and %d more areas", #finePointStats - 3))
			end
		end
	end

	-- Auto path informaton
	if G.Menu.Main.Enable then
		draw.Text(20, currentY, string.format("Current Node: %d", G.Navigation.currentNodeIndex))
		currentY = currentY + 20
	end

	-- Draw all nodes
	if G.Menu.Visuals.drawNodes then
		draw.Color(0, 255, 0, 255)
		for id, entry in pairs(visibleNodes) do
			local s = entry.screen
			draw.FilledRect(s[1] - 4, s[2] - 4, s[1] + 4, s[2] + 4)
			if G.Menu.Visuals.drawNodeIDs then
				draw.Text(s[1], s[2] + 10, tostring(id))
			end
		end
	end

	-- Draw current path
	if G.Menu.Visuals.drawPath and G.Navigation.path and #G.Navigation.path > 0 then
		draw.Color(255, 255, 255, 255)

		for i = 1, #G.Navigation.path - 1 do
			local n1 = G.Navigation.path[i]
			local n2 = G.Navigation.path[i + 1]
			local node1Pos = n1.pos
			local node2Pos = n2.pos

			local screenPos1 = client.WorldToScreen(node1Pos)
			local screenPos2 = client.WorldToScreen(node2Pos)

			if not screenPos1 or not screenPos2 then
				goto continue
			end

			if node1Pos and node2Pos then
				ArrowLine(node1Pos, node2Pos, 22, 15, false) -- Adjust the size for the perpendicular segment as needed
			end
			::continue::
		end
	end

	-- Draw current node
	if G.Menu.Visuals.drawCurrentNode and G.Navigation.path then
		draw.Color(255, 0, 0, 255)

		local currentNode = G.Navigation.path[G.Navigation.currentNodeIndex]
		local currentNodePos = currentNode.pos

		local screenPos = client.WorldToScreen(currentNodePos)
		if screenPos then
			Draw3DBox(20, currentNodePos)
			draw.Text(screenPos[1], screenPos[2] + 40, tostring(G.Navigation.currentNodeIndex))
		end
	end
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals
