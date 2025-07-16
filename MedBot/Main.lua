--[[ Annotations ]]
---@alias NavConnection { count: integer, connections: integer[] }
---@alias NavNode { id: integer, x: number, y: number, z: number, c: { [1]: NavConnection, [2]: NavConnection, [3]: NavConnection, [4]: NavConnection } }

--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Navigation = require("MedBot.Navigation")
local WorkManager = require("MedBot.WorkManager")
local Node = require("MedBot.Modules.Node")
local SmartJump = require("MedBot.Modules.SmartJump")
local isWalkable = require("MedBot.Modules.ISWalkable")

-- Load Profiler if available (Log not available yet, so use print)
local Profiler = nil
local profilerLoaded, profilerModule = pcall(require, "Profiler")
if profilerLoaded then
	Profiler = profilerModule
	Profiler.SetVisible(true)
	Profiler.Setup({
		smoothingSpeed = 8.0, -- Fast spike detection for performance hunting
		smoothingDecay = 4.0, -- Keep peaks visible longer
		systemMemoryMode = "system",
		compensateOverhead = true,
	})
	print("[MEDBOT] Profiler loaded successfully - performance monitoring enabled")
else
	print("[MEDBOT] Profiler not available - continuing without performance monitoring")
end

-- Helper function for profiler-safe operations
local function ProfilerBeginSystem(name)
	if Profiler then
		Profiler.BeginSystem(name)
	end
end

local function ProfilerEndSystem()
	if Profiler then
		Profiler.EndSystem()
	end
end

local function ProfilerBegin(name)
	if Profiler then
		Profiler.Begin(name)
	end
end

local function ProfilerEnd()
	if Profiler then
		Profiler.End()
	end
end

require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")
local Lib = Common.Lib

local Notify, Commands, WPlayer = Lib.UI.Notify, Lib.Utils.Commands, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

-- Circuit breaker for problematic connections
local ConnectionCircuitBreaker = {
	failures = {}, -- [connectionKey] = { count, lastFailTime, isBlocked }
	maxFailures = 3, -- Max failures before blocking connection temporarily
	blockDuration = 300, -- Ticks to block connection (5 seconds)
	cleanupInterval = 1800, -- Clean up old entries every 30 seconds
	lastCleanup = 0,
}

-- Add a connection failure to the circuit breaker
local function addConnectionFailure(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	local connectionKey = nodeA.id .. "->" .. nodeB.id
	local currentTick = globals.TickCount()

	-- Initialize or update failure count
	if not ConnectionCircuitBreaker.failures[connectionKey] then
		ConnectionCircuitBreaker.failures[connectionKey] = { count = 0, lastFailTime = 0, isBlocked = false }
	end

	local failure = ConnectionCircuitBreaker.failures[connectionKey]
	failure.count = failure.count + 1
	failure.lastFailTime = currentTick

	-- Block connection if too many failures
	if failure.count >= ConnectionCircuitBreaker.maxFailures then
		failure.isBlocked = true
		Log:Warn("Circuit breaker BLOCKED connection %s after %d failures", connectionKey, failure.count)
		return true
	end

	Log:Debug(
		"Circuit breaker recorded failure %d/%d for connection %s",
		failure.count,
		ConnectionCircuitBreaker.maxFailures,
		connectionKey
	)
	return false
end

-- Check if a connection is blocked by circuit breaker
local function isConnectionBlocked(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	local connectionKey = nodeA.id .. "->" .. nodeB.id
	local failure = ConnectionCircuitBreaker.failures[connectionKey]

	if not failure or not failure.isBlocked then
		return false
	end

	local currentTick = globals.TickCount()
	-- Unblock if enough time has passed
	if currentTick - failure.lastFailTime > ConnectionCircuitBreaker.blockDuration then
		failure.isBlocked = false
		failure.count = 0 -- Reset failure count
		Log:Info("Circuit breaker UNBLOCKED connection %s after timeout", connectionKey)
		return false
	end

	return true
end

-- Clean up old circuit breaker entries
local function cleanupCircuitBreaker()
	local currentTick = globals.TickCount()
	if currentTick - ConnectionCircuitBreaker.lastCleanup < ConnectionCircuitBreaker.cleanupInterval then
		return
	end

	ConnectionCircuitBreaker.lastCleanup = currentTick
	local cleaned = 0

	for connectionKey, failure in pairs(ConnectionCircuitBreaker.failures) do
		-- Clean up old, unblocked entries
		if
			not failure.isBlocked
			and (currentTick - failure.lastFailTime) > ConnectionCircuitBreaker.blockDuration * 2
		then
			ConnectionCircuitBreaker.failures[connectionKey] = nil
			cleaned = cleaned + 1
		end
	end

	if cleaned > 0 then
		Log:Debug("Circuit breaker cleaned up %d old entries", cleaned)
	end
end

--[[ Path Optimiser ]]
-- ############################################################
--  Path optimiser - prevents rubber-banding with smart windowing
-- ############################################################
-- Minimal Optimiser: only skip if next node is closer to the player than the current node
local Optimiser = {}

function Optimiser.skipIfCloser(origin, path)
	if not path or #path < 2 then
		return false
	end
	local curNode, nextNode = path[1], path[2]
	if not (curNode and nextNode and curNode.pos and nextNode.pos) then
		return false
	end
	local distCur = (curNode.pos - origin):Length()
	local distNext = (nextNode.pos - origin):Length()
	if distNext < distCur then
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()
		return true
	end
	return false
end

function Optimiser.skipIfWalkable(origin, path)
	if not path or #path < 2 then
		return false
	end
	local nextNode = path[2]
	local walkMode = G.Menu.Main.WalkableMode or "Smooth"
	-- For final nodes, use aggressive mode to avoid stopping short of goals
	if #path == 2 then
		walkMode = "Aggressive"
	end
	if nextNode and isWalkable.Path(origin, nextNode.pos, walkMode) then
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()
		return true
	end
	return false
end

function Optimiser.skipToGoalIfWalkable(origin, goalPos, path)
	local DEADZONE = 24 -- units, tweak as needed
	if not goalPos or not origin then
		return false
	end
	local dist = (goalPos - origin):Length()
	if dist < DEADZONE then
		Navigation.ClearPath()
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		return true
	end
	-- Only skip if we have a multi-node path AND goal is directly reachable with current walk mode
	if path and #path > 1 then
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if isWalkable.Path(origin, goalPos, walkMode) then
			Navigation.ClearPath()
			-- Set a direct path with just the goal as the node
			G.Navigation.path = { { pos = goalPos } }
			G.lastPathfindingTick = 0
			Log:Info("Cleared complex path, moving directly to goal with %s mode (distance: %.1f)", walkMode, dist)
			return true
		end
	end
	return false
end

--[[ Functions ]]
Common.AddCurrentTask("Objective")

local function HealthLogic(pLocal)
	if
		(pLocal:GetHealth() / pLocal:GetMaxHealth()) * 100 < G.Menu.Main.SelfHealTreshold
		and not pLocal:InCond(TFCond_Healing)
	then
		if not G.Current_Tasks[G.Tasks.Health] and G.Menu.Main.shouldfindhealth then
			Log:Info("Switching to health task")
			Common.AddCurrentTask("Health")
			Navigation.ClearPath()
		end
	else
		if G.Current_Tasks[G.Tasks.Health] then
			Log:Info("Health task no longer needed, switching back to objective task")
			Common.RemoveCurrentTask("Health")
			Navigation.ClearPath()
		end
	end
end

local function handleMemoryUsage()
	G.Benchmark.MemUsage = collectgarbage("count")
	if G.Benchmark.MemUsage / 1024 > 450 then
		collectgarbage()
		collectgarbage()
		collectgarbage()

		Log:Info("Trigger GC")
	end
end

-- Initialize current state
G.currentState = G.States.IDLE

-- Function to handle user input
local function handleUserInput(userCmd)
	if userCmd:GetForwardMove() ~= 0 or userCmd:GetSideMove() ~= 0 then
		G.Navigation.currentNodeTicks = 0
		G.currentState = G.States.IDLE
		G.wasManualWalking = true
		return true
	end
	return false
end

-- Function to handle the IDLE state
function handleIdleState()
	ProfilerBegin("idle_state")

	G.BotIsMoving = false -- Clear movement state when idle
	local currentTask = Common.GetHighestPriorityTask()
	if not currentTask then
		ProfilerEnd()
		return
	end

	ProfilerBegin("find_goal")
	-- Check for immediate goals first (before pathfinding cooldown)
	local goalNode, goalPos = findGoalNode(currentTask)
	ProfilerEnd()

	if goalNode and goalPos then
		local distance = (G.pLocal.Origin - goalPos):Length()

		-- PRIORITY 1: Always try direct movement to objectives first, regardless of current path
		if distance > 25 then -- Only if we're not already at the goal
			ProfilerBegin("direct_walk_check")
			local walkMode = G.Menu.Main.WalkableMode or "Smooth"
			-- Use aggressive mode for close goals (likely objectives/intel)
			if distance < 300 then
				walkMode = "Aggressive"
			end

			if isWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
				Log:Info(
					"Goal directly reachable with %s mode, moving immediately (distance: %.1f)",
					walkMode,
					distance
				)
				G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
				G.Navigation.goalPos = goalPos
				G.Navigation.goalNodeId = goalNode.id
				G.currentState = G.States.MOVING
				G.lastPathfindingTick = globals.TickCount()
				ProfilerEnd()
				ProfilerEnd()
				return
			end
			ProfilerEnd()
		end

		-- PRIORITY 2: Check if goal has changed significantly from current path
		if G.Navigation.goalPos then
			local goalChanged = (G.Navigation.goalPos - goalPos):Length() > 150
			if goalChanged then
				Log:Info("Goal changed significantly, forcing immediate repath (new distance: %.1f)", distance)
				G.lastPathfindingTick = 0 -- Force repath immediately
			end
		end
	end

	-- PERFORMANCE FIX: Prevent pathfinding spam by limiting frequency
	local currentTick = globals.TickCount()
	if not G.lastPathfindingTick then
		G.lastPathfindingTick = 0
	end

	-- Only allow pathfinding every 60 ticks (1 second) to prevent spam
	if currentTick - G.lastPathfindingTick < 60 then
		ProfilerEnd()
		return
	end

	ProfilerBegin("pathfinding_setup")
	-- Safety check: ensure nodes are available before pathfinding
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, staying in IDLE state")
		ProfilerEnd()
		ProfilerEnd()
		return
	end

	local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
	if not startNode then
		Log:Warn("Could not find start node")
		ProfilerEnd()
		ProfilerEnd()
		return
	end

	if not goalNode then
		goalNode, goalPos = findGoalNode(currentTask)
	end
	if not goalNode then
		Log:Warn("Could not find goal node")
		ProfilerEnd()
		ProfilerEnd()
		return
	end

	G.Navigation.goalPos = goalPos
	G.Navigation.goalNodeId = goalNode and goalNode.id or nil

	-- Avoid pathfinding if we're already at the goal
	if startNode.id == goalNode.id then
		-- Try direct movement or internal path before giving up
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if goalPos and isWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
			G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
			G.currentState = G.States.MOVING
			G.lastPathfindingTick = currentTick
		else
			local internal = Navigation.GetInternalPath(G.pLocal.Origin, goalPos)
			if internal then
				G.Navigation.path = internal
				G.currentState = G.States.MOVING
				G.lastPathfindingTick = currentTick
			else
				Log:Debug("Already at goal node %d, staying in IDLE", startNode.id)
				G.lastPathfindingTick = currentTick
			end
		end
		ProfilerEnd()
		ProfilerEnd()
		return
	end

	Log:Info("Generating new path from node %d to node %d", startNode.id, goalNode.id)
	WorkManager.addWork(Navigation.FindPath, { startNode, goalNode }, 33, "Pathfinding")
	G.currentState = G.States.PATHFINDING
	G.lastPathfindingTick = currentTick
	ProfilerEnd()
	ProfilerEnd()
end

-- Function to handle the PATHFINDING state
function handlePathfindingState()
	if Navigation.pathFound then
		G.currentState = G.States.MOVING
		Navigation.pathFound = false
	elseif Navigation.pathFailed then
		Log:Warn("Pathfinding failed")
		G.currentState = G.States.IDLE
		Navigation.pathFailed = false
	else
		-- If we're in pathfinding state but no work is in progress, start pathfinding
		local pathfindingWork = WorkManager.works["Pathfinding"]
		if not pathfindingWork or pathfindingWork.wasExecuted then
			-- Use existing goal if available, otherwise find new goal
			local goalPos = G.Navigation.goalPos
			local goalNodeId = G.Navigation.goalNodeId

			if goalPos and goalNodeId then
				local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
				local goalNode = G.Navigation.nodes and G.Navigation.nodes[goalNodeId]

				if startNode and goalNode and startNode.id ~= goalNode.id then
					-- Add a small delay before repathing to prevent immediate loops
					local currentTick = globals.TickCount()
					if not G.lastRepathTick then
						G.lastRepathTick = 0
					end

					if currentTick - G.lastRepathTick > 30 then -- Wait 30 ticks between repaths
						Log:Info("Repathing from stuck state: node %d to node %d", startNode.id, goalNode.id)
						WorkManager.addWork(Navigation.FindPath, { startNode, goalNode }, 33, "Pathfinding")
						G.lastRepathTick = currentTick
					else
						Log:Debug("Repath cooldown active, waiting...")
					end
				else
					Log:Debug("Cannot repath - invalid start/goal nodes, returning to IDLE")
					G.currentState = G.States.IDLE
				end
			else
				Log:Debug("No existing goal for repath, returning to IDLE")
				G.currentState = G.States.IDLE
			end
		end
	end
end

-- Function to handle the MOVING state
function handleMovingState(userCmd)
	ProfilerBegin("moving_state")

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		ProfilerEnd()
		return
	end

	-- Always target the first node in the remaining path
	local currentNode = G.Navigation.path[1]
	if not currentNode then
		Log:Warn("Current node is nil, returning to IDLE state")
		G.currentState = G.States.IDLE
		ProfilerEnd()
		return
	end

	ProfilerBegin("movement_setup")
	-- Store the intended movement direction for SmartJump to use
	local LocalOrigin = G.pLocal.Origin
	local direction = currentNode.pos - LocalOrigin
	G.BotMovementDirection = direction:Length() > 0 and (direction / direction:Length()) or Vector3(0, 0, 0)
	G.BotIsMoving = true
	ProfilerEnd()

	-- Check if this connection is blocked by circuit breaker before expensive movement
	ProfilerBegin("circuit_breaker_check")
	local path = G.Navigation.path
	if path and #path > 1 then
		local nextNode = path[2]
		if isConnectionBlocked(currentNode, nextNode) then
			Log:Warn(
				"Next connection %d -> %d is BLOCKED by circuit breaker - forcing repath",
				currentNode.id,
				nextNode.id
			)
			G.currentState = G.States.STUCK
			ProfilerEnd()
			ProfilerEnd()
			return
		end
	end
	ProfilerEnd()

	moveTowardsNode(userCmd, currentNode)

	-- Check if stuck - INCREASED THRESHOLD to prevent oscillation
	if G.Navigation.currentNodeTicks > 132 then -- Increased from 66 to 132 ticks (2 seconds)
		G.currentState = G.States.STUCK
	end

	ProfilerEnd()
end

-- Function to handle the STUCK state
function handleStuckState(userCmd)
	ProfilerBegin("stuck_state")

	local currentTick = globals.TickCount()

	-- Initialize stuck timer if not set
	if not G.Navigation.stuckStartTick then
		G.Navigation.stuckStartTick = currentTick
	end

	-- Calculate how long we've been stuck
	local stuckDuration = currentTick - G.Navigation.stuckStartTick

	-- SmartJump runs independently, just request emergency jump when needed
	-- Request emergency jump through SmartJump system (don't apply directly)
	if SmartJump.ShouldEmergencyJump(currentTick, G.Navigation.currentNodeTicks) then
		-- Set flag for SmartJump to handle emergency jump
		G.RequestEmergencyJump = true
		Log:Info("Emergency jump requested - SmartJump will handle it")
	end

	-- CIRCUIT BREAKER LOGIC - prevent infinite loops on blocked connections
	ProfilerBegin("stuck_analysis")
	local path = G.Navigation.path
	local shouldForceRepath = false
	local connectionBlocked = false

	if path and #path > 1 then
		local currentNode = path[1]
		local nextNode = path[2]

		if currentNode and nextNode and currentNode.id and nextNode.id and currentNode.id ~= nextNode.id then
			-- Check if this connection is blocked by circuit breaker
			if isConnectionBlocked(currentNode, nextNode) then
				Log:Warn(
					"Connection %d -> %d is BLOCKED by circuit breaker - forcing immediate repath",
					currentNode.id,
					nextNode.id
				)
				shouldForceRepath = true
				connectionBlocked = true
			end
		end
	end
	ProfilerEnd()

	-- INCREASED THRESHOLD - only repath after being stuck for much longer OR if connection is blocked
	if stuckDuration > 198 or shouldForceRepath then -- 198 ticks = 3 seconds of being stuck
		if not connectionBlocked then
			Log:Warn("Stuck for too long (%d ticks), analyzing connection and adding penalties...", stuckDuration)
		end

		ProfilerBegin("stuck_penalty_analysis")
		if path and #path > 1 then
			local currentNode = path[1]
			local nextNode = path[2]
			-- Better validation to prevent invalid penalties
			if currentNode and nextNode and currentNode.id and nextNode.id and currentNode.id ~= nextNode.id then
				-- Only do expensive walkability check if not already blocked by circuit breaker
				if not connectionBlocked then
					local walkMode = G.Menu.Main.WalkableMode or "Smooth"
					local penalty = 75 -- Higher base penalty for prolonged stuck

					if not isWalkable.Path(G.pLocal.Origin, nextNode.pos, walkMode) then
						if isWalkable.Path(G.pLocal.Origin, nextNode.pos, "Aggressive") then
							penalty = 150
							Log:Debug(
								"Stuck connection %d -> %d: fails with %s but works with Aggressive",
								currentNode.id,
								nextNode.id,
								walkMode
							)
						else
							penalty = 250 -- Very high penalty for completely blocked paths
							Log:Debug("Stuck connection %d -> %d: completely blocked", currentNode.id, nextNode.id)
						end
					else
						Log:Debug(
							"Stuck connection %d -> %d: walkable but still stuck (collision/geometry issue?)",
							currentNode.id,
							nextNode.id
						)
					end

					Node.AddFailurePenalty(currentNode, nextNode, penalty)

					-- Add to circuit breaker - if this returns true, connection is now blocked
					if addConnectionFailure(currentNode, nextNode) then
						Log:Error(
							"Connection %d -> %d has failed too many times - temporarily BLOCKED",
							currentNode.id,
							nextNode.id
						)
					end

					Log:Info(
						"Applied heavy penalty %d to connection %d -> %d after %d ticks stuck",
						penalty,
						currentNode.id,
						nextNode.id,
						stuckDuration
					)
				end
			else
				Log:Warn(
					"Skipping penalty for invalid stuck connection: currentNode=%s (id=%s) nextNode=%s (id=%s)",
					currentNode and "valid" or "nil",
					currentNode and currentNode.id or "nil",
					nextNode and "valid" or "nil",
					nextNode and nextNode.id or "nil"
				)
			end
		end
		ProfilerEnd()

		-- Clear stuck timer and reset navigation
		G.Navigation.stuckStartTick = nil
		Navigation.ResetTickTimer()
		G.currentState = G.States.PATHFINDING -- Use pathfinding state to trigger WorkManager repath
		G.lastPathfindingTick = 0 -- Force immediate repath

		-- If connection is blocked, also clear the current path to force a completely new one
		if connectionBlocked then
			Log:Info("Clearing current path due to blocked connection")
			Navigation.ClearPath()
		end
	else
		-- COOLDOWN: Only switch back to MOVING if we've been stuck for at least 33 ticks (0.5 seconds)
		if stuckDuration > 33 then
			G.Navigation.stuckStartTick = nil -- Reset stuck timer
			G.currentState = G.States.MOVING
		end
		-- If stuckDuration <= 33, stay in STUCK state to prevent oscillation
	end

	ProfilerEnd()
end

-- Function to find goal node based on the current task
function findGoalNode(currentTask)
	-- Safety check: ensure nodes are loaded before proceeding
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, cannot find goal")
		return nil
	end
	local pLocal = G.pLocal.entity
	local mapName = engine.GetMapName():lower()

	local function findPayloadGoal()
		-- Cache payload entities for 90 ticks (1.5 seconds) to avoid expensive entity searches
		local currentTick = globals.TickCount()
		if not G.World.payloadCacheTime or (currentTick - G.World.payloadCacheTime) > 90 then
			G.World.payloads = entities.FindByClass("CObjectCartDispenser")
			G.World.payloadCacheTime = currentTick
		end

		for _, entity in pairs(G.World.payloads or {}) do
			if entity:IsValid() and entity:GetTeamNumber() == pLocal:GetTeamNumber() then
				local pos = entity:GetAbsOrigin()
				return Navigation.GetClosestNode(pos), pos
			end
		end
	end

	local function findFlagGoal()
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
			return Navigation.GetClosestNode(targetPos), targetPos
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
			local healthNode = Navigation.GetClosestNode(pos)
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
					closestNode = Navigation.GetClosestNode(pos)
					targetPos = pos
				end
			end
		end

		-- If no alive teammates found, but we have a last known position, use that
		if not foundTarget and G.Navigation.lastKnownTargetPosition then
			Log:Info("No alive teammates found, moving to last known position")
			closestNode = Navigation.GetClosestNode(G.Navigation.lastKnownTargetPosition)
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
	return nil
end

-- Function to move towards the current node (simplified for better FPS)
function moveTowardsNode(userCmd, node)
	ProfilerBegin("move_to_node")

	local LocalOrigin = G.pLocal.Origin
	local goalPos = G.Navigation.goalPos -- Use the stored goal position directly

	-- Try to skip directly to the goal if we have a complex path
	ProfilerBegin("goal_skip_check")
	if G.Menu.Main.Skip_Nodes and goalPos and G.Navigation.path and #G.Navigation.path > 1 then
		if Optimiser.skipToGoalIfWalkable(LocalOrigin, goalPos, G.Navigation.path) then
			ProfilerEnd()
			ProfilerEnd()
			return -- Stop for this tick if we skipped to goal
		end
	end
	ProfilerEnd()

	-- Only rotate camera if LookingAhead is enabled
	ProfilerBegin("camera_rotation")
	if G.Menu.Main.LookingAhead then
		local pLocalWrapped = WPlayer.GetLocal()
		local angles = Lib.Utils.Math.PositionAngles(pLocalWrapped:GetEyePos(), node.pos)
		angles.x = 0

		local currentAngles = userCmd.viewangles
		local deltaAngles = { x = angles.x - currentAngles.x, y = angles.y - currentAngles.y }
		deltaAngles.y = ((deltaAngles.y + 180) % 360) - 180
		angles = EulerAngles(
			currentAngles.x + deltaAngles.x * 0.05,
			currentAngles.y + deltaAngles.y * G.Menu.Main.smoothFactor,
			0
		)
		engine.SetViewAngles(angles)
	end
	ProfilerEnd()

	ProfilerBegin("distance_check")
	local horizontalDist = math.abs(LocalOrigin.x - node.pos.x) + math.abs(LocalOrigin.y - node.pos.y)
	local verticalDist = math.abs(LocalOrigin.z - node.pos.z)

	-- Check if we've reached the current node
	if (horizontalDist < G.Misc.NodeTouchDistance) and verticalDist <= G.Misc.NodeTouchHeight then
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()

		-- Check if we've reached the end of the path
		if #G.Navigation.path == 0 then
			Navigation.ClearPath()
			Log:Info("Reached end of path")
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0 -- Reset cooldown to allow immediate direct movement check
		end
		ProfilerEnd()
		ProfilerEnd()
		return
	end
	ProfilerEnd()

	------------------------------------------------------------
	--  Hybrid Skip - Robust walkability check for node skipping
	------------------------------------------------------------
	ProfilerBegin("node_skipping")
	-- Only skip one node per tick, first if closer, then if walkable
	if G.Menu.Main.Skip_Nodes and #G.Navigation.path > 1 then
		local skipped = false
		if Optimiser.skipIfCloser(LocalOrigin, G.Navigation.path) then
			skipped = true
		elseif Optimiser.skipIfWalkable(LocalOrigin, G.Navigation.path) then
			skipped = true
		end
		if skipped then
			node = G.Navigation.path[1]
			if not node then
				ProfilerEnd()
				ProfilerEnd()
				return
			end
		end
	end
	ProfilerEnd()

	ProfilerBegin("movement_execution")
	-- Store current button state before WalkTo (SmartJump may have set jump/duck buttons)
	local originalButtons = userCmd.buttons

	-- Simple movement without complex optimizations
	Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)

	-- Preserve SmartJump button inputs (jump and duck commands)
	-- WalkTo might clear these, so we need to restore them
	local smartJumpButtons = originalButtons & (IN_JUMP | IN_DUCK)
	if smartJumpButtons ~= 0 then
		userCmd:SetButtons(userCmd.buttons | smartJumpButtons)
	end

	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
	ProfilerEnd()

	-- Expensive walkability verification - only when stuck for longer
	ProfilerBegin("stuck_analysis")
	if G.Navigation.currentNodeTicks > 132 then -- Increased from 66 to give more time
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if not isWalkable.Path(LocalOrigin, node.pos, walkMode) then
			Log:Warn("Path to current node blocked with %s mode after being stuck, repathing...", walkMode)
			local path = G.Navigation.path
			if path and #path > 1 then
				local currentNode = path[1]
				local nextNode = path[2]
				if currentNode and nextNode and currentNode.id and nextNode.id and currentNode.id ~= nextNode.id then -- Prevent self-loop penalties
					-- Test penalty based on walkability with different modes
					local penalty = 50 -- Increased base penalty
					if not isWalkable.Path(LocalOrigin, nextNode.pos, walkMode) then
						if isWalkable.Path(LocalOrigin, nextNode.pos, "Aggressive") then
							penalty = 100 -- Higher penalty for mode-specific failures
							Log:Debug(
								"Connection %d -> %d fails with %s but works with Aggressive",
								currentNode.id,
								nextNode.id,
								walkMode
							)
						else
							penalty = 200 -- Much higher penalty for completely blocked paths
							Log:Debug("Connection %d -> %d completely blocked", currentNode.id, nextNode.id)
						end
					end
					Node.AddFailurePenalty(currentNode, nextNode, penalty)
					Log:Info("Applied penalty %d to connection %d -> %d", penalty, currentNode.id, nextNode.id)
				else
					Log:Warn(
						"Skipping penalty for invalid connection: currentNode=%s (id=%s) nextNode=%s (id=%s)",
						currentNode and "valid" or "nil",
						currentNode and currentNode.id or "nil",
						nextNode and "valid" or "nil",
						nextNode and nextNode.id or "nil"
					)
				end
			end
			Navigation.ResetTickTimer()
			G.currentState = G.States.PATHFINDING -- Use pathfinding state to trigger WorkManager repath
			G.lastPathfindingTick = 0
			ProfilerEnd()
			ProfilerEnd()
			return
		end
	end
	ProfilerEnd()

	-- Smart displacement recovery - only when actually displaced, not when normally stuck
	ProfilerBegin("displacement_recovery")
	local path = G.Navigation.path
	local origin = G.pLocal.Origin

	-- Only check for displacement if we have a substantial path and we're not at the first node
	if path and #path > 2 and G.Navigation.currentNodeTicks > 60 then -- Increased threshold
		local currentNode = path[1]
		local distToCurrentNode = currentNode and (currentNode.pos - origin):Length() or math.huge

		-- Only consider displacement recovery if we're significantly far from our current target node
		-- This prevents infinite re-sync loops when normally stuck
		if distToCurrentNode > 300 then -- Must be >300 units away from current node to consider displacement
			local MAX_SNAP = 800 * 800 -- Reduced from 1200 to be more conservative
			local bestNodeIndex = nil
			local bestDistance = math.huge

			-- Find the closest node in our path that we can walk to (skip node 1 to avoid loops)
			for i = 2, math.min(#path, 15) do -- Start from node 2, reduced scan range
				local pathNode = path[i]
				if pathNode and pathNode.pos then
					local distSqr = (pathNode.pos - origin):LengthSqr()
					if distSqr < MAX_SNAP and distSqr < bestDistance then
						-- Only do expensive walkability check for the best candidate
						if isWalkable.Path(origin, pathNode.pos) then
							bestNodeIndex = i
							bestDistance = distSqr
							break -- Take the first walkable node we find
						end
					end
				end
			end

			-- Only re-sync if we found a significantly better node (not just node 1)
			if bestNodeIndex and bestNodeIndex > 1 then
				-- Store the fact that we used displacement recovery to prevent spam
				if not G.Navigation.lastDisplacementRecovery then
					G.Navigation.lastDisplacementRecovery = 0
				end

				local currentTick = globals.TickCount()
				-- Only allow displacement recovery once every 5 seconds to prevent spam
				if (currentTick - G.Navigation.lastDisplacementRecovery) > 300 then
					-- Drop everything before the best node
					for j = 1, bestNodeIndex - 1 do
						Navigation.RemoveCurrentNode()
					end
					G.Navigation.lastDisplacementRecovery = currentTick
					Log:Info(
						"Displacement recovery: skipped to path node %d (was %.1f units away)",
						bestNodeIndex,
						math.sqrt(bestDistance)
					)
					-- Reset stuck timer since we made progress
					Navigation.ResetTickTimer()
				end
			end
		end
	end
	ProfilerEnd()

	ProfilerEnd()
	-- Note: Stuck detection is handled by the STUCK state, no need for duplicate logic here
end

-- Main function
---@param userCmd UserCmd
local function OnCreateMove(userCmd)
	ProfilerBeginSystem("medbot_main")

	ProfilerBegin("initial_checks")
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		G.currentState = G.States.IDLE
		Navigation.ClearPath()
		ProfilerEnd()
		ProfilerEndSystem()
		return
	end

	if not G.prevState then
		G.prevState = G.currentState
	end

	-- If bot is disabled via menu, do nothing
	if not G.Menu.Main.Enable then
		Navigation.ClearPath()
		G.BotIsMoving = false -- Clear bot movement state when disabled
		ProfilerEnd()
		ProfilerEndSystem()
		return
	end

	G.pLocal.entity = pLocal
	G.pLocal.flags = pLocal:GetPropInt("m_fFlags")
	G.pLocal.Origin = pLocal:GetAbsOrigin()
	ProfilerEnd()

	-- PERFORMANCE FIX: Only run memory cleanup every 300 ticks (5 seconds) to prevent frame drops
	ProfilerBegin("maintenance")
	local currentTick = globals.TickCount()
	if not G.lastCleanupTick then
		G.lastCleanupTick = currentTick
	end

	if currentTick - G.lastCleanupTick > 300 then -- Every 5 seconds
		G.CleanupMemory()

		-- Clean up performance caches to prevent memory bloat
		if G.walkabilityCache then
			local cleaned = 0
			for key, entry in pairs(G.walkabilityCache) do
				if (currentTick - entry.timestamp) > 300 then -- Remove entries older than 5 seconds
					G.walkabilityCache[key] = nil
					cleaned = cleaned + 1
				end
			end
			if cleaned > 0 then
				Log:Debug("Cleaned up %d old walkability cache entries", cleaned)
			end
		end

		G.lastCleanupTick = currentTick
	end

	-- Clean up circuit breaker entries
	cleanupCircuitBreaker()
	ProfilerEnd()

	ProfilerBegin("user_input")
	if handleUserInput(userCmd) then
		G.BotIsMoving = false -- Clear bot movement state when user takes control
		ProfilerEnd()
		ProfilerEndSystem()
		return
	end --if user is walking

	if G.wasManualWalking then
		if userCmd:GetForwardMove() == 0 and userCmd:GetSideMove() == 0 then
			G.wasManualWalking = false
			G.lastPathfindingTick = 0 -- force repath soon
		end
	end
	ProfilerEnd()

	-- PRIORITY CHECK: Throttled check for direct objectives (only every 30 ticks to prevent lag)
	ProfilerBegin("priority_check")
	local currentTask = Common.GetHighestPriorityTask()

	-- Initialize priority check timer
	if not G.lastPriorityCheckTick then
		G.lastPriorityCheckTick = 0
	end

	-- Only run expensive priority checks every 30 ticks (0.5 seconds) unless we have no current goal
	local shouldRunPriorityCheck = false
	if not G.Navigation.goalPos then
		-- No current goal - run priority check immediately
		shouldRunPriorityCheck = true
	elseif (currentTick - G.lastPriorityCheckTick) > 30 then
		-- Regular throttled check
		shouldRunPriorityCheck = true
		G.lastPriorityCheckTick = currentTick
	end

	if currentTask and G.currentState ~= G.States.PATHFINDING and shouldRunPriorityCheck then -- Don't interrupt pathfinding
		local goalNode, goalPos = findGoalNode(currentTask)
		if goalNode and goalPos then
			local distance = (G.pLocal.Origin - goalPos):Length()

			-- If we can reach the objective directly, abandon current path and go for it
			if distance > 25 and distance < 400 then -- Within reasonable range
				-- Cache the walkability check result briefly to avoid repeated expensive calls
				local cacheKey = string.format(
					"%.0f_%.0f_%.0f_to_%.0f_%.0f_%.0f",
					G.pLocal.Origin.x,
					G.pLocal.Origin.y,
					G.pLocal.Origin.z,
					goalPos.x,
					goalPos.y,
					goalPos.z
				)

				if not G.walkabilityCache then
					G.walkabilityCache = {}
				end

				local walkMode = distance < 200 and "Aggressive" or G.Menu.Main.WalkableMode or "Smooth"
				local cacheEntry = G.walkabilityCache[cacheKey]
				local isWalkableResult = false

				-- Use cached result if it's recent (within 60 ticks = 1 second)
				if cacheEntry and (currentTick - cacheEntry.timestamp) < 60 and cacheEntry.walkMode == walkMode then
					isWalkableResult = cacheEntry.result
				else
					-- Expensive check - cache the result
					isWalkableResult = isWalkable.Path(G.pLocal.Origin, goalPos, walkMode)
					G.walkabilityCache[cacheKey] = {
						result = isWalkableResult,
						timestamp = currentTick,
						walkMode = walkMode,
					}

					-- Clean up old cache entries to prevent memory bloat
					if not G.lastCacheCleanup then
						G.lastCacheCleanup = 0
					end
					if (currentTick - G.lastCacheCleanup) > 300 then -- Clean every 5 seconds
						for key, entry in pairs(G.walkabilityCache) do
							if (currentTick - entry.timestamp) > 180 then -- Remove entries older than 3 seconds
								G.walkabilityCache[key] = nil
							end
						end
						G.lastCacheCleanup = currentTick
					end
				end

				if isWalkableResult then
					-- Check if this is a NEW objective or significantly closer than current goal
					local shouldSwitch = false
					if not G.Navigation.goalPos then
						shouldSwitch = true
						Log:Info("No current goal, switching to direct objective")
					else
						local currentGoalDist = (G.pLocal.Origin - G.Navigation.goalPos):Length()
						if distance < currentGoalDist * 0.7 then -- New goal is 30% closer
							shouldSwitch = true
							Log:Info(
								"Direct objective is much closer (%.1f vs %.1f), switching",
								distance,
								currentGoalDist
							)
						elseif (G.Navigation.goalPos - goalPos):Length() > 200 then -- Goal has changed significantly
							shouldSwitch = true
							Log:Info("Objective has moved significantly, switching to new position")
						end
					end

					if shouldSwitch then
						Log:Info("Switching to direct objective with %s mode (distance: %.1f)", walkMode, distance)
						G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
						G.Navigation.goalPos = goalPos
						G.Navigation.goalNodeId = goalNode.id
						G.currentState = G.States.MOVING
						G.lastPathfindingTick = globals.TickCount()
						Navigation.ResetTickTimer()
						-- Skip the normal state handling for this tick
						ProfilerEnd()
						ProfilerEndSystem()
						return
					end
				end
			end
		end
	end
	ProfilerEnd()

	-- STATE HANDLING: Rearrange the conditions for better performance
	ProfilerBegin("state_handling")
	if G.currentState == G.States.MOVING then
		handleMovingState(userCmd)
	elseif G.currentState == G.States.PATHFINDING then
		handlePathfindingState()
	elseif G.currentState == G.States.IDLE then
		handleIdleState()
	elseif G.currentState == G.States.STUCK then
		handleStuckState(userCmd)
	end
	ProfilerEnd()

	-- POST-PROCESSING: Repath triggers and work management
	ProfilerBegin("post_processing")
	-- Repath when state changes
	if G.prevState ~= G.currentState then
		Log:Debug("State changed from %s to %s", tostring(G.prevState), tostring(G.currentState))
		if WorkManager.attemptWork(33, "StateChangeRepath") then
			G.lastPathfindingTick = 0
		end
		G.prevState = G.currentState
	end

	-- Repath if goal node changed or if goal is directly reachable
	if G.Navigation.goalPos and G.Navigation.goalNodeId then
		if WorkManager.attemptWork(33, "GoalCheck") then
			local newNode = Navigation.GetClosestNode(G.Navigation.goalPos)
			if newNode and newNode.id ~= G.Navigation.goalNodeId then
				G.lastPathfindingTick = 0
				G.Navigation.goalNodeId = newNode.id
			end

			-- Check if we're close to goal and should switch to direct movement
			local distanceToGoal = (G.pLocal.Origin - G.Navigation.goalPos):Length()
			if distanceToGoal < 200 then
				local walkMode = G.Menu.Main.WalkableMode or "Smooth"
				if isWalkable.Path(G.pLocal.Origin, G.Navigation.goalPos, walkMode) then
					-- Only force re-evaluation occasionally when close and path is complex
					if G.Navigation.path and #G.Navigation.path > 3 then
						G.lastPathfindingTick = 0
					end
				end
			end
		end
	end

	-- Repath after navmesh updates
	if G.Navigation.navMeshUpdated then
		G.Navigation.navMeshUpdated = false
		G.lastPathfindingTick = 0
	end

	WorkManager.processWorks()
	ProfilerEnd()

	ProfilerEndSystem()
end

---@param ctx DrawModelContext
local function OnDrawModel(ctx)
	if ctx:GetModelName():find("medkit") then
		local entity = ctx:GetEntity()
		G.World.healthPacks[entity:GetIndex()] = entity:GetAbsOrigin()
	end
end

---@param event GameEvent
local function OnGameEvent(event)
	local eventName = event:GetName()

	if eventName == "game_newmap" then
		Log:Info("New map detected, reloading nav file...")
		Navigation.Setup()
	end
end

-- Ensure SmartJump callback runs BEFORE MedBot's callback by using a name that comes after alphabetically
callbacks.Unregister("CreateMove", "ZMedBot.CreateMove") -- Z prefix ensures it runs after SmartJump
callbacks.Unregister("DrawModel", "MedBot.DrawModel")
callbacks.Unregister("FireGameEvent", "MedBot.FireGameEvent")

callbacks.Register("CreateMove", "ZMedBot.CreateMove", OnCreateMove) -- Z prefix ensures it runs after SmartJump
callbacks.Register("DrawModel", "MedBot.DrawModel", OnDrawModel)
callbacks.Register("FireGameEvent", "MedBot.FireGameEvent", OnGameEvent)

--[[ Commands ]]

Commands.Register("pf_reload", function()
	Navigation.Setup()
end)

Commands.Register("pf_circuit_breaker", function(args)
	if args[1] == "status" then
		local currentTick = globals.TickCount()
		local blockedCount = 0
		local totalFailures = 0

		print("Circuit Breaker Status:")
		print("======================")

		for connectionKey, failure in pairs(ConnectionCircuitBreaker.failures) do
			totalFailures = totalFailures + failure.count
			local status = failure.isBlocked and "BLOCKED" or "active"
			local timeLeft = ""

			if failure.isBlocked then
				blockedCount = blockedCount + 1
				local ticksLeft = ConnectionCircuitBreaker.blockDuration - (currentTick - failure.lastFailTime)
				timeLeft = string.format(" (%d ticks left)", math.max(0, ticksLeft))
			end

			print(string.format("  %s: %d failures, %s%s", connectionKey, failure.count, status, timeLeft))
		end

		print(
			string.format(
				"\nSummary: %d connections tracked, %d currently blocked, %d total failures",
				table.getn and table.getn(ConnectionCircuitBreaker.failures) or 0,
				blockedCount,
				totalFailures
			)
		)
		print(
			string.format(
				"Settings: max_failures=%d, block_duration=%d ticks",
				ConnectionCircuitBreaker.maxFailures,
				ConnectionCircuitBreaker.blockDuration
			)
		)
	elseif args[1] == "clear" then
		ConnectionCircuitBreaker.failures = {}
		print("Circuit breaker cleared - all connections reset")
	elseif args[1] == "block" and args[2] and args[3] then
		local nodeA = tonumber(args[2])
		local nodeB = tonumber(args[3])
		if nodeA and nodeB then
			local connectionKey = nodeA .. "->" .. nodeB
			ConnectionCircuitBreaker.failures[connectionKey] = {
				count = ConnectionCircuitBreaker.maxFailures,
				lastFailTime = globals.TickCount(),
				isBlocked = true,
			}
			print(string.format("Manually blocked connection %s", connectionKey))
		else
			print("Usage: pf_circuit_breaker block <nodeA_id> <nodeB_id>")
		end
	elseif args[1] == "unblock" and args[2] and args[3] then
		local nodeA = tonumber(args[2])
		local nodeB = tonumber(args[3])
		if nodeA and nodeB then
			local connectionKey = nodeA .. "->" .. nodeB
			if ConnectionCircuitBreaker.failures[connectionKey] then
				ConnectionCircuitBreaker.failures[connectionKey].isBlocked = false
				ConnectionCircuitBreaker.failures[connectionKey].count = 0
				print(string.format("Manually unblocked connection %s", connectionKey))
			else
				print(string.format("Connection %s not found in circuit breaker", connectionKey))
			end
		else
			print("Usage: pf_circuit_breaker unblock <nodeA_id> <nodeB_id>")
		end
	else
		print("Usage: pf_circuit_breaker status | clear | block <nodeA> <nodeB> | unblock <nodeA> <nodeB>")
		print("  status  - Show all tracked connections and their status")
		print("  clear   - Reset all circuit breaker data")
		print("  block   - Manually block a specific connection")
		print("  unblock - Manually unblock a specific connection")
	end
end)

Commands.Register("pf_profiler", function(args)
	if not Profiler then
		print("Profiler not available - please install the Profiler module")
		return
	end

	if args[1] == "show" then
		Profiler.SetVisible(true)
		print("Profiler display enabled")
	elseif args[1] == "hide" then
		Profiler.SetVisible(false)
		print("Profiler display disabled")
	elseif args[1] == "reset" then
		Profiler.Reset()
		print("Profiler data reset")
	elseif args[1] == "config" then
		if args[2] == "performance" then
			Profiler.Setup({
				smoothingSpeed = 12.0, -- Fast spike detection
				smoothingDecay = 3.0, -- Keep peaks visible longer
				systemMemoryMode = "system",
				compensateOverhead = true,
			})
			print("Profiler configured for performance hunting")
		elseif args[2] == "smooth" then
			Profiler.Setup({
				smoothingSpeed = 2.5, -- Smooth animations
				smoothingDecay = 1.5, -- Slow decay
				systemMemoryMode = "components",
				compensateOverhead = true,
			})
			print("Profiler configured for smooth monitoring")
		else
			print("Usage: pf_profiler config performance | smooth")
		end
	else
		print("Usage: pf_profiler show | hide | reset | config <performance|smooth>")
		print("  show   - Enable profiler display")
		print("  hide   - Disable profiler display")
		print("  reset  - Clear all profiler data")
		print("  config - Configure profiler for different use cases")
	end
end)

Commands.Register("pf_performance", function(args)
	local currentTick = globals.TickCount()

	if args[1] == "cache" then
		print("Performance Cache Status:")
		print("========================")

		-- Walkability cache
		if G.walkabilityCache then
			local cacheCount = 0
			local oldEntries = 0
			for key, entry in pairs(G.walkabilityCache) do
				cacheCount = cacheCount + 1
				if (currentTick - entry.timestamp) > 180 then
					oldEntries = oldEntries + 1
				end
			end
			print(string.format("Walkability cache: %d entries (%d old)", cacheCount, oldEntries))
		else
			print("Walkability cache: not initialized")
		end

		-- Entity caches
		local flagCacheAge = G.World.flagCacheTime and (currentTick - G.World.flagCacheTime) or "never"
		local payloadCacheAge = G.World.payloadCacheTime and (currentTick - G.World.payloadCacheTime) or "never"
		local teammatesCacheAge = G.World.teammatesCacheTime and (currentTick - G.World.teammatesCacheTime) or "never"

		print(string.format("Flag cache age: %s ticks", tostring(flagCacheAge)))
		print(string.format("Payload cache age: %s ticks", tostring(payloadCacheAge)))
		print(string.format("Teammates cache age: %s ticks", tostring(teammatesCacheAge)))

		-- Priority check throttling
		local priorityCheckAge = G.lastPriorityCheckTick and (currentTick - G.lastPriorityCheckTick) or "never"
		print(string.format("Last priority check: %s ticks ago", tostring(priorityCheckAge)))
	elseif args[1] == "clear" then
		G.walkabilityCache = {}
		G.World.flagCacheTime = nil
		G.World.payloadCacheTime = nil
		G.World.teammatesCacheTime = nil
		G.lastPriorityCheckTick = 0
		print("All performance caches cleared")
	elseif args[1] == "stats" then
		print("Performance Optimization Stats:")
		print("==============================")
		print("Throttling intervals:")
		print("  Priority check: every 30 ticks (0.5s)")
		print("  Entity searches: every 90 ticks (1.5s)")
		print("  Teammate search: every 30 ticks (0.5s)")
		print("  Walkability cache: 60 tick lifetime (1s)")
		print("  Circuit breaker cleanup: every 1800 ticks (30s)")
		print("  Memory cleanup: every 300 ticks (5s)")
	else
		print("Usage: pf_performance cache | clear | stats")
		print("  cache - Show current cache status and ages")
		print("  clear - Clear all performance caches")
		print("  stats - Show performance optimization settings")
	end
end)

Commands.Register("pf_hierarchical", function(args)
	if args[1] == "network" then
		Node.GenerateHierarchicalNetwork()
		Notify.Simple(
			"Started hierarchical network generation",
			"Will process across multiple ticks to prevent freezing",
			5
		)
	elseif args[1] == "status" then
		-- Check setup progress by accessing the SetupState
		if G.Navigation.hierarchical then
			print("Hierarchical network ready and available")
		else
			print("Hierarchical network not yet available - check if setup is in progress")
		end
	elseif args[1] == "info" then
		local areaId = tonumber(args[2])
		if areaId then
			local points = Node.GetAreaPoints(areaId)
			if points then
				print(string.format("Area %d: %d fine points", areaId, #points))
				local edgeCount = 0
				for _, point in ipairs(points) do
					if point.isEdge then
						edgeCount = edgeCount + 1
					end
				end
				print(string.format("  - %d edge points, %d internal points", edgeCount, #points - edgeCount))
			else
				print("Area not found or no points generated")
			end
		else
			print("Usage: pf_hierarchical info <areaId>")
		end
	else
		print("Usage: pf_hierarchical network | status | info <areaId>")
		print("  network - Start multi-tick hierarchical network generation")
		print("  status  - Check if hierarchical network is ready")
		print("  info    - Show detailed info for specific area")
	end
end)

Commands.Register("pf_test_hierarchical", function()
	local hierarchical = G.Navigation.hierarchical
	if hierarchical then
		print(
			string.format("Hierarchical data available for %d areas", hierarchical.areas and #hierarchical.areas or 0)
		)
		local totalEdgePoints = 0
		local totalConnections = 0
		for areaId, areaInfo in pairs(hierarchical.areas or {}) do
			totalEdgePoints = totalEdgePoints + #areaInfo.edgePoints
			totalConnections = totalConnections + #areaInfo.interAreaConnections
		end
		print(string.format("Total: %d edge points, %d inter-area connections", totalEdgePoints, totalConnections))
	else
		print("No hierarchical data available. Run 'pf_hierarchical network' first.")
	end
end)

Commands.Register("pf_connections", function(args)
	if args[1] == "status" then
		local status = Node.GetConnectionProcessingStatus()
		if status.isProcessing then
			local phaseNames = {
				[1] = "Basic validation",
				[2] = "Expensive fallback",
				[3] = "Stair patching",
				[4] = "Fine point stitching",
			}
			print(string.format("Connection Processing Active:"))
			print(string.format("  Phase: %d (%s)", status.currentPhase, phaseNames[status.currentPhase] or "Unknown"))
			print(string.format("  Progress: %d/%d nodes processed", status.processedNodes, status.totalNodes))
			print(string.format("  Connections found: %d", status.connectionsFound))
			print(string.format("  Expensive checks used: %d", status.expensiveChecksUsed))
			print(string.format("  Fine point connections added: %d", status.finePointConnectionsAdded))
			print(string.format("  Current FPS: %.1f (batch size: %d)", status.currentFPS, status.currentBatchSize))
		else
			print("Connection processing is not active")
		end
	elseif args[1] == "stop" then
		Node.StopConnectionProcessing()
		print("Stopped connection processing")
	elseif args[1] == "start" then
		local nodes = Node.GetNodes()
		if nodes and next(nodes) then
			-- Trigger connection processing by calling the internal function
			-- This is a bit of a hack but allows manual restart
			print("Starting connection processing...")
			Node.CleanupConnections()
		else
			print("No nodes loaded")
		end
	else
		print("Usage: pf_connections status | stop | start")
		print("  status - Show current processing status")
		print("  stop   - Stop background processing")
		print("  start  - Start/restart connection processing")
	end
end)

Commands.Register("pf_optimize", function(args)
	if args[1] == "test" then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			local origin = pLocal:GetAbsOrigin()
			local path = G.Navigation.path
			if path and #path > 1 then
				local nextNode = path[2]
				if nextNode and Navigation.isWalkable(origin, nextNode.pos) then
					print("Path optimization successful - can skip to next node")
				else
					print("Path optimization failed - cannot skip current node")
				end
			else
				print("No path or insufficient nodes to test")
			end
		else
			print("Player not available for testing")
		end
	elseif args[1] == "info" then
		print(string.format("Skip Nodes: %s", G.Menu.Main.Skip_Nodes and "Enabled" or "Disabled"))
		print(string.format("Walking Mode: %s", G.Menu.Main.WalkableMode or "Smooth"))

		local path = G.Navigation.path
		if path and #path > 0 then
			print(string.format("Current path: %d nodes remaining", #path))
		else
			print("No active path")
		end
	else
		print("Usage: pf_optimize test | info")
		print("  test - Test if current node can be skipped")
		print("  info - Show node skipping settings and path status")
	end
end)

Commands.Register("pf_stairs", function(args)
	local nodes = Node.GetNodes()

	if not nodes or not next(nodes) then
		print("No navigation nodes loaded")
		return
	end

	if args[1] == "check" then
		-- Check for one-directional connections
		local oneWayConnections = 0
		local totalConnections = 0
		local existingConnections = {}

		-- Build connection lookup
		for nodeId, node in pairs(nodes) do
			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = Node.GetConnectionNodeId(connection)
							local key = nodeId .. "->" .. targetNodeId
							existingConnections[key] = true
							totalConnections = totalConnections + 1
						end
					end
				end
			end
		end

		-- Check for missing reverse connections
		for nodeId, node in pairs(nodes) do
			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = Node.GetConnectionNodeId(connection)
							local targetNode = nodes[targetNodeId]

							if targetNode then
								local reverseKey = targetNodeId .. "->" .. nodeId
								if not existingConnections[reverseKey] then
									local heightDiff = targetNode.pos.z - node.pos.z
									if math.abs(heightDiff) > 18 and math.abs(heightDiff) <= 200 then
										oneWayConnections = oneWayConnections + 1
									end
								end
							end
						end
					end
				end
			end
		end

		print(string.format("Connection Analysis:"))
		print(string.format("  Total connections: %d", totalConnections))
		print(string.format("  One-way stair connections: %d", oneWayConnections))
		print(string.format("  Potential patches: %d", oneWayConnections))
	else
		print("Usage: pf_stairs check")
		print("  check - Analyze one-directional stair connections")
	end
end)

Commands.Register("pf_costs", function(args)
	if args[1] == "recalc" then
		Node.RecalculateConnectionCosts()
		print("Connection costs recalculated for current walking mode")
	elseif args[1] == "info" then
		print(string.format("Walking Mode: %s", G.Menu.Main.WalkableMode or "Smooth"))
		if G.Menu.Main.WalkableMode == "Smooth" then
			print("  - Uses 18-unit steps + height penalties")
			print("  - Adds 10 cost per 18 units of height")
		else
			print("  - Allows 72-unit jumps without penalties")
		end

		local nodes = Node.GetNodes()
		if nodes then
			local totalConnections = 0
			local costlyConnections = 0
			for _, node in pairs(nodes) do
				if node and node.c then
					for _, connectionDir in pairs(node.c) do
						if connectionDir and connectionDir.connections then
							for _, connection in ipairs(connectionDir.connections) do
								totalConnections = totalConnections + 1
								local cost = Node.GetConnectionCost(connection)
								if cost > 1 then
									costlyConnections = costlyConnections + 1
								end
							end
						end
					end
				end
			end
			print(string.format("Connections: %d total, %d with extra costs", totalConnections, costlyConnections))
		end
	else
		print("Usage: pf_costs recalc | info")
		print("  recalc - Recalculate all connection costs for current walking mode")
		print("  info   - Show walking mode and connection cost statistics")
	end
end)

Notify.Alert("MedBot loaded!")
if entities.GetLocalPlayer() then
	-- Add safety check to prevent crashes when no map is loaded
	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Navigation.Setup()
	else
		Log:Info("Skipping navigation setup - no valid map loaded")
		-- Initialize empty nodes to prevent crashes
		G.Navigation.nodes = {}
	end

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		Log:Info("Connection cleanup enabled - this may cause temporary frame drops")
		-- Note: pruneInvalidConnections function is handled automatically during node setup
	else
		Log:Info("Connection cleanup is disabled in settings (recommended for performance)")
	end
end
