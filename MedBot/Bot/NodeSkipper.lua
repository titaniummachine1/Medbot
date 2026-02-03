--[[
Node Skipper - Per-tick node skipping with menu-controlled limits
Uses:
- G.Menu.Main.MaxSkipRange: max distance to skip (default 500)
- G.Menu.Main.MaxNodesToSkip: max nodes per tick (default 3)
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local isNavigable = require("MedBot.Navigation.isWalkable.isNavigable")
local Node = require("MedBot.Navigation.Node")
local WorkManager = require("MedBot.WorkManager")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

function NodeSkipper.Reset() end

function NodeSkipper.Tick(playerPos)
	assert(playerPos, "Tick: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	-- Check stuck cooldown (prevent skipping when stuck)
	if not WorkManager.attemptWork(1, "node_skipping") then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local targetNode = path[2]
	local nextTargetNode = path[3]

	-- SMART SKIP: Check if player already passed the current target (path[2])
	-- We compare distance to next target (path[3])
	if nextTargetNode and nextTargetNode.pos and targetNode and targetNode.pos then
		local distPlayerToNext = Common.Distance3D(playerPos, nextTargetNode.pos)
		local distTargetToNext = Common.Distance3D(targetNode.pos, nextTargetNode.pos)

		if distPlayerToNext < distTargetToNext then
			-- Player is closer to path[3] than path[2] is to path[3] - we passed path[2]
			-- Remove path[2] (current target) so we target path[3]
			local missedNode = table.remove(path, 2)

			-- Add to history
			G.Navigation.pathHistory = G.Navigation.pathHistory or {}
			table.insert(G.Navigation.pathHistory, 1, missedNode)
			while #G.Navigation.pathHistory > 32 do
				table.remove(G.Navigation.pathHistory)
			end

			-- Track when we last skipped
			G.Navigation.lastSkipTick = globals.TickCount()

			Log:Info(
				"MISSED waypoint %s (player closer to next), skipping to %s",
				tostring(missedNode.id),
				tostring(nextTargetNode.id)
			)
			G.Navigation.currentNodeIndex = 1
			return true
		end
	end

	-- FORWARD SKIP: Check if we can skip ahead multiple nodes
	-- Only skip if we can reach path[3] or further (bypassing at least 2 nodes)
	-- We start checking from path[3]. If reachable, we can skip path[2].
	if #path < 3 then
		return false
	end

	local maxSkipRange = G.Menu.Main.MaxSkipRange or 500
	local maxNodesToSkip = G.Menu.Main.MaxNodesToSkip or 3

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local furthestIdx = 1

	-- Start checking from path[3] (skip path[2] and potentially more)
	-- We want to go from path[1] (current) -> path[i] (new target)
	-- Actually, we check if we can walk from Player -> path[i]
	for i = 3, math.min(#path, maxNodesToSkip + 2) do -- +2 because we start at 3
		local checkNode = path[i]
		if not (checkNode and checkNode.pos) then
			break
		end

		-- Check distance limit
		local distToTarget = Common.Distance3D(playerPos, checkNode.pos)
		if distToTarget > maxSkipRange then
			break
		end

		-- Check if we can walk directly to this node (bypassing intermediate nodes)
		local success, canSkip = pcall(isNavigable.CanSkip, playerPos, checkNode.pos, currentArea, false)

		if success and canSkip then
			furthestIdx = i
			-- GREEDY: Keep checking further nodes to maximize skip distance
		else
			-- Blocked - but continue checking further nodes (maybe we can reach path[i+1] even if path[i] is blocked)
		end
	end

	-- Apply forward skip only if we can bypass at least 1 node (reach path[3] or further)
	if furthestIdx >= 3 then
		local targetNode = path[furthestIdx]

		-- Initialize path history if needed
		G.Navigation.pathHistory = G.Navigation.pathHistory or {}

		-- Remove nodes BETWEEN path[1] and path[furthestIdx]
		-- We want to remove path[2], path[3] ... path[furthestIdx-1]
		-- So we remove 'furthestIdx - 2' nodes starting at index 2
		local numToRemove = furthestIdx - 2
		for i = 1, numToRemove do
			local skipped = table.remove(path, 2)
			if skipped then
				table.insert(G.Navigation.pathHistory, 1, skipped)
			end
		end

		-- Bound history size
		while #G.Navigation.pathHistory > 32 do
			table.remove(G.Navigation.pathHistory)
		end

		-- Track when we last skipped
		G.Navigation.lastSkipTick = globals.TickCount()

		Log:Info(
			"FORWARD SKIP: bypassed %d nodes (direct path to %s, max %d, range %.0f)",
			numToRemove,
			tostring(targetNode.id),
			maxNodesToSkip,
			maxSkipRange
		)
		G.Navigation.currentNodeIndex = 1
		return true
	end

	return false
end

return NodeSkipper
