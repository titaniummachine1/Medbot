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

local function isDoorNode(node)
	return node and not node._minX
end

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

	-- SMART SKIP: Check if player already passed the current target (path[1])
	-- We compare distance to next target (path[2])
	if currentNode and currentNode.pos and nextNode and nextNode.pos then
		-- Get current area for walkability check
		local currentArea = Node.GetAreaAtPosition(playerPos)
		if not currentArea then
			return false
		end

		local distPlayerToNext = Common.Distance3D(playerPos, nextNode.pos)
		local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

		if distPlayerToNext < distCurrentToNext then
			if isDoorNode(currentNode) or isDoorNode(nextNode) then
				Log:Debug(
					"SMART SKIP blocked: door node in segment (%s -> %s)",
					tostring(currentNode.id),
					tostring(nextNode.id)
				)
				return false
			end
			-- Player is closer to path[2] than path[1] is to path[2] - we passed path[1]
			-- BUT: Only skip if we can actually walk to nextNode from current position
			local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
			local success, canSkip = pcall(isNavigable.CanSkip, playerPos, nextNode.pos, currentArea, true, allowJump)

			if success and canSkip then
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
					"MISSED waypoint %s (player closer to next), skipping to %s",
					tostring(missedNode.id),
					tostring(nextNode.id)
				)
				G.Navigation.currentNodeIndex = 1
				return true
			else
				Log:Debug(
					"SMART SKIP blocked: Cannot walk to next node %s from current position",
					tostring(nextNode.id)
				)
				return false
			end
		end
	end

	-- FORWARD SKIP: Single check per tick (path[3] only)
	-- If we can walk directly to path[3], skip path[1] and path[2] and bail.
	if #path < 3 then
		return false
	end

	local maxSkipRange = G.Menu.Main.MaxSkipRange or 500
	local skipTarget = path[3]
	if not (skipTarget and skipTarget.pos) then
		return false
	end

	if isDoorNode(path[1]) or isDoorNode(path[2]) or isDoorNode(skipTarget) then
		Log:Debug("FORWARD SKIP blocked: door node in candidate segment")
		return false
	end

	local distToTarget = Common.Distance3D(playerPos, skipTarget.pos)
	if distToTarget > maxSkipRange then
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, skipTarget.pos, currentArea, true, allowJump)
	if not (success and canSkip) then
		return false
	end

	G.Navigation.pathHistory = G.Navigation.pathHistory or {}

	local skipped1 = table.remove(path, 1)
	if skipped1 then
		table.insert(G.Navigation.pathHistory, 1, skipped1)
	end
	local skipped2 = table.remove(path, 1)
	if skipped2 then
		table.insert(G.Navigation.pathHistory, 1, skipped2)
	end

	while #G.Navigation.pathHistory > 32 do
		table.remove(G.Navigation.pathHistory)
	end

	G.Navigation.lastSkipTick = globals.TickCount()

	Log:Info("FORWARD SKIP: bypassed 2 nodes (direct path to %s, range %.0f)", tostring(skipTarget.id), maxSkipRange)
	G.Navigation.currentNodeIndex = 1
	return true
end

return NodeSkipper
