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
	if not path or #path < 3 then
		return
	end

	local skipTarget = path[3]
	if not (skipTarget and skipTarget.pos) then
		return
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return
	end

	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, skipTarget.pos, currentArea, false)

	if success and canSkip then
		table.remove(path, 1)
		table.remove(path, 1)

		Log:Info("Skipped 2 nodes, now at node %s", tostring(skipTarget.id))
		G.Navigation.currentNodeIndex = 1
	end
end

return NodeSkipper
