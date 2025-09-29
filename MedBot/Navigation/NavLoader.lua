--##########################################################################
--  NavLoader.lua  ·  Navigation file loading and parsing
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local SourceNav = require("MedBot.Utils.SourceNav")

local Log = Common.Log.new("NavLoader")
Log.Level = 0

local NavLoader = {}

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

function NavLoader.LoadFile(navFile)
	local full = "tf/" .. navFile
	local navData, err = tryLoadNavFile(full)
	if not navData and err == "File not found" then
		Log:Warning("Nav file not found: " .. full .. ", attempting to generate it")
		generateNavFile()
		return false
	end
	if not navData then
		Log:Error("Failed to load nav file: " .. (err or "Unknown error"))
		return false
	end
	
	local navNodes = NavLoader.ProcessNavData(navData)
	G.Navigation.nodes = navNodes
	G.Navigation.navMeshUpdated = true
	Log:Info("Navigation loaded: " .. #navData.areas .. " areas")
	return true
end

function NavLoader.LoadNavFile()
	local mf = engine.GetMapName()
	if mf and mf ~= "" then
		return NavLoader.LoadFile(string.gsub(mf, ".bsp", ".nav"))
	else
		Log:Error("No map name available")
		return false
	end
end

function NavLoader.ProcessNavData(navData)
	local navNodes = {}
	for _, area in pairs(navData.areas) do
		local cX = (area.north_west.x + area.south_east.x) / 2
		local cY = (area.north_west.y + area.south_east.y) / 2
		local cZ = (area.north_west.z + area.south_east.z) / 2
		
		-- Ensure diagonal z-coordinates have valid values (fallback to adjacent corners)
		local ne_z = area.north_east_z or area.north_west.z
		local sw_z = area.south_west_z or area.south_east.z
		
		local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
		local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
		local ne = Vector3(area.south_east.x, area.north_west.y, ne_z)
		local sw = Vector3(area.north_west.x, area.south_east.y, sw_z)
		
		navNodes[area.id] =
			{ pos = Vector3(cX, cY, cZ), id = area.id, c = area.connections, nw = nw, se = se, ne = ne, sw = sw }
	end
	return navNodes
end

return NavLoader
