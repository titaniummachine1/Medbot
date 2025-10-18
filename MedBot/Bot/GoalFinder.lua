--[[
Goal Finder - Finds navigation goals based on current tasks
Handles payload, CTF, health pack, and teammate following goals
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")

local GoalFinder = {}
local Log = Common.Log.new("GoalFinder")

local function findPayloadGoal()
	-- Cache payload entities for 90 ticks (1.5 seconds) to avoid expensive entity searches
	local currentTick = globals.TickCount()
	if not G.World.payloadCacheTime or (currentTick - G.World.payloadCacheTime) > 90 then
		G.World.payloads = entities.FindByClass("CObjectCartDispenser")
		G.World.payloadCacheTime = currentTick
	end

	local pLocal = G.pLocal.entity
	for _, entity in pairs(G.World.payloads or {}) do
		if entity:IsValid() and entity:GetTeamNumber() == pLocal:GetTeamNumber() then
			local pos = entity:GetAbsOrigin()
			return Navigation.GetAreaAtPosition(pos), pos
		end
	end
end

local function findFlagGoal()
	local pLocal = G.pLocal.entity
	local myItem = pLocal:GetPropInt("m_hItem")

	-- Cache flag entities for 90 ticks (1.5 seconds) to avoid expensive entity searches
	local currentTick = globals.TickCount()
	if not G.World.flagCacheTime or (currentTick - G.World.flagCacheTime) > 90 then
		G.World.flags = entities.FindByClass("CCaptureFlag")
		G.World.flagCacheTime = currentTick
	end

	-- Throttle debug logging to avoid spam (only log every 60 ticks)
	if not G.lastFlagLogTick then
		G.lastFlagLogTick = 0
	end
	local shouldLog = (currentTick - G.lastFlagLogTick) > 60

	if shouldLog then
		Log:Debug("CTF Flag Detection: myItem=%d, playerTeam=%d", myItem, pLocal:GetTeamNumber())
		G.lastFlagLogTick = currentTick
	end

	local targetFlag = nil
	local targetPos = nil

	for _, entity in pairs(G.World.flags or {}) do
		local flagTeam = entity:GetTeamNumber()
		local myTeam = flagTeam == pLocal:GetTeamNumber()
		local pos = entity:GetAbsOrigin()

		if shouldLog then
			Log:Debug("Flag found: team=%d, isMyTeam=%s, pos=%s", flagTeam, tostring(myTeam), tostring(pos))
		end

		-- If carrying enemy intel (myItem > 0), go to our team's capture point
		-- If not carrying intel (myItem <= 0), go get the enemy intel
		if (myItem > 0 and myTeam) or (myItem <= 0 and not myTeam) then
			targetFlag = entity
			targetPos = pos
			if shouldLog then
				Log:Info(
					"CTF Goal: %s (carrying=%s)",
					myItem > 0 and "Return to base" or "Get enemy intel",
					tostring(myItem > 0)
				)
			end
			break -- Take the first valid target
		end
	end

	if targetFlag and targetPos then
		return Navigation.GetAreaAtPosition(targetPos), targetPos
	end

	if shouldLog then
		Log:Debug("No suitable flag target found - available flags: %d", #G.World.flags)
	end
	return nil
end

local function findHealthGoal()
	local closestDist = math.huge
	local closestNode = nil
	local closestPos = nil
	for _, pos in pairs(G.World.healthPacks) do
		local healthNode = Navigation.GetAreaAtPosition(pos)
		if healthNode then
			local dist = (G.pLocal.Origin - pos):Length()
			if dist < closestDist then
				closestDist = dist
				closestNode = healthNode
				closestPos = pos
			end
		end
	end
	return closestNode, closestPos
end

-- Find and follow the closest teammate using FastPlayers (throttled to avoid lag)
local function findFollowGoal()
	local localWP = Common.FastPlayers.GetLocal()
	if not localWP then
		return nil
	end
	local origin = localWP:GetRawEntity():GetAbsOrigin()
	local closestDist = math.huge
	local closestNode = nil
	local targetPos = nil
	local foundTarget = false

	-- Cache teammate search for 30 ticks (0.5 seconds) to reduce expensive player iteration
	local currentTick = globals.TickCount()
	if not G.World.teammatesCacheTime or (currentTick - G.World.teammatesCacheTime) > 30 then
		G.World.cachedTeammates = Common.FastPlayers.GetTeammates(true)
		G.World.teammatesCacheTime = currentTick
	end

	for _, wp in ipairs(G.World.cachedTeammates or {}) do
		local ent = wp:GetRawEntity()
		if ent and ent:IsValid() and ent:IsAlive() then
			foundTarget = true
			local pos = ent:GetAbsOrigin()
			local dist = (pos - origin):Length()
			if dist < closestDist then
				closestDist = dist
				-- Update our memory of where we last saw this target
				G.Navigation.lastKnownTargetPosition = pos
				closestNode = Navigation.GetAreaAtPosition(pos)
				targetPos = pos
			end
		end
	end

	-- If no alive teammates found, but we have a last known position, use that
	if not foundTarget and G.Navigation.lastKnownTargetPosition then
		Log:Info("No alive teammates found, moving to last known position")
		closestNode = Navigation.GetAreaAtPosition(G.Navigation.lastKnownTargetPosition)
		targetPos = G.Navigation.lastKnownTargetPosition
	end

	-- If the target is very close (same node), add some distance to avoid pathfinding to self
	if closestNode and closestDist < 150 then -- 150 units is quite close
		local startNode = Navigation.GetClosestNode(origin)
		if startNode and closestNode.id == startNode.id then
			Log:Debug("Target too close (same node), expanding search radius")
			-- Look for a node near the target but not the same as our current node
			for _, node in pairs(G.Navigation.nodes or {}) do
				if node.id ~= startNode.id then
					local targetPos = G.Navigation.lastKnownTargetPosition or closestNode.pos
					local nodeToTargetDist = (node.pos - targetPos):Length()
					if nodeToTargetDist < 200 then -- Within 200 units of target
						closestNode = node
						break
					end
				end
			end
		end
	end

	return closestNode, targetPos
end

-- Main function to find goal node based on current task
function GoalFinder.findGoal(currentTask)
	-- Safety check: ensure nodes are loaded before proceeding
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, cannot find goal")
		return nil
	end

	local mapName = engine.GetMapName():lower()

	if currentTask == "Objective" then
		if mapName:find("plr_") or mapName:find("pl_") then
			return findPayloadGoal()
		elseif mapName:find("ctf_") then
			return findFlagGoal()
		else
			-- fallback to following the closest teammate
			return findFollowGoal()
		end
	elseif currentTask == "Health" then
		return findHealthGoal()
	elseif currentTask == "Follow" then
		return findFollowGoal()
	else
		Log:Debug("Unknown task: %s", currentTask)
	end

	-- Fallbacks when no goal was found by specific strategies
	-- 1) Try following a teammate as a generic goal
	local node, pos = findFollowGoal()
	if node and pos then
		return node, pos
	end

	-- 2) Roaming fallback: pick a reasonable nearby node to move towards
	if G.Navigation.nodes and next(G.Navigation.nodes) then
		local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
		if startNode then
			local bestNode = nil
			local bestDist = math.huge
			for _, candidate in pairs(G.Navigation.nodes) do
				if candidate and candidate.id ~= startNode.id and candidate.pos then
					local d = (candidate.pos - G.pLocal.Origin):Length()
					-- Prefer nodes within 300..1200 units to avoid picking ourselves or too far targets
					if d > 300 and d < 1200 and d < bestDist then
						bestDist = d
						bestNode = candidate
					end
				end
			end
			if not bestNode then
				-- If none in preferred band, just pick the closest different node
				for _, candidate in pairs(G.Navigation.nodes) do
					if candidate and candidate.id ~= startNode.id and candidate.pos then
						local d = (candidate.pos - G.pLocal.Origin):Length()
						if d < bestDist then
							bestDist = d
							bestNode = candidate
						end
					end
				end
			end
			if bestNode then
				-- Throttle info log
				local now = globals.TickCount()
				G.lastRoamLogTick = G.lastRoamLogTick or 0
				if now - G.lastRoamLogTick > 60 then
					Log:Info("Using roaming fallback to node %d (dist=%.0f)", bestNode.id, bestDist)
					G.lastRoamLogTick = now
				end
				return bestNode, bestNode.pos
			end
		end
	end

	-- Nothing found
	return nil
end

return GoalFinder
