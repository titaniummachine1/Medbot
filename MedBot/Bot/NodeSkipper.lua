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

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

function NodeSkipper.Reset() end

function NodeSkipper.Tick(playerPos)
	assert(playerPos, "Tick: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
		return
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return
	end

	local maxSkipRange = G.Menu.Main.MaxSkipRange or 500
	local maxNodesToSkip = G.Menu.Main.MaxNodesToSkip or 3

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return
	end

	local nodesSkipped = 0
	local furthestIdx = 1

	-- Check nodes ahead up to maxNodesToSkip + 1 (since we need to check path[2] to path[max+1])
	for i = 2, math.min(#path, maxNodesToSkip + 1) do
		local targetNode = path[i]
		if not (targetNode and targetNode.pos) then
			break
		end

		-- Check distance limit
		local distToTarget = Common.Distance3D(playerPos, targetNode.pos)
		if distToTarget > maxSkipRange then
			Log:Debug(
				"Skip target %s at %.0f units exceeds max range %.0f",
				tostring(targetNode.id),
				distToTarget,
				maxSkipRange
			)
			break
		end

		-- Check if walkable
		local success, canSkip = pcall(isNavigable.CanSkip, playerPos, targetNode.pos, currentArea, false)

		if success and canSkip then
			furthestIdx = i
			nodesSkipped = nodesSkipped + 1
			Log:Debug("Can skip to node %s (%d/%d)", tostring(targetNode.id), nodesSkipped, maxNodesToSkip)
		else
			-- Blocked - stop checking further
			break
		end
	end

	-- Remove skipped nodes and add to path history (as if we reached them normally)
	if furthestIdx > 1 then
		local targetNode = path[furthestIdx]

		-- Initialize path history if needed
		G.Navigation.pathHistory = G.Navigation.pathHistory or {}

		-- Remove nodes and add to history (like Navigation.RemoveCurrentNode does)
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

		Log:Info(
			"Skipped %d nodes (max %d, range %d), now at node %s",
			nodesSkipped,
			maxNodesToSkip,
			maxSkipRange,
			tostring(targetNode.id)
		)
		G.Navigation.currentNodeIndex = 1
	end
end

return NodeSkipper
