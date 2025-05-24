local sourcenav = require "sourcenav"

---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
assert(libLoaded, "lnxLib not found, please install it!")
UnloadLib() --unloads all packages

local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer, WWeapon = lnxLib.TF2.WPlayer, lnxLib.TF2.WWeapon
local Helpers = lnxLib.TF2.Helpers
local Prediction = lnxLib.TF2.Prediction
local Fonts = lnxLib.UI.Fonts

SIGNONSTATE_NONE = 0 -- no state yet, about to connect
SIGNONSTATE_CHALLENGE = 1 -- client challenging server, all OOB packets
SIGNONSTATE_CONNECTED = 2 -- client is connected to server, netchans ready
SIGNONSTATE_NEW = 3 -- just got serverinfo and string tables
SIGNONSTATE_PRESPAWN = 4 -- received signon buffers
SIGNONSTATE_SPAWN = 5 -- ready to receive entity packets
SIGNONSTATE_FULL = 6 -- we are fully connected, first non-delta packet received
SIGNONSTATE_CHANGELEVEL = 7 -- server is changing level, please wait

local nav_area_attributes = {
    CROUCH = 0x1, --must crouch to use this node/area
    JUMP = 0x2, --must jump to traverse this area (only used during generation)
    PRECISE = 0x4,	--do not adjust for obstacles, just move along area
    NO_JUMP = 0x8,	--inhibit discontinuity jumping
    STOP = 0x10, --must stop when entering this area
    RUN = 0x20,	--must run to traverse this area
    WALK = 0x40, --must walk to traverse this area
    AVOID = 0x80, --avoid this area unless alternatives are too dangerous
    TRANSIENT = 0x100, --area may become blocked, and should be periodically checked
    DONT_HIDE = 0x200, --area should not be considered for hiding spot generation
    STAND = 0x400, --bots hiding in this area should stand
    NO_HOSTAGES = 0x800, --hostages shouldn't use this area
    STAIRS = 0x1000, --this area represents stairs, do not attempt to climb or jump them - just walk up
    NO_MERGE = 0x2000, --don't merge this area with adjacent areas
    OBSTACLE_TOP = 0x4000, --this nav area is the climb point on the tip of an obstacle
    CLIFF = 0x8000, --this nav area is adjacent to a drop of at least CliffHeight

    FIRST_CUSTOM = 0x10000, --apps may define custom app-specific bits starting with this value
    LAST_CUSTOM = 0x4000000, --apps must not define custom app-specific bits higher than with this value
    FUNC_COST = 0x20000000, --area has designer specified cost controlled by func_nav_cost entities

    HAS_ELEVATOR = 0x40000000, --area is in an elevator's path
    NAV_BLOCKER = 0x80000000, --area is blocked by nav blocker ( Alas, needed to hijack a bit in the attributes to get within a cache line [7/24/2008 tom])
}

local config = {
	square = {
		enabled = true;
		r = 55;
		g = 255;
		b = 155;
		a = 50;
	};
	
	line = {
		enabled = true;
		r = 255;
		g = 255;
		b = 255;
		a = 100;
	};
};

-- Manhattan distance between two points
local function manhattanDistance(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

-- Function to get the center of an area
local function get_area_center(area)
    if not area then
        return nil
    end

    local center = Vector3()

    if area.north_west then
        center.x = (area.north_west.x + area.south_east.x) / 2
        center.y = (area.north_west.y + area.south_east.y) / 2
        center.z = (area.north_west.z + area.south_east.z) / 2
    else
        center = Vector3(area.x, area.y, area.z)
    end

    return center
end

-- Function to adjust the area's orientation based on a surface normal obtained from a trace
local function adjustAreaOrientation(area)
    local traceStart = Vector3(area.pos.x, area.pos.y, area.pos.z + 10)
    local traceEnd = Vector3(area.pos.x, area.pos.y, area.pos.z - 10)
    local hitResult = engine.TraceLine(traceStart, traceEnd, MASK_PLAYERSOLID)
    
    if hitResult and hitResult.fraction < 1 then
        local normal = hitResult.plane
        area.orientation = normal  -- Update the area's orientation based on the surface normal
    end
end

local navData  -- Variable to hold the parsed navmesh
local parsed_areas

-- Function to fetch and parse the navmesh
local function GetNavMesh()
    -- Inner function to open and read the nav file
    local function open_nav_file(map_name, basedir)
        if map_name:len() < 1 then
            --print("Invalid map name.")
            return nil
        end

        -- Construct the filename
        basedir = basedir or engine.GetGameDir()
        local filename = string.format('%s/%s', basedir, map_name:gsub('.bsp$', '.nav'))

        -- Open the file
        local file = io.open(filename, 'rb')
        if not file then
            client.RemoveConVarProtection("sv_cheats")
            client.RemoveConVarProtection("nav_generate")
            client.SetConVar("sv_cheats", "1")
            client.Command("nav_generate", true)
            --print("Generated navmesh. Please reload Lua to read the new navmesh.")
            return nil
        end

        -- Read and parse the nav file
        local content = file:read('a')
        file:close()
        local nav = sourcenav.parse(content)

        --assert(nav.minor == 2, "Invalid minor version, must be 2.")
        return nav
    end

    --print("Fetching NavMesh file...")

    -- Get current map name
    local current_map = engine.GetMapName()

    -- Open and parse the nav file
    navData = open_nav_file(current_map)

    -- Check if navData and its properties exist before trying to print them
    if navData then
        local places_count = navData.places and #navData.places or "N/A"
        local areas_count = navData.areas and #navData.areas or "N/A"
        local total_connections = 0
        local hiding_spots_count = 0  -- Initialize hiding spots count

        for _, area in ipairs(navData.areas) do
            for dir, connections_dir in pairs(area.connections) do
                total_connections = total_connections + connections_dir.count
            end
            -- Count hiding spots if they exist
            if area.hiding_spots then
                hiding_spots_count = hiding_spots_count + #area.hiding_spots
            end
        end

        --print("Parsed " .. places_count .. " places, " .. areas_count .. " areas, " .. total_connections .. " connections, " .. hiding_spots_count .. " hiding spots.")
    else
       -- print("navData is not available.")
        return nil
    end

-- Initialize parsed_areas table
parsed_areas = {}

-- Function to generate a grid of points within an area, considering rotation
local function generate_points(area)

    
    local points = {}
    local step = 60  -- Grid step in units. Adjust based on your needs.
    local edge_buffer = 20  -- Distance from edges
    
    local nw = area.north_west
    local se = area.south_east
    local sw = { x = nw.x, y = se.y, z = se.z }  -- south_west point, assuming a rectangular area
    
    -- Calculate the normal vector of the plane formed by nw, se, and sw
    local A = { x = se.x - nw.x, y = se.y - nw.y, z = se.z - nw.z }
    local B = { x = sw.x - nw.x, y = sw.y - nw.y, z = sw.z - nw.z }
    local N = { 
        x = A.y * B.z - A.z * B.y, 
        y = A.z * B.x - A.x * B.z,
        z = A.x * B.y - A.y * B.x
    }
    
    -- Calculate dimensions
    local dim_x = math.abs(se.x - nw.x) - 2 * edge_buffer
    local dim_y = math.abs(se.y - nw.y) - 2 * edge_buffer
    
    -- Calculate number of steps in each dimension
    local steps_x = math.floor(dim_x / step)
    local steps_y = math.floor(dim_y / step)
    
    -- Generate points
    for i = 0, steps_x do
        for j = 0, steps_y do
            local point_x = nw.x + edge_buffer + i * step
            local point_y = nw.y + edge_buffer + j * step
            
            -- Calculate point_z based on the normal vector N
            -- Assuming the plane equation is Ax + By + Cz = D
            -- point_z = (D - Ax - By) / C
            local D = nw.x * N.x + nw.y * N.y + nw.z * N.z
            local point_z = (D - point_x * N.x - point_y * N.y) / N.z
            
            -- Add the point to the points table
            table.insert(points, Vector3(point_x, point_y, point_z))
        end
    end

    -- If no points are generated, add a single point at area.pos
    if #points == 0 then
        if area then
            table.insert(points, get_area_center(area))
        end
    end
    
    return points
end

-- Loop through all areas in navData.areas
for _, area in ipairs(navData.areas) do
    if not area then
        goto continue
    end
    local area_id = area.id

    local area_pos = get_area_center(area)  -- Assuming this function returns a Vector3
    -- Hiding Spots
    local hiding_spots_positions = {}
    for _, hiding_spot in ipairs(area.hiding_spots) do
        local location = hiding_spot.location
        if location then
            -- Convert to Vector3 (Replace with your game's Vector3 constructor if needed)
            local vector3_position = Vector3(location.x, location.y, location.z)
            table.insert(hiding_spots_positions, vector3_position)
        end
    end

    -- Connections
    local connections_out = {}
    for dir, connections_dir in pairs(area.connections) do
        local dir_connections = {}
        for _, target_id in ipairs(connections_dir.connections) do
            -- You can also convert target positions to Vector3 here, similar to hiding_spots_positions
            table.insert(dir_connections, target_id)
        end
        connections_out[dir] = dir_connections
    end

    -- Iterate through all areas and add the 'pos' field if it's not present
    for _, area in pairs(navData.areas) do
        if not area.pos then
            area.pos = get_area_center(area)
        end
    end


    -- Store parsed data
    parsed_areas[area_id] = {
        pos = area_pos,
        hiding_spots = hiding_spots_positions,
        connections_out = connections_out,
        flags = area.flags,  -- store flags if needed
        points = {}
    }
    
    parsed_areas[area_id].points = generate_points(area)
    --print(area.flags) -- keep for later
    ::continue::
end

    return navData, parsed_areas  -- Return the parsed nav_data
end

navData, parsed_areas = GetNavMesh() --prealocate navmesh so it doesnt crash for some reason

---------------------ACTUAL CODE BELOW----------------------------------------------


-- Helper function to open, read, and parse the nav file
local function open_nav_file(map_name, basedir)
    -- Validate map name
    if map_name:len() < 1 then
        print("Invalid map name.")
        return nil
    end

    -- Construct the filename
    basedir = basedir or engine.GetGameDir()
    local filename = string.format('%s/%s', basedir, map_name:gsub('.bsp$', '.nav'))

    -- Open the file
    local file = io.open(filename, 'rb')

    -- If file not found, generate a new navmesh
    if not file then
        client.RemoveConVarProtection("sv_cheats")
        client.RemoveConVarProtection("nav_generate")
        client.SetConVar("sv_cheats", "1")
        client.Command("nav_generate", true)
        print("Generated navmesh. Please reload Lua to read the new navmesh.")
        return nil
    end

    -- Read and parse the nav file
    local content = file:read('a')
    file:close()
    local nav = sourcenav.parse(content)

    -- Validate nav file version
    assert(nav.minor == 2, "Invalid minor version, must be 2.")
    return nav
end

-- Function to generate a grid of points within an area, considering rotation
local function generate_points(area)
    local points = {}
    local step = 60  -- Grid step in units. Adjust based on your needs.
    local edge_buffer = 12  -- Distance from edges

    local nw = area.north_west
    local se = area.south_east

    -- Calculate dimensions of the area
    local dim_x = math.abs(se.x - nw.x) - 2 * edge_buffer
    local dim_y = math.abs(se.y - nw.y) - 2 * edge_buffer

    -- Calculate the starting point for the grid, so that it's edge_buffer units away from the edges
    local start_x = nw.x + edge_buffer
    local start_y = nw.y + edge_buffer

    -- Calculate the number of points (steps) that fit within the adjusted dimensions
    local steps_x = math.floor(dim_x / step)
    local steps_y = math.floor(dim_y / step)

    -- Center the grid by adjusting the starting point
    local extra_space_x = dim_x - steps_x * step
    local extra_space_y = dim_y - steps_y * step

    start_x = start_x + extra_space_x / 2
    start_y = start_y + extra_space_y / 2

    -- Generate points
    for i = 0, steps_x do
        for j = 0, steps_y do
            local point_x = start_x + i * step
            local point_y = start_y + j * step
            local point_z = nw.z  -- Assuming the area is flat

            -- Add the point to the points table
            table.insert(points, {pos = Vector3(point_x, point_y, point_z), neighbors = {}, id = #points + 1})
        end
    end

    -- Function to assign neighbors to each point
    for i, point_a in ipairs(points) do
        for j, point_b in ipairs(points) do
            if i ~= j then  -- Skip self
                local distance = (point_a.pos - point_b.pos):Length()
                if distance <= (step * 2) + 1 then  -- Check if within maximum allowed distance
                    table.insert(point_a.neighbors, {point = point_b, cost = distance})
                end
            end
        end
    end

    -- If no points are generated, add a single point at area.pos
    if #points == 0 then
        if area then
            table.insert(points, {pos = get_area_center(area), neighbors = {}, id = #points + 1})
        end
    end

    return points
end

-- Function to fetch and parse the navmesh
local function GetNavMesh()
    print("Fetching NavMesh file...")

    -- Get the current map name
    local current_map = engine.GetMapName()

    -- Open and parse the nav file
    navData = open_nav_file(current_map)

    -- Validate and print navData properties
    if navData then
        local places_count = navData.places and #navData.places or "N/A"
        local areas_count = navData.areas and #navData.areas or "N/A"
        local total_connections = 0
        local hiding_spots_count = 0  -- Initialize hiding spots count

        -- Iterate through areas to count connections and hiding spots
        for _, area in ipairs(navData.areas) do
            for dir, connections_dir in pairs(area.connections) do
                total_connections = total_connections + connections_dir.count
            end

            -- Count hiding spots if they exist
            if area.hiding_spots then
                hiding_spots_count = hiding_spots_count + #area.hiding_spots
            end
        end

        print(string.format("Parsed %s places, %s areas, %d connections, %d hiding spots.", 
                            places_count, areas_count, total_connections, hiding_spots_count))
    else
        print("navData is not available.")
        return nil
    end


    -- Initialize parsed_areas table
    parsed_areas = {}

    -- Loop through all areas in navData.areas
    for _, area in ipairs(navData.areas) do
        if not area then
            goto continue
        end
        local area_id = area.id
        local area_pos = get_area_center(area)  -- Assuming this function returns a Vector3
        -- Hiding Spots
        local hiding_spots_positions = {}
        for _, hiding_spot in ipairs(area.hiding_spots) do
            local location = hiding_spot.location
            if location then
                -- Convert to Vector3 (Replace with your game's Vector3 constructor if needed)
                local vector3_position = Vector3(location.x, location.y, location.z)
                table.insert(hiding_spots_positions, vector3_position)
            end
        end

        -- Connections of areas
        local connections_out = {}
        for dir, connections_dir in pairs(area.connections) do
            local dir_connections = {}
            for _, target_id in ipairs(connections_dir.connections) do
                -- You can also convert target positions to Vector3 here, similar to hiding_spots_positions
                table.insert(dir_connections, target_id)
            end
            connections_out[dir] = dir_connections
        end

        -- Store parsed data
        parsed_areas[area_id] = {
            id = area.id,
            pos = area_pos,
            hiding_spots = hiding_spots_positions,
            connections_out = connections_out,
            flags = area.flags,  -- store flags if needed
            points = {}
        }

        parsed_areas[area_id].points = generate_points(area)
        --print(area.id) -- keep for later
        ::continue::
    end

    return navData, parsed_areas  -- Return the parsed nav_data
end

navData, parsed_areas = GetNavMesh()

--printLuaTable(navData.areas)

callbacks.Register( 'FireGameEvent', function( event )

    if event:GetName() == 'player_connect_full' then
        navData = GetNavMesh()
    end

    if event:GetName() == 'round_prestart' then

    end

    if event:GetName() == 'player_spawn' then

    end

end )

-- Function to find the closest points and areas to given start and end positions
local function findClosestPointsAndAreas(parsed_areas, startPos, endPos)
    local closestStart = {area = nil, point = nil}
    local closestEnd = {area = nil, point = nil}
    local minStartDistance = math.huge  -- Initialize with a large value
    local minEndDistance = math.huge  -- Initialize with a large value

    for area_id, area_data in pairs(parsed_areas) do
        local area_pos = area_data.pos
        local startDistance = (startPos - area_pos):Length()
        local endDistance = (endPos - area_pos):Length()

        if startDistance < minStartDistance then
            closestStart.area = area_data  -- Now assigning the whole area data, not just the position
            minStartDistance = startDistance

            -- find the closest point within this area to startPos
            for _, point in ipairs(area_data.points) do
                local pointDistance = (startPos - point.pos):Length()
                if pointDistance < minStartDistance then
                    closestStart.point = point
                    minStartDistance = pointDistance
                end
            end
        end

        if endDistance < minEndDistance then
            closestEnd.area = area_data  -- Now assigning the whole area data, not just the position
            minEndDistance = endDistance

            -- find the closest point within this area to endPos
            for _, point in ipairs(area_data.points) do
                local pointDistance = (endPos - point.pos):Length()
                if pointDistance < minEndDistance then
                    closestEnd.point = point
                    minEndDistance = pointDistance
                end
            end
        end
    end

    return closestStart, closestEnd
end


-- Function to get the current position
local function getCurrentPos()
    local pLocal = entities.GetLocalPlayer()
    if pLocal then
        return pLocal:GetAbsOrigin()  -- Replace with your game's function to get position
    end
    return nil
end

-- Function to get the position the player is looking at
local function getLookPos()
    local pLocal = entities.GetLocalPlayer()
    if not pLocal then return nil end

    local source = pLocal:GetAbsOrigin() + pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
    local destination = source + engine.GetViewAngles():Forward() * 1000  -- Replace 1000 with the desired distance
    
    local trace = engine.TraceLine(source, destination, MASK_SHOT_HULL)
    if trace then
        return trace.endpos  -- Position where the player is looking at
    end
    return nil  -- Return nil if no entity is found
end

-- Function to check if a list contains a specific area
local function containsArea(areaList, targetArea)
    if targetArea then
        for _, area in ipairs(areaList) do
            if area.id == targetArea.id then
                return true
            end
        end
        return false
    else
        print("targetarea is nil")
        return false
    end
end

--------------------------Pathfinding----------------------------------------------

-- Function to find the closest areas to the start and end positions
local function findClosestAreas(parsed_areas, startPos, endPos)
    local closestStartArea, closestEndArea = nil, nil
    local minStartDistance, minEndDistance = math.huge, math.huge

    for area_id, area_data in pairs(parsed_areas) do
        local startDistance = manhattanDistance(startPos, area_data.pos)
        local endDistance = manhattanDistance(endPos, area_data.pos)

        if startDistance < minStartDistance then
            closestStartArea = area_data
            minStartDistance = startDistance
        end

        if endDistance < minEndDistance then
            closestEndArea = area_data
            minEndDistance = endDistance
        end
    end

    return closestStartArea, closestEndArea
end

local function distanceBetweenAreas(area1, area2)
    if area1 and area2 then
        return manhattanDistance(area1.pos, area2.pos)
    else
        print("area1 or area2 is nil")
        return math.huge
    end
--[[
    local center1 = get_area_center(area1)
    local center2 = get_area_center(area2)
    -- Compute the distance between center1 and center2.
    -- Replace this with your actual distance computation method.
    return manhattanDistance(center1.pos, center2.pos)]]
end

-- Dijkstra's algorithm for pathfinding between areas
local function Dijkstra_Areas(startPos, endPos)
    local closestStartArea, closestEndArea = findClosestAreas(parsed_areas, startPos, endPos)
    local startAreaID = closestStartArea.id
    local endAreaID = closestEndArea.id

    local openSet = {}
    local distances = {}
    local prev = {}

    for areaID, _ in pairs(parsed_areas) do
        distances[areaID] = math.huge
        prev[areaID] = nil
    end

    distances[startAreaID] = 0
    table.insert(openSet, startAreaID)

    while #openSet > 0 do
        table.sort(openSet, function(a, b) return distances[a] < distances[b] end)
        local currentAreaID = table.remove(openSet, 1)

        if currentAreaID == endAreaID then
            local path = {}
            local tempAreaID = currentAreaID
            while tempAreaID do
                table.insert(path, 1, tempAreaID)
                tempAreaID = prev[tempAreaID]
            end
            return path
        end

        for _, neighborAreaID in ipairs(parsed_areas[currentAreaID].connections_out) do
            local alt = distances[currentAreaID] + distanceBetweenAreas(parsed_areas[currentAreaID], parsed_areas[neighborAreaID])
            if alt < (distances[neighborAreaID] or math.huge) then
                distances[neighborAreaID] = alt
                prev[neighborAreaID] = currentAreaID
                table.insert(openSet, neighborAreaID)
            end
        end
    end

    print("Path not found")
    return nil
end


--[[ Utility function to check if an area ID exists in a given list of areas
local function containsArea(areaList, areaID)
    for _, area in ipairs(areaList) do
        if area.id == areaID then
            return true
        end
    end
    return false
end

local function AStar_Areas(startData, endData)
    -- Initialization
    local startAreaID = startData.area.id
    local endAreaID = endData.area.id

    if not navData then print("navData not exist") return nil end
    if not navData.areas[startAreaID] or not navData.areas[endAreaID] then 
        print("Invalid start or end area ID") 
        return nil 
    end

    local openSet = {}
    local closedSet = {}
    local cameFrom = {}
    local gScore, fScore = {}, {}
    
    -- Initialize scores for all areas
    for areaID, _ in pairs(navData.areas) do
        gScore[areaID] = math.huge  -- Initialize to a large value
        fScore[areaID] = math.huge  -- Initialize to a large value
    end

    gScore[startAreaID] = 0
    fScore[startAreaID] = manhattanDistance(navData.areas[startAreaID].pos, navData.areas[endAreaID].pos)

    table.insert(openSet, navData.areas[startAreaID])

    while #openSet > 0 do
        local current = openSet[1]
        local currentIndex = 1

        for i, area in ipairs(openSet) do
            if fScore[area.id] < fScore[current.id] then
                current = area
                currentIndex = i
            end
        end

        if current.id == endAreaID then
            local path = {}
            local temp = current
            while temp ~= nil do
                table.insert(path, 1, temp)
                temp = cameFrom[temp.id]
            end
            return path
        end

        table.remove(openSet, currentIndex)
        table.insert(closedSet, current)

        for _, connectionID in ipairs(current.connections_out) do
            local neighbor = navData.areas[connectionID]

            if not containsArea(closedSet, neighbor.id) then
                local tentative_gScore = gScore[current.id] + 1  -- Assuming each step has a cost of 1

                if tentative_gScore < gScore[neighbor.id] then
                    cameFrom[neighbor.id] = current
                    gScore[neighbor.id] = tentative_gScore
                    fScore[neighbor.id] = tentative_gScore + manhattanDistance(neighbor.pos, navData.areas[endAreaID].pos)

                    if not containsArea(openSet, neighbor.id) then
                        table.insert(openSet, neighbor)
                    end
                end
            end
        end
    end

    print("Path not found")
    return nil  -- Path not found
end]]




-- Example usage (Assuming you have findClosestPointsAndAreas, getCurrentPos, and getLookPos)
local startData, endData = findClosestPointsAndAreas(parsed_areas, getCurrentPos(), getLookPos())
--local path = AStar_Areas(startData, endData)

local function OnCreateMove(pCmd)
    
end





----------------------------DRAWING CODE---------------------------------------------------
local white_texture = draw.CreateTextureRGBA(string.char(
	0xff, 0xff, 0xff, config.square.a,
	0xff, 0xff, 0xff, config.square.a,
	0xff, 0xff, 0xff, config.square.a,
	0xff, 0xff, 0xff, config.square.a
), 2, 2);

local drawPolygon = (function()
	local v1x, v1y = 0, 0;
	local function cross(a, b)
		return (b[1] - a[1]) * (v1y - a[2]) - (b[2] - a[2]) * (v1x - a[1])
	end

	local TexturedPolygon = draw.TexturedPolygon;

	return function(vertices)
		local cords, reverse_cords = {}, {};
		local sizeof = #vertices;
		local sum = 0;

		v1x, v1y = vertices[1][1], vertices[1][2];
		for i, pos in pairs(vertices) do
			local convertedTbl = {pos[1], pos[2], 0, 0};

			cords[i], reverse_cords[sizeof - i + 1] = convertedTbl, convertedTbl;

			sum = sum + cross(pos, vertices[(i % sizeof) + 1]);
		end


		TexturedPolygon(white_texture, (sum < 0) and reverse_cords or cords, true)
	end
end)();

local corners1


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
            Vector3(-halfSize, halfSize, halfSize)
        }
    end

    local linesToDraw = {
        {1, 2}, {2, 3}, {3, 4}, {4, 1},
        {5, 6}, {6, 7}, {7, 8}, {8, 5},
        {1, 5}, {2, 6}, {3, 7}, {4, 8}
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

-- Assuming you have a Vector3 function and WorldToScreen function from your API
local drawLine, WorldToScreen = draw.Line, client.WorldToScreen
local DrawDist = 700 --render distance
-- Flag to indicate whether lines have been cached
local lines_cached = false


local function doDraw()
    draw.SetFont(Fonts.Verdana)
    draw.Color(255, 255, 255, 255)
    
    local pLocal = entities.GetLocalPlayer()
    if not pLocal or not pLocal:IsAlive() then return end

    -- Check if navData exists
    if not navData or not parsed_areas then return end  -- Replacing goto with return for better readability

    for _, area in pairs(parsed_areas) do  -- Assuming parsed_areas contains all your areas
        if (area.pos - pLocal:GetAbsOrigin()):Length() < DrawDist then --distance check

            -- Iterate through each hiding spot in the current area
            for _, hidingSpot in ipairs(area.hiding_spots) do  -- Assuming hiding_spots is an array of Vector3 positions
                local screenPos = client.WorldToScreen(Vector3(hidingSpot.x, hidingSpot.y, hidingSpot.z))
                if screenPos then
                    draw.Color(255, 0, 0, 255)  -- Red color for hiding spots
                    Draw3DBox(10, hidingSpot)  -- Assuming the size of the cube is 10
                end
            end

            -- Table to keep track of already drawn connections
            local drawn_connections = {}

            -- Draw points as small squares on the screen
            for _, point in ipairs(area.points) do  -- Assuming points is an array of Vector3 positions
                local screenPos = client.WorldToScreen(Vector3(point.pos.x, point.pos.y, point.pos.z))
                if screenPos then
                    draw.Color(0, 255, 0, 255)  -- Green color for points
                    local x, y = screenPos[1], screenPos[2]
                    draw.FilledRect(x - 2, y - 2, x + 2, y + 2)  -- Draw a small square centered at (x, y)
                end

                local start_pos = point.pos
                local start_screen = WorldToScreen(Vector3(start_pos.x, start_pos.y, start_pos.z))
                
                for _, neighbor in ipairs(point.neighbors) do  -- Assuming neighbors contains direct neighbors
                    local end_pos = neighbor.point.pos

                    -- Generate a unique identifier for each pair of connected points
                    local connection_id = math.min(point.id, neighbor.point.id) .. "-" .. math.max(point.id, neighbor.point.id)

                    -- Only draw the line if this connection hasn't been drawn yet
                    if not drawn_connections[connection_id] then
                        local end_screen = WorldToScreen(Vector3(end_pos.x, end_pos.y, end_pos.z))
                        
                        if start_screen and end_screen then
                            draw.Color(0, 255, 0, 255)  -- Green color for point-to-point connections
                            draw.Line(start_screen[1], start_screen[2], end_screen[1], end_screen[2])
                        end

                        -- Mark this connection as drawn
                        drawn_connections[connection_id] = true
                    end
                end

            end

            -- New code to draw lines between connected areas
            for dir, connected_areas in pairs(area.connections_out) do
                for _, target_id in ipairs(connected_areas) do
                    local target_area = parsed_areas[target_id]
                    if target_area then
                        local start_pos = area.pos
                        local end_pos = target_area.pos

                        -- Convert start and end positions to screen coordinates
                        local start_screen = WorldToScreen(Vector3(start_pos.x, start_pos.y, start_pos.z))
                        local end_screen = WorldToScreen(Vector3(end_pos.x, end_pos.y, end_pos.z))

                        if start_screen and end_screen then
                            draw.Color(255, 255, 0, 255)  -- Yellow color for connections
                            draw.Line(start_screen[1], start_screen[2], end_screen[1], end_screen[2])
                        end
                    end
                end
            end
        end
    end

    -- Iterate over all parsed areas
    for _, area in pairs(navData.areas) do
        local nw = area.north_west  -- Assuming a table with x, y, z keys
        local se = area.south_east  -- Assuming a table with x, y, z keys

        if (area.pos - pLocal:GetAbsOrigin()):Length() < DrawDist then --distance check
            -- Calculate the other two corners
            local ne = { x = se.x, y = nw.y, z = nw.z }
            local sw = { x = nw.x, y = se.y, z = se.z }

            local corners = {nw, ne, se, sw}

            -- Convert each point to screen coordinates
            local screenPoints = {}
            local polygonVertices = {}  -- for drawPolygon
            for i, point in ipairs(corners) do
                local vec3_point = Vector3(point.x, point.y, point.z)  -- Convert to Vector3
                local screenPos = WorldToScreen(vec3_point)
                if screenPos then
                    table.insert(screenPoints, { x = screenPos[1], y = screenPos[2] })
                    table.insert(polygonVertices, { screenPos[1], screenPos[2] })  -- Prepare for drawPolygon
                else
                    goto continue  -- Skip drawing if any point is not on the screen
                end
            end

            -- Draw polygon using drawPolygon function
            draw.Color(config.square.r, config.square.g, config.square.b, config.square.a)
            drawPolygon(polygonVertices)

            -- Draw polygon outline
            draw.Color(255, 255, 255, 255)
            local linesToDraw = { {1, 2}, {2, 3}, {3, 4}, {4, 1} }
            for _, line in ipairs(linesToDraw) do
                local p1, p2 = screenPoints[line[1]], screenPoints[line[2]]
                if p1 and p2 then
                    draw.Line(p1.x, p1.y, p2.x, p2.y)
                end
            end
        end
        ::continue::
    end
end

local function OnUnload()                                -- Called when the script is unloaded
    UnloadLib() --unloading lualib
    client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
end


--[[ Unregister previous callbacks ]]--
callbacks.Unregister("CreateMove", "medbot_CreateMove")            -- Unregister the "CreateMove" callback
callbacks.Unregister("Draw", "NavBot_DrawX")                        -- Unregister the "Draw" callback
callbacks.Register("Draw", "NavBot_DrawX", doDraw)                               -- Register the "Draw" callback

--[[ Register callbacks ]]--
callbacks.Register("CreateMove", "medbot_CreateMove", OnCreateMove)             -- Register the "CreateMove" callback
callbacks.Unregister("Unload", "MCT_Unload")                    -- Unregister the "Unload" callback
callbacks.Register("Unload", "MCT_Unload", OnUnload)                         -- Register the "Unload" callback
--[[ Play sound when loaded ]]--
client.Command('play "ui/buttonclick"', true) -- Play the "buttonclick" sound when the script is loaded