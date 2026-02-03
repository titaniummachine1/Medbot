--[[
Node Skipper - Per-tick node skipping with virtual waypoints
Runs every tick:
1. Smart skip: If player closer to next node than current node is, skip current
2. Forward skip: Check if can skip to further nodes using isNavigable
3. Virtual waypoints: Instead of discarding nodes, create interpolated waypoints
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local isNavigable = require("MedBot.Navigation.isWalkable.isNavigable")
local Node = require("MedBot.Navigation.Node")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

local VIRTUAL_WAYPOINT_SPACING = 150

function NodeSkipper.Reset()
	G.Navigation.virtualWaypoints = nil
end

local function createVirtualWaypoints(startPos, endPos, skippedNodes)
	assert(startPos, "createVirtualWaypoints: startPos missing")
	assert(endPos, "createVirtualWaypoints: endPos missing")
	assert(skippedNodes, "createVirtualWaypoints: skippedNodes missing")

	local waypoints = {}
	local totalDist = Common.Distance3D(startPos, endPos)

	if totalDist < 1 then
		return waypoints
	end

	local dir = (endPos - startPos) / totalDist

	local numSkipped = #skippedNodes
	if numSkipped == 0 then
		return waypoints
	end

	for i = 1, numSkipped do
		local skippedNode = skippedNodes[i]
		assert(skippedNode and skippedNode.pos, "createVirtualWaypoints: invalid skipped node")

		local distToSkipped = Common.Distance3D(startPos, skippedNode.pos)
		local ratio = distToSkipped / totalDist

		local virtualPos = startPos + dir * (ratio * totalDist)

		table.insert(waypoints, {
			pos = virtualPos,
			virtual = true,
			originalNode = skippedNode,
		})
	end

	return waypoints
end

function NodeSkipper.CheckSmartSkip(playerPos)
	assert(playerPos, "CheckSmartSkip: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not (currentNode and currentNode.pos and nextNode and nextNode.pos) then
		Log:Debug("Smart skip: invalid nodes")
		return false
	end

	local distPlayerToNext = Common.Distance3D(playerPos, nextNode.pos)
	local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

	Log:Debug(
		"Smart skip check: player->next=%.0f current->next=%.0f (nodes: %s -> %s)",
		distPlayerToNext,
		distCurrentToNext,
		tostring(currentNode.id),
		tostring(nextNode.id)
	)

	if distPlayerToNext < distCurrentToNext then
		Log:Debug("Smart skip: SKIPPING current node (player closer to next)")
		table.remove(path, 1)
		G.Navigation.currentNodeIndex = 1
		return true
	end

	return false
end

function NodeSkipper.CheckForwardSkip(playerPos)
	assert(playerPos, "CheckForwardSkip: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 3 then
		return false
	end

	local currentNode = path[1]
	if not (currentNode and currentNode.pos) then
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		Log:Debug("Forward skip: GetAreaAtPosition returned nil")
		return false
	end

	local furthestSkipIdx = 1
	local skippedNodes = {}

	for i = 2, math.min(#path, 10) do
		local targetNode = path[i]
		if not (targetNode and targetNode.pos) then
			Log:Debug("Forward skip: path[%d] invalid", i)
			break
		end

		local success, canSkip = pcall(isNavigable.CanSkip, playerPos, targetNode.pos, currentArea, false)

		if not success then
			Log:Debug("Forward skip: isNavigable.CanSkip crashed for path[%d]: %s", i, tostring(canSkip))
			break
		end

		if canSkip then
			furthestSkipIdx = i
			Log:Debug("Can skip to path[%d] (node %s)", i, tostring(targetNode.id))
		else
			Log:Debug("Cannot skip to path[%d] (node %s) - blocked", i, tostring(targetNode.id))
			break
		end
	end

	if furthestSkipIdx > 1 then
		for i = 1, furthestSkipIdx - 1 do
			table.insert(skippedNodes, path[1])
			table.remove(path, 1)
		end

		local targetNode = path[1]
		assert(targetNode and targetNode.pos, "CheckForwardSkip: target node invalid after skip")

		local virtuals = createVirtualWaypoints(playerPos, targetNode.pos, skippedNodes)
		G.Navigation.virtualWaypoints = virtuals

		Log:Debug("Forward skip: removed %d nodes, created %d virtual waypoints", #skippedNodes, #virtuals)

		G.Navigation.currentNodeIndex = 1
		return true
	end

	Log:Debug("Forward skip: no nodes skipped (furthest=%d)", furthestSkipIdx)
	return false
end

function NodeSkipper.Tick(playerPos)
	assert(playerPos, "Tick: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
		return
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return
	end

	local smartSkipped = NodeSkipper.CheckSmartSkip(playerPos)
	if smartSkipped then
		Log:Debug("Smart skip executed - skipping forward skip this tick")
		return
	end

	local forwardSkipped = NodeSkipper.CheckForwardSkip(playerPos)
	if not forwardSkipped then
		Log:Debug("Forward skip failed or found no skippable nodes")
	end
end

return NodeSkipper
