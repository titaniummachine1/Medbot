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
local DStar = require("MedBot.Utils.DStar")
local AStar = require("MedBot.Utils.A-Star")

-- Profiler disabled to prevent crashes
local Profiler = nil

-- Disable all profiler functions to prevent crashes
local function ProfilerBeginSystem(name) end
local function ProfilerEndSystem() end
local function ProfilerBegin(name) end
local function ProfilerEnd() end

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
	maxFailures = 2, -- Max failures before blocking connection temporarily (reduced from 3 for faster blocking)
	blockDuration = 300, -- Ticks to block connection (5 seconds)
	cleanupInterval = 180, -- Clean up old entries every 3 seconds (was 30s - MEMORY LEAK FIX)
	maxEntries = 500, -- Hard limit to prevent memory exhaustion (reduced from 1000)
	lastCleanup = 0,
}

-- Expose circuit breaker globally for pathfinding adjacency filter
G.CircuitBreaker = ConnectionCircuitBreaker

-- Add a connection failure to the circuit breaker (using integer keys)
local function addConnectionFailure(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	-- Use integer key instead of string concatenation
	local connectionKey = nodeA.id * 1000000 + nodeB.id -- Simple hash for unique key
	local currentTick = globals.TickCount()

	-- Initialize or update failure count
	if not ConnectionCircuitBreaker.failures[connectionKey] then
		ConnectionCircuitBreaker.failures[connectionKey] = { count = 0, lastFailTime = 0, isBlocked = false }
	end

	local failure = ConnectionCircuitBreaker.failures[connectionKey]
	failure.count = failure.count + 1
	failure.lastFailTime = currentTick

	-- Each failure adds MORE penalty (makes path progressively more expensive)
	local additionalPenalty = 100 -- Add 100 units per failure
	Node.AddFailurePenalty(nodeA, nodeB, additionalPenalty)

	Log:Info(
		"Connection %d->%d failure #%d - added %d penalty (total accumulating)",
		nodeA.id,
		nodeB.id,
		failure.count,
		additionalPenalty
	)

	-- Block connection if too many failures
	if failure.count >= ConnectionCircuitBreaker.maxFailures then
		failure.isBlocked = true
		-- Add a very large penalty so A* strongly avoids this edge
		local blockingPenalty = 5000
		Node.AddFailurePenalty(nodeA, nodeB, blockingPenalty)

		Log:Warn(
			"Connection %d->%d BLOCKED after %d failures (added final %d penalty)",
			nodeA.id,
			nodeB.id,
			failure.count,
			blockingPenalty
		)
		return true
	end

	return false
end

-- Check if a connection is blocked by circuit breaker
local function isConnectionBlocked(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	local connectionKey = nodeA.id * 1000000 + nodeB.id -- Use same integer key
	local failure = ConnectionCircuitBreaker.failures[connectionKey]

	if not failure or not failure.isBlocked then
		return false
	end

	local currentTick = globals.TickCount()
	-- Unblock if enough time has passed (penalties remain but connection becomes usable)
	if currentTick - failure.lastFailTime > ConnectionCircuitBreaker.blockDuration then
		failure.isBlocked = false
		failure.count = 0 -- Reset failure count (penalties stay, giving A* a chance to reconsider)

		Log:Info(
			"Connection %d->%d UNBLOCKED after timeout (accumulated penalties remain as lesson learned)",
			nodeA.id,
			nodeB.id
		)
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

	-- Hard cap: prune oldest non-blocked entries when table grows too large
	local limit = ConnectionCircuitBreaker.maxEntries
	local count = 0
	for _ in pairs(ConnectionCircuitBreaker.failures) do
		count = count + 1
	end
	if count > limit then
		-- Collect candidates (non-blocked) sorted by oldest lastFailTime
		local cand = {}
		for key, f in pairs(ConnectionCircuitBreaker.failures) do
			if not f.isBlocked then
				table.insert(cand, { key = key, t = f.lastFailTime or 0 })
			end
		end
		table.sort(cand, function(a, b)
			return a.t < b.t
		end)
		local toRemove = math.min(#cand, count - limit)
		for i = 1, toRemove do
			ConnectionCircuitBreaker.failures[cand[i].key] = nil
		end
		if toRemove > 0 then
			Log:Debug("Circuit breaker pruned %d oldest entries (cap=%d)", toRemove, limit)
		end
	end

	-- SIMPLE emergency cleanup: if still over limit, clear half the cache
	local finalCount = 0
	for _ in pairs(ConnectionCircuitBreaker.failures) do
		finalCount = finalCount + 1
	end
	if finalCount > limit then
		Log:Warn("Circuit breaker emergency cleanup: %d entries exceed limit %d", finalCount, limit)
		-- Simple approach: clear half the cache to prevent crash
		local cleared = 0
		local targetClear = math.floor(finalCount / 2)
		for key, _ in pairs(ConnectionCircuitBreaker.failures) do
			ConnectionCircuitBreaker.failures[key] = nil
			cleared = cleared + 1
			if cleared >= targetClear then
				break
			end
		end
		Log:Debug("Emergency cleanup cleared %d entries", cleared)
	end
end

-- Expose circuit breaker API methods on the global table
ConnectionCircuitBreaker.addConnectionFailure = addConnectionFailure
ConnectionCircuitBreaker.isConnectionBlocked = isConnectionBlocked
ConnectionCircuitBreaker.cleanupCircuitBreaker = cleanupCircuitBreaker
G.CircuitBreaker = ConnectionCircuitBreaker

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
	-- We assume the immediate next node (path[2]) is already walkable.
	-- Skip ONLY if we can walk directly to the node after next (path[3]).
	if not path or #path < 3 then
		return false
	end
	local candidate = path[3]
	local walkMode = G.Menu.Main.WalkableMode or "Smooth"
	-- If the candidate is the last node (goal), be more aggressive
	if #path == 3 then
		walkMode = "Aggressive"
	end
	if candidate and candidate.pos then
		-- Conservative guardrails to prevent over-skipping
		local horizontalManhattan = math.abs(origin.x - candidate.pos.x) + math.abs(origin.y - candidate.pos.y)
		if horizontalManhattan <= 600 and isWalkable.Path(origin, candidate.pos, walkMode) then
			-- Optional straight LOS check to avoid corner cases
			local upOffset = Vector3(0, 0, 32)
			local los = engine.TraceLine(origin + upOffset, candidate.pos + upOffset, MASK_PLAYERSOLID_BRUSHONLY)
			if los and los.fraction == 1 then
				-- Drop the current node and keep moving toward the now-next node
				Navigation.RemoveCurrentNode()
				Navigation.ResetTickTimer()
				return true
			end
		end
	end
	return false
end

function Optimiser.skipToNextIfWalkable(origin, path)
	if not path or #path < 2 then
		return false
	end
	local currentNode = path[1]
	local nextNode = path[2]
	local walkMode = G.Menu.Main.WalkableMode or "Smooth"
	if not (currentNode and nextNode and nextNode.pos) then
		return false
	end

	-- Prefer door-aware skip: ensure at least one door point for the edge is reachable
	local entry = Node.GetConnectionEntry(currentNode, nextNode)
	local candidateDoorPoints = {}
	if entry then
		-- Prefer middle, then side points
		if entry.middle then
			table.insert(candidateDoorPoints, entry.middle)
		end
		if entry.left then
			table.insert(candidateDoorPoints, entry.left)
		end
		if entry.right then
			table.insert(candidateDoorPoints, entry.right)
		end
	else
		-- Fallback single door target if no enriched entry is available
		local single = Node.GetDoorTargetPoint(currentNode, nextNode)
		if single then
			table.insert(candidateDoorPoints, single)
		end
	end

	local doorReachable = false
	for _, p in ipairs(candidateDoorPoints) do
		if isWalkable.Path(origin, p, walkMode) then
			doorReachable = true
			break
		end
	end

	-- Only skip to the next area if the door transition is actually reachable
	if doorReachable and isWalkable.Path(origin, nextNode.pos, walkMode) then
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
	-- Switch to direct-goal only when very close and definitely walkable (tight guard to avoid false clears)
	if path and #path > 1 then
		-- Final goal checks always use Aggressive mode
		local walkMode = "Aggressive"
		local horizontalManhattan = math.abs(origin.x - goalPos.x) + math.abs(origin.y - goalPos.y)
		if horizontalManhattan <= 250 and isWalkable.Path(origin, goalPos, walkMode) then
			local upOffset = Vector3(0, 0, 32)
			local los = engine.TraceLine(origin + upOffset, goalPos + upOffset, MASK_PLAYERSOLID_BRUSHONLY)
			if los and los.fraction == 1 then
				Navigation.ClearPath()
				-- Set a direct path and a single goal waypoint for clarity in movement/visuals
				G.Navigation.path = { { pos = goalPos } }
				G.Navigation.waypoints = { { pos = goalPos, kind = "goal" } }
				G.Navigation.currentWaypointIndex = 1
				G.lastPathfindingTick = 0
				Log:Debug("Direct-goal shortcut engaged (<=250u, %s mode)", walkMode)
				return true
			end
		end
	end
	return false
end

--[[ Superior WalkTo Implementation (from standstill dummy) ]]

-- Constants for physics-accurate movement
local MAX_SPEED = 450 -- Maximum speed the player can move
local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180

-- Ground-physics helpers (synced with server convars)
local DEFAULT_GROUND_FRICTION = 4 -- fallback for sv_friction
local DEFAULT_SV_ACCELERATE = 10 -- fallback for sv_accelerate

local function GetGroundFriction()
	local ok, val = pcall(client.GetConVar, "sv_friction")
	if ok and val and val > 0 then
		return val
	end
	return DEFAULT_GROUND_FRICTION
end

local function GetGroundMaxDeltaV(player, tick)
	tick = (tick and tick > 0) and tick or 1 / 66.67
	local svA = client.GetConVar("sv_accelerate") or 0
	if svA <= 0 then
		svA = DEFAULT_SV_ACCELERATE
	end

	local cap = player and player:GetPropFloat("m_flMaxspeed") or MAX_SPEED
	if not cap or cap <= 0 then
		cap = MAX_SPEED
	end

	return svA * cap * tick
end

-- Computes the move vector between two points
local function ComputeMove(userCmd, a, b)
	local dx, dy = b.x - a.x, b.y - a.y

	local targetYaw = (math.atan(dy, dx) + TWO_PI) % TWO_PI
	local _, currentYaw = userCmd:GetViewAngles()
	currentYaw = currentYaw * DEG_TO_RAD

	local yawDiff = (targetYaw - currentYaw + math.pi) % TWO_PI - math.pi

	return Vector3(math.cos(yawDiff) * MAX_SPEED, math.sin(-yawDiff) * MAX_SPEED, 0)
end

-- Predictive/no-overshoot WalkTo (superior implementation from standstill dummy)
local function WalkTo(cmd, player, dest)
	if not (cmd and player and dest) then
		return
	end

	local pos = player:GetAbsOrigin()
	if not pos then
		return
	end

	local tick = globals.TickInterval()
	if tick <= 0 then
		tick = 1 / 66.67
	end

	-- Current horizontal velocity (ignore Z)
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0

	-- Predict passive drag to next tick
	local drag = math.max(0, 1 - GetGroundFriction() * tick)
	local velNext = vel * drag
	local predicted = Vector3(pos.x + velNext.x * tick, pos.y + velNext.y * tick, pos.z)

	-- Remaining displacement after coast
	local need = dest - predicted
	need.z = 0
	local dist = need:Length()
	if dist < 1.5 then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	-- Velocity we need at start of next tick to land on dest
	local deltaV = (need / tick) - velNext
	local deltaLen = deltaV:Length()
	if deltaLen < 0.1 then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	-- Accel clamp from sv_accelerate
	local aMax = GetGroundMaxDeltaV(player, tick)
	local accelDir = deltaV / deltaLen
	local accelLen = math.min(deltaLen, aMax)

	-- wishspeed proportional to allowed Δv
	local wishSpeed = math.max(MAX_SPEED * (accelLen / aMax), 20)

	-- Overshoot guard
	local maxNoOvershoot = dist / tick
	wishSpeed = math.min(wishSpeed, maxNoOvershoot)
	if wishSpeed < 5 then
		wishSpeed = 0
	end

	-- Convert accelDir into local move inputs
	local dirEnd = pos + accelDir
	local moveVec = ComputeMove(cmd, pos, dirEnd)
	local fwd = (moveVec.x / MAX_SPEED) * wishSpeed
	local side = (moveVec.y / MAX_SPEED) * wishSpeed

	cmd:SetForwardMove(fwd)
	cmd:SetSideMove(side)
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
		if distance > 25 and distance < 250 then -- Only if close enough to justify direct
			ProfilerBegin("direct_walk_check")
			-- Final goal checks always use Aggressive mode to allow duck-jumps up to 72u
			local walkMode = "Aggressive"

			-- Require line-of-sight hull trace in addition to walkability
			local up = Vector3(0, 0, 32)
			local los = engine.TraceLine(G.pLocal.Origin + up, goalPos + up, MASK_PLAYERSOLID_BRUSHONLY)
			if (los and los.fraction == 1) and isWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
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
	if not WorkManager.attemptWork(60, "PathfindingCooldown") then
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

	-- Track when we change to a new goal
	local previousGoalId = G._previousGoalId
	if previousGoalId ~= goalNode.id then
		G.lastGoalChangeTick = globals.TickCount()
		G._previousGoalId = goalNode.id
		Log:Debug("Goal changed from %s to %d", tostring(previousGoalId), goalNode.id)
	end

	-- Avoid pathfinding if we're already at the goal
	if startNode.id == goalNode.id then
		-- Try direct movement or internal path before giving up
		-- Final goal checks always use Aggressive mode
		local walkMode = "Aggressive"

		if goalPos and isWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
			G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
			G.currentState = G.States.MOVING
			G.lastPathfindingTick = currentTick
			Log:Info("Moving directly to goal with %s mode from goal node %d", walkMode, startNode.id)
		else
			-- Try internal path if aggressive also fails
			local internal = Navigation.GetInternalPath(G.pLocal.Origin, goalPos)
			if internal then
				G.Navigation.path = internal
				G.currentState = G.States.MOVING
				G.lastPathfindingTick = currentTick
				Log:Info("Using internal path")
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
	-- Direct pathfinding call instead of scheduling work
	Navigation.FindPath(startNode, goalNode)
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
		-- Reset failure counter on success
		G.pathfindingFailures = 0
	elseif Navigation.pathFailed then
		Log:Warn("Pathfinding failed")

		-- Increment failure counter
		G.pathfindingFailures = (G.pathfindingFailures or 0) + 1

		-- If we've failed too many times in a row, take a longer break
		if G.pathfindingFailures >= 5 then
			Log:Warn("Pathfinding failed %d times in a row - taking extended break", G.pathfindingFailures)

			-- Clear the current goal to force finding a new one
			G.Navigation.goalPos = nil
			G.Navigation.goalNodeId = nil
			G.pathfindingFailures = 0 -- Reset failure counter

			-- Set a much longer cooldown to prevent immediate repathing
			G.lastRepathTick = globals.TickCount()
			G.extendedBreakUntil = globals.TickCount() + 300 -- 5 second break

			G.currentState = G.States.IDLE
			Navigation.pathFailed = false
			return
		end

		G.currentState = G.States.IDLE
		Navigation.pathFailed = false
	else
		-- If we're in pathfinding state but no work is in progress, start pathfinding
		local pathfindingWork = WorkManager.works["Pathfinding"]
		if not pathfindingWork or pathfindingWork.wasExecuted then
			-- Check if we're in an extended break
			if G.extendedBreakUntil and globals.TickCount() < G.extendedBreakUntil then
				-- Still in extended break, stay in IDLE
				return
			end

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

					-- Use WorkManager for cooldown with increasing delay based on failure count
					local cooldownTicks = 30 + (G.pathfindingFailures or 0) * 15 -- 30 + 15 per failure

					if WorkManager.attemptWork(cooldownTicks, "RepathCooldown") then
						Log:Info(
							"Repathing from stuck state: node %d to node %d (failure #%d)",
							startNode.id,
							goalNode.id,
							G.pathfindingFailures or 0
						)
						-- Direct pathfinding call instead of scheduling work
						Navigation.FindPath(startNode, goalNode)
					else
						-- Throttle noisy log to avoid console spam and overhead
						if WorkManager.attemptWork(30, "RepathWaitLog") then
							Log:Debug("Repath cooldown active, waiting... (cooldown: %d ticks)", cooldownTicks)
						end
					end
				else
					Log:Debug("Cannot repath - invalid start/goal nodes, returning to IDLE")
					G.currentState = G.States.IDLE
					G.pathfindingFailures = 0 -- Reset on invalid nodes
				end
			else
				Log:Debug("No existing goal for repath, returning to IDLE")
				G.currentState = G.States.IDLE
				G.pathfindingFailures = 0 -- Reset on no goal
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
	-- Simplified: no circuit-breaker gating here

	moveTowardsNode(userCmd, currentNode)

	-- Only detect stuck; actual penalties applied in STUCK state every ~1s
	if G.Navigation.currentNodeTicks > 66 then
		-- Remember last node before stuck to target penalty precisely
		local hist = G.Navigation.pathHistory or {}
		G.Navigation.lastPreStuckNodeId = (hist[1] and hist[1].id) or nil
		G.Navigation.currentStuckTargetNodeId = currentNode and currentNode.id or nil

		G.currentState = G.States.STUCK
		ProfilerEnd()
		return
	end

	ProfilerEnd()
end

-- Function to handle the STUCK state
function handleStuckState(userCmd)
	ProfilerBegin("stuck_state_penalise_backtrace")

	local currentTick = globals.TickCount()
	if not G.Navigation._lastStuckEval then
		G.Navigation._lastStuckEval = 0
	end

	-- Evaluate roughly every second (~66 ticks)
	if (currentTick - G.Navigation._lastStuckEval) < 66 then
		ProfilerEnd()
		return
	end
	G.Navigation._lastStuckEval = currentTick

	local path = G.Navigation.path
	if path and #path > 1 then
		local fromNode = path[1]
		local toNode = path[2]
		if fromNode and toNode and fromNode.id and toNode.id and fromNode.id ~= toNode.id then
			local walkMode = G.Menu.Main.WalkableMode or "Smooth"
			local blocked = not isWalkable.Path(G.pLocal.Origin, toNode.pos, walkMode)

			-- Also treat zero-velocity / no-progress as stuck
			local origin = G.pLocal.Origin
			local ent = G.pLocal and G.pLocal.entity or nil
			local vel = ent and ent.EstimateAbsVelocity and ent:EstimateAbsVelocity() or Vector3(0, 0, 0)
			if vel then vel.z = 0 end
			local speed = vel and vel.Length and vel:Length() or 0
			local distNow = (toNode.pos - origin):Length()
			local lastDist = G.Navigation._lastStuckEvalDist or distNow
			local progress = lastDist - distNow
			G.Navigation._lastStuckEvalDist = distNow
			-- Thresholds: very low speed and negligible progress since last evaluation (~1s)
			local stall = (speed < 10) and (progress < 8)

			if blocked or stall then
				-- Penalize the exact current edge (door) from fromNode -> toNode
				if fromNode and toNode and fromNode.id ~= toNode.id then
					Node.AddFailurePenalty(fromNode, toNode, 100)
					Log:Debug("STUCK: current edge penalty applied %d -> %d (+100)", fromNode.id, toNode.id)
					-- Record a circuit-breaker failure for this edge
					if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
						G.CircuitBreaker.addConnectionFailure(fromNode, toNode)
						Log:Debug("STUCK: recorded connection failure %d -> %d", fromNode.id, toNode.id)
					end
				end

				-- Build up to two prior edges: prev2->prev1, prev1->fromNode
				local edges = {}
				local hist = G.Navigation.pathHistory or {}
				-- Edge 1: prev2 -> prev1
				if hist[2] and hist[1] then
					edges[#edges + 1] = { a = hist[2], b = hist[1] }
				end
				-- Edge 2: prev1 -> fromNode
				if hist[1] then
					edges[#edges + 1] = { a = hist[1], b = fromNode }
				end

				-- Additionally, penalize remembered last->current edge for precise targeting
				local nodesTbl = G.Navigation.nodes
				if nodesTbl and G.Navigation.lastPreStuckNodeId then
					local lastNode = nodesTbl[G.Navigation.lastPreStuckNodeId]
					if lastNode and fromNode then
						edges[#edges + 1] = { a = lastNode, b = fromNode, remembered = true }
					end
				end
				-- Note: do not add the current from->to edge; we focus on prior/remembered edges only

				for _, e in ipairs(edges) do
					if e.a and e.b and e.a.id and e.b.id and e.a.id ~= e.b.id then
						Node.AddFailurePenalty(e.a, e.b, 100)
						if e.remembered then
							Log:Debug("STUCK: remembered edge penalty applied %d -> %d (+100)", e.a.id, e.b.id)
						end
						-- Record circuit-breaker failure for prior/remembered edges as well
						if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
							G.CircuitBreaker.addConnectionFailure(e.a, e.b)
						end
					end
				end

				if blocked then
					Log:Info(
						"STUCK: destination unwalkable (%s). Penalised prior edges near %d -> %d and repathing",
						walkMode,
						fromNode.id,
						toNode.id
					)
				else
					Log:Info(
						"STUCK: no progress (speed=%.1f, progress=%.1f). Penalised prior edges near %d -> %d and repathing",
						speed,
						progress,
						fromNode.id,
						toNode.id
					)
				end

				-- Clear traversal history and remembered IDs for the new attempt
				G.Navigation.pathHistory = {}
				G.Navigation.lastPreStuckNodeId = nil
				G.Navigation.currentStuckTargetNodeId = nil

				-- Trigger repath and continue
				Navigation.ResetTickTimer()
				G.currentState = G.States.PATHFINDING
				G.lastPathfindingTick = 0
				ProfilerEnd()
				return
			else
				-- Not blocked anymore: resume moving
				Navigation.ResetTickTimer()
				G.currentState = G.States.MOVING
				ProfilerEnd()
				return
			end
		end
	end

	-- Fallback: if no path or invalid, return to PATHFINDING
	Navigation.ResetTickTimer()
	G.currentState = G.States.PATHFINDING
	G.lastPathfindingTick = 0
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

	-- No early circuit-breaker gating; proceed with movement

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

	-- Only rotate camera if LookingAhead is enabled (toward actual movement target, not last area)
	ProfilerBegin("camera_rotation")
	if G.Menu.Main.LookingAhead then
		local pLocalWrapped = WPlayer.GetLocal()
		local eyePos = pLocalWrapped:GetEyePos()
		local lookTarget = G.Navigation.currentTargetPos or node.pos
		local angles = Lib.Utils.Math.PositionAngles(eyePos, lookTarget)
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
	local targetCenter = node.pos
	if G.Navigation.path and #G.Navigation.path > 1 then
		targetCenter = G.Navigation.path[2].pos
	end
	local horizontalDist = math.abs(LocalOrigin.x - targetCenter.x) + math.abs(LocalOrigin.y - targetCenter.y)
	local verticalDist = math.abs(LocalOrigin.z - targetCenter.z)

	-- Check if we've reached the current node
	if (horizontalDist < G.Misc.NodeTouchDistance) and verticalDist <= G.Misc.NodeTouchHeight then
		-- Entered next area center: reset edge stage and advance path
		G.Navigation.edgeStage = nil
		G.Navigation.edgeKey = nil
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
	--  Node Skipping - Simple and deterministic: next center only
	------------------------------------------------------------
	ProfilerBegin("node_skipping")
	if G.Menu.Main.Skip_Nodes and #G.Navigation.path > 1 then
		local now = globals.TickCount()
		if not G.lastNodeSkipTick then
			G.lastNodeSkipTick = 0
		end
		if (now - G.lastNodeSkipTick) >= 3 then -- ~50 ms cadence
			G.lastNodeSkipTick = now
			if Optimiser.skipToNextIfWalkable(LocalOrigin, G.Navigation.path) then
				node = G.Navigation.path[1] or node
				Navigation.ResetTickTimer()
			end
		end
	end
	ProfilerEnd()

	ProfilerBegin("movement_execution")
	-- Store current button state before WalkTo (SmartJump may have set jump/duck buttons)
	local originalButtons = userCmd.buttons

	-- Use explicit door-aware waypoints built by Navigation
	local destPos = node.pos
	local wp = Navigation.GetCurrentWaypoint()
	if wp then
		if wp.kind == "door" and wp.points and #wp.points > 0 then
			-- Use the closest of available door points as current target
			local best, bestD = nil, math.huge
			for _, p in ipairs(wp.points) do
				local d = (LocalOrigin - p):Length()
				if d < bestD then
					best, bestD = p, d
				end
			end
			if best then
				destPos = best
			end
			if bestD < (G.Misc.NodeTouchDistance * 1.5) then
				Navigation.AdvanceWaypoint()
				Navigation.ResetTickTimer()
				-- Refresh waypoint to avoid drawing stale door residue
				wp = Navigation.GetCurrentWaypoint()
				if wp and wp.pos then
					destPos = wp.pos
				end
			end
		elseif wp.kind == "center" and wp.pos then
			destPos = wp.pos
			local distToWp = (LocalOrigin - destPos):Length()
			if distToWp < (G.Misc.NodeTouchDistance * 1.5) then
				Navigation.AdvanceWaypoint()
				Navigation.ResetTickTimer()
				-- After advancing center, publish next target if any
				local nextWp = Navigation.GetCurrentWaypoint()
				if nextWp then
					if nextWp.pos then
						destPos = nextWp.pos
					elseif nextWp.points and #nextWp.points > 0 then
						destPos = nextWp.points[1]
					end
				end
			end
		elseif wp.kind == "goal" and wp.pos then
			-- Final exact destination: prioritize reaching it even if area path is done
			destPos = wp.pos
			local distToGoal = (LocalOrigin - destPos):Length()
			if distToGoal < (G.Misc.NodeTouchDistance * 1.5) then
				-- Goal reached; clear path and waypoints and go idle
				Navigation.ClearPath()
				G.currentState = G.States.IDLE
				G.lastPathfindingTick = 0
				Navigation.ResetTickTimer()
				ProfilerEnd()
				return
			end
		end
	end

	-- Publish the current movement target for visuals
	G.Navigation.currentTargetPos = destPos

	-- Use superior physics-accurate movement from standstill dummy
	WalkTo(userCmd, G.pLocal.entity, destPos)

	-- Preserve SmartJump button inputs (jump and duck commands)
	-- WalkTo only sets forward/side move, so button state is preserved automatically
	local smartJumpButtons = originalButtons & (IN_JUMP | IN_DUCK)
	if smartJumpButtons ~= 0 then
		userCmd:SetButtons(userCmd.buttons | smartJumpButtons)
	end

	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
	ProfilerEnd()

	-- No heavy stuck analysis here; handle moving-state simple repath instead

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
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		G.currentState = G.States.IDLE
		Navigation.ClearPath()
		return
	end

	if not G.prevState then
		G.prevState = G.currentState
	end

	-- If bot is disabled via menu, do nothing
	if not G.Menu.Main.Enable then
		Navigation.ClearPath()
		G.BotIsMoving = false -- Clear bot movement state when disabled
		return
	end

	G.pLocal.entity = pLocal
	G.pLocal.flags = pLocal:GetPropInt("m_fFlags")
	G.pLocal.Origin = pLocal:GetAbsOrigin()

	-- PERFORMANCE FIX: Only run memory cleanup every 300 ticks (5 seconds) to prevent frame drops
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
			-- Cap cache size aggressively to avoid unbounded growth (reduced from 2000 to 1000)
			local count = 0
			for _ in pairs(G.walkabilityCache) do
				count = count + 1
			end
			if count > 1000 then
				-- More efficient cleanup: collect entries with timestamps and sort by oldest first
				local entries = {}
				for key, entry in pairs(G.walkabilityCache) do
					table.insert(entries, { key = key, timestamp = entry.timestamp })
				end
				table.sort(entries, function(a, b)
					return a.timestamp < b.timestamp
				end)

				local targetRemove = count - 800 -- Leave some headroom
				for i = 1, math.min(targetRemove, #entries) do
					G.walkabilityCache[entries[i].key] = nil
				end
				Log:Debug("Pruned walkability cache: %d/%d entries removed (cap=1000)", targetRemove, count)
			end
		end

		G.lastCleanupTick = currentTick
	end

	-- Circuit breaker cleanup
	if G.CircuitBreaker and G.CircuitBreaker.cleanupCircuitBreaker then
		G.CircuitBreaker.cleanupCircuitBreaker()
	end

	-- Circuit breaker is unused by simplified unstuck; skip maintenance
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

	-- PRIORITY CHECK: Use WorkManager for cooldown instead of inline tick math
	ProfilerBegin("priority_check")
	local currentTask = Common.GetHighestPriorityTask()

	-- Only run expensive priority checks every 30 ticks, and never while traversing a door
	local shouldRunPriorityCheck = false
	if not G.Navigation.goalPos then
		shouldRunPriorityCheck = true
	else
		if not (G.Navigation.edgeStage == "toDoor") and WorkManager.attemptWork(30, "PriorityCheck") then
			shouldRunPriorityCheck = true
		end
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

				-- Final objective reachability check uses Aggressive regardless of option
				local walkMode = "Aggressive"
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
						-- Do not return early: allow movement handling this tick to avoid stutter
					end
				end
			end
		end
	end
	ProfilerEnd()

	-- STATE HANDLING: Schedule via WorkManager to smooth CPU spikes
	ProfilerBegin("state_handling")
	local state = G.currentState
	if state == G.States.MOVING then
		if WorkManager.attemptWork(1, "State.MOVING") then
			handleMovingState(userCmd)
		end
	elseif state == G.States.PATHFINDING then
		if WorkManager.attemptWork(4, "State.PATHFINDING") then
			handlePathfindingState()
		end
	elseif state == G.States.IDLE then
		if WorkManager.attemptWork(4, "State.IDLE") then -- run at most every 2 ticks
			handleIdleState()
		end
	elseif state == G.States.STUCK then
		if WorkManager.attemptWork(4, "State.STUCK") then
			handleStuckState(userCmd)
		end
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
				-- Use Aggressive when very close to final goal
				local walkMode = "Aggressive"
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
	ProfilerBeginSystem("draw_model")

	if ctx:GetModelName():find("medkit") then
		local entity = ctx:GetEntity()
		G.World.healthPacks[entity:GetIndex()] = entity:GetAbsOrigin()
	end

	ProfilerEndSystem()
end

---@param event GameEvent
local function OnGameEvent(event)
	ProfilerBeginSystem("game_event")

	local eventName = event:GetName()

	if eventName == "game_newmap" then
		Log:Info("New map detected, reloading nav file...")
		Navigation.Setup()
	end

	ProfilerEndSystem()
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
	Node.ResetSetup()
	Navigation.Setup()
end)

Commands.Register("pf_circuit_breaker", function(args)
	if not args or not args[1] then
		print("Circuit Breaker Commands:")
		print("  status - Show current circuit breaker status")
		print("  clear - Clear all circuit breaker data")
		print("  block <nodeA> <nodeB> - Manually block a connection")
		print("  unblock <nodeA> <nodeB> - Manually unblock a connection")
		print("  test_cost <nodeA> <nodeB> - Test cost assignment")
		return
	end

	if args[1] == "test_cost" and args[2] and args[3] then
		local nodeA_id = tonumber(args[2])
		local nodeB_id = tonumber(args[3])
		if nodeA_id and nodeB_id then
			local nodes = G.Navigation.nodes
			local nodeA = nodes[nodeA_id]
			local nodeB = nodes[nodeB_id]

			if nodeA and nodeB then
				print(string.format("Testing cost assignment for %d->%d:", nodeA_id, nodeB_id))

				-- Get current cost
				local currentCost = nil
				for _, cDir in pairs(nodeA.c or {}) do
					if cDir and cDir.connections then
						for _, connection in pairs(cDir.connections) do
							local targetNodeId = connection.node
							if targetNodeId == nodeB_id then
								currentCost = connection.cost or 1
								print(string.format("  Current cost: %.1f", currentCost))
								break
							end
						end
					end
				end

				-- Add penalty
				Node.AddFailurePenalty(nodeA, nodeB, 500)
				print("  Added 500 penalty")

				-- Check new cost
				local newCost = nil
				for _, cDir in pairs(nodeA.c or {}) do
					if cDir and cDir.connections then
						for _, connection in pairs(cDir.connections) do
							local targetNodeId = connection.node
							if targetNodeId == nodeB_id then
								newCost = connection.cost or 1
								print(string.format("  New cost: %.1f", newCost))
								break
							end
						end
					end
				end

				if currentCost and newCost then
					print(string.format("  Cost change: %.1f -> %.1f", currentCost, newCost))
				else
					print("  Could not find connection!")
				end
			else
				print(string.format("Nodes %d or %d not found", nodeA_id, nodeB_id))
			end
		else
			print("Usage: pf_circuit_breaker test_cost <nodeA_id> <nodeB_id>")
		end
		return
	end

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

			-- Convert integer key back to readable format
			local nodeA_id = math.floor(connectionKey / 1000000)
			local nodeB_id = connectionKey % 1000000
			print(string.format("  %d->%d: %d failures, %s%s", nodeA_id, nodeB_id, failure.count, status, timeLeft))
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
			local connectionKey = nodeA * 1000000 + nodeB
			ConnectionCircuitBreaker.failures[connectionKey] = {
				count = ConnectionCircuitBreaker.maxFailures,
				lastFailTime = globals.TickCount(),
				isBlocked = true,
			}
			print(string.format("Manually blocked connection %d->%d", nodeA, nodeB))
		else
			print("Usage: pf_circuit_breaker block <nodeA_id> <nodeB_id>")
		end
	elseif args[1] == "unblock" and args[2] and args[3] then
		local nodeA = tonumber(args[2])
		local nodeB = tonumber(args[3])
		if nodeA and nodeB then
			local connectionKey = nodeA * 1000000 + nodeB
			if ConnectionCircuitBreaker.failures[connectionKey] then
				ConnectionCircuitBreaker.failures[connectionKey].isBlocked = false
				ConnectionCircuitBreaker.failures[connectionKey].count = 0
				print(string.format("Manually unblocked connection %d->%d", nodeA, nodeB))
			else
				print(string.format("Connection %d->%d not found in circuit breaker", nodeA, nodeB))
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
	Notify.Simple("Hierarchical pathfinding removed", "Using simplified pathfinding system", 5)
	print("Hierarchical pathfinding has been removed from this version.")
	print("The simplified pathfinding system works without hierarchical data.")
end)

Commands.Register("pf_test_hierarchical", function()
	print("Hierarchical pathfinding has been removed from this version.")
	print("The simplified pathfinding system works without hierarchical data.")
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

Commands.Register("pf_debug", function(args)
	if args[1] == "path" then
		if args[2] and args[3] then
			local startId = tonumber(args[2])
			local goalId = tonumber(args[3])

			if startId and goalId then
				local nodes = G.Navigation.nodes
				local startNode = nodes[startId]
				local goalNode = nodes[goalId]

				if startNode and goalNode then
					print(string.format("Testing pathfinding from node %d to node %d", startId, goalId))
					print(
						string.format(
							"Start pos: [%.1f, %.1f, %.1f]",
							startNode.pos.x,
							startNode.pos.y,
							startNode.pos.z
						)
					)
					print(string.format("Goal pos: [%.1f, %.1f, %.1f]", goalNode.pos.x, goalNode.pos.y, goalNode.pos.z))

					-- Test adjacency function first
					print("Testing adjacency function...")
					local success, adjacent = pcall(Node.GetAdjacentNodesSimple, startNode, nodes)
					if not success then
						print("ERROR: Adjacency function failed - " .. tostring(adjacent))
						return
					end

					if not adjacent or #adjacent == 0 then
						print("ERROR: No adjacent nodes found - start node may be isolated")
						return
					end

					print(string.format("Start node has %d connections:", #adjacent))
					for i, adj in ipairs(adjacent) do
						if i <= 5 then -- Show first 5
							print(string.format("  -> %d (cost: %.1f)", adj.node.id, adj.cost))
						end
					end
					if #adjacent > 5 then
						print(string.format("  ... and %d more connections", #adjacent - 5))
					end

					-- Try D* pathfinding with safety
					print("Attempting D* pathfinding...")
					local success, path =
						pcall(DStar.NormalPath, startNode, goalNode, nodes, Node.GetAdjacentNodesSimple)

					if not success then
						print("ERROR: D* pathfinding failed with error - " .. tostring(path))
						print("Trying A* fallback...")

						success, path = pcall(AStar.NormalPath, startNode, goalNode, nodes, Node.GetAdjacentNodesSimple)
						if not success then
							print("ERROR: A* fallback also failed - " .. tostring(path))
							return
						elseif path then
							print("A* fallback succeeded!")
						end
					end

					if path then
						print(string.format("Success! Path found with %d nodes:", #path))
						for i, pathNode in ipairs(path) do
							if i <= 10 then -- Show first 10
								print(string.format("  %d. Node %d", i, pathNode.id))
							end
						end
						if #path > 10 then
							print(string.format("  ... and %d more nodes", #path - 10))
						end
					else
						print("FAILED - No path found!")

						-- Check if nodes are isolated (with safety)
						print("Checking connectivity...")
						local visited = {}
						local queue = { startNode }
						visited[startNode.id] = true
						local reachableCount = 0

						while #queue > 0 and reachableCount < 1000 do
							local current = table.remove(queue, 1)
							reachableCount = reachableCount + 1

							local success, neighbors = pcall(Node.GetAdjacentNodesSimple, current, nodes)
							if not success then
								print("ERROR: Failed to get neighbors during connectivity check")
								break
							end

							for _, neighbor in ipairs(neighbors) do
								if not visited[neighbor.node.id] then
									visited[neighbor.node.id] = true
									table.insert(queue, neighbor.node)
								end
							end
						end

						print(string.format("Can reach %d nodes from start node", reachableCount))
						if visited[goalId] then
							print("Goal IS reachable - there may be a bug in pathfinding algorithm")
						else
							print("Goal is NOT reachable - nodes are disconnected")
						end
					end
				else
					print(string.format("Invalid nodes: start=%s, goal=%s", tostring(startNode), tostring(goalNode)))
				end
			else
				print("Usage: pf_debug path <startNodeId> <goalNodeId>")
			end
		else
			print("Usage: pf_debug path <startNodeId> <goalNodeId>")
		end
	else
		print("Usage: pf_debug path <startNodeId> <goalNodeId>")
		print("  path - Debug pathfinding between two specific nodes")
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

Commands.Register("pf_test_circuit", function()
	print("Testing circuit breaker functionality...")

	if not G.CircuitBreaker then
		print("ERROR: Circuit breaker not initialized")
		return
	end

	if not G.CircuitBreaker.addConnectionFailure then
		print("ERROR: addConnectionFailure function not available")
		return
	end

	print("Circuit breaker is properly initialized")
	print("Functions available:")
	print("  - addConnectionFailure: " .. tostring(G.CircuitBreaker.addConnectionFailure ~= nil))
	print("  - isConnectionBlocked: " .. tostring(G.CircuitBreaker.isConnectionBlocked ~= nil))
	print("  - cleanupCircuitBreaker: " .. tostring(G.CircuitBreaker.cleanupCircuitBreaker ~= nil))

	-- Test with dummy nodes
	local dummyNodeA = { id = 999999 }
	local dummyNodeB = { id = 999998 }

	local success, result = pcall(G.CircuitBreaker.addConnectionFailure, dummyNodeA, dummyNodeB)
	if success then
		print("addConnectionFailure test: SUCCESS")
	else
		print("addConnectionFailure test: FAILED - " .. tostring(result))
	end
end)

Commands.Register("pf_test_astar", function(args)
	if args[1] and args[2] then
		local startId = tonumber(args[1])
		local goalId = tonumber(args[2])

		if startId and goalId then
			local nodes = G.Navigation.nodes
			local startNode = nodes[startId]
			local goalNode = nodes[goalId]

			if startNode and goalNode then
				print(string.format("Testing A* from node %d to node %d", startId, goalId))

				-- Test adjacency function
				local success, adjacent = pcall(Node.GetAdjacentNodesSimple, startNode, nodes)
				if success and adjacent and #adjacent > 0 then
					print(string.format("Start node has %d connections", #adjacent))

					-- Test A* pathfinding
					local success, path =
						pcall(AStar.NormalPath, startNode, goalNode, nodes, Node.GetAdjacentNodesSimple)
					if success and path then
						print(string.format("A* SUCCESS: Found path with %d nodes", #path))
						for i, node in ipairs(path) do
							if i <= 5 then
								print(string.format("  %d. Node %d", i, node.id))
							end
						end
						if #path > 5 then
							print(string.format("  ... and %d more nodes", #path - 5))
						end
					else
						print("A* FAILED: No path found")
					end
				else
					print("ERROR: Could not get adjacent nodes")
				end
			else
				print(string.format("ERROR: Nodes %d or %d not found", startId, goalId))
			end
		else
			print("Usage: pf_test_astar <startNodeId> <goalNodeId>")
		end
	else
		print("Usage: pf_test_astar <startNodeId> <goalNodeId>")
	end
end)
