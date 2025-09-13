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
Common.Log = Lib.Utils.Logger
Common.Math = Lib.Utils.Math
Common.Conversion = Lib.Utils.Conversion
Common.WPlayer = Lib.TF2.WPlayer
Common.PR = Lib.TF2.PlayerResource
Common.Helpers = Lib.TF2.Helpers

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

-- Vector helpers
function Common.Normalize(vec)
	return vec / vec:Length()
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

return Common
