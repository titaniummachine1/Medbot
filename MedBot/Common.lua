---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

--[[ Imports ]]
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
Common.Json = require("MedBot.Utils.Json")

-- Globals
local G = require("MedBot.Utils.Globals")

-- FastPlayers and WrappedPlayer utilities
local FastPlayers = require("MedBot.Utils.FastPlayers")
Common.FastPlayers = FastPlayers

--[[ Utility Functions ]]
--- Normalize a vector
---@param vec Vector3
---@return Vector3
function Common.Normalize(vec)
	return vec / vec:Length()
end

--- Manhattan distance on XY plane
---@param pos1 Vector3
---@param pos2 Vector3
---@return number
function Common.horizontal_manhattan_distance(pos1, pos2)
	return math.abs(pos1.x - pos2.x) + math.abs(pos1.y - pos2.y)
end

--- Add a task to current tasks if not present
---@param taskKey string
function Common.AddCurrentTask(taskKey)
	local priority = G.Tasks[taskKey]
	if priority and not G.Current_Tasks[taskKey] then
		G.Current_Tasks[taskKey] = priority
	end
end

--- Remove a task from current tasks
---@param taskKey string
function Common.RemoveCurrentTask(taskKey)
	G.Current_Tasks[taskKey] = nil
end

--- Get the highest priority task
---@return string
function Common.GetHighestPriorityTask()
	local bestKey, bestPri = nil, math.huge
	for key, pri in pairs(G.Current_Tasks) do
		if pri < bestPri then
			bestPri = pri
			bestKey = key
		end
	end
	return bestKey or "None"
end

--- Check if entity is a valid player
---@param entity Entity The entity to check
---@param checkFriend boolean? Unused; reserved for future friend filtering
---@param checkDormant boolean? Skip if true and entity is dormant
---@param skipEnt Entity? Skip this specific entity (e.g., local player)
---@return boolean
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEnt)
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return false
	end
	if checkDormant and entity:IsDormant() then
		return false
	end
	if skipEnt and entity == skipEnt then
		return false
	end
	return true
end

-- Play UI sound on load and unload
client.Command('play "ui/buttonclickrelease"', true)
local function OnUnload()
        ProfilerBeginSystem("common_unload")

        client.Command('play "ui/buttonclickrelease"', true)

        ProfilerEndSystem()
end
callbacks.Unregister("Unload", "Common_OnUnload")
callbacks.Register("Unload", "Common_OnUnload", OnUnload)

return Common
