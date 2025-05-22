---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1.0, "LNXlib version is too old, please update it!")

Common.Lib = Lib
Common.Notify = Lib.UI.Notify
Common.TF2 = Common.Lib.TF2

Common.Log = Lib.Utils.Logger
Common.Math, Common.Conversion = Common.Lib.Utils.Math, Common.Lib.Utils.Conversion
Common.WPlayer, Common.PR = Common.TF2.WPlayer, Common.TF2.PlayerResource
Common.Helpers = Common.TF2.Helpers

Common.Notify = Lib.UI.Notify
Common.Json = require("Lmaobot.Utils.Json") -- Require Json.lua directly

local G = require("Lmaobot.Utils.Globals")
local IsWalkable = require("Lmaobot.Modules.IsWalkable")

function Common.Normalize(vec)
    local length = math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
    return Vector3(vec.x / length, vec.y / length, vec.z / length)
end

function Common.horizontal_manhattan_distance(pos1, pos2)
    return math.abs(pos1.x - pos2.x) + math.abs(pos1.y - pos2.y)
end
function Common.AddCurrentTask(taskKey)
    local taskPriority = G.Tasks[taskKey]
    if taskPriority and not G.Current_Tasks[taskKey] then
        G.Current_Tasks[taskKey] = taskPriority
    end
end

function Common.RemoveCurrentTask(taskKey)
    if G.Current_Tasks[taskKey] then
        G.Current_Tasks[taskKey] = nil
    end
end

function Common.GetHighestPriorityTask()
    local highestPriorityTaskKey = nil
    local highestPriority = math.huge

    for taskKey, priority in pairs(G.Current_Tasks) do
        if priority < highestPriority then
            highestPriority = priority
            highestPriorityTaskKey = taskKey
        end
    end

    return highestPriorityTaskKey or "None"
end

client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
--[[ Callbacks ]]
local function OnUnload() -- Called when the script is unloaded
    client.Command('play "ui/buttonclickrelease"', true) -- Play the "buttonclickrelease" sound
end

callbacks.Unregister("Unload", "CD_Unload")
callbacks.Register("Unload", "CD_Unload", OnUnload)

return Common