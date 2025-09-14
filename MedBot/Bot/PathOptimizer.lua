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

-- Skip entire path if goal is directly reachable
function PathOptimizer.skipToGoalIfWalkable(origin, goalPos, path)
	-- Check menu setting first
	if not G.Menu.Main.Skip_Nodes then
		return false
	end

	local DEADZONE = 24 -- units
	if not goalPos or not origin then
		return false
	end
	local dist = Common.Distance3D(goalPos, origin)
	if dist < DEADZONE then
		Navigation.ClearPath()
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		return true
	end
	-- Only skip if we have a multi-node path AND goal is directly reachable
	-- Never skip on CTF maps to avoid beelining to the wrong flag area
	local mapName = engine.GetMapName():lower()
	if path and #path > 1 and not mapName:find("ctf_") then
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if ISWalkable.PathCached(origin, goalPos, walkMode) then
			Navigation.ClearPath()
			-- Set a direct path with just the goal as the node
			G.Navigation.path = { { pos = goalPos } }
			G.lastPathfindingTick = 0
			Log:Info("Cleared complex path, moving directly to goal with %s mode (distance: %.1f)", walkMode, dist)
			return true
		end
	end
	return false
end

-- Skip if next node is closer to player than current node and walkable
function PathOptimizer.skipIfNextCloserAndWalkable(origin, path)
	-- Check menu setting first
	if not G.Menu.Main.Skip_Nodes then
		return false
	end

	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not (currentNode and nextNode and currentNode.pos and nextNode.pos) then
		return false
	end

	-- Check distances
	local distCurrent = Common.Distance3D(currentNode.pos, origin)
	local distNext = Common.Distance3D(nextNode.pos, origin)

	-- Only skip if next node is actually closer than current node
	if distNext >= distCurrent then
		return false
	end

	-- Check if we can walk directly to the next node
	local walkMode = G.Menu.Main.WalkableMode or "Smooth"
	if ISWalkable.PathCached(origin, nextNode.pos, walkMode) then
		Log:Debug(
			"Next node %d is closer (%.1f < %.1f) and walkable, skipping current node %d",
			nextNode.id or 0,
			distNext,
			distCurrent,
			currentNode.id or 0
		)

		-- Skip to next node
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()
		return true
	end

	return false
end

-- Optimize path by trying different skip strategies with work manager
function PathOptimizer.optimize(origin, path, goalPos)
	-- DEBUG: Log current menu state
	Log:Debug("PathOptimizer.optimize called - Skip_Nodes = %s", tostring(G.Menu.Main.Skip_Nodes))

	if not G.Menu.Main.Skip_Nodes or not path or #path <= 1 then
		Log:Debug("PathOptimizer.optimize: Skipping optimization (menu disabled or invalid path)")
		return false
	end

	Log:Debug("PathOptimizer.optimize: Starting optimization (menu enabled)")

	-- Try to skip directly to the goal if we have a complex path
	if goalPos and #path > 1 then
		if PathOptimizer.skipToGoalIfWalkable(origin, goalPos, path) then
			Log:Debug("PathOptimizer.optimize: Skipped to goal")
			return true
		end
	end

	-- Use work manager for node skipping cooldown (same as unstuck logic)
	if not WorkManager.attemptWork(3, "node_skip") then -- 3 tick cooldown (~50ms)
		Log:Debug("PathOptimizer.optimize: Work manager blocked")
		return false
	end

	-- Try the simple algorithm: skip if next node is closer and walkable
	if PathOptimizer.skipIfNextCloserAndWalkable(origin, path) then
		Log:Debug("PathOptimizer.optimize: Skipped to closer node")
		return true
	end

	Log:Debug("PathOptimizer.optimize: No optimization performed")
	return false
end

return PathOptimizer
