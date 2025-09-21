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

-- Simplified path optimization - enhanced algorithms
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

	-- Algorithm 1: Closer next node skipping
	local distToCurrent = Common.Distance3D(origin, currentNode.pos)
	local distToNext = Common.Distance3D(origin, nextNode.pos)

	-- Skip if next node is closer than current (collected first node)
	if distToNext < distToCurrent then
		if ISWalkable.Path(origin, nextNode.pos) then
			Navigation.RemoveCurrentNode()
			Navigation.ResetTickTimer()
			Log:Debug("Skipped to closer next node - %.1f < %.1f units", distToNext, distToCurrent)
			return true
		else
			Log:Debug("Next node closer but not walkable - staying on current")
		end
	end

	return false
end

-- Algorithm 2: Speed penalty system for unwalkable connections
function PathOptimizer.checkSpeedPenalty(origin, currentTarget, currentNode, path)
	if not currentTarget or not currentNode or not path then
		return false
	end

	-- Check if we should run speed penalty check (every half second)
	if not WorkManager.attemptWork(33, "speed_penalty_check") then -- ~0.5s at 66fps
		return false
	end

	-- Get current player speed
	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		return false
	end

	local velocity = pLocal:EstimateAbsVelocity() or Vector3(0, 0, 0)
	local speed = velocity:Length2D()

	-- Only trigger if speed is below 50
	if speed >= 50 then
		return false
	end

	Log:Debug("Speed penalty check triggered - speed: %.1f", speed)

	-- Check if direct path to current target is walkable
	if not ISWalkable.Path(origin, currentTarget) then
		Log:Debug("Direct path to target not walkable - adding penalty to connection")

		-- Add penalty to the connection we're currently traversing
		if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
			local nextNode = path[2]
			if nextNode then
				G.CircuitBreaker.addConnectionFailure(currentNode, nextNode)
			end
		end

		-- Force repath from stuck state
		if G.StateHandler and G.StateHandler.forceRepath then
			G.StateHandler.forceRepath()
			Log:Debug("Forced repath due to unwalkable connection")
			return true
		end
	end

	return false
end

return PathOptimizer
