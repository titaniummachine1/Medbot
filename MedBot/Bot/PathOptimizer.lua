--[[
Path Optimizer - Prevents rubber-banding with smart windowing
Handles node skipping and direct path optimization
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local ISWalkable = require("MedBot.Navigation.ISWalkable")
local WorkManager = require("MedBot.WorkManager")

local Log = Common.Log.new("PathOptimizer")
local PathOptimizer = {}

-- Simplified path optimization - single predictable algorithm
function PathOptimizer.optimize(origin, path, goalPos)
	-- Early exit if optimization disabled or invalid path
	if not G.Menu.Main.Skip_Nodes or not path or #path <= 1 then
		return false
	end

	-- Use work manager to throttle optimization attempts
	if not WorkManager.attemptWork(5, "path_optimize") then -- 5 tick cooldown (~83ms)
		return false
	end

	-- Only optimize if we have at least 3 nodes (current + next + goal)
	if #path < 3 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not (currentNode and nextNode and currentNode.pos and nextNode.pos) then
		return false
	end

	-- Simple optimization: skip current node if next is closer and walkable
	local distToCurrent = Common.Distance3D(origin, currentNode.pos)
	local distToNext = Common.Distance3D(origin, nextNode.pos)

	-- Only skip if next node is significantly closer (at least 20% closer)
	if distToNext < (distToCurrent * 0.8) then
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if ISWalkable.PathCached(origin, nextNode.pos, walkMode) then
			Navigation.RemoveCurrentNode()
			Navigation.ResetTickTimer()
			Log:Debug("Skipped node - next closer by %.1f units", distToCurrent - distToNext)
			return true
		end
	end

	return false
end

return PathOptimizer
