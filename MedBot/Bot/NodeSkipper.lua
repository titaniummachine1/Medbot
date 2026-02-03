--[[
Node Skipper - Simple per-tick node skipping
Runs every tick: Find furthest node you can walk to directly and skip to it
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

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return
	end

	local furthestIdx = 1

	for i = 2, math.min(#path, 10) do
		local targetNode = path[i]
		if not (targetNode and targetNode.pos) then
			break
		end

		local success, canSkip = pcall(isNavigable.CanSkip, playerPos, targetNode.pos, currentArea, false)

		if success and canSkip then
			furthestIdx = i
		else
			break
		end
	end

	if furthestIdx > 1 then
		local skippedCount = furthestIdx - 1
		local targetNode = path[furthestIdx]

		for i = 1, skippedCount do
			table.remove(path, 1)
		end

		Log:Info("Skipped %d nodes, now at node %s", skippedCount, tostring(targetNode.id))

		G.Navigation.currentNodeIndex = 1
	end
end

return NodeSkipper
