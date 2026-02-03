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
	if not (currentNode and currentNode.pos) then
		return false
	end

	local targetNode = nil
	for i = 2, math.min(#path, 5) do
		if path[i] and path[i].pos and not path[i].isDoor then
			targetNode = path[i]
			break
		end
	end

	if not targetNode then
		return false
	end

	local distPlayerToTarget = Common.Distance3D(playerPos, targetNode.pos)
	local distCurrentToTarget = Common.Distance3D(currentNode.pos, targetNode.pos)

	if distPlayerToTarget < distCurrentToTarget then
		Log:Info(
			"Smart skip: player->target=%.0f < current->target=%.0f, SKIPPING node %s",
			distPlayerToTarget,
			distCurrentToTarget,
			tostring(currentNode.id)
		)
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
		Log:Info("Forward skip: GetAreaAtPosition returned nil - cannot determine current area")
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
			Log:Info("Forward skip: isNavigable crashed for path[%d]: %s", i, tostring(canSkip))
			break
		end

		if canSkip then
			furthestSkipIdx = i
		else
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

		Log:Info(
			"Forward skip: skipped %d nodes (up to node %s), created %d virtual waypoints",
			#skippedNodes,
			tostring(targetNode.id),
			#virtuals
		)

		G.Navigation.currentNodeIndex = 1
		return true
	end

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
		return
	end

	NodeSkipper.CheckForwardSkip(playerPos)
end

return NodeSkipper
