--##########################################################################
--  Phase1_NavLoad.lua  ·  Load raw nav file and convert to node format
--##########################################################################

local Common = require("MedBot.Core.Common")
local SourceNav = require("MedBot.Utils.SourceNav")

local Phase1_NavLoad = {}

local Log = Common.Log.new("Phase1_NavLoad")

--##########################################################################
--  LOCAL HELPERS (NOT exported)
--##########################################################################

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

local function processNavData(navData)
    local navNodes = {}
    for _, area in pairs(navData.areas) do
        local cX = (area.north_west.x + area.south_east.x) / 2
        local cY = (area.north_west.y + area.south_east.y) / 2
        local cZ = (area.north_west.z + area.south_east.z) / 2

        local ne_z = area.north_east_z or area.north_west.z
        local sw_z = area.south_west_z or area.south_east.z

        local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
        local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
        local ne = Vector3(area.south_east.x, area.north_west.y, ne_z)
        local sw = Vector3(area.north_west.x, area.south_east.y, sw_z)

        navNodes[area.id] = {
            pos = Vector3(cX, cY, cZ),
            id = area.id,
            c = area.connections,
            nw = nw,
            se = se,
            ne = ne,
            sw = sw,
        }
    end
    return navNodes
end

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Load nav file and convert to internal node format
--- Returns: nodes table (areaId -> node) or nil, error
function Phase1_NavLoad.Execute(navFilePath)
    assert(type(navFilePath) == "string", "Phase1_NavLoad.Execute: navFilePath must be string")

    Log:Info("Loading nav file: %s", navFilePath)

    local navData, err = tryLoadNavFile(navFilePath)
    if not navData then
        return nil, err
    end

    local nodes = processNavData(navData)
    Log:Info("Phase 1 complete: %d areas loaded", #navData.areas)

    return nodes
end

return Phase1_NavLoad
