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
	local nextNode = path[2]

	if not (currentNode and currentNode.pos and nextNode and nextNode.pos) then
		return false
	end

	-- SMART SKIP: Check if player already passed the current waypoint
	local distPlayerToNext = Common.Distance3D(playerPos, nextNode.pos)
	local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

	if distPlayerToNext < distCurrentToNext then
		-- Player is closer to next node than current node is - we missed it
		local missedNode = table.remove(path, 1)

		-- Add to history
		G.Navigation.pathHistory = G.Navigation.pathHistory or {}
		table.insert(G.Navigation.pathHistory, 1, missedNode)
		while #G.Navigation.pathHistory > 32 do
			table.remove(G.Navigation.pathHistory)
		end

		-- Track when we last skipped
		G.Navigation.lastSkipTick = globals.TickCount()

		Log:Info(
			"MISSED waypoint %s (player closer to next), continuing to node %s",
			tostring(missedNode.id),
			tostring(nextNode.id)
		)
		G.Navigation.currentNodeIndex = 1
		return true
	end

	-- FORWARD SKIP: Check if we can skip ahead multiple nodes
	-- Only skip if we can reach path[3] or further (bypassing at least 2 nodes)
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

	-- Start checking from path[3] (skip at least 2 nodes)
	for i = 3, math.min(#path, maxNodesToSkip + 1) do
		local targetNode = path[i]
		if not (targetNode and targetNode.pos) then
			break
		end

		-- Check distance limit
		local distToTarget = Common.Distance3D(playerPos, targetNode.pos)
		if distToTarget > maxSkipRange then
			break
		end

		-- Check if we can walk directly to this node (bypassing intermediate nodes)
		local success, canSkip = pcall(isNavigable.CanSkip, playerPos, targetNode.pos, currentArea, false)

		if success and canSkip then
			furthestIdx = i
			-- GREEDY: Keep checking further nodes to maximize skip distance
		else
			-- Blocked - but continue checking further nodes (maybe we can reach path[i+1] even if path[i] is blocked)
		end
	end

	-- Apply forward skip only if we can bypass at least 2 nodes (reach path[3] or further)
	if furthestIdx >= 3 then
		local targetNode = path[furthestIdx]

		-- Initialize path history if needed
		G.Navigation.pathHistory = G.Navigation.pathHistory or {}

		-- Remove nodes and add to history
		for i = 1, furthestIdx - 1 do
			local skipped = table.remove(path, 1)
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
			furthestIdx - 1,
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
