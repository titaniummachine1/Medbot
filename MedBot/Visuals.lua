--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Node = require("MedBot.Modules.Node")

-- Optional profiler support
local Profiler = nil
do
        local loaded, mod = pcall(require, "Profiler")
        if loaded then
                Profiler = mod
        end
end

local function ProfilerBeginSystem(name)
        if Profiler then
                Profiler.BeginSystem(name)
        end
end

local function ProfilerEndSystem()
        if Profiler then
                Profiler.EndSystem()
        end
end

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

-- Grid-based rendering helpers
local gridIndex = {}
local nodeCell = {}
local visBuf = {}
local visCount = 0
Visuals.lastChunkSize = nil
Visuals.lastRenderChunks = nil

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

-- Convert world position to chunk cell
local function worldToCell(pos)
    local size = G.Menu.Visuals.chunkSize or 256
    if size <= 0 then
        error("chunkSize must be greater than 0")
    end
    return math.floor(pos.x / size),
        math.floor(pos.y / size),
        math.floor(pos.z / size)
end

-- Build lookup grid of node ids per cell
local function buildGrid()
    gridIndex = {}
    nodeCell = {}
    local size = G.Menu.Visuals.chunkSize or 256
    for id, node in pairs(G.Navigation.nodes or {}) do
        if not node or not node.pos then
            Log:Warn("Visuals.buildGrid: skipping invalid node %s", tostring(id))
            goto continue
        end
        local cx, cy, cz = worldToCell(node.pos)
        gridIndex[cx] = gridIndex[cx] or {}
        gridIndex[cx][cy] = gridIndex[cx][cy] or {}
        gridIndex[cx][cy][cz] = gridIndex[cx][cy][cz] or {}
        table.insert(gridIndex[cx][cy][cz], id)
        nodeCell[id] = { cx, cy, cz }
        ::continue::
    end
    Visuals.lastChunkSize = size
    Visuals.lastRenderChunks = G.Menu.Visuals.renderChunks or 3
end

-- Rebuild grid if configuration changed
function Visuals.MaybeRebuildGrid()
    local size = G.Menu.Visuals.chunkSize or 256
    local chunks = G.Menu.Visuals.renderChunks or 3
    if size ~= Visuals.lastChunkSize or chunks ~= Visuals.lastRenderChunks then
        buildGrid()
    end
end

-- External access to rebuild grid
function Visuals.BuildGrid()
    buildGrid()
end

function Visuals.Initialize()
    local success, err = pcall(buildGrid)
    if not success then
        print("Error initializing visuals grid: " .. tostring(err))
        gridIndex = {}
        nodeCell = {}
        visBuf = {}
        visCount = 0
    end
end

-- Collect visible node ids around player
local function collectVisible(me)
    visCount = 0
    local px, py, pz = worldToCell(me:GetAbsOrigin())
    local r = G.Menu.Visuals.renderChunks or 3
    for dx = -r, r do
        local ax = math.abs(dx)
        for dy = -(r - ax), (r - ax) do
            local dzMax = r - ax - math.abs(dy)
            for dz = -dzMax, dzMax do
                local bx = gridIndex[px + dx]
                local by = bx and bx[py + dy]
                local bucket = by and by[pz + dz]
                if bucket then
                    for _, id in ipairs(bucket) do
                        visCount = visCount + 1
                        visBuf[visCount] = id
                    end
                end
            end
        end
    end
end


local function OnDraw()
        ProfilerBeginSystem("visuals_draw")

        draw.SetFont(Fonts.Verdana)
	draw.Color(255, 0, 0, 255)

    local me = entities.GetLocalPlayer()
    if not me then
        ProfilerEndSystem()
        return
    end
    -- Master enable switch for visuals
    if not G.Menu.Visuals.EnableVisuals then
        ProfilerEndSystem()
        return
    end

        local currentY = 120
	-- Draw memory usage if enabled in config
	if G.Menu.Visuals.memoryUsage then
		draw.SetFont(Fonts.Verdana) -- Ensure font is set before drawing text
		draw.Color(255, 255, 255, 200)
		-- Get current memory usage directly for real-time display
		local currentMemKB = collectgarbage("count")
		local memMB = currentMemKB / 1024
		draw.Text(10, 10, string.format("Memory Usage: %.1f MB", memMB))
		currentY = currentY + 20
	end
        -- Collect visible nodes using chunk grid
        Visuals.MaybeRebuildGrid()
        collectVisible(me)
        local visibleNodes = {}
        for i = 1, visCount do
                local id = visBuf[i]
                local node = G.Navigation.nodes and G.Navigation.nodes[id]
                if node then
                        local scr = client.WorldToScreen(node.pos)
                        if scr then
                                visibleNodes[id] = { node = node, screen = scr }
                        end
                end
        end
    G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
    if G.Navigation.currentNodeIndex == nil then
        ProfilerEndSystem()
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
                    for _, conn in ipairs(cDir.connections) do
                        local nid = (type(conn) == "table") and conn.node or conn
                        local otherNode = G.Navigation.nodes and G.Navigation.nodes[nid]
                        if otherNode then
                            local s1 = client.WorldToScreen(node.pos)
                            local s2 = client.WorldToScreen(otherNode.pos)
                            if s1 and s2 then
                                -- determine if other->id exists in its connections
                                local bidir = false
                                for d2 = 1, 4 do
                                    local otherCDir = otherNode.c[d2]
                                    if otherCDir and otherCDir.connections then
                                        for _, backConn in ipairs(otherCDir.connections) do
                                            local backId = (type(backConn) == "table") and backConn.node or backConn
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
    end

    -- Draw Doors (left, middle, right) if enabled
    if G.Menu.Visuals.showDoors then
        for id, entry in pairs(visibleNodes) do
            local node = entry.node
            for dir = 1, 4 do
                local cDir = node.c[dir]
                if cDir and cDir.connections then
                    for _, conn in ipairs(cDir.connections) do
                        local up = Vector3(0, 0, 1)
                        local zLift = up * 1.0
                        local doorLeft = conn.left and (conn.left + zLift)
                        local doorMid = conn.middle and (conn.middle + zLift)
                        local doorRight = conn.right and (conn.right + zLift)
                        if doorLeft and doorMid and doorRight then
                            local sL = client.WorldToScreen(doorLeft)
                            local sM = client.WorldToScreen(doorMid)
                            local sR = client.WorldToScreen(doorRight)
                            if sL and sM and sR then
                                -- Door line (cyan)
                                draw.Color(0, 200, 255, 220)
                                draw.Line(sL[1], sL[2], sR[1], sR[2])
                                -- Distinct end markers (magenta)
                                draw.Color(220, 0, 220, 230)
                                draw.FilledRect(sL[1] - 2, sL[2] - 2, sL[1] + 2, sL[2] + 2)
                                draw.FilledRect(sR[1] - 2, sR[2] - 2, sR[1] + 2, sR[2] + 2)
                                -- Middle marker color based on needJump (green/orange)
                                if conn.needJump then
                                    draw.Color(255, 140, 0, 255) -- orange means jump required
                                else
                                    draw.Color(0, 255, 0, 255) -- green means walkable
                                end
                                draw.FilledRect(sM[1] - 2, sM[2] - 2, sM[1] + 2, sM[2] + 2)
                            else
                                -- If only two points present (left/right), compute middle as midpoint
                                local sL2 = doorLeft and client.WorldToScreen(doorLeft)
                                local sR2 = doorRight and client.WorldToScreen(doorRight)
                                if sL2 and sR2 then
                                    draw.Color(0, 200, 255, 220)
                                    draw.Line(sL2[1], sL2[2], sR2[1], sR2[2])
                                    draw.Color(220, 0, 220, 230)
                                    draw.FilledRect(sL2[1] - 2, sL2[2] - 2, sL2[1] + 2, sL2[2] + 2)
                                    draw.FilledRect(sR2[1] - 2, sR2[2] - 2, sR2[1] + 2, sR2[2] + 2)
                                end
                            end
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

    -- Fine points removed
        if false then
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
					isolatedPoints = isolatedPoints,
				})
			end
		end
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

    ProfilerEndSystem()
end


--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals
