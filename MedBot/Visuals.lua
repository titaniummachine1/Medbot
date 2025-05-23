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
local AREA_FILL_COLOR = { 55, 255, 155, 50 } -- r, g, b, a for filled area
local AREA_OUTLINE_COLOR = { 255, 255, 255, 100 } -- r, g, b, a for area outline

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
	G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
	if G.Navigation.currentNodeIndex == nil then
		return
	end

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

	if agent2Pos then
		local screenPos2 = client.WorldToScreen(agent2Pos)
		if screenPos2 then
			draw.Color(0, 255, 0, 255) -- Green color for the second agent
			Draw3DBox(20, agent2Pos) -- Larger size for the second agent
		end
	end

	-- Memory usage
	if G.Menu.Visuals.memoryUsage then
		draw.Text(20, currentY, string.format("Memory usage: %.2f MB", G.Benchmark.MemUsage / 1024))
		currentY = currentY + 20
	end

	-- Show hiding spots (health packs)
	if G.Menu.Visuals.showHidingSpots then
		draw.Color(255, 0, 0, 255)
		for _, pos in pairs(G.World.healthPacks) do
			local scr = client.WorldToScreen(pos)
			if scr then
				draw.FilledRect(scr[1] - 4, scr[2] - 4, scr[1] + 4, scr[2] + 4)
			end
		end
	end

	-- Show connections between nav nodes
	if G.Menu.Visuals.showConnections then
		draw.Color(255, 255, 0, 255)
		for id, node in pairs(G.Navigation.nodes) do
			local dist = (myPos - node.pos):Length()
			if dist > 700 then
				goto continue_conn
			end
			for dir = 1, 4 do
				local conDir = node.c[dir]
				for _, nid in ipairs(conDir.connections) do
					if id < nid then
						local other = G.Navigation.nodes[nid]
						local s1 = client.WorldToScreen(node.pos)
						local s2 = client.WorldToScreen(other.pos)
						if s1 and s2 then
							draw.Line(s1[1], s1[2], s2[1], s2[2])
						end
					end
				end
			end
			::continue_conn::
		end
	end

	-- Fill and outline areas
	if G.Menu.Visuals.showAreas then
		for _, node in pairs(G.Navigation.nodes) do
			local dist = (myPos - node.pos):Length()
			if dist > 700 then
				goto continue_area
			end
			-- world corners to Vector3
			local nw_tbl, se_tbl = node.nw, node.se
			local nw = Vector3(nw_tbl.x, nw_tbl.y, nw_tbl.z)
			local se = Vector3(se_tbl.x, se_tbl.y, se_tbl.z)
			local ne = Vector3(se_tbl.x, nw_tbl.y, nw_tbl.z)
			local sw = Vector3(nw_tbl.x, se_tbl.y, se_tbl.z)
			-- project to screen
			local verts = { nw, ne, se, sw }
			local scr, ok = {}, true
			for i, w in ipairs(verts) do
				local s = client.WorldToScreen(w)
				if not s then
					ok = false
					break
				end
				scr[i] = { s[1], s[2] }
			end
			if ok then
				-- filled polygon (semi-transparent blue)
				fillPolygon(scr, table.unpack(AREA_FILL_COLOR))
				-- outline in opaque blue
				draw.Color(table.unpack(AREA_OUTLINE_COLOR))
				for i = 1, 4 do
					local a = scr[i]
					local b = scr[i % 4 + 1]
					draw.Line(a[1], a[2], b[1], b[2])
				end
			end
			::continue_area::
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

		local navNodes = G.Navigation.nodes
		for id, node in pairs(navNodes) do
			local dist = (myPos - node.pos):Length()
			if dist > 700 then
				goto continue
			end

			local screenPos = client.WorldToScreen(node.pos)
			if not screenPos then
				goto continue
			end

			local x, y = screenPos[1], screenPos[2]
			draw.FilledRect(x - 4, y - 4, x + 4, y + 4) -- Draw a small square centered at (x, y)

			-- Node IDs
			if G.Menu.Visuals.drawNodeIDs then
				draw.Text(screenPos[1], screenPos[2] + 10, tostring(id))
			end

			::continue::
		end
	end

	-- Draw current path
	if G.Menu.Visuals.drawPath and G.Navigation.path then
		draw.Color(255, 255, 255, 255)

		for i = 1, #G.Navigation.path - 1 do
			local node1 = G.Navigation.path[i]
			local node2 = G.Navigation.path[i + 1]

			local node1Pos = Vector3(node1.x, node1.y, node1.z)
			local node2Pos = Vector3(node2.x, node2.y, node2.z)

			local screenPos1 = client.WorldToScreen(node1Pos)
			local screenPos2 = client.WorldToScreen(node2Pos)
			if not screenPos1 or not screenPos2 then
				goto continue
			end

			if node1Pos and node2Pos then
				ArrowLine(node1Pos, node2Pos, 22, 15, true) -- Adjust the size for the perpendicular segment as needed
			end
			::continue::
		end

		-- Draw a line from the player to the second node from the end
		local node1 = G.Navigation.path[#G.Navigation.path]
		if node1 then
			node1 = Vector3(node1.x, node1.y, node1.z)
			ArrowLine(myPos, node1, 22, 15, false)
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
