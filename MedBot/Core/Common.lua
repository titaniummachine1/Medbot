---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

--[[ Imports ]]
-- Use literal require to allow luabundle to treat it as an external/static require
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1.0, "LNXlib version is too old, please update it!")

Common.Lib = Lib
Common.Notify = Lib.UI.Notify
Common.TF2 = Lib.TF2
Common.Math = Lib.Utils.Math
Common.Conversion = Lib.Utils.Conversion
Common.WPlayer = Lib.TF2.WPlayer
Common.PR = Lib.TF2.PlayerResource
Common.Helpers = Lib.TF2.Helpers

-- Import G module at file scope
local G = require("MedBot.Core.Globals")

-- Safe logging system (replaces LNX Logger)
local function safePrint(msg)
	local success, err = pcall(print, msg)
	if not success then
		-- Fallback: try again
		pcall(print, "LOG ERROR")
	end
end

local Logger = {}
Logger.__index = Logger

function Logger.new(moduleName)
	local self = setmetatable({}, Logger)
	self.moduleName = moduleName or "MedBot"
	return self
end

function Logger:Info(msg, ...)
	local success, formatted = pcall(string.format, "[Info  %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Info] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

function Logger:Warn(msg, ...)
	local success, formatted = pcall(string.format, "[Warn  %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Warn] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

function Logger:Debug(msg, ...)
	-- Only print debug messages if debug is enabled in menu
	if not (G.Menu.Visuals and G.Menu.Visuals.Debug_Mode) then
		return -- Skip debug output when debug is disabled
	end

	local success, formatted = pcall(string.format, "[Debug %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Debug] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

function Logger:Error(msg, ...)
	local success, formatted = pcall(string.format, "[Error %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Error] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

Common.Log = Logger

-- JSON support
local JSON = {}
function JSON.parse(str)
	-- Simple JSON parser for basic objects/arrays
	if not str or str == "" then
		return nil
	end

	-- Remove whitespace
	str = str:gsub("%s+", "")

	-- Handle simple object
	if str:match("^{.-}$") then
		local result = {}
		for k, v in str:gmatch('"([^"]+)":([^,}]+)') do
			if v:match('^".*"$') then
				result[k] = v:sub(2, -2) -- Remove quotes
			elseif v == "true" then
				result[k] = true
			elseif v == "false" then
				result[k] = false
			elseif tonumber(v) then
				result[k] = tonumber(v)
			end
		end
		return result
	end

	return nil
end

function JSON.stringify(obj)
	if type(obj) ~= "table" then
		return tostring(obj)
	end

	local parts = {}
	for k, v in pairs(obj) do
		local key = '"' .. tostring(k) .. '"'
		local value
		if type(v) == "string" then
			value = '"' .. v .. '"'
		elseif type(v) == "boolean" then
			value = tostring(v)
		else
			value = tostring(v)
		end
		table.insert(parts, key .. ":" .. value)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

Common.JSON = JSON
local vectorDivide = vector.Divide

--- Normalize vector using in-place :Normalize() (fastest method)
function Common.Normalize(vec)
	return vector.Divide(vec, vec:Length()) -- Return the normalized vector
end

-- Arrow line drawing function (moved from Visuals.lua and ISWalkable.lua)
function Common.DrawArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	assert(start_pos and end_pos, "Common.DrawArrowLine: start_pos and end_pos are required")
	assert(
		arrowhead_length and arrowhead_width,
		"Common.DrawArrowLine: arrowhead_length and arrowhead_width are required"
	)

	-- If invert is true, swap start_pos and end_pos
	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	-- Calculate direction from start to end
	local direction = end_pos - start_pos
	local direction_length = direction:Length()

	-- Skip drawing if positions are identical (valid case when waypoints overlap)
	if direction_length == 0 then
		return
	end

	-- Normalize the direction vector safely
	local normalized_direction = direction / direction_length

	-- Calculate the arrow base position by moving back from end_pos in the direction of start_pos
	local arrow_base = end_pos - normalized_direction * arrowhead_length

	-- Calculate the perpendicular vector for the arrow width
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	-- Convert world positions to screen positions
	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	-- Only draw if all screen positions are valid
	if w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2 then
		-- Set color before drawing
		draw.Color(255, 255, 255, 255) -- White for arrows

		-- Draw the line from start to the base of the arrow (not all the way to the end)
		draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])

		-- Draw the sides of the arrowhead
		draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
		draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])

		-- Optionally, draw the base of the arrowhead to close it
		draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
	end
end

function Common.VectorToString(vec)
	if not vec then
		return "nil"
	end
	return string.format("(%.1f, %.1f, %.1f)", vec.x, vec.y, vec.z)
end

-- Distance helpers (legacy compatibility - use Distance module for new code)
function Common.Distance2D(a, b)
	return (a - b):Length2D()
end

function Common.Distance3D(a, b)
	return (a - b):Length()
end

-- Dynamic hull size functions (access via Common for consistency)
function Common.GetPlayerHull()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		-- Fallback to hardcoded values if no player
		return {
			Min = Vector3(-24, -24, 0),
			Max = Vector3(24, 24, 82),
		}
	end

	-- Get dynamic hull size from player
	return {
		Min = pLocal:GetPropVector("m_vecMins") or Vector3(-24, -24, 0),
		Max = pLocal:GetPropVector("m_vecMaxs") or Vector3(24, 24, 82),
	}
end

function Common.GetHullMin()
	return Common.GetPlayerHull().Min
end

function Common.GetHullMax()
	return Common.GetPlayerHull().Max
end

-- Trace hull utilities (centralized for consistency)
Common.Trace = {}

function Common.Trace.Hull(startPos, endPos, hullMin, hullMax, mask, shouldHitEntity)
	assert(startPos and endPos, "Trace.Hull: startPos and endPos are required")
	assert(hullMin and hullMax, "Trace.Hull: hullMin and hullMax are required")

	local mask = mask or MASK_PLAYERSOLID
	local shouldHitEntity = shouldHitEntity or function(entity)
		return entity ~= entities.GetLocalPlayer()
	end

	return engine.TraceHull(startPos, endPos, hullMin, hullMax, mask, shouldHitEntity)
end

function Common.Trace.PlayerHull(startPos, endPos, shouldHitEntity)
	local hull = Common.GetPlayerHull()
	return Common.Trace.Hull(startPos, endPos, hull.Min, hull.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

-- Drawing utilities (centralized for consistency)
Common.Drawing = {}

function Common.Drawing.SetColor(r, g, b, a)
	draw.Color(r, g, b, a)
end

function Common.Drawing.DrawLine(x1, y1, x2, y2)
	draw.Line(x1, y1, x2, y2)
end

function Common.Drawing.WorldToScreen(worldPos)
	return client.WorldToScreen(worldPos)
end

function Common.Drawing.Draw3DBox(size, pos)
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
		local screenPos = Common.Drawing.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			Common.Drawing.DrawLine(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

-- Dynamic values cache (updated periodically to avoid repeated cvar calls)
Common.Dynamic = {
	LastUpdate = 0,
	UpdateInterval = 1.0, -- Update every second
	Values = {},
}

function Common.Dynamic.Update()
	local currentTime = globals.RealTime()
	if currentTime - Common.Dynamic.LastUpdate < Common.Dynamic.UpdateInterval then
		return -- Not time to update yet
	end

	Common.Dynamic.LastUpdate = currentTime

	-- Update dynamic values from cvars and player properties
	local pLocal = entities.GetLocalPlayer()
	if pLocal then
		Common.Dynamic.Values.MaxSpeed = pLocal:GetPropFloat("m_flMaxspeed") or 450
		Common.Dynamic.Values.StepSize = pLocal:GetPropFloat("localdata", "m_flStepSize") or 18
		Common.Dynamic.Values.HullMin = pLocal:GetPropVector("m_vecMins") or Vector3(-24, -24, 0)
		Common.Dynamic.Values.HullMax = pLocal:GetPropVector("m_vecMaxs") or Vector3(24, 24, 82)
	end

	Common.Dynamic.Values.Gravity = client.GetConVar("sv_gravity") or 800
	Common.Dynamic.Values.TickInterval = globals.TickInterval()
end

function Common.Dynamic.GetMaxSpeed()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.MaxSpeed or 450
end

function Common.Dynamic.GetStepSize()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.StepSize or 18
end

function Common.Dynamic.GetGravity()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.Gravity or 800
end

function Common.Dynamic.GetTickInterval()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.TickInterval or (1 / 66.67)
end

function Common.Dynamic.GetHullMin()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.HullMin or Vector3(-24, -24, 0)
end

function Common.Dynamic.GetHullMax()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.HullMax or Vector3(24, 24, 82)
end

-- Performance optimization utilities
Common.Cache = {}
local cacheStorage = {} -- Separate storage to avoid polluting Cache namespace

function Common.Cache.GetOrCompute(key, computeFunc, ttl)
	local currentTime = globals.RealTime()
	local cached = cacheStorage[key]

	if cached and (currentTime - cached.time) < (ttl or 1.0) then
		return cached.value
	end

	local value = computeFunc()
	cacheStorage[key] = { value = value, time = currentTime }
	return value
end

function Common.Cache.Clear()
	cacheStorage = {} -- Clear the storage, not the module table
end

-- Optimized math operations
function Common.Math.Clamp(value, min, max)
	return math.max(min, math.min(max, value))
end

function Common.Math.DistanceSquared(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Debug logging wrapper (deprecated - Logger:Debug now handles menu check automatically)
function Common.DebugLog(level, ...)
	if G.Menu.Visuals and G.Menu.Visuals.Debug_Mode then
		Common.Log[level](...)
	end
end

--- Vector normalization test suite - tries EVERY possible method
function Common.TestVectorNormalize()
	print("[Common] ============================================")
	print("[Common] TESTING ALL VECTOR NORMALIZATION METHODS")
	print("[Common] ============================================")

	local testVec = Vector3(3, 4, 0)
	local originalLen = testVec:Length()
	print(
		string.format(
			"[Common] Test vector: (%.1f, %.1f, %.1f), Length: %.1f",
			testVec.x,
			testVec.y,
			testVec.z,
			originalLen
		)
	)
	print("")

	-- Method 1: vector.Normalize() library function (from docs)
	print("[Common] Method 1: vector.Normalize(vec) - Library function")
	local m1_vec = Vector3(3, 4, 0)
	local success1, result1 = pcall(function()
		return vector.Normalize(m1_vec)
	end)
	if success1 then
		print(
			string.format(
				"  SUCCESS! Return: (%.3f, %.3f, %.3f), Length: %.3f",
				result1.x,
				result1.y,
				result1.z,
				result1:Length()
			)
		)
	else
		print("  FAILED: " .. tostring(result1))
	end
	print("")

	-- Method 1b: vector.normalize() lowercase
	print("[Common] Method 1b: vector.normalize(vec) - Library function lowercase")
	local m1b_vec = Vector3(3, 4, 0)
	local success1b, result1b = pcall(function()
		return vector.normalize(m1b_vec)
	end)
	if success1b then
		print(
			string.format(
				"  SUCCESS! Return: (%.3f, %.3f, %.3f), Length: %.3f",
				result1b.x,
				result1b.y,
				result1b.z,
				result1b:Length()
			)
		)
	else
		print("  FAILED: " .. tostring(result1b))
	end
	print("")

	-- Method 2: vec:Normalize() instance method (from docs)
	print("[Common] Method 2: vec:Normalize() - Instance method (modifies in-place)")
	local m2_vec = Vector3(3, 4, 0)
	local success2, result2 = pcall(function()
		return m2_vec:Normalize()
	end)
	if success2 then
		print(
			string.format(
				"  Called successfully, vec now: (%.3f, %.3f, %.3f), Length: %.3f",
				m2_vec.x,
				m2_vec.y,
				m2_vec.z,
				m2_vec:Length()
			)
		)
		print(string.format("  Return value: %s (type: %s)", tostring(result2), type(result2)))
	else
		print("  FAILED: " .. tostring(result2))
	end
	print("")

	-- Method 2b: vec:normalize() lowercase
	print("[Common] Method 2b: vec:normalize() - Instance method lowercase")
	local m2b_vec = Vector3(3, 4, 0)
	local success2b, result2b = pcall(function()
		return m2b_vec:normalize()
	end)
	if success2b then
		print(
			string.format(
				"  Called successfully, vec now: (%.3f, %.3f, %.3f), Length: %.3f",
				m2b_vec.x,
				m2b_vec.y,
				m2b_vec.z,
				m2b_vec:Length()
			)
		)
		print(string.format("  Return value: %s (type: %s)", tostring(result2b), type(result2b)))
	else
		print("  FAILED: " .. tostring(result2b))
	end
	print("")

	-- Method 2c: vec:Normalize() like Freecam.lua (explicit test)
	print("[Common] Method 2c: vec:Normalize() - Like Freecam.lua pattern")
	local m2c_vec = Vector3(3, 4, 0)
	local success2c, result2c = pcall(function()
		m2c_vec:Normalize() -- This is what Freecam.lua does
		return m2c_vec -- Return the modified vector
	end)
	if success2c then
		print(
			string.format(
				"  Called successfully, vec now: (%.3f, %.3f, %.3f), Length: %.3f",
				m2c_vec.x,
				m2c_vec.y,
				m2c_vec.z,
				m2c_vec:Length()
			)
		)
		print(string.format("  Return value: %s (type: %s)", tostring(result2c), type(result2c)))
	else
		print("  FAILED: " .. tostring(result2c))
	end
	print("")

	-- Method 3: Vector3.Normalize() static method (unlikely but test)
	print("[Common] Method 3: Vector3.Normalize(vec) - Static method")
	local m3_vec = Vector3(3, 4, 0)
	local success3, result3 = pcall(function()
		return Vector3.Normalize(m3_vec)
	end)
	if success3 then
		print(
			string.format(
				"  SUCCESS! Return: (%.3f, %.3f, %.3f), Length: %.3f",
				result3.x,
				result3.y,
				result3.z,
				result3:Length()
			)
		)
	else
		print("  FAILED: " .. tostring(result3))
	end
	print("")

	-- Method 4: Division approach (known working)
	print("[Common] Method 4: vec / vec:Length() - Division")
	local m4_vec = Vector3(3, 4, 0)
	local success4, result4 = pcall(function()
		return m4_vec / m4_vec:Length()
	end)
	if success4 then
		print(
			string.format(
				"  SUCCESS! Result: (%.3f, %.3f, %.3f), Length: %.3f",
				result4.x,
				result4.y,
				result4.z,
				result4:Length()
			)
		)
	else
		print("  FAILED: " .. tostring(result4))
	end
	print("")

	-- Method 5: Inline division with new vector
	print("[Common] Method 5: Vector3(a,b,c) / length - Inline with constructor")
	local success5, result5 = pcall(function()
		local v = Vector3(3, 4, 0)
		return v / 5.0
	end)
	if success5 then
		print(
			string.format(
				"  SUCCESS! Result: (%.3f, %.3f, %.3f), Length: %.3f",
				result5.x,
				result5.y,
				result5.z,
				result5:Length()
			)
		)
	else
		print("  FAILED: " .. tostring(result5))
	end
	print("")

	-- Method 6: Using vector.Divide if exists
	print("[Common] Method 6: vector.Divide(vec, scalar) - Library divide")
	local m6_vec = Vector3(3, 4, 0)
	local success6, result6 = pcall(function()
		return vector.Divide(m6_vec, 5.0)
	end)
	if success6 then
		print(
			string.format(
				"  SUCCESS! Result: (%.3f, %.3f, %.3f), Length: %.3f",
				result6.x,
				result6.y,
				result6.z,
				result6:Length()
			)
		)
	else
		print("  FAILED: " .. tostring(result6))
	end
	print("")

	-- Method 7: Check what vector library actually has
	print("[Common] Method 7: Inspect vector library contents")
	local success7, result7 = pcall(function()
		local keys = {}
		for k, v in pairs(vector) do
			table.insert(keys, k)
		end
		return table.concat(keys, ", ")
	end)
	if success7 then
		print("  Vector library functions: " .. tostring(result7))
	else
		print("  FAILED: " .. tostring(result7))
	end
	print("")

	print("[Common] ============================================")
	print("[Common] TEST COMPLETE")
	print("[Common] ============================================")
end

-- Run test on load to verify behavior
Common.TestVectorNormalize()

return Common
