local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = {[{}] = true}

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
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
	maxFailures = 2, -- Max failures before blocking connection temporarily (reduced from 3 for faster blocking)
	blockDuration = 300, -- Ticks to block connection (5 seconds)
	cleanupInterval = 1800, -- Clean up old entries every 30 seconds
	lastCleanup = 0,
}

-- Add a connection failure to the circuit breaker
local function addConnectionFailure(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
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

	-- Each failure adds MORE penalty (makes path progressively more expensive)
	local additionalPenalty = 100 -- Add 100 units per failure
	Node.AddFailurePenalty(nodeA, nodeB, additionalPenalty)

	Log:Debug(
		"Connection %s failure #%d - added %d penalty (total accumulating)",
		connectionKey,
		failure.count,
		additionalPenalty
	)

	-- Block connection if too many failures
	if failure.count >= ConnectionCircuitBreaker.maxFailures then
		failure.isBlocked = true
		-- Add a big penalty to ensure A* avoids this completely
		local blockingPenalty = 500
		Node.AddFailurePenalty(nodeA, nodeB, blockingPenalty)

		Log:Warn(
			"Connection %s BLOCKED after %d failures (added final %d penalty)",
			connectionKey,
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

	local connectionKey = nodeA.id .. "->" .. nodeB.id
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
			"Connection %s UNBLOCKED after timeout (accumulated penalties remain as lesson learned)",
			connectionKey
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
	local limit = 1000
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
	if candidate and candidate.pos and isWalkable.Path(origin, candidate.pos, walkMode) then
		-- Drop the current node and keep moving toward the now-next node
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
	-- Switch to direct-goal whenever it's reachable and we still have multiple areas to traverse
	if path and #path > 1 then
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		if isWalkable.Path(origin, goalPos, walkMode) then
			Navigation.ClearPath()
			-- Set a direct path and a single goal waypoint for clarity in movement/visuals
			G.Navigation.path = { { pos = goalPos } }
			G.Navigation.waypoints = { { pos = goalPos, kind = "goal" } }
			G.Navigation.currentWaypointIndex = 1
			G.lastPathfindingTick = 0
			Log:Info("Direct-goal shortcut – moving straight with %s mode (distance: %.1f)", walkMode, dist)
			return true
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

		-- Use aggressive mode for CTF intel objectives to handle intel on tables (like 2fort)
		if currentTask == "Objective" and mapName:find("ctf_") then
			local pLocal = G.pLocal.entity
			local myItem = pLocal:GetPropInt("m_hItem")
			-- If not carrying intel (trying to get enemy intel), use aggressive mode
			if myItem <= 0 then
				walkMode = "Aggressive"
				Log:Info("Using Aggressive mode for CTF intel objective (intel on table)")
			end
		end

		if goalPos and isWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
			G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
			G.currentState = G.States.MOVING
			G.lastPathfindingTick = currentTick
			Log:Info("Moving directly to goal with %s mode from goal node %d", walkMode, startNode.id)
		else
			-- If normal walkMode fails, try aggressive mode as fallback for any objective
			if walkMode ~= "Aggressive" and currentTask == "Objective" then
				Log:Info("Normal walkMode failed, trying Aggressive mode as fallback")
				if isWalkable.Path(G.pLocal.Origin, goalPos, "Aggressive") then
					G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
					G.currentState = G.States.MOVING
					G.lastPathfindingTick = currentTick
					Log:Info("Aggressive mode fallback successful")
				else
					-- Try internal path if aggressive also fails
					local internal = Navigation.GetInternalPath(G.pLocal.Origin, goalPos)
					if internal then
						G.Navigation.path = internal
						G.currentState = G.States.MOVING
						G.lastPathfindingTick = currentTick
						Log:Info("Using internal path as final fallback")
					else
						Log:Debug(
							"Already at goal node %d, staying in IDLE (all direct movement attempts failed)",
							startNode.id
						)
						G.lastPathfindingTick = currentTick
					end
				end
			else
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
						-- Throttle noisy log to avoid console spam and overhead
						if not G._lastRepathWaitLog or (currentTick - G._lastRepathWaitLog) > 30 then
							Log:Debug("Repath cooldown active, waiting...")
							G._lastRepathWaitLog = currentTick
						end
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
		local currentNode, nextNode

		-- Determine which path segment we are closest to
		local closestIndex, closestDist = 1, math.huge
		local pPos = G.pLocal.Origin
		for i = 1, #path do
			local node = path[i]
			local dist = (node.pos - pPos):Length()
			if dist < closestDist then
				closestDist = dist
				closestIndex = i
			end
		end

		if closestIndex >= #path then
			closestIndex = #path - 1
		end

		if closestIndex >= 1 then
			currentNode = path[closestIndex]
			nextNode = path[closestIndex + 1]
		end

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
			local currentNode, nextNode
			-- Reuse closest segment logic to target the problematic edge
			local closestIndex, closestDist = 1, math.huge
			local pPos = G.pLocal.Origin
			for i = 1, #path do
				local node = path[i]
				local dist = (node.pos - pPos):Length()
				if dist < closestDist then
					closestDist = dist
					closestIndex = i
				end
			end

			if closestIndex >= #path then
				closestIndex = #path - 1
			end

			if closestIndex >= 1 then
				currentNode = path[closestIndex]
				nextNode = path[closestIndex + 1]
			end
			-- Better validation to prevent invalid penalties
			if currentNode and nextNode and currentNode.id and nextNode.id and currentNode.id ~= nextNode.id then
				-- Only do expensive walkability check if not already blocked by circuit breaker
				if not connectionBlocked then
					local walkMode = G.Menu.Main.WalkableMode or "Smooth"
					local stuckPenalty = 75 -- Base penalty to add for being stuck

					if not isWalkable.Path(G.pLocal.Origin, nextNode.pos, walkMode) then
						if isWalkable.Path(G.pLocal.Origin, nextNode.pos, "Aggressive") then
							stuckPenalty = 150 -- Mode-specific stuck penalty
							Log:Debug(
								"Stuck connection %d -> %d: fails with %s but works with Aggressive - adding %d penalty",
								currentNode.id,
								nextNode.id,
								walkMode,
								stuckPenalty
							)
						else
							stuckPenalty = 250 -- Complete blockage stuck penalty
							Log:Debug(
								"Stuck connection %d -> %d: completely blocked - adding %d penalty",
								currentNode.id,
								nextNode.id,
								stuckPenalty
							)
						end
					else
						Log:Debug(
							"Stuck connection %d -> %d: walkable but still stuck (collision/geometry issue?) - adding %d penalty",
							currentNode.id,
							nextNode.id,
							stuckPenalty
						)
					end

					-- Add the penalty (accumulates with all previous penalties)
					Node.AddFailurePenalty(currentNode, nextNode, stuckPenalty)

					-- Add to circuit breaker - if this returns true, connection is now blocked
					if addConnectionFailure(currentNode, nextNode) then
						Log:Error(
							"Connection %d -> %d has failed too many times - temporarily BLOCKED",
							currentNode.id,
							nextNode.id
						)
					end

					Log:Info(
						"Added stuck penalty %d to connection %d -> %d after %d ticks stuck (accumulating)",
						stuckPenalty,
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
			-- Also reset per-node tick counter to avoid immediate re-trigger of STUCK
			Navigation.ResetTickTimer()
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

	-- EARLY CIRCUIT BREAKER CHECK: Don't even try moving if the next connection is blocked
	ProfilerBegin("early_circuit_check")
	local path = G.Navigation.path
	if path and #path > 1 then
		local currentNode = path[1]
		local nextNode = path[2]
		if isConnectionBlocked(currentNode, nextNode) then
			Log:Warn(
				"Early circuit breaker detection: connection %d -> %d is BLOCKED, attempting center recovery",
				currentNode.id,
				nextNode.id
			)
			G.Navigation.recoverToCenter = true
			G.Navigation.edgeStage = nil
			G.Navigation.edgeKey = nil
			Navigation.ResetTickTimer()
			ProfilerEnd()
			ProfilerEnd()
			return
		end
	end
	ProfilerEnd()

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
	--  Hybrid Skip - Robust walkability check for node skipping
	------------------------------------------------------------
	ProfilerBegin("node_skipping")
	-- Only run the heavier skip checks every few ticks to reduce CPU
	if G.Menu.Main.Skip_Nodes and #G.Navigation.path > 1 then
		local now = globals.TickCount()
		if not G.lastNodeSkipTick then
			G.lastNodeSkipTick = 0
		end
		if (now - G.lastNodeSkipTick) >= 3 then -- run every 3 ticks (~50 ms)
			G.lastNodeSkipTick = now
			local didSkip = false
			-- Simple skip: if we can walk directly to the next area's center, drop current node
			if G.Navigation.path and #G.Navigation.path > 1 then
				local walkMode = G.Menu.Main.WalkableMode or "Smooth"
				local nextArea = G.Navigation.path[2]
				if nextArea and nextArea.pos and isWalkable.Path(LocalOrigin, nextArea.pos, walkMode) then
					Navigation.RemoveCurrentNode()
					didSkip = true
				end
			end
			local curWp = Navigation.GetCurrentWaypoint()
			if curWp and curWp.kind == "door" then
				local walkMode = G.Menu.Main.WalkableMode or "Smooth"
				local wps = G.Navigation.waypoints or {}
				local idx = G.Navigation.currentWaypointIndex or 1
				local nextWp = wps[idx + 1]
				-- 1) If can reach next area center directly, drop the door waypoint
				if
					nextWp
					and nextWp.kind == "center"
					and nextWp.pos
					and isWalkable.Path(LocalOrigin, nextWp.pos, walkMode)
				then
					Navigation.SkipWaypoints(1)
					didSkip = true
				else
					-- 2) If can reach the center of the following area directly, skip door+center for current edge
					if G.Navigation.path and #G.Navigation.path > 2 then
						local targetArea = G.Navigation.path[3]
						if targetArea and targetArea.pos and isWalkable.Path(LocalOrigin, targetArea.pos, walkMode) then
							Navigation.SkipWaypoints(2)
							didSkip = true
						end
					end
					-- 3) If any door point is reachable, drop door waypoint to avoid dithering
					if not didSkip and curWp.points then
						for _, p in ipairs(curWp.points) do
							if isWalkable.Path(LocalOrigin, p, walkMode) then
								Navigation.SkipWaypoints(1)
								didSkip = true
								break
							end
						end
					end
				end
			elseif curWp and curWp.kind == "center" then
				-- Center-to-center (or goal) skipping: if we can walk directly to the next center/goal, skip ahead
				local walkMode = G.Menu.Main.WalkableMode or "Smooth"
				local wps = G.Navigation.waypoints or {}
				local idx = G.Navigation.currentWaypointIndex or 1
				-- Look ahead a few waypoints to find the next with a position (center or goal)
				for look = 1, 3 do
					local nxt = wps[idx + look]
					if not nxt then
						break
					end
					if (nxt.kind == "center" or nxt.kind == "goal") and nxt.pos then
						if isWalkable.Path(LocalOrigin, nxt.pos, walkMode) then
							Navigation.SkipWaypoints(look)
							didSkip = true
						end
						break
					end
				end
			end
			-- Fallback: area-level skipping
			if not didSkip then
				if
					Optimiser.skipIfCloser(LocalOrigin, G.Navigation.path)
					or Optimiser.skipIfWalkable(LocalOrigin, G.Navigation.path)
				then
					didSkip = true
				end
			end
			if didSkip then
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
					-- Add penalty based on walkability - each failure makes connection more expensive
					local additionalPenalty = 50 -- Base penalty to add

					if not isWalkable.Path(LocalOrigin, nextNode.pos, walkMode) then
						if isWalkable.Path(LocalOrigin, nextNode.pos, "Aggressive") then
							additionalPenalty = 100 -- Mode-specific failure penalty
							Log:Debug(
								"Connection %d -> %d fails with %s but works with Aggressive - adding %d penalty",
								currentNode.id,
								nextNode.id,
								walkMode,
								additionalPenalty
							)
						else
							additionalPenalty = 200 -- Completely blocked path penalty
							Log:Debug(
								"Connection %d -> %d completely blocked - adding %d penalty",
								currentNode.id,
								nextNode.id,
								additionalPenalty
							)
						end
					else
						Log:Debug(
							"Connection %d -> %d is walkable but stuck (geometry issue?) - adding %d penalty",
							currentNode.id,
							nextNode.id,
							additionalPenalty
						)
					end

					-- Add the penalty (accumulates with previous penalties)
					Node.AddFailurePenalty(currentNode, nextNode, additionalPenalty)
					Log:Info(
						"Added %d penalty to connection %d -> %d (accumulating)",
						additionalPenalty,
						currentNode.id,
						nextNode.id
					)

					-- CIRCUIT BREAKER: Track failures and potentially block connection
					if addConnectionFailure(currentNode, nextNode) then
						Log:Warn(
							"Connection %d -> %d is now BLOCKED by circuit breaker - forcing path clear",
							currentNode.id,
							nextNode.id
						)
						Navigation.ClearPath() -- Force completely new path when connection is blocked
					end
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
			-- Cap cache size aggressively to avoid unbounded growth
			local count = 0
			for _ in pairs(G.walkabilityCache) do
				count = count + 1
			end
			if count > 2000 then
				local removed = 0
				for k, _ in pairs(G.walkabilityCache) do
					G.walkabilityCache[k] = nil
					removed = removed + 1
					if removed >= (count - 2000) then
						break
					end
				end
				Log:Debug("Pruned walkability cache by %d entries (cap=2000)", removed)
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

end)
__bundle_register("MedBot.Menu", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[debug commands
    client.SetConVar("cl_vWeapon_sway_interp",              0)             -- Set cl_vWeapon_sway_interp to 0
    client.SetConVar("cl_jiggle_bone_framerate_cutoff", 0)             -- Set cl_jiggle_bone_framerate_cutoff to 0
    client.SetConVar("cl_bobcycle",                     10000)         -- Set cl_bobcycle to 10000
    client.SetConVar("sv_cheats", 1)                                    -- debug fast setup
    client.SetConVar("mp_disable_respawn_times", 1)
    client.SetConVar("mp_respawnwavetime", -1)
    client.SetConVar("mp_teams_unbalance_limit", 1000)

    -- debug command: ent_fire !picker Addoutput "health 99999" --superbot
]]
local MenuModule = {}

-- Import globals
local G = require("MedBot.Utils.Globals")
local Node = require("MedBot.Modules.Node")
local Visuals = require("MedBot.Visuals")

-- Optional profiler support
local Profiler = nil
do
	local loaded, mod = pcall(require, "Profiler")
	if loaded then
		Profiler = mod
	end
end

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

-- Try loading TimMenu
---@type boolean, table
local menuLoaded, TimMenu = pcall(require, "TimMenu")
assert(menuLoaded, "TimMenu not found, please install it!")

-- Draw the menu
local function OnDrawMenu()
	ProfilerBeginSystem("draw_menu")

	-- Only draw when the Lmaobox menu is open
	if not gui.IsMenuOpen() then
		ProfilerEndSystem()
		return
	end

	if TimMenu.Begin("MedBot Control") then
		-- Tab control
		G.Menu.Tab = TimMenu.TabControl("MedBotTabs", { "Main", "Visuals" }, G.Menu.Tab)
		TimMenu.NextLine()

		if G.Menu.Tab == "Main" then
			-- Bot Control Section
			TimMenu.BeginSector("Bot Control")
			G.Menu.Main.Enable = TimMenu.Checkbox("Enable Bot", G.Menu.Main.Enable)
			TimMenu.NextLine()

			G.Menu.Main.SelfHealTreshold =
				TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
			TimMenu.NextLine()

			G.Menu.Main.LookingAhead = TimMenu.Checkbox("Auto Rotate Camera", G.Menu.Main.LookingAhead or false)
			TimMenu.Tooltip("Enable automatic camera rotation towards target node (disable for manual camera control)")
			TimMenu.NextLine()

			G.Menu.Main.smoothFactor = G.Menu.Main.smoothFactor or 0.1
			G.Menu.Main.smoothFactor = TimMenu.Slider("Smooth Factor", G.Menu.Main.smoothFactor, 0.01, 1, 0.01)
			TimMenu.Tooltip("Camera rotation smoothness (only when Auto Rotate Camera is enabled)")
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Movement & Pathfinding Section
			TimMenu.BeginSector("Movement & Pathfinding")
			G.Menu.Main.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Main.Skip_Nodes)
			TimMenu.Tooltip("Allow skipping nodes when direct path is walkable (handles all optimization)")
			TimMenu.NextLine()

			-- Smart Jump (works independently of MedBot enable state)
			G.Menu.SmartJump = G.Menu.SmartJump or {}
			G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable ~= false)
			TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")
			TimMenu.NextLine()

			G.Menu.SmartJump.Debug = G.Menu.SmartJump.Debug or false
			G.Menu.SmartJump.Debug = TimMenu.Checkbox("Smart Jump Debug", G.Menu.SmartJump.Debug)
			TimMenu.Tooltip("Print Smart Jump debug logs to console")
			TimMenu.NextLine()

			-- Path optimisation mode for following nodes
			G.Menu.Main.WalkableMode = G.Menu.Main.WalkableMode or "Smooth"
			local walkableModes = { "Smooth", "Aggressive" }
			-- Get current mode as index number
			local currentModeIndex = (G.Menu.Main.WalkableMode == "Aggressive") and 2 or 1
			local previousMode = G.Menu.Main.WalkableMode

			-- TimMenu.Selector expects a number, not a table
			local selectedIndex = TimMenu.Selector("Walkable Mode", currentModeIndex, walkableModes)

			-- Update the mode based on selection
			if selectedIndex == 1 then
				G.Menu.Main.WalkableMode = "Smooth"
			elseif selectedIndex == 2 then
				G.Menu.Main.WalkableMode = "Aggressive"
			end

			-- Auto-recalculate costs if mode changed
			if G.Menu.Main.WalkableMode ~= previousMode then
				Node.RecalculateConnectionCosts()
			end
			TimMenu.Tooltip(
				"Applies to path following only. Aggressive also enables direct skipping when path is walkable"
			)
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Advanced Settings Section
			TimMenu.BeginSector("Advanced Settings")
			G.Menu.Main.CleanupConnections =
				TimMenu.Checkbox("Cleanup Invalid Connections", G.Menu.Main.CleanupConnections or false)
			TimMenu.Tooltip("Clean up navigation connections on map load (DISABLE if causing performance issues)")
			TimMenu.NextLine()

			G.Menu.Main.AllowExpensiveChecks =
				TimMenu.Checkbox("Allow Expensive Walkability Checks", G.Menu.Main.AllowExpensiveChecks or false)
			TimMenu.Tooltip("Enable expensive trace-based walkability validation (rarely needed)")
			TimMenu.NextLine()

			-- Hierarchical pathfinding removed: single-layer areas only

			-- Connection processing status display
			if G.Menu.Main.CleanupConnections then
				local status = Node.GetConnectionProcessingStatus()
				if status.isProcessing then
					local phaseNames = {
						[1] = "Basic validation",
						[2] = "Expensive fallback",
						[3] = "Stair patching",
						[4] = "Fine point stitching",
					}
					TimMenu.Text(
						string.format(
							"Processing Connections: Phase %d (%s)",
							status.currentPhase,
							phaseNames[status.currentPhase] or "Unknown"
						)
					)
					TimMenu.NextLine()
					TimMenu.Text(
						string.format(
							"Progress: %d/%d nodes (FPS: %.1f)",
							status.processedNodes,
							status.totalNodes,
							status.currentFPS
						)
					)
					TimMenu.NextLine()
					TimMenu.Text(
						string.format(
							"Found: %d connections, Expensive: %d, Fine points: %d",
							status.connectionsFound,
							status.expensiveChecksUsed,
							status.finePointConnectionsAdded
						)
					)
					TimMenu.NextLine()
				end
			end

			TimMenu.EndSector()
		elseif G.Menu.Tab == "Visuals" then
			-- Visual Settings Section
			TimMenu.BeginSector("Visual Settings")
			G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
			TimMenu.NextLine()

			-- Align naming with visuals: renderRadius is what Visuals.lua reads
			G.Menu.Visuals.renderRadius = G.Menu.Visuals.renderRadius or G.Menu.Visuals.renderDistance or 800
			G.Menu.Visuals.renderRadius = TimMenu.Slider("Render Radius", G.Menu.Visuals.renderRadius, 100, 3000, 100)
			TimMenu.NextLine()

			G.Menu.Visuals.chunkSize = G.Menu.Visuals.chunkSize or 256
			G.Menu.Visuals.chunkSize = TimMenu.Slider("Chunk Size", G.Menu.Visuals.chunkSize, 64, 512, 16)
			TimMenu.NextLine()

			G.Menu.Visuals.renderChunks = G.Menu.Visuals.renderChunks or 3
			G.Menu.Visuals.renderChunks = TimMenu.Slider("Render Chunks", G.Menu.Visuals.renderChunks, 1, 10, 1)
			Visuals.MaybeRebuildGrid()
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Node Display Section
			TimMenu.BeginSector("Display Options")
			-- Basic display options
			local basicOptions = { "Show Nodes", "Show Node IDs", "Show Nav Connections", "Show Areas", "Show Doors" }
			G.Menu.Visuals.basicDisplay = G.Menu.Visuals.basicDisplay or { true, true, true, true, true }
			G.Menu.Visuals.basicDisplay = TimMenu.Combo("Basic Display", G.Menu.Visuals.basicDisplay, basicOptions)
			TimMenu.NextLine()

			-- Update individual settings based on combo selection
			G.Menu.Visuals.drawNodes = G.Menu.Visuals.basicDisplay[1]
			G.Menu.Visuals.drawNodeIDs = G.Menu.Visuals.basicDisplay[2]
			G.Menu.Visuals.showConnections = G.Menu.Visuals.basicDisplay[3]
			G.Menu.Visuals.showAreas = G.Menu.Visuals.basicDisplay[4]
			G.Menu.Visuals.showDoors = G.Menu.Visuals.basicDisplay[5]
			TimMenu.EndSector()
		end

		TimMenu.End() -- Properly close the menu
	end

	ProfilerEndSystem()
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule

end)
__bundle_register("MedBot.Visuals", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Node = require("MedBot.Modules.Node")
local isWalkable = require("MedBot.Modules.ISWalkable")

-- Optional profiler support
local Profiler = nil
do
        local loaded, mod = pcall(require, "Profiler")
        if loaded then
                Profiler = mod
        end
end

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

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Log = Common.Log.new("Visuals")

-- Grid-based rendering helpers
local gridIndex = {}
local nodeCell = {}
local visBuf = {}
local visCount = 0
Visuals.lastChunkSize = nil
Visuals.lastRenderChunks = nil

--[[ Functions ]]
local function Draw3DBox(size, pos)
    local halfSize = size / 2
    -- Recompute corners every call to ensure correct size; caching caused wrong sizes
    local corners = {
        Vector3(-halfSize, -halfSize, -halfSize),
        Vector3(halfSize, -halfSize, -halfSize),
        Vector3(halfSize, halfSize, -halfSize),
        Vector3(-halfSize, halfSize, -halfSize),
        Vector3(-halfSize, -halfSize, halfSize),
        Vector3(halfSize, -halfSize, halfSize),
        Vector3(halfSize, halfSize, halfSize),
        Vector3(-halfSize, halfSize, halfSize),
    }

    local linesToDraw = {
        { 1, 2 },
        { 2, 3 },
        { 3, 4 },
        { 4, 1 },
        { 5, 6 },
        { 6, 7 },
        { 7, 8 },
        { 8, 5 },
        { 1, 5 },
        { 2, 6 },
        { 3, 7 },
        { 4, 8 },
    }

    local screenPositions = {}
    for _, cornerPos in ipairs(corners) do
        local worldPos = pos + cornerPos
        local screenPos = client.WorldToScreen(worldPos)
        if screenPos then
            table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
        end
    end

    for _, line in ipairs(linesToDraw) do
        local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
        if p1 and p2 then
            draw.Line(p1.x, p1.y, p2.x, p2.y)
        end
    end
end

local UP_VECTOR = Vector3(0, 0, 1)

local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	-- If invert is true, swap start_pos and end_pos
	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	-- Calculate direction from start to end
	local direction = end_pos - start_pos
	local direction_length = direction:Length()
	if direction_length == 0 then
		return
	end

	-- Normalize the direction vector
	local normalized_direction = Common.Normalize(direction)

	-- Calculate the arrow base position by moving back from end_pos in the direction of start_pos
	local arrow_base = end_pos - normalized_direction * arrowhead_length

	-- Calculate the perpendicular vector for the arrow width
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	-- Convert world positions to screen positions
	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	-- Draw the line from start to the base of the arrow (not all the way to the end)
	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])

	-- Draw the sides of the arrowhead
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])

	-- Optionally, draw the base of the arrowhead to close it
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- 1×1 white texture for filled polygons
local white_texture_fill = draw.CreateTextureRGBA(string.char(0xff, 0xff, 0xff, 0xff), 1, 1)

-- fillPolygon(vertices: {{x,y}}, r,g,b,a): filled convex polygon
local function fillPolygon(vertices, r, g, b, a)
	draw.Color(r, g, b, a)
	local n = #vertices
	local cords, rev = {}, {}
	local sum = 0
	local v1x, v1y = vertices[1][1], vertices[1][2]
	local function cross(a, b)
		return (b[1] - a[1]) * (v1y - a[2]) - (b[2] - a[2]) * (v1x - a[1])
	end
	for i, v in ipairs(vertices) do
		cords[i] = { v[1], v[2], 0, 0 }
		rev[n - i + 1] = cords[i]
		local nxt = vertices[i % n + 1]
		sum = sum + cross(v, nxt)
	end
	draw.TexturedPolygon(white_texture_fill, (sum < 0 and rev or cords), true)
end

-- Easy color configuration for area rendering
local AREA_FILL_COLOR = { 55, 255, 155, 12 } -- r, g, b, a for filled area
local AREA_OUTLINE_COLOR = { 255, 255, 255, 77 } -- r, g, b, a for area outline

-- Convert world position to chunk cell
local function worldToCell(pos)
    local size = G.Menu.Visuals.chunkSize or 256
    if size <= 0 then
        error("chunkSize must be greater than 0")
    end
    return math.floor(pos.x / size),
        math.floor(pos.y / size),
        math.floor(pos.z / size)
end

-- Build lookup grid of node ids per cell
local function buildGrid()
    gridIndex = {}
    nodeCell = {}
    local size = G.Menu.Visuals.chunkSize or 256
    for id, node in pairs(G.Navigation.nodes or {}) do
        if not node or not node.pos then
            Log:Warn("Visuals.buildGrid: skipping invalid node %s", tostring(id))
            goto continue
        end
        local cx, cy, cz = worldToCell(node.pos)
        gridIndex[cx] = gridIndex[cx] or {}
        gridIndex[cx][cy] = gridIndex[cx][cy] or {}
        gridIndex[cx][cy][cz] = gridIndex[cx][cy][cz] or {}
        table.insert(gridIndex[cx][cy][cz], id)
        nodeCell[id] = { cx, cy, cz }
        ::continue::
    end
    Visuals.lastChunkSize = size
    Visuals.lastRenderChunks = G.Menu.Visuals.renderChunks or 3
end

-- Rebuild grid if configuration changed
function Visuals.MaybeRebuildGrid()
    local size = G.Menu.Visuals.chunkSize or 256
    local chunks = G.Menu.Visuals.renderChunks or 3
    if size ~= Visuals.lastChunkSize or chunks ~= Visuals.lastRenderChunks then
        buildGrid()
    end
end

-- External access to rebuild grid
function Visuals.BuildGrid()
    buildGrid()
end

function Visuals.Initialize()
    local success, err = pcall(buildGrid)
    if not success then
        print("Error initializing visuals grid: " .. tostring(err))
        gridIndex = {}
        nodeCell = {}
        visBuf = {}
        visCount = 0
    end
end

-- Collect visible node ids around player
local function collectVisible(me)
    visCount = 0
    local px, py, pz = worldToCell(me:GetAbsOrigin())
    local r = G.Menu.Visuals.renderChunks or 3
    for dx = -r, r do
        local ax = math.abs(dx)
        for dy = -(r - ax), (r - ax) do
            local dzMax = r - ax - math.abs(dy)
            for dz = -dzMax, dzMax do
                local bx = gridIndex[px + dx]
                local by = bx and bx[py + dy]
                local bucket = by and by[pz + dz]
                if bucket then
                    for _, id in ipairs(bucket) do
                        visCount = visCount + 1
                        visBuf[visCount] = id
                    end
                end
            end
        end
    end
end


local function OnDraw()
        ProfilerBeginSystem("visuals_draw")

        draw.SetFont(Fonts.Verdana)
	draw.Color(255, 0, 0, 255)

    local me = entities.GetLocalPlayer()
    if not me then
        ProfilerEndSystem()
        return
    end
    -- Master enable switch for visuals
    if not G.Menu.Visuals.EnableVisuals then
        ProfilerEndSystem()
        return
    end

        local currentY = 120
	-- Draw memory usage if enabled in config
	if G.Menu.Visuals.memoryUsage then
		draw.SetFont(Fonts.Verdana) -- Ensure font is set before drawing text
		draw.Color(255, 255, 255, 200)
		-- Get current memory usage directly for real-time display
		local currentMemKB = collectgarbage("count")
		local memMB = currentMemKB / 1024
		draw.Text(10, 10, string.format("Memory Usage: %.1f MB", memMB))
		currentY = currentY + 20
	end
    -- Collect visible nodes using chunk grid and Manhattan render radius
    Visuals.MaybeRebuildGrid()
    collectVisible(me)
    local p = me:GetAbsOrigin()
    local manhattanRadius = (G.Menu.Visuals.renderRadius or 2000)
    local function withinRadius(pos)
        -- use cheaper 2D where viable
        local d2 = math.abs(pos.x - p.x) + math.abs(pos.y - p.y)
        return d2 <= manhattanRadius
    end
        local visibleNodes = {}
        for i = 1, visCount do
            local id = visBuf[i]
            local node = G.Navigation.nodes and G.Navigation.nodes[id]
            if node then
                -- Manhattan distance cull
                local d = math.abs(node.pos.x - p.x) + math.abs(node.pos.y - p.y)
                if d <= manhattanRadius then
                    local scr = client.WorldToScreen(node.pos)
                    if scr then
                        visibleNodes[id] = { node = node, screen = scr }
                    end
                end
            end
        end
    G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
    if G.Navigation.currentNodeIndex == nil then
        ProfilerEndSystem()
        return
    end

    if G.Menu.Visuals.showAgentBoxes and G.Navigation.path then
        -- Visualizing agents (optional)
        local agent1Pos = G.Navigation.path[G.Navigation.FirstAgentNode]
            and G.Navigation.path[G.Navigation.FirstAgentNode].pos
        local agent2Pos = G.Navigation.path[G.Navigation.SecondAgentNode]
            and G.Navigation.path[G.Navigation.SecondAgentNode].pos

        if agent1Pos then
            local screenPos1 = client.WorldToScreen(agent1Pos)
            if screenPos1 then
                draw.Color(255, 255, 255, 255)
                Draw3DBox(10, agent1Pos)
            end
        end
        if agent2Pos then
            local screenPos2 = client.WorldToScreen(agent2Pos)
            if screenPos2 then
                draw.Color(0, 255, 0, 255)
                Draw3DBox(20, agent2Pos)
            end
        end
    end

    -- Show connections between nav nodes (colored by directionality)
    if G.Menu.Visuals.showConnections then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
            if not withinRadius(node.pos) then goto continue_node end
			for dir = 1, 4 do
				local cDir = node.c[dir]
				if cDir and cDir.connections then
                    for _, conn in ipairs(cDir.connections) do
                        local nid = (type(conn) == "table") and conn.node or conn
                        local otherNode = G.Navigation.nodes and G.Navigation.nodes[nid]
                        if otherNode then
                            local pos1 = node.pos + UP_VECTOR
                            local pos2 = otherNode.pos + UP_VECTOR
                            if not (withinRadius(pos1) and withinRadius(pos2)) then goto continue_conn end
                            local s1 = client.WorldToScreen(pos1)
                            local s2 = client.WorldToScreen(pos2)
                            if s1 and s2 then
							-- determine if other->id exists in its connections
							local bidir = false
                            
							for d2 = 1, 4 do
								local otherCDir = otherNode.c[d2]
								if otherCDir and otherCDir.connections then
                                    for _, backConn in ipairs(otherCDir.connections) do
                                        local backId = (type(backConn) == "table") and backConn.node or backConn
                                        if backId == id then
											bidir = true
											break
										end
									end
									if bidir then
										break
									end
								end
							end
							-- yellow for two-way, red for one-way
                                if bidir then draw.Color(255, 255, 0, 160) else draw.Color(255, 64, 64, 160) end
                                draw.Line(s1[1], s1[2], s2[1], s2[2])
                            end
                            ::continue_conn::
                        end
					end
				end
			end
            ::continue_node::
		end
	end

    -- Draw Doors (left, middle, right) if enabled
    if G.Menu.Visuals.showDoors then
        for id, entry in pairs(visibleNodes) do
            local node = entry.node
            for dir = 1, 4 do
                local cDir = node.c[dir]
                if cDir and cDir.connections then
                    for _, conn in ipairs(cDir.connections) do
                        local doorLeft = conn.left and (conn.left + UP_VECTOR)
                        local doorMid = conn.middle and (conn.middle + UP_VECTOR)
                        local doorRight = conn.right and (conn.right + UP_VECTOR)
                        if doorLeft and doorMid and doorRight then
                            local sL = client.WorldToScreen(doorLeft)
                            local sM = client.WorldToScreen(doorMid)
                            local sR = client.WorldToScreen(doorRight)
                            if sL and sM and sR then
                                -- Door line
                                draw.Color(0, 180, 255, 220)
                                draw.Line(sL[1], sL[2], sR[1], sR[2])
                                -- Left and right ticks
                                draw.Color(0, 120, 255, 255)
                                draw.FilledRect(sL[1] - 2, sL[2] - 2, sL[1] + 2, sL[2] + 2)
                                draw.FilledRect(sR[1] - 2, sR[2] - 2, sR[1] + 2, sR[2] + 2)
                                -- Middle marker color based on needJump
                                if conn.needJump then
                                    draw.Color(255, 140, 0, 255) -- orange means jump required
                                else
                                    draw.Color(0, 255, 0, 255) -- green means walkable
                                end
                                draw.FilledRect(sM[1] - 2, sM[2] - 2, sM[1] + 2, sM[2] + 2)
                            else
                                -- If only two points present (left/right), compute middle as midpoint
                                local sL2 = doorLeft and client.WorldToScreen(doorLeft)
                                local sR2 = doorRight and client.WorldToScreen(doorRight)
                                if sL2 and sR2 then
                                    draw.Color(0, 180, 255, 220)
                                    draw.Line(sL2[1], sL2[2], sR2[1], sR2[2])
                                    draw.Color(0, 120, 255, 255)
                                    draw.FilledRect(sL2[1] - 2, sL2[2] - 2, sL2[1] + 2, sL2[2] + 2)
                                    draw.FilledRect(sR2[1] - 2, sR2[2] - 2, sR2[1] + 2, sR2[2] + 2)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

	-- Fill and outline areas using fixed corners from Navigation
    if G.Menu.Visuals.showAreas then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
			-- Collect the four corner vectors from the node
			local worldCorners = { node.nw, node.ne, node.se, node.sw }
			local scr = {}
			local ok = true
			for i, corner in ipairs(worldCorners) do
				local s = client.WorldToScreen(corner)
				if not s then
					ok = false
					break
				end
				scr[i] = { s[1], s[2] }
			end
			if ok then
				-- filled polygon
				fillPolygon(scr, table.unpack(AREA_FILL_COLOR))
				-- outline
				draw.Color(table.unpack(AREA_OUTLINE_COLOR))
				for i = 1, 4 do
					local a = scr[i]
					local b = scr[i % 4 + 1]
					draw.Line(a[1], a[2], b[1], b[2])
				end
			end
		end
	end

    -- Fine points removed
        if false then
                -- Track drawn inter-area connections to avoid duplicates
                local drawnInterConnections = {}
                local drawnIntraConnections = {}

		for id, entry in pairs(visibleNodes) do
			local points = Node.GetAreaPoints(id)
			if points then
				-- First pass: draw connections if enabled
				for _, point in ipairs(points) do
					local screenPos = client.WorldToScreen(point.pos)
					if screenPos then
						for _, neighbor in ipairs(point.neighbors) do
							local neighborScreenPos = client.WorldToScreen(neighbor.point.pos)
							if neighborScreenPos then
								if neighbor.isInterArea and G.Menu.Visuals.showInterConnections then
									-- Orange for inter-area connections
									local connectionKey = string.format(
										"%d_%d-%d_%d",
										point.parentArea,
										point.id,
										neighbor.point.parentArea,
										neighbor.point.id
									)
									if not drawnInterConnections[connectionKey] then
										draw.Color(255, 165, 0, 180) -- Orange for inter-area connections
										draw.Line(
											screenPos[1],
											screenPos[2],
											neighborScreenPos[1],
											neighborScreenPos[2]
										)
										drawnInterConnections[connectionKey] = true
									end
								elseif not neighbor.isInterArea then
									-- Intra-area connections with different colors based on type
									local connectionKey = string.format(
										"%d_%d-%d_%d",
										math.min(point.id, neighbor.point.id),
										point.parentArea,
										math.max(point.id, neighbor.point.id),
										neighbor.point.parentArea
									)
									if not drawnIntraConnections[connectionKey] then
										if
											point.isEdge
											and neighbor.point.isEdge
											and G.Menu.Visuals.showEdgeConnections
										then
											draw.Color(0, 150, 255, 140) -- Bright blue for edge-to-edge connections
											draw.Line(
												screenPos[1],
												screenPos[2],
												neighborScreenPos[1],
												neighborScreenPos[2]
											)
											drawnIntraConnections[connectionKey] = true
										elseif G.Menu.Visuals.showIntraConnections then
											draw.Color(0, 100, 200, 60) -- Blue for regular intra-area connections
											draw.Line(
												screenPos[1],
												screenPos[2],
												neighborScreenPos[1],
												neighborScreenPos[2]
											)
											drawnIntraConnections[connectionKey] = true
										end
									end
								end
							end
						end
					end
				end

				-- Second pass: draw points (so they appear on top of lines)
				for _, point in ipairs(points) do
					local screenPos = client.WorldToScreen(point.pos)
					if screenPos then
						-- Color-code points: yellow for edge points, blue for regular points
						if point.isEdge then
							draw.Color(255, 255, 0, 220) -- Yellow for edge points
							draw.FilledRect(screenPos[1] - 2, screenPos[2] - 2, screenPos[1] + 2, screenPos[2] + 2)
						else
							draw.Color(0, 150, 255, 180) -- Light blue for regular points
							draw.FilledRect(screenPos[1] - 1, screenPos[2] - 1, screenPos[1] + 1, screenPos[2] + 1)
						end
					end
				end
			end
		end

		-- Show fine point statistics for areas with points
		local finePointStats = {}
		for id, entry in pairs(visibleNodes) do
			local points = Node.GetAreaPoints(id)
			if points and #points > 1 then -- Only count areas with multiple points
				local edgeCount = 0
				local interConnections = 0
				local intraConnections = 0
				local isolatedPoints = 0
				for _, point in ipairs(points) do
					if point.isEdge then
						edgeCount = edgeCount + 1
					end
					if #point.neighbors == 0 then
						isolatedPoints = isolatedPoints + 1
					end
					for _, neighbor in ipairs(point.neighbors) do
						if neighbor.isInterArea then
							interConnections = interConnections + 1
						else
							intraConnections = intraConnections + 1
						end
					end
				end
				table.insert(finePointStats, {
					id = id,
					totalPoints = #points,
					edgePoints = edgeCount,
					interConnections = interConnections,
					intraConnections = intraConnections,
					isolatedPoints = isolatedPoints,
				})
			end
		end
	end

	-- Draw all nodes
    if G.Menu.Visuals.drawNodes then
		draw.Color(0, 255, 0, 255)
		for id, entry in pairs(visibleNodes) do
			local s = entry.screen
			draw.FilledRect(s[1] - 4, s[2] - 4, s[1] + 4, s[2] + 4)
			if G.Menu.Visuals.drawNodeIDs then
				draw.Text(s[1], s[2] + 10, tostring(id))
			end
		end
	end

    -- Draw only the actual-followed path using door-aware waypoints, with a live target arrow
    if G.Menu.Visuals.drawPath then
        local wps = G.Navigation.waypoints
        if wps and #wps > 0 then
            -- Draw remaining route only from current waypoint onward to avoid residue arrows
            local startIdx = G.Navigation.currentWaypointIndex or 1
            if startIdx < 1 then startIdx = 1 end
            for i = startIdx, #wps - 1 do
                local a, b = wps[i], wps[i + 1]
                local aPos = a.pos
                local bPos = b.pos
                if not aPos and a.kind == "door" and a.points and #a.points > 0 then
                    aPos = a.points[math.ceil(#a.points / 2)]
                end
                if not bPos and b.kind == "door" and b.points and #b.points > 0 then
                    bPos = b.points[math.ceil(#b.points / 2)]
                end
                local inRad = withinRadius(aPos or p) and withinRadius(bPos or p)
                if aPos and bPos and (G.Menu.Visuals.ignorePathRadius or inRad) then
                    draw.Color(255, 255, 255, 220) -- white route
                    ArrowLine(aPos, bPos, 18, 12, false)
                end
            end
            -- Current target indicator + box at the target
            local tgt = G.Navigation.currentTargetPos
            if tgt and (G.Menu.Visuals.ignorePathRadius or withinRadius(tgt)) then
                -- Arrow color logic: white normal, red if stuck & not walkable, yellow if stuck & walkable
                local arrowR, arrowG, arrowB = 255, 255, 255
                if G.currentState == G.States.STUCK then
                    local now = globals.TickCount()
                    if not G._lastStuckWalkableTick or (now - G._lastStuckWalkableTick) > 15 then
                        local me = entities.GetLocalPlayer()
                        local mePos = me and me:GetAbsOrigin()
                        local walkMode = G.Menu.Main.WalkableMode or "Smooth"
                        G._lastStuckWalkableResult = (mePos and isWalkable.Path(mePos, tgt, walkMode)) or false
                        G._lastStuckWalkableTick = now
                    end
                    if G._lastStuckWalkableResult then
                        arrowR, arrowG, arrowB = 255, 255, 0 -- yellow: stuck but walkable
                    else
                        arrowR, arrowG, arrowB = 255, 0, 0 -- red: stuck and blocked
                    end
                end
                draw.Color(arrowR, arrowG, arrowB, 255)
                local me = entities.GetLocalPlayer()
                if me then
                    local mePos = me:GetAbsOrigin()
                    ArrowLine(mePos, tgt, 22, 16, false)
                end
                -- Also place a square at the target with same color
                local s = client.WorldToScreen(tgt)
                if s then
                    draw.Color(arrowR, arrowG, arrowB, 255)
                    draw.FilledRect(s[1] - 4, s[2] - 4, s[1] + 4, s[2] + 4)
                end
            end
            -- Omit extra squares; arrows indicate route; 3D boxes already mark agents
        end
    end

	-- Draw current node
    if G.Menu.Visuals.drawCurrentNode and G.Navigation.path then
                draw.Color(255, 0, 0, 255)

		local currentNode = G.Navigation.path[G.Navigation.currentNodeIndex]
		local currentNodePos = currentNode.pos

        local screenPos = client.WorldToScreen(currentNodePos)
        if screenPos then
            Draw3DBox(20, currentNodePos)
            draw.Text(screenPos[1], screenPos[2] + 40, tostring(G.Navigation.currentNodeIndex))
        end
    end

    ProfilerEndSystem()
end


--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals

end)
__bundle_register("MedBot.Modules.ISWalkable", function(require, _LOADED, __bundle_register, __bundle_modules)
local isWalkable = {}
local G = require("MedBot.Utils.Globals")
local Common = require("MedBot.Common")

-- Constants based on standstill dummy's robust implementation
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) } -- Player collision hull
local STEP_HEIGHT = 18 -- Maximum height the player can step up
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250 -- Maximum distance the player can fall without taking fall damage
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE

local UP_VECTOR = Vector3(0, 0, 1)
local MAX_SURFACE_ANGLE = 45 -- Maximum angle for ground surfaces
local MAX_ITERATIONS = 37 -- Maximum number of iterations to prevent infinite loops

-- Helper function to get local player for speed calculation
local function getLocalPlayer()
	return entities.GetLocalPlayer()
end

-- Helper function to get min step size based on player speed
local function getMinStepSize()
	local pLocal = getLocalPlayer()
	if pLocal then
		local maxSpeed = pLocal:GetPropFloat("m_flMaxspeed") or 450
		return maxSpeed * globals.TickInterval()
	end
	return 7.5 -- Fallback value (450 * 1/66)
end

-- Helper function to check if we should hit an entity (ignore local player)
local function shouldHitEntity(entity)
	local pLocal = getLocalPlayer()
	return entity ~= pLocal -- Ignore self (the player being simulated)
end

-- Normalize a vector
local function Normalize(vec)
	local length = vec:Length()
	if length == 0 then
		return vec
	end
	return vec / length
end

-- Calculate horizontal Manhattan distance between two points
local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Perform a hull trace to check for obstructions between two points
local function performTraceHull(startPos, endPos)
	return engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	-- Check if the surface is within the maximum allowed angle for adjustment
	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)

	-- Adjust the z component of the direction in place
	direction.z = direction.z - surfaceNormal.z * dotProduct

	-- Normalize the direction after adjustment
	return Normalize(direction)
end

-- Main function to check if the path between the current position and the node is walkable.
-- Uses robust algorithm from standstill dummy to prevent walking over walls
-- Respects Walkable Mode setting: "Step" = 18-unit steps only, "Jump" = 72-unit duck jumps allowed
function isWalkable.Path(startPos, endPos, overrideMode)
	-- Get walkable mode from menu or override value
	local walkableMode = overrideMode or G.Menu.Main.WalkableMode or "Smooth"
	local maxStepHeight = walkableMode == "Aggressive" and 72 or STEP_HEIGHT -- 72 for duck jumps, 18 for steps
	local maxStepVector = Vector3(0, 0, maxStepHeight)
	local stepFraction = maxStepHeight / MAX_FALL_DISTANCE

	-- Quick height check first
	local totalHeightDiff = endPos.z - startPos.z
	if totalHeightDiff > maxStepHeight then
		return false -- Too high for current mode
	end

	local blocked = false
	local currentPos = startPos
	local MIN_STEP_SIZE = 7.5 -- Use fixed small step size for robust ground checks

	-- Adjust start position to ground level
	local startGroundTrace = performTraceHull(startPos + maxStepVector, startPos - MAX_FALL_DISTANCE_Vector)
	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(endPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, endPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		-- Calculate distance to goal and update direction
		local distanceToGoal = (currentPos - endPos):Length()
		local direction = lastDirection

		-- Calculate next position
		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check - this prevents walking through walls
		local wallTrace = performTraceHull(lastPos + maxStepVector, NextPos + maxStepVector)
		currentPos = wallTrace.endpos

		-- If we start inside a wall, it's not walkable
		if wallTrace.fraction == 0 then
			return false
		end
		-- If we immediately hit an obstacle and barely progressed, treat as blocked
		if wallTrace.fraction < 1 then
			local progressed = (currentPos - lastPos):Length()
			if progressed < (MIN_STEP_SIZE * 0.5) then
				return false
			end
		end

		-- Ground collision with segmentation - ensures we always have ground beneath us
		local totalDistance = (currentPos - lastPos):Length()
		local numSegments = math.max(1, math.floor(totalDistance / MIN_STEP_SIZE))

		for seg = 1, numSegments do
			local t = seg / numSegments
			local segmentPos = lastPos + (currentPos - lastPos) * t
			local segmentTop = segmentPos + maxStepVector
			local segmentBottom = segmentPos - MAX_FALL_DISTANCE_Vector

			local groundTrace = performTraceHull(segmentTop, segmentBottom)

			if groundTrace.fraction == 1 then
				return false -- No ground beneath; path is unwalkable
			end

			-- Check if obstacle is within acceptable height for current mode
			local obstacleHeight = (segmentBottom - groundTrace.endpos).z
			if obstacleHeight > maxStepHeight then
				return false -- Obstacle too high for current mode
			end

			-- Stronger step acceptance: require either we reached near the ground or we are at the last segment
			if groundTrace.fraction >= (stepFraction * 0.9) or seg == numSegments then
				-- Adjust position to ground
				direction = adjustDirectionToSurface(direction, groundTrace.plane)
				currentPos = groundTrace.endpos
				blocked = false
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, endPos)
		if blocked or currentDistance > MaxDistance then -- if target is unreachable
			return false
		end

		-- If we're close enough to the goal, check both horizontal and vertical proximity
		if currentDistance < 24 then
			local verticalDist = math.abs(endPos.z - currentPos.z)
			if verticalDist < maxStepHeight then
				-- Final forward micro-check to avoid clipping through thin objects near the goal
				local microEnd = endPos
				local microTrace = performTraceHull(currentPos + maxStepVector, microEnd + maxStepVector)
				if microTrace.fraction < 1 and (microTrace.endpos - currentPos):Length() < 24 then
					return false
				end
				return true
			else
				return false
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	return false -- Max iterations reached without finding a path
end

return isWalkable

end)
__bundle_register("MedBot.Common", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

--[[ Imports ]]
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1.0, "LNXlib version is too old, please update it!")

Common.Lib = Lib
Common.Notify = Lib.UI.Notify
Common.TF2 = Lib.TF2
Common.Log = Lib.Utils.Logger
Common.Math = Lib.Utils.Math
Common.Conversion = Lib.Utils.Conversion
Common.WPlayer = Lib.TF2.WPlayer
Common.PR = Lib.TF2.PlayerResource
Common.Helpers = Lib.TF2.Helpers

-- JSON support

-- Optional profiler support
local Profiler = nil
do
        local loaded, mod = pcall(require, "Profiler")
        if loaded then
                Profiler = mod
        end
end

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
Common.Json = require("MedBot.Utils.Json")

-- Globals
local G = require("MedBot.Utils.Globals")

-- FastPlayers and WrappedPlayer utilities
local FastPlayers = require("MedBot.Utils.FastPlayers")
Common.FastPlayers = FastPlayers

--[[ Utility Functions ]]
--- Normalize a vector
---@param vec Vector3
---@return Vector3
function Common.Normalize(vec)
	return vec / vec:Length()
end

--- Manhattan distance on XY plane
---@param pos1 Vector3
---@param pos2 Vector3
---@return number
function Common.horizontal_manhattan_distance(pos1, pos2)
	return math.abs(pos1.x - pos2.x) + math.abs(pos1.y - pos2.y)
end

--- Add a task to current tasks if not present
---@param taskKey string
function Common.AddCurrentTask(taskKey)
	local priority = G.Tasks[taskKey]
	if priority and not G.Current_Tasks[taskKey] then
		G.Current_Tasks[taskKey] = priority
	end
end

--- Remove a task from current tasks
---@param taskKey string
function Common.RemoveCurrentTask(taskKey)
	G.Current_Tasks[taskKey] = nil
end

--- Get the highest priority task
---@return string
function Common.GetHighestPriorityTask()
	local bestKey, bestPri = nil, math.huge
	for key, pri in pairs(G.Current_Tasks) do
		if pri < bestPri then
			bestPri = pri
			bestKey = key
		end
	end
	return bestKey or "None"
end

--- Check if entity is a valid player
---@param entity Entity The entity to check
---@param checkFriend boolean? Unused; reserved for future friend filtering
---@param checkDormant boolean? Skip if true and entity is dormant
---@param skipEnt Entity? Skip this specific entity (e.g., local player)
---@return boolean
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEnt)
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return false
	end
	if checkDormant and entity:IsDormant() then
		return false
	end
	if skipEnt and entity == skipEnt then
		return false
	end
	return true
end

-- Play UI sound on load and unload
client.Command('play "ui/buttonclickrelease"', true)
local function OnUnload()
        ProfilerBeginSystem("common_unload")

        client.Command('play "ui/buttonclickrelease"', true)

        ProfilerEndSystem()
end
callbacks.Unregister("Unload", "Common_OnUnload")
callbacks.Register("Unload", "Common_OnUnload", OnUnload)

return Common

end)
__bundle_register("MedBot.Utils.FastPlayers", function(require, _LOADED, __bundle_register, __bundle_modules)
-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Per-tick cached player lists for MedBot, now using LNXlib's WPlayer directly.
--
-- This version uses LNXlib's WPlayer as the player wrapper, removing the old custom WrappedPlayer.

--[[ Imports ]]
local G = require("MedBot.Utils.Globals")
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
local WPlayer = Lib.TF2.WPlayer

-- Optional profiler support
local Profiler = nil
do
        local loaded, mod = pcall(require, "Profiler")
        if loaded then
                Profiler = mod
        end
end

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

--[[ Module Declaration ]]
local FastPlayers = {}

--[[ Local Caches ]]
local cachedAllPlayers, cachedTeammates, cachedEnemies, cachedLocal

FastPlayers.AllUpdated = false
FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

--[[ Private: Reset per-tick caches ]]
local function ResetCaches()
        ProfilerBeginSystem("fastplayers_reset")
        cachedAllPlayers = nil
        cachedTeammates = nil
        cachedEnemies = nil
        cachedLocal = nil
        FastPlayers.AllUpdated = false
        FastPlayers.TeammatesUpdated = false
        FastPlayers.EnemiesUpdated = false

        ProfilerEndSystem()
end

--[[ Simplified validity check ]]
local function isValidPlayer(ent, excludeEnt)
	return ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant() and ent ~= excludeEnt
end

--[[ Public API ]]

--- Returns list of valid, non-dormant players once per tick.
---@param excludeLocal boolean? exclude local player if true
---@return table[] -- WPlayer[]
function FastPlayers.GetAll(excludeLocal)
	if FastPlayers.AllUpdated then
		return cachedAllPlayers
	end
	-- Determine entity to skip (local player)
	local skipEnt = excludeLocal and entities.GetLocalPlayer() or nil
	cachedAllPlayers = {}
	-- Gather valid players
	for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
		if isValidPlayer(ent, skipEnt) then
			local wp = WPlayer.FromEntity(ent)
			if wp then
				table.insert(cachedAllPlayers, wp)
			end
		end
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a WPlayer instance, cached after first wrap.
---@return table|nil -- WPlayer|nil
function FastPlayers.GetLocal()
	if not cachedLocal then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WPlayer.FromEntity(rawLocal) or nil
	end
	return cachedLocal
end

--- Returns list of teammates, optionally excluding local player.
---@param excludeLocal boolean? exclude local player if true
---@return table[] -- WPlayer[]
function FastPlayers.GetTeammates(excludeLocal)
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll(true)
		end
		cachedTeammates = {}
		local localWP = FastPlayers.GetLocal()
		local ex = excludeLocal and localWP or nil
		local myTeam = localWP and localWP:GetTeamNumber()
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() == myTeam and wp ~= ex then
					table.insert(cachedTeammates, wp)
				end
			end
		end
		FastPlayers.TeammatesUpdated = true
	end
	return cachedTeammates
end

--- Returns list of enemies (different team).
---@return table[] -- WPlayer[]
function FastPlayers.GetEnemies()
	if not FastPlayers.EnemiesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		cachedEnemies = {}
		local localWP = FastPlayers.GetLocal()
		local myTeam = localWP and localWP:GetTeamNumber()
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() ~= myTeam then
					table.insert(cachedEnemies, wp)
				end
			end
		end
		FastPlayers.EnemiesUpdated = true
	end
	return cachedEnemies
end

-- Reset caches at the start of every CreateMove tick.
callbacks.Register("CreateMove", "FastPlayers_ResetCaches", ResetCaches)

return FastPlayers

end)
__bundle_register("MedBot.Utils.Globals", function(require, _LOADED, __bundle_register, __bundle_modules)
local DefaultConfig = require("MedBot.Utils.DefaultConfig")
-- Define the G module
local G = {}

G.Menu = DefaultConfig

G.Default = {
	entity = nil,
	index = 1,
	team = 1,
	Class = 1,
	flags = 1,
	OnGround = true,
	Origin = Vector3(0, 0, 0),
	ViewAngles = EulerAngles(90, 0, 0),
	Viewheight = Vector3(0, 0, 75),
	VisPos = Vector3(0, 0, 75),
	vHitbox = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 45) },
}

G.pLocal = G.Default

G.World_Default = {
	players = {},
	healthPacks = {}, -- Stores positions of health packs
	spawns = {}, -- Stores positions of spawn points
	payloads = {}, -- Stores payload entities in payload maps
	flags = {}, -- Stores flag entities in CTF maps (implicitly included in the logic)
}

G.World = G.World_Default

G.Misc = {
	NodeTouchDistance = 24,
	NodeTouchHeight = 82,
	workLimit = 1,
}

G.Navigation = {
	path = nil,
	nodes = nil,
	currentNodeIndex = 1, -- Current node we're moving towards (1 = first node in path)
	currentNodeTicks = 0,
	stuckStartTick = nil, -- Track when we first entered stuck state
	FirstAgentNode = 1,
	SecondAgentNode = 2,
	lastKnownTargetPosition = nil, -- Remember last position of follow target
	goalPos = nil, -- Current goal world position
	goalNodeId = nil, -- Closest node to the goal position
	navMeshUpdated = false, -- Set when navmesh is rebuilt
}

-- SmartJump integration
G.ShouldJump = false -- Set by SmartJump module when jump should be performed
G.LastSmartJumpAttempt = 0 -- Track last time SmartJump was attempted
G.LastEmergencyJump = 0 -- Track last emergency jump time
G.ObstacleDetected = false -- Track if obstacle is detected but no jump attempted
G.RequestEmergencyJump = false -- Request emergency jump from stuck detection

-- Bot movement tracking (for SmartJump integration)
G.BotIsMoving = false -- Track if bot is actively moving
G.BotMovementDirection = Vector3(0, 0, 0) -- Bot's intended movement direction

-- Memory management and cache tracking
G.Cache = {
	lastCleanup = 0,
	cleanupInterval = 2000, -- Clean up every 2000 ticks (~30 seconds)
	maxCacheSize = 1000, -- Maximum number of cached items
}

G.Tasks = {
	None = 0,
	Objective = 1,
	Follow = 2,
	Health = 3,
	Medic = 4,
	Goto = 5,
}

G.Current_Tasks = {}
G.Current_Task = G.Tasks.Objective

G.Benchmark = {
	MemUsage = 0,
}

-- Define states
G.States = {
	IDLE = "IDLE",
	PATHFINDING = "PATHFINDING",
	MOVING = "MOVING",
	STUCK = "STUCK",
}

G.currentState = nil
G.prevState = nil -- Track previous bot state
G.wasManualWalking = false -- Track if user manually walked last tick

-- Function to clean up memory and caches
function G.CleanupMemory()
	local currentTick = globals.TickCount()
	if currentTick - G.Cache.lastCleanup < G.Cache.cleanupInterval then
		return -- Too soon to cleanup
	end

	-- Update memory usage statistics
	local memUsage = collectgarbage("count")
	G.Benchmark.MemUsage = memUsage

	-- NOTE: Fine point caches are kept to avoid expensive re-generation
	-- when garbage collection happens.

	-- Hierarchical pathfinding removed
	G.Navigation.hierarchical = nil

	-- Reset stuck timer if it's been set for too long (prevents infinite stuck states)
	if G.Navigation.stuckStartTick and (currentTick - G.Navigation.stuckStartTick) > 1000 then
		print("Reset stuck timer during cleanup (was stuck for >1000 ticks)")
		G.Navigation.stuckStartTick = nil
		G.Navigation.currentNodeTicks = 0
	end

	-- Force garbage collection if memory usage is high
	local memBefore = memUsage
	if memUsage > 1024 * 1024 then -- More than 1GB
		collectgarbage("collect")
		memUsage = collectgarbage("count")
		G.Benchmark.MemUsage = memUsage
		print(string.format("Force GC: %.2f MB -> %.2f MB", memBefore / 1024, memUsage / 1024))
	end

	G.Cache.lastCleanup = currentTick
end

return G

end)
__bundle_register("MedBot.Utils.DefaultConfig", function(require, _LOADED, __bundle_register, __bundle_modules)
local defaultconfig
defaultconfig = {
	Tab = "Main",
	Tabs = {
		Main = true,
		Settings = false,
		Visuals = false,
		Movement = false,
	},

	Main = {
		Enable = true,
		Skip_Nodes = true, --skips nodes if it can go directly to ones closer to target.
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
		LookingAhead = true, -- Enable automatic camera rotation towards target node
		WalkableMode = "Smooth", -- "Smooth" uses 18-unit steps, "Aggressive" allows 72-unit jumps
		CleanupConnections = true, -- Cleanup invalid connections during map load (disable to prevent crashes)
		AllowExpensiveChecks = true, -- Allow expensive walkability checks for proper stair/ramp connections
		-- Hierarchical pathfinding removed
	},
	Visuals = {
		renderRadius = 400, -- Manhattan radius used by visuals culling (x+y+z)
		chunkSize = 256,
		renderChunks = 3,
		EnableVisuals = true,
		memoryUsage = true,
		ignorePathRadius = true, -- When true, path lines ignore render radius and draw full route
		showAgentBoxes = false, -- Optional legacy agent 3D boxes
		-- Combo-based display options
		basicDisplay = { false, false, false, true, true }, -- Show Nodes, Node IDs, Nav Connections, Areas, Doors
		-- Individual settings (automatically set by combo selections)
		drawNodes = false, -- Draws all nodes on the map
		drawNodeIDs = false, -- Show node IDs  [[ Used by: MedBot.Visuals ]]
		drawPath = true, -- Draws the path to the current goal
		Objective = true,
		drawCurrentNode = false, -- Draws the current node
		showHidingSpots = false, -- Show hiding spots (areas where health packs are located)  [[ Used by: MedBot.Visuals ]]
		showConnections = false, -- Show connections between nodes  [[ Used by: MedBot.Visuals ]]
		showAreas = true, -- Show area outlines  [[ Used by: MedBot.Visuals ]]
		showDoors = true,
	},
	Movement = {
		lookatpath = true, -- Look at where we are walking
		smoothLookAtPath = true, -- Set this to true to enable smooth look at path
		Smart_Jump = true, -- jumps perfectly before obstacle to be at peek of jump height when at colision point
	},
	SmartJump = {
		Enable = true,
		Debug = false,
	},
}

return defaultconfig

end)
__bundle_register("MedBot.Utils.Json", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
David Kolf's JSON module for Lua 5.1 - 5.4

Version 2.6


For the documentation see the corresponding readme.txt or visit
<http://dkolf.de/src/dkjson-lua.fsl/>.

You can contact the author by sending an e-mail to 'david' at the
domain 'dkolf.de'.


Copyright (C) 2010-2021 David Heiko Kolf

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

---@alias JsonState { indent : boolean?, keyorder : integer[]?, level : integer?, buffer : string[]?, bufferlen : integer?, tables : table[]?, exception : function? }

-- global dependencies:
local pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset =
    pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
    string.rep, string.gsub, string.sub, string.byte, string.char,
    string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat

---@class Json
local json = { version = "dkjson 2.6.1 L" }

local _ENV = nil -- blocking globals in Lua 5.2 and later

json.null = setmetatable({}, {
    __tojson = function() return "null" end
})

local function isarray(tbl)
    local max, n, arraylen = 0, 0, 0
    for k, v in pairs(tbl) do
        if k == 'n' and type(v) == 'number' then
            arraylen = v
            if v > max then
                max = v
            end
        else
            if type(k) ~= 'number' or k < 1 or floor(k) ~= k then
                return false
            end
            if k > max then
                max = k
            end
            n = n + 1
        end
    end
    if max > 10 and max > arraylen and max > n * 2 then
        return false -- don't create an array with too many holes
    end
    return true, max
end

local escapecodes = {
    ["\""] = "\\\"",
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t"
}

local function escapeutf8(uchar)
    local value = escapecodes[uchar]
    if value then
        return value
    end
    local a, b, c, d = strbyte(uchar, 1, 4)
    a, b, c, d = a or 0, b or 0, c or 0, d or 0
    if a <= 0x7f then
        value = a
    elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
        value = (a - 0xc0) * 0x40 + b - 0x80
    elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
        value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
    elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
        value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
    else
        return ""
    end
    if value <= 0xffff then
        return strformat("\\u%.4x", value)
    elseif value <= 0x10ffff then
        -- encode as UTF-16 surrogate pair
        value = value - 0x10000
        local highsur, lowsur = 0xD800 + floor(value / 0x400), 0xDC00 + (value % 0x400)
        return strformat("\\u%.4x\\u%.4x", highsur, lowsur)
    else
        return ""
    end
end

local function fsub(str, pattern, repl)
    -- gsub always builds a new string in a buffer, even when no match
    -- exists. First using find should be more efficient when most strings
    -- don't contain the pattern.
    if strfind(str, pattern) then
        return gsub(str, pattern, repl)
    else
        return str
    end
end

local function quotestring(value)
    -- based on the regexp "escapable" in https://github.com/douglascrockford/JSON-js
    value = fsub(value, "[%z\1-\31\"\\\127]", escapeutf8)
    if strfind(value, "[\194\216\220\225\226\239]") then
        value = fsub(value, "\194[\128-\159\173]", escapeutf8)
        value = fsub(value, "\216[\128-\132]", escapeutf8)
        value = fsub(value, "\220\143", escapeutf8)
        value = fsub(value, "\225\158[\180\181]", escapeutf8)
        value = fsub(value, "\226\128[\140-\143\168-\175]", escapeutf8)
        value = fsub(value, "\226\129[\160-\175]", escapeutf8)
        value = fsub(value, "\239\187\191", escapeutf8)
        value = fsub(value, "\239\191[\176-\191]", escapeutf8)
    end
    return "\"" .. value .. "\""
end
json.quotestring = quotestring

local function replace(str, o, n)
    local i, j = strfind(str, o, 1, true)
    if i then
        return strsub(str, 1, i - 1) .. n .. strsub(str, j + 1, -1)
    else
        return str
    end
end

-- locale independent num2str and str2num functions
local decpoint, numfilter

local function updatedecpoint()
    decpoint = strmatch(tostring(0.5), "([^05+])")
    -- build a filter that can be used to remove group separators
    numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str(num)
    return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function str2num(str)
    local num = tonumber(replace(str, ".", decpoint))
    if not num then
        updatedecpoint()
        num = tonumber(replace(str, ".", decpoint))
    end
    return num
end

local function addnewline2(level, buffer, buflen)
    buffer[buflen + 1] = "\n"
    buffer[buflen + 2] = strrep("  ", level)
    buflen = buflen + 2
    return buflen
end

function json.addnewline(state)
    if state.indent then
        state.bufferlen = addnewline2(state.level or 0,
            state.buffer, state.bufferlen or #(state.buffer))
    end
end

local encode2 -- forward declaration

local function addpair(key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
    local kt = type(key)
    if kt ~= 'string' and kt ~= 'number' then
        return nil, "type '" .. kt .. "' is not supported as a key by JSON."
    end
    if prev then
        buflen = buflen + 1
        buffer[buflen] = ","
    end
    if indent then
        buflen = addnewline2(level, buffer, buflen)
    end
    buffer[buflen + 1] = quotestring(key)
    buffer[buflen + 2] = ":"
    return encode2(value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
    local buflen = state.bufferlen
    if type(res) == 'string' then
        buflen = buflen + 1
        buffer[buflen] = res
    end
    return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
    defaultmessage = defaultmessage or reason
    local handler = state.exception
    if not handler then
        return nil, defaultmessage
    else
        state.bufferlen = buflen
        local ret, msg = handler(reason, value, state, defaultmessage)
        if not ret then return nil, msg or defaultmessage end
        return appendcustom(ret, buffer, state)
    end
end

function json.encodeexception(reason, value, state, defaultmessage)
    return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function(value, indent, level, buffer, buflen, tables, globalorder, state)
    local valtype = type(value)
    local valmeta = getmetatable(value)
    valmeta = type(valmeta) == 'table' and valmeta -- only tables
    local valtojson = valmeta and valmeta.__tojson
    if valtojson then
        if tables[value] then
            return exception('reference cycle', value, state, buffer, buflen)
        end
        tables[value] = true
        state.bufferlen = buflen
        local ret, msg = valtojson(value, state)
        if not ret then return exception('custom encoder failed', value, state, buffer, buflen, msg) end
        tables[value] = nil
        buflen = appendcustom(ret, buffer, state)
    elseif value == nil then
        buflen = buflen + 1
        buffer[buflen] = "null"
    elseif valtype == 'number' then
        local s
        if value ~= value or value >= huge or -value >= huge then
            -- This is the behaviour of the original JSON implementation.
            s = "null"
        else
            s = num2str(value)
        end
        buflen = buflen + 1
        buffer[buflen] = s
    elseif valtype == 'boolean' then
        buflen = buflen + 1
        buffer[buflen] = value and "true" or "false"
    elseif valtype == 'string' then
        buflen = buflen + 1
        buffer[buflen] = quotestring(value)
    elseif valtype == 'table' then
        if tables[value] then
            return exception('reference cycle', value, state, buffer, buflen)
        end
        tables[value] = true
        level = level + 1
        local isa, n = isarray(value)
        if n == 0 and valmeta and valmeta.__jsontype == 'object' then
            isa = false
        end
        local msg
        if isa then -- JSON array
            buflen = buflen + 1
            buffer[buflen] = "["
            for i = 1, n do
                buflen, msg = encode2(value[i], indent, level, buffer, buflen, tables, globalorder, state)
                if not buflen then return nil, msg end
                if i < n then
                    buflen = buflen + 1
                    buffer[buflen] = ","
                end
            end
            buflen = buflen + 1
            buffer[buflen] = "]"
        else -- JSON object
            local prev = false
            buflen = buflen + 1
            buffer[buflen] = "{"
            local order = valmeta and valmeta.__jsonorder or globalorder
            if order then
                local used = {}
                n = #order
                for i = 1, n do
                    local k = order[i]
                    local v = value[k]
                    if v ~= nil then
                        used[k] = true
                        buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
                        prev = true -- add a seperator before the next element
                    end
                end
                for k, v in pairs(value) do
                    if not used[k] then
                        buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
                        if not buflen then return nil, msg end
                        prev = true -- add a seperator before the next element
                    end
                end
            else -- unordered
                for k, v in pairs(value) do
                    buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
                    if not buflen then return nil, msg end
                    prev = true -- add a seperator before the next element
                end
            end
            if indent then
                buflen = addnewline2(level - 1, buffer, buflen)
            end
            buflen = buflen + 1
            buffer[buflen] = "}"
        end
        tables[value] = nil
    else
        return exception('unsupported type', value, state, buffer, buflen,
            "type '" .. valtype .. "' is not supported by JSON.")
    end
    return buflen
end

---Encodes a lua table to a JSON string.
---@param value any
---@param state JsonState
---@return string|boolean
function json.encode(value, state)
    state = state or {}
    local oldbuffer = state.buffer
    local buffer = oldbuffer or {}
    state.buffer = buffer
    updatedecpoint()
    local ret, msg = encode2(value, state.indent, state.level or 0,
        buffer, state.bufferlen or 0, state.tables or {}, state.keyorder, state)
    if not ret then
        error(msg, 2)
    elseif oldbuffer == buffer then
        state.bufferlen = ret
        return true
    else
        state.bufferlen = nil
        state.buffer = nil
        return concat(buffer)
    end
end

local function loc(str, where)
    local line, pos, linepos = 1, 1, 0
    while true do
        pos = strfind(str, "\n", pos, true)
        if pos and pos < where then
            line = line + 1
            linepos = pos
            pos = pos + 1
        else
            break
        end
    end
    return "line " .. line .. ", column " .. (where - linepos)
end

local function unterminated(str, what, where)
    return nil, strlen(str) + 1, "unterminated " .. what .. " at " .. loc(str, where)
end

local function scanwhite(str, pos)
    while true do
        pos = strfind(str, "%S", pos)
        if not pos then return nil end
        local sub2 = strsub(str, pos, pos + 1)
        if sub2 == "\239\187" and strsub(str, pos + 2, pos + 2) == "\191" then
            -- UTF-8 Byte Order Mark
            pos = pos + 3
        elseif sub2 == "//" then
            pos = strfind(str, "[\n\r]", pos + 2)
            if not pos then return nil end
        elseif sub2 == "/*" then
            pos = strfind(str, "*/", pos + 2)
            if not pos then return nil end
            pos = pos + 2
        else
            return pos
        end
    end
end

local escapechars = {
    ["\""] = "\"",
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t"
}

local function unichar(value)
    if value < 0 then
        return nil
    elseif value <= 0x007f then
        return strchar(value)
    elseif value <= 0x07ff then
        return strchar(0xc0 + floor(value / 0x40),
            0x80 + (floor(value) % 0x40))
    elseif value <= 0xffff then
        return strchar(0xe0 + floor(value / 0x1000),
            0x80 + (floor(value / 0x40) % 0x40),
            0x80 + (floor(value) % 0x40))
    elseif value <= 0x10ffff then
        return strchar(0xf0 + floor(value / 0x40000),
            0x80 + (floor(value / 0x1000) % 0x40),
            0x80 + (floor(value / 0x40) % 0x40),
            0x80 + (floor(value) % 0x40))
    else
        return nil
    end
end

local function scanstring(str, pos)
    local lastpos = pos + 1
    local buffer, n = {}, 0
    while true do
        local nextpos = strfind(str, "[\"\\]", lastpos)
        if not nextpos then
            return unterminated(str, "string", pos)
        end
        if nextpos > lastpos then
            n = n + 1
            buffer[n] = strsub(str, lastpos, nextpos - 1)
        end
        if strsub(str, nextpos, nextpos) == "\"" then
            lastpos = nextpos + 1
            break
        else
            local escchar = strsub(str, nextpos + 1, nextpos + 1)
            local value
            if escchar == "u" then
                value = tonumber(strsub(str, nextpos + 2, nextpos + 5), 16)
                if value then
                    local value2
                    if 0xD800 <= value and value <= 0xDBff then
                        -- we have the high surrogate of UTF-16. Check if there is a
                        -- low surrogate escaped nearby to combine them.
                        if strsub(str, nextpos + 6, nextpos + 7) == "\\u" then
                            value2 = tonumber(strsub(str, nextpos + 8, nextpos + 11), 16)
                            if value2 and 0xDC00 <= value2 and value2 <= 0xDFFF then
                                value = (value - 0xD800) * 0x400 + (value2 - 0xDC00) + 0x10000
                            else
                                value2 = nil -- in case it was out of range for a low surrogate
                            end
                        end
                    end
                    value = value and unichar(value)
                    if value then
                        if value2 then
                            lastpos = nextpos + 12
                        else
                            lastpos = nextpos + 6
                        end
                    end
                end
            end
            if not value then
                value = escapechars[escchar] or escchar
                lastpos = nextpos + 2
            end
            n = n + 1
            buffer[n] = value
        end
    end
    if n == 1 then
        return buffer[1], lastpos
    elseif n > 1 then
        return concat(buffer), lastpos
    else
        return "", lastpos
    end
end

local scanvalue -- forward declaration

local function scantable(what, closechar, str, startpos, nullval, objectmeta, arraymeta)
    local tbl, n = {}, 0
    local pos = startpos + 1
    if what == 'object' then
        setmetatable(tbl, objectmeta)
    else
        setmetatable(tbl, arraymeta)
    end
    while true do
        pos = scanwhite(str, pos)
        if not pos then return unterminated(str, what, startpos) end
        local char = strsub(str, pos, pos)
        if char == closechar then
            return tbl, pos + 1
        end
        local val1, err
        val1, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
        if err then return nil, pos, err end
        pos = scanwhite(str, pos)
        if not pos then return unterminated(str, what, startpos) end
        char = strsub(str, pos, pos)
        if char == ":" then
            if val1 == nil then
                return nil, pos, "cannot use nil as table index (at " .. loc(str, pos) .. ")"
            end
            pos = scanwhite(str, pos + 1)
            if not pos then return unterminated(str, what, startpos) end
            local val2
            val2, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
            if err then return nil, pos, err end
            tbl[val1] = val2
            pos = scanwhite(str, pos)
            if not pos then return unterminated(str, what, startpos) end
            char = strsub(str, pos, pos)
        else
            n = n + 1
            tbl[n] = val1
        end
        if char == "," then
            pos = pos + 1
        end
    end
end

scanvalue = function(str, pos, nullval, objectmeta, arraymeta)
    pos = pos or 1
    pos = scanwhite(str, pos)
    if not pos then
        return nil, strlen(str) + 1, "no valid JSON value (reached the end)"
    end
    local char = strsub(str, pos, pos)
    if char == "{" then
        return scantable('object', "}", str, pos, nullval, objectmeta, arraymeta)
    elseif char == "[" then
        return scantable('array', "]", str, pos, nullval, objectmeta, arraymeta)
    elseif char == "\"" then
        return scanstring(str, pos)
    else
        local pstart, pend = strfind(str, "^%-?[%d%.]+[eE]?[%+%-]?%d*", pos)
        if pstart then
            local number = str2num(strsub(str, pstart, pend))
            if number then
                return number, pend + 1
            end
        end
        pstart, pend = strfind(str, "^%a%w*", pos)
        if pstart then
            local name = strsub(str, pstart, pend)
            if name == "true" then
                return true, pend + 1
            elseif name == "false" then
                return false, pend + 1
            elseif name == "null" then
                return nullval, pend + 1
            end
        end
        return nil, pos, "no valid JSON value at " .. loc(str, pos)
    end
end

local function optionalmetatables(...)
    if select("#", ...) > 0 then
        return ...
    else
        return { __jsontype = 'object' }, { __jsontype = 'array' }
    end
end

---@param str string
---@param pos integer?
---@param nullval any?
---@param ... table?
function json.decode(str, pos, nullval, ...)
    local objectmeta, arraymeta = optionalmetatables(...)
    return scanvalue(str, pos, nullval, objectmeta, arraymeta)
end

return json

end)
__bundle_register("MedBot.Modules.Node", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Node.lua  ·  MedBot Navigation / Hierarchical path-finding
--  2025-05-24  fully re-worked thin-area grid + robust inter-area linking
--##########################################################################

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local SourceNav = require("MedBot.Utils.SourceNav")
local isWalkable = require("MedBot.Modules.ISWalkable")

-- Optional profiler support
local Profiler = nil
do
	local loaded, mod = pcall(require, "Profiler")
	if loaded then
		Profiler = mod
	end
end

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

local Log = Common.Log.new("Node") -- default Verbose in dev-build
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

--==========================================================================
--  CONSTANTS
--==========================================================================
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local GRID = 24 -- 24-unit fine grid

--==========================================================================
--  NAV-FILE LOADING (unchanged)
--==========================================================================
local function tryLoadNavFile(navFilePath)
	local file = io.open(navFilePath, "rb")
	if not file then
		return nil, "File not found"
	end
	local content = file:read("*a")
	file:close()
	local navData = SourceNav.parse(content)
	if not navData or #navData.areas == 0 then
		return nil, "Failed to parse nav file or no areas found."
	end
	return navData
end

local function generateNavFile()
	client.RemoveConVarProtection("sv_cheats")
	client.RemoveConVarProtection("nav_generate")
	client.SetConVar("sv_cheats", "1")
	client.Command("nav_generate", true)
	Log:Info("Generating nav file. Please wait...")
	local delay = 10
	local startTime = os.time()
	repeat
	until os.time() - startTime > delay
end

local function processNavData(navData)
	local navNodes = {}
	for _, area in pairs(navData.areas) do
		local cX = (area.north_west.x + area.south_east.x) / 2
		local cY = (area.north_west.y + area.south_east.y) / 2
		local cZ = (area.north_west.z + area.south_east.z) / 2
		local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
		local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
		local ne = Vector3(area.south_east.x, area.north_west.y, area.north_east_z)
		local sw = Vector3(area.north_west.x, area.south_east.y, area.south_west_z)
		navNodes[area.id] =
			{ pos = Vector3(cX, cY, cZ), id = area.id, c = area.connections, nw = nw, se = se, ne = ne, sw = sw }
	end
	return navNodes
end

local function traceHullDown(position)
	-- Trace hull from above down to find ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, TRACE_MASK)
end

local function traceLineDown(position)
	-- Line trace down to adjust corner to ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceLine(startPos, endPos, TRACE_MASK)
end

local function getGroundNormal(position)
	local trace =
		engine.TraceLine(position + GROUND_TRACE_OFFSET_START, position + GROUND_TRACE_OFFSET_END, MASK_BRUSH_ONLY)
	return trace.plane
end

local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()
	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)
	local function rotateAroundNormal(vector, angle)
		local cosT = math.cos(angle)
		local sinT = math.sin(angle)
		return Vector3(
			(cosT + (1 - cosT) * normal.x ^ 2) * vector.x
				+ ((1 - cosT) * normal.x * normal.y - normal.z * sinT) * vector.y
				+ ((1 - cosT) * normal.x * normal.z + normal.y * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.y + normal.z * sinT) * vector.x
				+ (cosT + (1 - cosT) * normal.y ^ 2) * vector.y
				+ ((1 - cosT) * normal.y * normal.z - normal.x * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.z - normal.y * sinT) * vector.x
				+ ((1 - cosT) * normal.y * normal.z + normal.x * sinT) * vector.y
				+ (cosT + (1 - cosT) * normal.z ^ 2) * vector.z
		)
	end
	local rot = rotateAroundNormal(heightVector, math.pi / 2)
	return { corner1 + rot * (height / widthLength), corner2 + rot * (height / widthLength) }
end

--- Get all corner positions of a node
---@param node table The node to get corners from
---@return Vector3[] Array of corner positions
local function getNodeCorners(node)
	local corners = {}
	if node.nw then
		table.insert(corners, node.nw)
	end
	if node.ne then
		table.insert(corners, node.ne)
	end
	if node.se then
		table.insert(corners, node.se)
	end
	if node.sw then
		table.insert(corners, node.sw)
	end
	-- Always include center position
	if node.pos then
		table.insert(corners, node.pos)
	end
	return corners
end

--- Check if two nodes are accessible and return cost multiplier
--- Follows proper accessibility checking order as specified
---@param nodeA table First node (source)
---@param nodeB table Second node (destination)
---@param allowExpensive boolean Optional override to allow expensive checks
---@return boolean, number accessibility status and cost multiplier (1 = normal, >1 = penalty)
local function isNodeAccessible(nodeA, nodeB, allowExpensive)
	local heightDiff = nodeB.pos.z - nodeA.pos.z -- Positive = going up, negative = going down

	-- Always allow going downward (falling) regardless of height - no penalty
	if heightDiff <= 0 then
		return true, 1
	end

	-- Step 1: Check if destination is higher than 72 units
	if heightDiff > 72 then
		-- Step 2: Check if any of 4 corners of area A to any 4 corners of area B is within 72 units
		local cornersA = getNodeCorners(nodeA)
		local cornersB = getNodeCorners(nodeB)

		local foundValidCornerPath = false
		for _, cornerA in pairs(cornersA) do
			for _, cornerB in pairs(cornersB) do
				local cornerHeightDiff = cornerB.z - cornerA.z
				-- Allow if any corner-to-corner connection is within jump height
				if cornerHeightDiff <= 72 then
					foundValidCornerPath = true
					break
				end
			end
			if foundValidCornerPath then
				break
			end
		end

		if not foundValidCornerPath then
			-- Step 3: Last resort - check isWalkable if expensive checks allowed
			if allowExpensive and G.Menu.Main.AllowExpensiveChecks then
				if isWalkable.Path(nodeA.pos, nodeB.pos) then
					return true, 3 -- High cost for requiring expensive walkability check
				else
					-- Step 4: If all fails, still keep connection but with very high penalty
					return true, 10 -- Very high penalty instead of removing
				end
			else
				-- During fast processing, assume high penalty but keep connection
				return true, 5 -- High penalty for uncertain accessibility
			end
		else
			-- Corner path found - moderate penalty for complex terrain
			return true, 2
		end
	else
		-- For upward movement within 72 units, normal cost with small penalty
		if heightDiff > 18 then
			return true, 1.5 -- Small penalty for significant height gain
		else
			return true, 1 -- Normal cost for easy height gain
		end
	end
end

--==========================================================================
--  Connection utilities - Handle both integer IDs and cost objects
--==========================================================================

--- Extract node ID from connection (handles both integer and table format)
---@param connection any Connection data (integer ID or table with node/cost)
---@return integer Node ID
local function getConnectionNodeId(connection)
	if type(connection) == "table" then
		-- Support new enriched connection objects
		return connection.node or connection.neighborId
	else
		return connection
	end
end

--- Extract cost from connection (handles both integer and table format)
---@param connection any Connection data (integer ID or table with node/cost)
---@return number Cost value
local function getConnectionCost(connection)
	if type(connection) == "table" then
		return connection.cost or 1
	else
		return 1
	end
end

-- Normalize a single connection entry to the enriched table form
-- Keeps code simple and consistent across the codebase.
local function normalizeConnectionEntry(entry)
	if type(entry) == "table" then
		-- Ensure required keys exist; preserve any extra fields (flatten door points)
		entry.node = entry.node or entry.neighborId
		entry.cost = entry.cost or 1
		entry.left = entry.left or (entry.door and entry.door.left) or nil
		entry.middle = entry.middle or (entry.door and (entry.door.middle or entry.door.mid)) or nil
		entry.right = entry.right or (entry.door and entry.door.right) or nil
		entry.dir = entry.dir or (entry.door and entry.door.dir) or nil
		entry.door = nil -- flatten to keep structure simple per project philosophy
		return entry
	else
		-- Integer neighbor id -> enriched object
		return {
			node = entry,
			cost = 1,
			left = nil,
			middle = nil,
			right = nil,
			dir = nil,
		}
	end
end

--- Convert all raw integer connections to enriched objects with {node, cost, left, middle, right}
function Node.NormalizeConnections()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	-- Deterministic area order
	local ids = {}
	for id in pairs(nodes) do
		ids[#ids + 1] = id
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local area = nodes[id]
		if area and area.c then
			-- Prefer numeric 1..4 order for determinism
			for idx = 1, 4 do
				local cDir = area.c[idx]
				if cDir and cDir.connections then
					local newList = {}
					for _, entry in ipairs(cDir.connections) do
						newList[#newList + 1] = normalizeConnectionEntry(entry)
					end
					cDir.connections = newList
				end
			end
		end
	end
end

--=========================================================================
--  Door building on connections (Left, Middle, Right + needJump)
--=========================================================================

local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local CLEARANCE_OFFSET = 34 -- Move toward reachable side by 34 units after cutoff

local function signDirection(delta, threshold)
	if delta > threshold then
		return 1
	elseif delta < -threshold then
		return -1
	end
	return 0
end

-- Determine primary axis direction based purely on center delta.
-- Chooses the dominant axis by magnitude; sign encodes direction.
-- Examples:
--   dx=50, dy=100   -> dirX=0,  dirY= 1
--   dx=50, dy=-100  -> dirX=0,  dirY=-1
--   dx=-120,dy=40   -> dirX=-1, dirY= 0
local function determineDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx >= 0) and 1 or -1, 0
	else
		return 0, (dy >= 0) and 1 or -1
	end
end

-- Robust cardinal direction using area bounds overlap (axis-aligned).
-- Returns dirX, dirY in {-1,0,1}. Falls back to center-based when ambiguous.
local function cardinalDirectionFromBounds(areaA, areaB)
	local function bounds(area)
		local minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
		local maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
		local minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
		local maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)
		return minX, maxX, minY, maxY
	end
	local aMinX, aMaxX, aMinY, aMaxY = bounds(areaA)
	local bMinX, bMaxX, bMinY, bMaxY = bounds(areaB)
	local eps = 2.0
	local overlapY = (aMinY <= bMaxY + eps) and (bMinY <= aMaxY + eps)
	local overlapX = (aMinX <= bMaxX + eps) and (bMinX <= aMaxX + eps)

	if overlapY and (aMaxX <= bMinX) then
		return 1, 0 -- A -> B is East
	end
	if overlapY and (bMaxX <= aMinX) then
		return -1, 0 -- A -> B is West
	end
	-- Note: Source Y axis appears inverted in-world for our use case; swap N/S signs
	if overlapX and (aMaxY <= bMinY) then
		return 0, -1 -- A -> B is South
	end
	if overlapX and (bMaxY <= aMinY) then
		return 0, 1 -- A -> B is North
	end
	-- Fallback: dominant axis with inverted Y sign
	local dx = areaB.pos.x - areaA.pos.x
	local dy = areaB.pos.y - areaA.pos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx >= 0) and 1 or -1, 0
	else
		return 0, (dy >= 0) and -1 or 1
	end
end

local function cross2D(ax, ay, bx, by)
	return ax * by - ay * bx
end

local function orderEdgeLeftRight(area, targetPos, c1, c2)
	local dir = Vector3(targetPos.x - area.pos.x, targetPos.y - area.pos.y, 0)
	local v1 = Vector3(c1.x - area.pos.x, c1.y - area.pos.y, 0)
	local v2 = Vector3(c2.x - area.pos.x, c2.y - area.pos.y, 0)
	local s1 = cross2D(dir.x, dir.y, v1.x, v1.y)
	local s2 = cross2D(dir.x, dir.y, v2.x, v2.y)
	if s1 == s2 then
		-- Fallback: keep original order
		return c1, c2
	end
	if s1 > s2 then
		return c1, c2 -- c1 is left of dir
	else
		return c2, c1
	end
end

local function getNearestEdgeCorners(area, targetPos)
	-- Return the edge whose segment is closest in XY to targetPos
	local edges = {
		{ area.nw, area.ne }, -- North
		{ area.ne, area.se }, -- East
		{ area.se, area.sw }, -- South
		{ area.sw, area.nw }, -- West
	}
	local function distPointToSeg2(p, a, b)
		local px, py = p.x, p.y
		local ax, ay = a.x, a.y
		local bx, by = b.x, b.y
		local vx, vy = bx - ax, by - ay
		local wx, wy = px - ax, py - ay
		local vv = vx * vx + vy * vy
		local t = vv > 0 and ((wx * vx + wy * vy) / vv) or 0
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
		local cx, cy = ax + t * vx, ay + t * vy
		local dx, dy = px - cx, py - cy
		return dx * dx + dy * dy
	end
	local bestA, bestB, bestD = nil, nil, math.huge
	for _, e in ipairs(edges) do
		local d = distPointToSeg2(targetPos, e[1], e[2])
		if d < bestD then
			bestD = d
			bestA, bestB = e[1], e[2]
		end
	end
	return bestA, bestB
end

local function getFacingEdgeCorners(area, dirX, dirY, otherPos)
	-- Returns leftCorner, rightCorner on the facing edge (world positions)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end
	-- Deterministic left/right per cardinal direction (axis-aligned):
	-- North: left=nw, right=ne
	-- South: left=se, right=sw
	-- East:  left=ne, right=se
	-- West:  left=sw, right=nw
	if dirX == 1 then
		return area.ne, area.se
	elseif dirX == -1 then
		return area.sw, area.nw
	elseif dirY == 1 then
		return area.nw, area.ne
	elseif dirY == -1 then
		return area.se, area.sw
	else
		-- Ambiguous: fall back to nearest edge without reordering
		local a, b = getNearestEdgeCorners(area, otherPos)
		return a, b
	end
end

local function lerpVec(a, b, t)
	return Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

local function absZDiff(a, b)
	return math.abs(a.z - b.z)
end

local function distance3D(p, q)
	local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Spec-compliant side selection:
-- Compare A_left<->B_left vs A_right<->B_right and keep the orientation with the shorter distance.
-- If distances are equal, keep as-is (stable – do nothing).
local function chooseMappingPreferShorterSide(aLeft, aRight, bLeft, bRight)
	local dLL = distance3D(aLeft, bLeft)
	local dRR = distance3D(aRight, bRight)
	if dRR < dLL then
		-- Flip B so that B_left/B_right align with the shorter side
		return bRight, bLeft
	end
	return bLeft, bRight
end

local function binarySearchCutoff(aReach, aUnreach, bReach, bUnreach)
	local low, high = 0.0, 1.0
	for _ = 1, 4 do -- ~4 iterations sufficient
		local mid = (low + high) * 0.5
		local pA = lerpVec(aReach, aUnreach, mid)
		local pB = lerpVec(bReach, bUnreach, mid)
		local diff = absZDiff(pA, pB)
		if diff >= MAX_JUMP then
			high = mid -- move toward reachable side
		else
			low = mid -- move toward unreachable side
		end
	end
	-- Back off by clearance along the edge toward reachable side
	local edgeLen = (aUnreach - aReach):Length()
	local backT = edgeLen > 0 and (CLEARANCE_OFFSET / edgeLen) or 0
	local tFinal = math.max(0, low - backT)
	local aCut = lerpVec(aReach, aUnreach, tFinal)
	local bCut = lerpVec(bReach, bUnreach, tFinal)
	return aCut, bCut
end

-- Compute overlapping projection of two facing edges along their dominant axis
local function computeOverlapParams(aLeft, aRight, bLeft, bRight)
	local dxA, dyA = aRight.x - aLeft.x, aRight.y - aLeft.y
	local useX = math.abs(dxA) >= math.abs(dyA)

	local function axisVal(p)
		return useX and p.x or p.y
	end

	local a0, a1 = axisVal(aLeft), axisVal(aRight)
	local b0, b1 = axisVal(bLeft), axisVal(bRight)
	local aMin, aMax = math.min(a0, a1), math.max(a0, a1)
	local bMin, bMax = math.min(b0, b1), math.max(b0, b1)
	local oMin, oMax = math.max(aMin, bMin), math.min(aMax, bMax)
	if oMax <= oMin then
		return nil
	end

	local function paramOn(seg0, seg1, v)
		local denom = (seg1 - seg0)
		if denom == 0 then
			return nil
		end
		return (v - seg0) / denom
	end

	local tA0 = paramOn(a0, a1, oMin)
	local tA1 = paramOn(a0, a1, oMax)
	local tB0 = paramOn(b0, b1, oMin)
	local tB1 = paramOn(b0, b1, oMax)
	if not (tA0 and tA1 and tB0 and tB1) then
		return nil
	end

	local tAL, tAR = math.min(tA0, tA1), math.max(tA0, tA1)
	local tBL, tBR = math.min(tB0, tB1), math.max(tB0, tB1)
	-- Also return axis values to allow clamping to common domain with clearance
	return {
		useX = useX,
		a0 = a0,
		a1 = a1,
		b0 = b0,
		b1 = b1,
		aMin = aMin,
		aMax = aMax,
		bMin = bMin,
		bMax = bMax,
		oMin = oMin,
		oMax = oMax,
		tAL = tAL,
		tAR = tAR,
		tBL = tBL,
		tBR = tBR,
	}
end

-- Returns tLeft, tRight (inclusive) on A-edge and minDiff across the reachable span; nil if none
local function findReachableSpan(aLeft, aRight, bLeft, bRight)
	local p = computeOverlapParams(aLeft, aRight, bLeft, bRight)
	if not p then
		return nil
	end
	-- Defensive: ensure numeric params for linters/types
	local tAL = p.tAL or 0.0
	local tAR = p.tAR or 1.0
	local tBL = p.tBL or 0.0
	local tBR = p.tBR or 1.0

	local aStart, aEnd = lerpVec(aLeft, aRight, tAL), lerpVec(aLeft, aRight, tAR)
	local bStart, bEnd = lerpVec(bLeft, bRight, tBL), lerpVec(bLeft, bRight, tBR)

	local dStart = absZDiff(aStart, bStart)
	local dEnd = absZDiff(aEnd, bEnd)
	local startReach, endReach = dStart < MAX_JUMP, dEnd < MAX_JUMP

	if (not startReach) and not endReach then
		return nil
	end

	if startReach and endReach then
		-- Clamp to common domain on the shared axis with 24u from each area's corners when possible
		local edgeLen = (aRight - aLeft):Length()
		local domainMin, domainMax = p.oMin, p.oMax
		local widthA = p.aMax - p.aMin
		local widthB = p.bMax - p.bMin
		local clearance = HITBOX_WIDTH
		if widthA > (2 * clearance) then
			domainMin = math.max(domainMin, p.aMin + clearance)
			domainMax = math.min(domainMax, p.aMax - clearance)
		end
		if widthB > (2 * clearance) then
			domainMin = math.max(domainMin, p.bMin + clearance)
			domainMax = math.min(domainMax, p.bMax - clearance)
		end
		if domainMax <= domainMin then
			domainMin, domainMax = p.oMin, p.oMax
		end

		local denomA = (p.a1 - p.a0)
		local tL = denomA ~= 0 and ((domainMin - p.a0) / denomA) or tAL
		local tR = denomA ~= 0 and ((domainMax - p.a0) / denomA) or tAR
		tL = math.max(tAL, math.max(0, math.min(1, tL)))
		tR = math.min(tAR, math.max(0, math.min(1, tR)))
		tR = math.max(tL, tR)
		local minDiff = math.min(dStart, dEnd)
		return tL, tR, minDiff
	end

	if startReach and not endReach then
		if dStart >= MAX_JUMP then
			return nil
		end
		local aCut = binarySearchCutoff(aStart, aEnd, bStart, bEnd)
		-- Map cut point back to param along A edge (project on XY)
		local vx, vy = aRight.x - aLeft.x, aRight.y - aLeft.y
		local wx, wy = aCut.x - aLeft.x, aCut.y - aLeft.y
		local denom = vx * vx + vy * vy
		local tRraw = denom > 0 and ((wx * vx + wy * vy) / denom) or tAR
		local tRnum = (type(tRraw) == "number") and tRraw or 0.0
		local tL = tAL
		local tRval = math.max(tL, math.min(tAR, tRnum))
		return tL, tRval, dStart
	elseif endReach and not startReach then
		if dEnd >= MAX_JUMP then
			return nil
		end
		local aCut = binarySearchCutoff(aEnd, aStart, bEnd, bStart)
		local vx, vy = aRight.x - aLeft.x, aRight.y - aLeft.y
		local wx, wy = aCut.x - aLeft.x, aCut.y - aLeft.y
		local denom = vx * vx + vy * vy
		local tLraw = denom > 0 and ((wx * vx + wy * vy) / denom) or tAL
		local tLnum = (type(tLraw) == "number") and tLraw or 0.0
		local tR = tAR
		local tLval = math.min(math.max(tAL, tLnum), tR)
		return tLval, tR, dEnd
	end

	return nil
end

local function createDoorForAreas(areaA, areaB)
	-- Determine axis-aligned facing sides: A faces toward B; B faces back toward A
	local dirAX, dirAY = cardinalDirectionFromBounds(areaA, areaB)
	local dirBX, dirBY = -dirAX, -dirAY
	local aLeft, aRight = getFacingEdgeCorners(areaA, dirAX, dirAY, areaB.pos)
	local bLeft, bRight = getFacingEdgeCorners(areaB, dirBX, dirBY, areaA.pos)
	if not (aLeft and aRight and bLeft and bRight) then
		return nil
	end

	-- Detect downward one-way first to bypass any bidirectional clamping logic
	local aZ = (areaA.nw.z + areaA.ne.z + areaA.se.z + areaA.sw.z) * 0.25
	local bZ = (areaB.nw.z + areaB.ne.z + areaB.se.z + areaB.sw.z) * 0.25
	local isDownwardOneWay = (bZ < aZ - 0.5)

	local tL, tR
	if isDownwardOneWay then
		-- Build overlap domain directly and accept it regardless of height delta
		local p = computeOverlapParams(aLeft, aRight, bLeft, bRight)
		if not p then
			return nil
		end
		local tAL = p.tAL or 0.0
		local tAR = p.tAR or 1.0
		-- Apply clearance only when there is ample width; otherwise keep raw domain (no corner clamping)
		local domainMin, domainMax = p.oMin, p.oMax
		local widthA = p.aMax - p.aMin
		local widthB = p.bMax - p.bMin
		local clearance = HITBOX_WIDTH
		if widthA > (2 * clearance) then
			domainMin = math.max(domainMin, p.aMin + clearance)
			domainMax = math.min(domainMax, p.aMax - clearance)
		end
		if widthB > (2 * clearance) then
			domainMin = math.max(domainMin, p.bMin + clearance)
			domainMax = math.min(domainMax, p.bMax - clearance)
		end
		local denomA = (p.a1 - p.a0)
		local tLval = denomA ~= 0 and ((domainMin - p.a0) / denomA) or tAL
		local tRval = denomA ~= 0 and ((domainMax - p.a0) / denomA) or tAR
		-- Clamp
		tLval = math.max(tAL, math.max(0, math.min(1, tLval)))
		tRval = math.min(tAR, math.max(0, math.min(1, tRval)))
		tRval = math.max(tLval, tRval)
		tL, tR = tLval, tRval
	else
		-- Only consider the two facing sides (no cross-side mapping). Use overlap along their shared axis.
		local tL2, tR2 = findReachableSpan(aLeft, aRight, bLeft, bRight)
		if not tL2 then
			return nil
		end
		tL, tR = tL2, tR2
	end

	local aDoorLeft = lerpVec(aLeft, aRight, tL)
	local aDoorRight = lerpVec(aLeft, aRight, tR)
	-- Do not clamp away from corners for one-way downward doors when width < 48u (keep them),
	-- but still report the direction so movement can choose the best point.
	local mid = lerpVec(aDoorLeft, aDoorRight, 0.5)

	-- Need jump if any endpoint in the chosen span needs >18 and <72
	local leftEndDiff = absZDiff(lerpVec(aLeft, aRight, tL), lerpVec(bLeft, bRight, tL))
	local rightEndDiff = absZDiff(lerpVec(aLeft, aRight, tR), lerpVec(bLeft, bRight, tR))
	local needJump = (leftEndDiff > STEP_HEIGHT and leftEndDiff < MAX_JUMP)
		or (rightEndDiff > STEP_HEIGHT and rightEndDiff < MAX_JUMP)

	-- Compute cardinal direction string from A to B
	local dx, dy = cardinalDirectionFromBounds(areaA, areaB)
	local dirStr = (dx == 1 and "E") or (dx == -1 and "W") or (dy == 1 and "N") or (dy == -1 and "S") or "N"

	return {
		left = aDoorLeft,
		middle = mid,
		right = aDoorRight,
		needJump = needJump,
		dir = dirStr,
		oneWayDown = isDownwardOneWay,
	}
end

function Node.BuildDoorsForConnections()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	-- Deterministic area order
	local ids = {}
	for id in pairs(nodes) do
		ids[#ids + 1] = id
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local areaA = nodes[id]
		if areaA and areaA.c then
			for dirIndex = 1, 4 do
				local cDir = areaA.c[dirIndex]
				if cDir and cDir.connections then
					local updated = {}
					for _, connection in ipairs(cDir.connections) do
						local entry = normalizeConnectionEntry(connection)
						local neighbor = nodes[entry.node]
						if neighbor and neighbor.pos then
							local door = createDoorForAreas(areaA, neighbor)
							if door then
								entry.left = door.left
								entry.middle = door.middle
								entry.right = door.right
								entry.needJump = door.needJump and true or false
								entry.dir = door.dir
								entry.oneWayDown = door.oneWayDown and true or false
								updated[#updated + 1] = entry
							else
								-- Drop unreachable connection
							end
						end
					end
					cDir.connections = updated
					cDir.count = #updated
				end
			end
		end
	end
end

--- Public utility functions for connection handling
---@param connection any Connection data (integer ID or table with node/cost)
---@return integer Node ID
function Node.GetConnectionNodeId(connection)
	return getConnectionNodeId(connection)
end

--- Public utility function for getting connection cost
---@param connection any Connection data (integer ID or table with node/cost)
---@return number Cost value
function Node.GetConnectionCost(connection)
	return getConnectionCost(connection)
end

--- Returns the enriched connection entry (with door points) from A->B if present
---@param nodeA table
---@param nodeB table
---@return table|nil
function Node.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then
		return nil
	end
	local nodes = Node.GetNodes()
	if not nodes then
		return nil
	end
	local areaA = nodes[nodeA.id]
	if not (areaA and areaA.c) then
		return nil
	end
	for _, cDir in pairs(areaA.c) do
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				if targetNodeId == nodeB.id then
					return normalizeConnectionEntry(connection)
				end
			end
		end
	end
	return nil
end

-- Cache for quick door target lookup
local DoorTargetCache = {}

--- Get a door target point for transitioning from areaA to areaB.
--- Chooses middle for N/S, right for E, left for W. Falls back to middle when uncertain.
---@param areaA table
---@param areaB table
---@return Vector3|nil
function Node.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then
		return nil
	end
	local key = tostring(areaA.id) .. "->" .. tostring(areaB.id)
	if DoorTargetCache[key] then
		return DoorTargetCache[key]
	end

	-- Prefer precomputed door points on the connection
	local entry = Node.GetConnectionEntry(areaA, areaB)
	local doorLeft, doorMid, doorRight = nil, nil, nil
	local dirOverride = nil
	if entry then
		doorLeft, doorMid, doorRight = entry.left, entry.middle, entry.right
		dirOverride = entry.dir
	end

	-- If we lack door points, try constructing them on the fly
	if not (doorLeft and doorMid and doorRight) then
		local dirAX, dirAY = cardinalDirectionFromBounds(areaA, areaB)
		local aLeft, aRight = getFacingEdgeCorners(areaA, dirAX, dirAY, areaB.pos)
		local bLeft, bRight = getFacingEdgeCorners(areaB, -dirAX, -dirAY, areaA.pos)
		if aLeft and aRight and bLeft and bRight then
			local tL, tR = findReachableSpan(aLeft, aRight, bLeft, bRight)
			if tL and tR then
				doorLeft = lerpVec(aLeft, aRight, tL)
				doorRight = lerpVec(aLeft, aRight, tR)
				doorMid = lerpVec(doorLeft, doorRight, 0.5)
			end
		end
	end

	if not (doorLeft or doorMid or doorRight) then
		return nil
	end

	-- Choose side by cardinal direction: E=right, W=left, N/S=middle
	local dirX, dirY = cardinalDirectionFromBounds(areaA, areaB)
	if dirOverride then
		if dirOverride == "E" then
			dirX, dirY = 1, 0
		elseif dirOverride == "W" then
			dirX, dirY = -1, 0
		elseif dirOverride == "N" then
			dirX, dirY = 0, 1
		elseif dirOverride == "S" then
			dirX, dirY = 0, -1
		end
	end
	local target = nil
	if dirX == 1 then
		target = doorRight or doorMid or doorLeft
	elseif dirX == -1 then
		target = doorLeft or doorMid or doorRight
	else
		target = doorMid or doorLeft or doorRight
	end

	DoorTargetCache[key] = target
	return target
end

--==========================================================================
--  Dynamic batch processing system with frame time monitoring
--==========================================================================

local ConnectionProcessor = {
	-- Current processing state
	isProcessing = false,
	currentPhase = 1, -- 1 = basic connections, 2 = expensive fallback, 3 = fine point expensive stitching
	processedNodes = {},
	pendingNodes = {},
	nodeQueue = {},

	-- Performance monitoring
	targetFPS = 24,
	maxFrameTime = 1.0 / 24, -- ~41.7ms for 24 FPS
	currentBatchSize = 5,
	minBatchSize = 1,
	maxBatchSize = 20,

	-- Statistics
	totalProcessed = 0,
	connectionsFound = 0,
	expensiveChecksUsed = 0,
	finePointConnectionsAdded = 0,
}

--- Calculate current FPS and adjust batch size dynamically
local function adjustBatchSize()
	local frameTime = globals.FrameTime()
	local currentFPS = 1 / frameTime

	-- If FPS is too low, reduce batch size
	if currentFPS < ConnectionProcessor.targetFPS then
		ConnectionProcessor.currentBatchSize =
			math.max(ConnectionProcessor.minBatchSize, ConnectionProcessor.currentBatchSize - 1)
	-- If FPS is good, try to increase batch size for faster processing
	elseif currentFPS > ConnectionProcessor.targetFPS * 1.5 and frameTime < ConnectionProcessor.maxFrameTime * 0.8 then
		ConnectionProcessor.currentBatchSize =
			math.min(ConnectionProcessor.maxBatchSize, ConnectionProcessor.currentBatchSize + 1)
	end

	return currentFPS
end

--- Initialize connection processing
local function initializeConnectionProcessing(nodes)
	ConnectionProcessor.isProcessing = true
	ConnectionProcessor.currentPhase = 1
	ConnectionProcessor.processedNodes = {}
	ConnectionProcessor.pendingNodes = {}
	ConnectionProcessor.nodeQueue = {}

	-- Build queue of all nodes to process
	for nodeId, node in pairs(nodes) do
		if node and node.c then
			table.insert(ConnectionProcessor.nodeQueue, { id = nodeId, node = node })
		end
	end

	ConnectionProcessor.totalProcessed = 0
	ConnectionProcessor.connectionsFound = 0
	ConnectionProcessor.expensiveChecksUsed = 0

	Log:Info(
		"Started dynamic connection processing: %d nodes queued, target FPS: %d",
		#ConnectionProcessor.nodeQueue,
		ConnectionProcessor.targetFPS
	)
end

--- Process a batch of connections for one frame
local function processBatch(nodes)
	if not ConnectionProcessor.isProcessing then
		return false
	end

	local startTime = globals.FrameTime()
	local processed = 0

	-- Phase 1: Basic connection validation (no expensive checks)
	if ConnectionProcessor.currentPhase == 1 then
		while processed < ConnectionProcessor.currentBatchSize and #ConnectionProcessor.nodeQueue > 0 do
			local nodeData = table.remove(ConnectionProcessor.nodeQueue, 1)
			local nodeId, node = nodeData.id, nodeData.node

			if node and node.c then
				-- Process all directions for this node
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						local validConnections = {}

						for _, connection in pairs(connectionDir.connections) do
							local targetNodeId = getConnectionNodeId(connection)
							local currentCost = getConnectionCost(connection)
							local targetNode = nodes[targetNodeId]

							if targetNode then
								-- Phase 1: Fast accessibility check without expensive operations
								local isAccessible, costMultiplier = isNodeAccessible(node, targetNode, false)
								local finalCost = currentCost * costMultiplier

								-- Add height-based cost for smooth walking mode
								if G.Menu.Main.WalkableMode == "Smooth" then
									local heightDiff = targetNode.pos.z - node.pos.z
									if heightDiff > 18 then -- Requires jump in smooth mode
										local heightPenalty = math.floor(heightDiff / 18) * 10 -- 10 cost per 18 units
										finalCost = finalCost + heightPenalty
									end
								end

								-- Always keep connection but adjust cost; preserve door points if any
								local base = normalizeConnectionEntry(connection)
								table.insert(validConnections, {
									node = targetNodeId,
									cost = finalCost,
									left = base.left,
									middle = base.middle,
									right = base.right,
								})

								ConnectionProcessor.connectionsFound = ConnectionProcessor.connectionsFound + 1

								-- If high penalty was applied, mark for potential expensive check
								if costMultiplier >= 5 then
									if not ConnectionProcessor.pendingNodes[nodeId] then
										ConnectionProcessor.pendingNodes[nodeId] = {}
									end
									table.insert(ConnectionProcessor.pendingNodes[nodeId], {
										dir = dir,
										targetId = targetNodeId,
										originalCost = currentCost,
										connectionIndex = #validConnections, -- Track which connection to update
									})
								end
							end
						end

						-- Update connections (always enriched objects)
						connectionDir.connections = validConnections
						connectionDir.count = #validConnections
					end
				end

				ConnectionProcessor.processedNodes[nodeId] = true
			end

			processed = processed + 1
			ConnectionProcessor.totalProcessed = ConnectionProcessor.totalProcessed + 1
		end

		-- Check if phase 1 is complete
		if #ConnectionProcessor.nodeQueue == 0 then
			local pendingCount = 0
			for _ in pairs(ConnectionProcessor.pendingNodes) do
				pendingCount = pendingCount + 1
			end
			Log:Info(
				"Phase 1 complete: %d basic connections found, %d nodes need expensive checks",
				ConnectionProcessor.connectionsFound,
				pendingCount
			)

			ConnectionProcessor.currentPhase = 2
			ConnectionProcessor.currentBatchSize = math.max(1, ConnectionProcessor.currentBatchSize / 4) -- Slower for expensive checks
		end

	-- Phase 2: Expensive fallback checks to improve high-penalty connections
	elseif ConnectionProcessor.currentPhase == 2 then
		local pendingProcessed = 0

		for nodeId, pendingConnections in pairs(ConnectionProcessor.pendingNodes) do
			if pendingProcessed >= ConnectionProcessor.currentBatchSize then
				break
			end

			local node = nodes[nodeId]
			if node and #pendingConnections > 0 then
				local connectionData = table.remove(pendingConnections, 1)
				local targetNode = nodes[connectionData.targetId]

				if targetNode then
					-- Use expensive check to get better cost assessment
					local isAccessible, costMultiplier = isNodeAccessible(node, targetNode, true)
					local dir = connectionData.dir
					local connectionDir = node.c[dir]

					if connectionDir and connectionDir.connections and connectionData.connectionIndex then
						-- Update the existing connection with better cost information
						local existingConnection = connectionDir.connections[connectionData.connectionIndex]
						if existingConnection then
							local improvedCost = connectionData.originalCost * costMultiplier

							-- Update the connection cost
							local base = normalizeConnectionEntry(existingConnection)
							connectionDir.connections[connectionData.connectionIndex] = {
								node = base.node,
								cost = improvedCost,
								left = base.left,
								middle = base.middle,
								right = base.right,
							}

							ConnectionProcessor.expensiveChecksUsed = ConnectionProcessor.expensiveChecksUsed + 1

							Log:Debug(
								"Improved connection cost from node %d to %d: %s -> %.1f",
								nodeId,
								connectionData.targetId,
								"high penalty",
								improvedCost
							)
						end
					end
				end

				pendingProcessed = pendingProcessed + 1

				-- Clean up empty pending lists
				if #pendingConnections == 0 then
					ConnectionProcessor.pendingNodes[nodeId] = nil
				end
			end
		end

		-- Check if all processing is complete
		local hasPending = false
		for _, pendingList in pairs(ConnectionProcessor.pendingNodes) do
			if #pendingList > 0 then
				hasPending = true
				break
			end
		end

		if not hasPending then
			Log:Info(
				"Phase 2 complete: %d total connections, %d expensive checks used, starting stair patching",
				ConnectionProcessor.connectionsFound,
				ConnectionProcessor.expensiveChecksUsed
			)
			ConnectionProcessor.currentPhase = 3
			ConnectionProcessor.currentBatchSize = math.max(1, ConnectionProcessor.currentBatchSize / 2) -- Moderate speed for stair patching
		end

	-- Phase 3: Stair connection patching - add missing reverse connections for stairs
	elseif ConnectionProcessor.currentPhase == 3 then
		local processed = 0
		local maxProcessPerFrame = ConnectionProcessor.currentBatchSize
		local patchedConnections = 0

		-- Build a quick lookup of all existing connections
		local existingConnections = {}
		for nodeId, node in pairs(nodes) do
			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = getConnectionNodeId(connection)
							local key = nodeId .. "->" .. targetNodeId
							existingConnections[key] = true
						end
					end
				end
			end
		end

		-- Check for missing reverse connections, especially for stairs
		for nodeId, node in pairs(nodes) do
			if processed >= maxProcessPerFrame then
				break
			end

			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = getConnectionNodeId(connection)
							local targetNode = nodes[targetNodeId]

							if targetNode then
								-- Check if reverse connection exists
								local reverseKey = targetNodeId .. "->" .. nodeId
								if not existingConnections[reverseKey] then
									-- No reverse connection exists, check if we should add one
									local heightDiff = targetNode.pos.z - node.pos.z

									-- For stair-like connections (significant height difference)
									if math.abs(heightDiff) > 18 and math.abs(heightDiff) <= 200 then
										-- Use expensive isWalkable check for reverse direction
										if
											G.Menu.Main.AllowExpensiveChecks
											and isWalkable.Path(targetNode.pos, node.pos)
										then
											-- Add reverse connection to target node
											local addedToDirection = false
											for targetDir, targetConnectionDir in pairs(targetNode.c) do
												if
													targetConnectionDir
													and targetConnectionDir.connections
													and not addedToDirection
												then
													-- Calculate appropriate cost for reverse connection
													local reverseCost = 1
													if heightDiff > 0 then
														-- Going down - easier, lower cost
														reverseCost = 1
													else
														-- Going up - harder, higher cost
														reverseCost = math.abs(heightDiff) > 72 and 3 or 1.5
													end

													table.insert(targetConnectionDir.connections, {
														node = nodeId,
														cost = reverseCost,
														left = nil,
														middle = nil,
														right = nil,
													})
													targetConnectionDir.count = targetConnectionDir.count + 1
													patchedConnections = patchedConnections + 1
													addedToDirection = true

													-- Update our lookup to prevent duplicate patching
													existingConnections[reverseKey] = true

													Log:Debug(
														"Patched stair connection: %d -> %d (height: %.1f, cost: %.1f)",
														targetNodeId,
														nodeId,
														-heightDiff,
														reverseCost
													)
													break
												end
											end
										end
									end
								end
							end
							processed = processed + 1
						end
					end
				end
			end
		end

		-- Check if Phase 3 is complete
		if processed == 0 or patchedConnections == 0 then
			Log:Info("Stair patching complete: %d reverse connections added", patchedConnections)
			ConnectionProcessor.currentPhase = 4
			ConnectionProcessor.currentBatchSize = math.max(1, ConnectionProcessor.currentBatchSize / 2)
			ConnectionProcessor.finePointConnectionsAdded = patchedConnections
		end

	-- Phase 4: Fine point expensive stitching for missing inter-area connections
	elseif ConnectionProcessor.currentPhase == 4 then
		if G.Navigation.hierarchical and G.Navigation.hierarchical.areas then
			local processed = 0
			local maxProcessPerFrame = ConnectionProcessor.currentBatchSize

			-- Process fine point connections between adjacent areas
			for areaId, areaInfo in pairs(G.Navigation.hierarchical.areas) do
				if processed >= maxProcessPerFrame then
					break
				end

				-- Get adjacent areas for this area
				local area = areaInfo.area
				if area and area.c then
					local adjacentAreas = Node.GetAdjacentNodesOnly(area, nodes)

					-- Check each edge point against edge points in adjacent areas
					for _, edgePoint in pairs(areaInfo.edgePoints) do
						if processed >= maxProcessPerFrame then
							break
						end

						for _, adjacentArea in pairs(adjacentAreas) do
							local adjacentAreaInfo = G.Navigation.hierarchical.areas[adjacentArea.id]
							if adjacentAreaInfo then
								-- Check connections to edge points in adjacent area
								for _, adjacentEdgePoint in pairs(adjacentAreaInfo.edgePoints) do
									-- Check if connection already exists
									local connectionExists = false
									for _, neighbor in pairs(edgePoint.neighbors) do
										if
											neighbor.point
											and neighbor.point.id == adjacentEdgePoint.id
											and neighbor.point.parentArea == adjacentEdgePoint.parentArea
										then
											connectionExists = true
											break
										end
									end

									-- If no connection exists, try expensive check
									if not connectionExists then
										local distance = (edgePoint.pos - adjacentEdgePoint.pos):Length()

										-- Only check reasonable distances (not too far apart)
										if distance < 150 and distance > 5 then
											-- Use expensive walkability check
											if isWalkable.Path(edgePoint.pos, adjacentEdgePoint.pos) then
												-- Add bidirectional connection
												table.insert(edgePoint.neighbors, {
													point = adjacentEdgePoint,
													cost = distance,
													isInterArea = true,
												})
												table.insert(adjacentEdgePoint.neighbors, {
													point = edgePoint,
													cost = distance,
													isInterArea = true,
												})

												ConnectionProcessor.finePointConnectionsAdded = ConnectionProcessor.finePointConnectionsAdded
													+ 1
												ConnectionProcessor.expensiveChecksUsed = ConnectionProcessor.expensiveChecksUsed
													+ 1

												Log:Debug(
													"Added fine point connection: Area %d point %d <-> Area %d point %d (dist: %.1f)",
													areaId,
													edgePoint.id,
													adjacentArea.id,
													adjacentEdgePoint.id,
													distance
												)
											end
										end
									end
								end
							end
						end
						processed = processed + 1
					end
				end
			end

			-- Check if Phase 3 is complete (when we've processed all areas)
			if processed == 0 then
				Log:Info(
					"Fine point stitching complete: %d connections added with expensive checks",
					ConnectionProcessor.finePointConnectionsAdded
				)
				ConnectionProcessor.isProcessing = false
				return false -- Processing finished
			end
		else
			-- No hierarchical data, skip Phase 3
			Log:Info("No hierarchical data available, skipping fine point stitching")
			ConnectionProcessor.isProcessing = false
			return false
		end
	end

	-- Adjust batch size based on frame time
	adjustBatchSize()

	return true -- Continue processing
end

--- Apply proper connection cost analysis without removing connections
local function pruneInvalidConnections(nodes)
	Log:Info("Starting proper connection cost analysis (no connections removed)")

	-- Apply cost penalties to all connections using our proper accessibility logic
	local processedConnections = 0
	local penalizedConnections = 0

	for nodeId, node in pairs(nodes) do
		if node and node.c then
			for dir, connectionDir in pairs(node.c) do
				if connectionDir and connectionDir.connections then
					local updatedConnections = {}

					for _, connection in pairs(connectionDir.connections) do
						local targetNodeId = getConnectionNodeId(connection)
						local currentCost = getConnectionCost(connection)
						local targetNode = nodes[targetNodeId]

						if targetNode then
							-- Use our proper accessibility checking with expensive checks allowed
							local isAccessible, costMultiplier = isNodeAccessible(node, targetNode, true)
							local finalCost = currentCost * costMultiplier

							-- Always keep connection, just adjust cost; preserve door points if any
							local base = normalizeConnectionEntry(connection)
							table.insert(updatedConnections, {
								node = targetNodeId,
								cost = finalCost,
								left = base.left,
								middle = base.middle,
								right = base.right,
							})

							if costMultiplier > 1 then
								penalizedConnections = penalizedConnections + 1
							end
							processedConnections = processedConnections + 1
						else
							-- Only remove connections to non-existent nodes
							Log:Debug("Removing connection to non-existent node %d", targetNodeId)
						end
					end

					connectionDir.connections = updatedConnections
					connectionDir.count = #updatedConnections
				end
			end
		end
	end

	Log:Info(
		"Connection analysis complete: %d processed, %d penalized, 0 removed",
		processedConnections,
		penalizedConnections
	)

	-- Initialize background processing for fine-tuning if enabled
	if G.Menu.Main.CleanupConnections then
		initializeConnectionProcessing(nodes)
	end
end

--- Process connections in background (called from OnDraw)
function Node.ProcessConnectionsBackground()
	if ConnectionProcessor.isProcessing then
		local nodes = Node.GetNodes()
		if nodes then
			return processBatch(nodes)
		end
	end
	return false
end

--- Get connection processing status
function Node.GetConnectionProcessingStatus()
	return {
		isProcessing = ConnectionProcessor.isProcessing,
		currentPhase = ConnectionProcessor.currentPhase,
		totalNodes = #ConnectionProcessor.nodeQueue + ConnectionProcessor.totalProcessed,
		processedNodes = ConnectionProcessor.totalProcessed,
		connectionsFound = ConnectionProcessor.connectionsFound,
		expensiveChecksUsed = ConnectionProcessor.expensiveChecksUsed,
		finePointConnectionsAdded = ConnectionProcessor.finePointConnectionsAdded,
		currentBatchSize = ConnectionProcessor.currentBatchSize,
		currentFPS = ConnectionProcessor.isProcessing and (1 / globals.FrameTime()) or 0,
	}
end

--- Force stop connection processing
function Node.StopConnectionProcessing()
	ConnectionProcessor.isProcessing = false
	Log:Info("Connection processing stopped by user")
end

------------------------------------------------------------------------
--  Utility  ·  bilinear Z on the area-plane
------------------------------------------------------------------------
local function bilinearZ(x, y, nw, ne, se, sw)
	local w, h = se.x - nw.x, se.y - nw.y
	if w == 0 or h == 0 then
		return nw.z
	end
	local u, v = (x - nw.x) / w, (y - nw.y) / h
	u, v = math.max(0, math.min(1, u)), math.max(0, math.min(1, v))
	local zN = nw.z * (1 - u) + ne.z * u
	local zS = sw.z * (1 - u) + se.z * u
	return zN * (1 - v) + zS * v
end

------------------------------------------------------------------------
--  Fine-grid generation   (thin-area aware + ring & dir tags)
------------------------------------------------------------------------
local function generateAreaPoints(area)
	------------------------------------------------------------
	-- cache bounds
	------------------------------------------------------------
	area.minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	area.maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	area.minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
	area.maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)

	local areaWidth = area.maxX - area.minX
	local areaHeight = area.maxY - area.minY

	-- If area is smaller than grid size in either dimension, treat as minor node
	if areaWidth < GRID or areaHeight < GRID then
		Log:Debug("Area %d too small (%dx%d), treating as minor node", area.id, areaWidth, areaHeight)
		local minorPoint = {
			id = 1,
			gridX = 0,
			gridY = 0,
			pos = area.pos,
			neighbors = {},
			parentArea = area.id,
			ring = 0,
			isEdge = true,
			isInner = false,
			dirTags = { "N", "S", "E", "W" }, -- Minor area connects in all directions
			dirMask = Node.DIR.N | Node.DIR.S | Node.DIR.E | Node.DIR.W,
		}

		-- Create edgeSets for minor areas - single point represents all directions
		area.edgeSets = {
			N = { minorPoint },
			S = { minorPoint },
			E = { minorPoint },
			W = { minorPoint },
		}

		-- Set grid extents for minor areas
		area.gridMinX, area.gridMaxX = 0, 0
		area.gridMinY, area.gridMaxY = 0, 0

		return { minorPoint }
	end

	-- Use larger edge buffer to prevent grid points from being placed too close to walls
	local edgeBuffer = math.max(16, GRID * 0.75) -- At least 16 units or 75% of grid size
	local usableWidth = areaWidth - (2 * edgeBuffer)
	local usableHeight = areaHeight - (2 * edgeBuffer)

	-- If usable area after edge buffer is too small, treat as minor node
	if usableWidth < GRID or usableHeight < GRID then
		Log:Debug("Area %d usable space too small after edge buffer, treating as minor node", area.id)
		local minorPoint = {
			id = 1,
			gridX = 0,
			gridY = 0,
			pos = area.pos,
			neighbors = {},
			parentArea = area.id,
			ring = 0,
			isEdge = true,
			isInner = false,
			dirTags = { "N", "S", "E", "W" }, -- Minor area connects in all directions
			dirMask = Node.DIR.N | Node.DIR.S | Node.DIR.E | Node.DIR.W,
		}

		-- Create edgeSets for minor areas - single point represents all directions
		area.edgeSets = {
			N = { minorPoint },
			S = { minorPoint },
			E = { minorPoint },
			W = { minorPoint },
		}

		-- Set grid extents for minor areas
		area.gridMinX, area.gridMaxX = 0, 0
		area.gridMinY, area.gridMaxY = 0, 0

		return { minorPoint }
	end

	local gx = math.floor(usableWidth / GRID) + 1
	local gy = math.floor(usableHeight / GRID) + 1

	-- Double-check for degenerate cases
	if gx <= 0 or gy <= 0 then
		Log:Debug("Area %d grid calculation resulted in degenerate dimensions (%dx%d)", area.id, gx, gy)
		local minorPoint = {
			id = 1,
			gridX = 0,
			gridY = 0,
			pos = area.pos,
			neighbors = {},
			parentArea = area.id,
			ring = 0,
			isEdge = true,
			isInner = false,
			dirTags = { "N", "S", "E", "W" }, -- Minor area connects in all directions
			dirMask = Node.DIR.N | Node.DIR.S | Node.DIR.E | Node.DIR.W,
		}

		-- Create edgeSets for minor areas - single point represents all directions
		area.edgeSets = {
			N = { minorPoint },
			S = { minorPoint },
			E = { minorPoint },
			W = { minorPoint },
		}

		-- Set grid extents for minor areas
		area.gridMinX, area.gridMaxX = 0, 0
		area.gridMinY, area.gridMaxY = 0, 0

		return { minorPoint }
	end

	------------------------------------------------------------
	-- build raw grid
	------------------------------------------------------------
	local raw = {}
	for ix = 0, gx - 1 do
		for iy = 0, gy - 1 do
			-- Place grid points within the usable area, starting from edgeBuffer offset
			local x = area.minX + edgeBuffer + ix * GRID
			local y = area.minY + edgeBuffer + iy * GRID
			raw[#raw + 1] = {
				gridX = ix,
				gridY = iy,
				pos = Vector3(x, y, bilinearZ(x, y, area.nw, area.ne, area.se, area.sw)),
				neighbors = {},
				parentArea = area.id,
			}
		end
	end

	------------------------------------------------------------
	-- peel border IF we still have something inside afterwards
	------------------------------------------------------------
	local keepFull = (gx <= 2) or (gy <= 2)
	local points = {}
	if keepFull then
		points = raw
		Log:Debug("Area %d keeping full grid (%dx%d points) - too small to peel border", area.id, gx, gy)
	else
		for _, p in ipairs(raw) do
			if not (p.gridX == 0 or p.gridX == gx - 1 or p.gridY == 0 or p.gridY == gy - 1) then
				points[#points + 1] = p
			end
		end
		if #points == 0 then -- pathological L-shape → revert
			points, keepFull = raw, true
			Log:Debug("Area %d reverting to full grid - peeling resulted in no points", area.id)
		else
			Log:Debug("Area %d peeled border: %d -> %d points", area.id, #raw, #points)
		end
	end

	------------------------------------------------------------
	-- ring metric + edge / inner flags + directional tags
	------------------------------------------------------------
	local minGX, maxGX, minGY, maxGY = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(points) do
		minGX, maxGX = math.min(minGX, p.gridX), math.max(maxGX, p.gridX)
		minGY, maxGY = math.min(minGY, p.gridY), math.max(maxGY, p.gridY)
	end
	for i, p in ipairs(points) do
		p.id = i
		p.ring = math.min(p.gridX - minGX, maxGX - p.gridX, p.gridY - minGY, maxGY - p.gridY)
		p.isEdge = (p.ring == 0 or p.ring == 1) -- 1-st/2-nd order
		p.isInner = (p.ring >= 2)
		p.dirTags = {}
	end
	------------------------------------------------------------
	-- dirTags computed against the ring-2 rectangle
	------------------------------------------------------------
	local innerMinGX, innerMaxGX = math.huge, -math.huge
	local innerMinGY, innerMaxGY = math.huge, -math.huge
	for _, p in ipairs(points) do
		if p.isInner then
			innerMinGX, innerMaxGX = math.min(innerMinGX, p.gridX), math.max(innerMaxGX, p.gridX)
			innerMinGY, innerMaxGY = math.min(innerMinGY, p.gridY), math.max(innerMaxGY, p.gridY)
		end
	end
	for _, p in ipairs(points) do
		if innerMinGX <= innerMaxGX then
			if p.gridX < innerMinGX then
				p.dirTags[#p.dirTags + 1] = "W"
			end
			if p.gridX > innerMaxGX then
				p.dirTags[#p.dirTags + 1] = "E"
			end
			if p.gridY < innerMinGY then
				p.dirTags[#p.dirTags + 1] = "S"
			end
			if p.gridY > innerMaxGY then
				p.dirTags[#p.dirTags + 1] = "N"
			end
		end
	end

	------------------------------------------------------------
	-- NEW: build edge buckets and dirMask for fast lookups
	------------------------------------------------------------
	area.edgeSets = { N = {}, S = {}, E = {}, W = {} }
	for _, p in ipairs(points) do
		local m = 0
		if p.gridY == maxGY then
			m = m | Node.DIR.N
			area.edgeSets.N[#area.edgeSets.N + 1] = p
		end
		if p.gridY == minGY then
			m = m | Node.DIR.S
			area.edgeSets.S[#area.edgeSets.S + 1] = p
		end
		if p.gridX == maxGX then
			m = m | Node.DIR.E
			area.edgeSets.E[#area.edgeSets.E + 1] = p
		end
		if p.gridX == minGX then
			m = m | Node.DIR.W
			area.edgeSets.W[#area.edgeSets.W + 1] = p
		end
		p.dirMask = m
	end

	------------------------------------------------------------
	-- orthogonal neighbours, fallback diagonal if isolated
	------------------------------------------------------------
	local function addLink(a, b)
		local d = (a.pos - b.pos):Length()
		local cost = d

		-- Add height-based cost for smooth walking mode
		if G.Menu.Main.WalkableMode == "Smooth" then
			local heightDiff = math.abs(b.pos.z - a.pos.z)
			if heightDiff > 18 then -- Requires jump in smooth mode
				local heightPenalty = math.floor(heightDiff / 18) * 10 -- 10 cost per 18 units
				cost = cost + heightPenalty
			end
		end

		a.neighbors[#a.neighbors + 1] = { point = b, cost = cost, isInterArea = true }
		b.neighbors[#b.neighbors + 1] = { point = a, cost = cost, isInterArea = true }
	end
	local idx = {} -- quick lookup
	for _, p in ipairs(points) do
		idx[p.gridX .. "," .. p.gridY] = p
	end
	local added = 0
	for _, p in ipairs(points) do
		local n = idx[p.gridX .. "," .. (p.gridY + 1)]
		local s = idx[p.gridX .. "," .. (p.gridY - 1)]
		local e = idx[(p.gridX + 1) .. "," .. p.gridY]
		local w = idx[(p.gridX - 1) .. "," .. p.gridY]
		if n then
			addLink(p, n)
			added = added + 1
		end
		if s then
			addLink(p, s)
			added = added + 1
		end
		if e then
			addLink(p, e)
			added = added + 1
		end
		if w then
			addLink(p, w)
			added = added + 1
		end
		if #p.neighbors == 0 then -- stranded corner → diag
			local ne = idx[(p.gridX + 1) .. "," .. (p.gridY + 1)]
			local nw = idx[(p.gridX - 1) .. "," .. (p.gridY + 1)]
			local se = idx[(p.gridX + 1) .. "," .. (p.gridY - 1)]
			local sw = idx[(p.gridX - 1) .. "," .. (p.gridY - 1)]
			if ne then
				addLink(p, ne)
				added = added + 1
			end
			if nw then
				addLink(p, nw)
				added = added + 1
			end
			if se then
				addLink(p, se)
				added = added + 1
			end
			if sw then
				addLink(p, sw)
				added = added + 1
			end
		end
	end

	Log:Debug("Area %d grid %dx%d  kept %d pts  links %d", area.id, gx, gy, #points, added)

	-- Cache grid extents for edge detection (use actual grid dimensions, not area bounds)
	area.gridMinX, area.gridMaxX, area.gridMinY, area.gridMaxY = minGX, maxGX, minGY, maxGY

	return points
end

--==========================================================================
--  Area point cache helpers  (unchanged API)
--==========================================================================

--- Check if an area should be treated as a minor node (too small for grid)
---@param area table The area to check
---@return boolean True if area should be treated as minor node
function Node.IsMinorArea(area)
	if not area then
		return true
	end

	local minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	local maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	local minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
	local maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)

	local areaWidth = maxX - minX
	local areaHeight = maxY - minY

	return areaWidth < GRID or areaHeight < GRID
end

function Node.GenerateAreaPoints(id)
	local nodes = G.Navigation.nodes
	if not (nodes and nodes[id]) then
		return
	end
	local area = nodes[id]
	if area.finePoints then
		return area.finePoints
	end
	area.finePoints = generateAreaPoints(area)

	-- Log whether this area was treated as minor
	if area.finePoints and #area.finePoints == 1 then
		Log:Debug("Area %d treated as minor node (single point)", id)
	end

	return area.finePoints
end

function Node.GetAreaPoints(id)
	return Node.GenerateAreaPoints(id)
end

--==========================================================================
--  Touching-boxes helper
--==========================================================================
local function neighbourSide(a, b, eps)
	eps = eps or 1.0
	local overlapY = (a.minY <= b.maxY + eps) and (b.minY <= a.maxY + eps)
	local overlapX = (a.minX <= b.maxX + eps) and (b.minX <= a.maxX + eps)
	if overlapY and math.abs(a.maxX - b.minX) < eps then
		return "E", "W"
	end
	if overlapY and math.abs(b.maxX - a.minX) < eps then
		return "W", "E"
	end
	if overlapX and math.abs(a.maxY - b.minY) < eps then
		return "N", "S"
	end
	if overlapX and math.abs(b.maxY - a.minY) < eps then
		return "S", "N"
	end
	return nil
end

local function edgePoints(area, side)
	-- return precomputed bucket for the side
	return area.edgeSets[side] or {}
end

local function link(a, b)
	local d = (a.pos - b.pos):Length()
	local cost = d

	-- Add height-based cost for smooth walking mode
	if G.Menu.Main.WalkableMode == "Smooth" then
		local heightDiff = math.abs(b.pos.z - a.pos.z)
		if heightDiff > 18 then -- Requires jump in smooth mode
			local heightPenalty = math.floor(heightDiff / 18) * 10 -- 10 cost per 18 units
			cost = cost + heightPenalty
		end
	end

	a.neighbors[#a.neighbors + 1] = { point = b, cost = cost, isInterArea = true }
	b.neighbors[#b.neighbors + 1] = { point = a, cost = cost, isInterArea = true }
end

local function connectPair(areaA, areaB)
	-- Simple and fast stitching: each edge node connects to its 2 closest neighbors
	local sideA, sideB = neighbourSide(areaA, areaB, 5.0)
	if not sideA then
		return 0
	end

	local edgeA, edgeB = edgePoints(areaA, sideA), edgePoints(areaB, sideB)
	if #edgeA == 0 or #edgeB == 0 then
		return 0
	end

	local connectionCount = 0
	local maxDistance = 200 -- Maximum connection distance

	-- For each edge point in area A, find up to 2 closest points in area B
	for _, pointA in ipairs(edgeA) do
		local candidates = {}

		-- Find all candidates within max distance
		for _, pointB in ipairs(edgeB) do
			local distance = (pointA.pos - pointB.pos):Length()
			if distance <= maxDistance and isNodeAccessible(pointA, pointB, true) then
				table.insert(candidates, {
					point = pointB,
					distance = distance,
				})
			end
		end

		-- Sort by distance and take the 2 closest
		table.sort(candidates, function(a, b)
			return a.distance < b.distance
		end)

		-- Connect to up to 2 closest candidates
		local connectionsForThisPoint = 0
		for i = 1, math.min(2, #candidates) do
			local candidate = candidates[i]
			link(pointA, candidate.point)
			connectionCount = connectionCount + 1
			connectionsForThisPoint = connectionsForThisPoint + 1
		end

		-- Log detailed connections for debugging
		if connectionsForThisPoint > 0 then
			Log:Debug("Point in area %d connected to %d points in area %d", areaA.id, connectionsForThisPoint, areaB.id)
		end
	end

	-- For each edge point in area B, find up to 2 closest points in area A (bidirectional)
	for _, pointB in ipairs(edgeB) do
		local candidates = {}

		-- Find all candidates within max distance
		for _, pointA in ipairs(edgeA) do
			local distance = (pointB.pos - pointA.pos):Length()
			if distance <= maxDistance and isNodeAccessible(pointB, pointA, true) then
				-- Check if this connection already exists to avoid duplicates
				local alreadyConnected = false
				for _, neighbor in ipairs(pointB.neighbors) do
					if neighbor.point == pointA then
						alreadyConnected = true
						break
					end
				end

				if not alreadyConnected then
					table.insert(candidates, {
						point = pointA,
						distance = distance,
					})
				end
			end
		end

		-- Sort by distance and take the 2 closest
		table.sort(candidates, function(a, b)
			return a.distance < b.distance
		end)

		-- Connect to up to 2 closest candidates (if not already connected)
		local connectionsForThisPoint = 0
		for i = 1, math.min(2, #candidates) do
			local candidate = candidates[i]
			link(pointB, candidate.point)
			connectionCount = connectionCount + 1
			connectionsForThisPoint = connectionsForThisPoint + 1
		end
	end

	Log:Debug("Fast stitching: %d total connections between areas %d <-> %d", connectionCount, areaA.id, areaB.id)
	return connectionCount
end

--- Build hierarchical data structure for HPA* pathfinding
---@param processedAreas table Areas with their fine points and connections
local function buildHierarchicalStructure(processedAreas)
	-- Initialize hierarchical structure in globals
	if not G.Navigation.hierarchical then
		G.Navigation.hierarchical = {}
	end

	G.Navigation.hierarchical.areas = {}
	G.Navigation.hierarchical.edgePoints = {} -- Global registry of edge points for fast lookup

	local totalEdgePoints = 0
	local totalInterConnections = 0

	-- Process each area and build the hierarchical structure
	for areaId, data in pairs(processedAreas) do
		local areaInfo = {
			id = areaId,
			area = data.area,
			points = data.points,
			edgePoints = {}, -- Points on the boundary of this area
			internalPoints = {}, -- Points inside this area
			interAreaConnections = {}, -- Connections to other areas
		}
		-- Categorize points as edge or internal
		for _, point in pairs(data.points) do
			if point.isEdge then
				table.insert(areaInfo.edgePoints, point)
				-- Add to global edge point registry with area reference
				G.Navigation.hierarchical.edgePoints[point.id .. "_" .. areaId] = {
					point = point,
					areaId = areaId,
				}
				totalEdgePoints = totalEdgePoints + 1
			else
				table.insert(areaInfo.internalPoints, point)
			end

			-- Count inter-area connections
			for _, neighbor in pairs(point.neighbors) do
				if neighbor.isInterArea then
					totalInterConnections = totalInterConnections + 1
					-- Store inter-area connection info
					table.insert(areaInfo.interAreaConnections, {
						fromPoint = point,
						toPoint = neighbor.point,
						toArea = neighbor.point.parentArea,
						cost = neighbor.cost,
					})
				end
			end
		end

		G.Navigation.hierarchical.areas[areaId] = areaInfo
		Log:Debug(
			"Area %d: %d edge points, %d internal points, %d inter-area connections",
			areaId,
			#areaInfo.edgePoints,
			#areaInfo.internalPoints,
			#areaInfo.interAreaConnections
		)
	end

	Log:Info(
		"Built hierarchical structure: %d total edge points, %d inter-area connections",
		totalEdgePoints,
		totalInterConnections
	)
end

--==========================================================================
--  Multi-tick setup system to prevent game freezing
--==========================================================================
local SetupState = {
	currentPhase = 0,
	processedAreas = {},
	maxAreasPerTick = 10, -- Increased from 5 since stitching is now much faster
	totalAreas = 0,
	currentAreaIndex = 0,
	hierarchicalData = {},
}

--- Apply height penalties to all fine point connections
local function applyHeightPenaltiesToConnections(processedAreas)
	local penalizedCount = 0
	local invalidatedCount = 0

	Log:Info("Applying height penalties to fine point connections...")

	for areaId, data in pairs(processedAreas) do
		for _, point in ipairs(data.points) do
			local validNeighbors = {}

			for _, neighbor in ipairs(point.neighbors) do
				local heightDiff = neighbor.point.pos.z - point.pos.z

				if heightDiff > 72 then
					-- Invalid connection - can't jump this high
					invalidatedCount = invalidatedCount + 1
				elseif heightDiff > 18 then
					-- Apply 100 unit penalty for steep climbs
					neighbor.cost = (neighbor.cost or 1) + 100
					table.insert(validNeighbors, neighbor)
					penalizedCount = penalizedCount + 1
				else
					-- Normal connection
					table.insert(validNeighbors, neighbor)
				end
			end

			point.neighbors = validNeighbors
		end
	end

	Log:Info("Height penalties applied: %d penalized, %d invalidated", penalizedCount, invalidatedCount)
end

--- Initialize multi-tick setup
local function initializeSetup()
	SetupState.currentPhase = 1
	SetupState.processedAreas = {}
	SetupState.currentAreaIndex = 0
	SetupState.hierarchicalData = {}

	local nodes = G.Navigation.nodes
	if nodes then
		SetupState.totalAreas = 0
		for _ in pairs(nodes) do
			SetupState.totalAreas = SetupState.totalAreas + 1
		end
	end

	Log:Info("Starting multi-tick hierarchical setup: %d areas total", SetupState.totalAreas)
end

--- Process one tick of setup work
local function processSetupTick()
	if SetupState.currentPhase == 0 then
		return false -- No setup in progress
	end

	local nodes = G.Navigation.nodes
	if not nodes then
		SetupState.currentPhase = 0
		return false
	end

	if SetupState.currentPhase == 1 then
		-- Phase 1: Generate fine points (spread across multiple ticks)
		local processed = 0
		local areaIds = {}
		for id in pairs(nodes) do
			table.insert(areaIds, id)
		end

		local startIdx = SetupState.currentAreaIndex + 1
		local endIdx = math.min(startIdx + SetupState.maxAreasPerTick - 1, #areaIds)

		for i = startIdx, endIdx do
			local areaId = areaIds[i]
			local area = nodes[areaId]

			-- Generate fine points for this area (this also sets area bounds)
			local finePoints = Node.GenerateAreaPoints(areaId)

			-- Ensure the area has its bounds properly cached for neighbourSide function
			if not area.minX then
				area.minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
				area.maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
				area.minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
				area.maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)
			end

			SetupState.processedAreas[areaId] = {
				area = area,
				points = finePoints,
			}
			processed = processed + 1
		end

		SetupState.currentAreaIndex = endIdx

		Log:Debug("Phase 1: Processed %d areas (%d/%d)", processed, SetupState.currentAreaIndex, #areaIds)

		if SetupState.currentAreaIndex >= #areaIds then
			SetupState.currentPhase = 2
			SetupState.currentAreaIndex = 0
			Log:Info("Phase 1 complete: Fine points generated for all areas with proper bounds")
		end

		return true -- More work to do
	elseif SetupState.currentPhase == 2 then
		-- Phase 2: Connect fine points between adjacent areas (spread across ticks) - OPTIMIZED
		local processed = 0
		local totalConnections = 0
		local areaIds = {}
		for id in pairs(SetupState.processedAreas) do
			table.insert(areaIds, id)
		end

		local startIdx = SetupState.currentAreaIndex + 1
		local endIdx = math.min(startIdx + SetupState.maxAreasPerTick - 1, #areaIds)

		for i = startIdx, endIdx do
			local areaId = areaIds[i]
			local data = SetupState.processedAreas[areaId]
			local area = data.area

			-- Get adjacent areas and process connections more efficiently
			local adjacentAreas = Node.GetAdjacentNodesOnly(area, nodes)

			if #adjacentAreas > 0 then
				Log:Debug("Area %d processing %d adjacent areas", areaId, #adjacentAreas)
			end

			for _, adjacentArea in ipairs(adjacentAreas) do
				-- Only connect to areas with higher IDs to avoid duplicate processing
				if SetupState.processedAreas[adjacentArea.id] and adjacentArea.id > areaId then
					-- Ensure both areas have their edgeSets (only regenerate if truly missing)
					local needsRegenA = not area.edgeSets
					local needsRegenB = not adjacentArea.edgeSets

					if needsRegenA then
						Log:Debug("Regenerating edgeSets for area %d", areaId)
						Node.GenerateAreaPoints(areaId)
					end
					if needsRegenB then
						Log:Debug("Regenerating edgeSets for area %d", adjacentArea.id)
						Node.GenerateAreaPoints(adjacentArea.id)
					end

					-- Fast stitching with the new algorithm
					local connections = connectPair(area, adjacentArea)
					totalConnections = totalConnections + connections

					if connections > 0 then
						Log:Debug("Fast stitched %d connections: %d <-> %d", connections, areaId, adjacentArea.id)
					end
				end
			end
			processed = processed + 1
		end

		SetupState.currentAreaIndex = endIdx

		Log:Debug(
			"Phase 2 (Fast): Processed %d areas (%d/%d), created %d connections this batch",
			processed,
			SetupState.currentAreaIndex,
			#areaIds,
			totalConnections
		)

		if SetupState.currentAreaIndex >= #areaIds then
			SetupState.currentPhase = 3
			Log:Info("Phase 2 complete: Fast inter-area stitching finished")
		end

		return true -- More work to do
	elseif SetupState.currentPhase == 3 then
		-- Phase 3: Apply height penalties and build hierarchical structure
		applyHeightPenaltiesToConnections(SetupState.processedAreas)
		buildHierarchicalStructure(SetupState.processedAreas)

		SetupState.currentPhase = 0 -- Setup complete
		Log:Info("Multi-tick hierarchical setup complete!")
		G.Navigation.navMeshUpdated = true
		return false -- Setup finished
	end

	return false
end

--==========================================================================
--  Enhanced hierarchical network generation with multi-tick support
--==========================================================================
function Node.GenerateHierarchicalNetwork(maxAreas)
	-- Start multi-tick setup process
	initializeSetup()

	-- Register callback to process setup across multiple ticks
	callbacks.Unregister("CreateMove", "HierarchicalSetup")

	local function HierarchicalSetupTick()
		ProfilerBeginSystem("hierarchical_setup")
		-- Hierarchical stitching disabled per simplified pipeline
		callbacks.Unregister("CreateMove", "HierarchicalSetup")
		ProfilerEndSystem()
	end

	callbacks.Unregister("CreateMove", "HierarchicalSetup")
end

--==========================================================================
--  PUBLIC (everything else unchanged)
--==========================================================================

function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes and G.Navigation.nodes[id] or nil
end

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end
	local closestArea, minDist = nil, math.huge
	for _, area in pairs(G.Navigation.nodes) do
		local d = (area.pos - pos):Length()
		if d < minDist then
			minDist = d
			closestArea = area
		end
	end
	return closestArea
end

--- Manually trigger connection cleanup (useful for debugging)
function Node.CleanupConnections()
	local nodes = Node.GetNodes()
	if nodes then
		pruneInvalidConnections(nodes)
	else
		Log:Warn("No nodes loaded for cleanup")
	end
end

function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified connection adding
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			table.insert(cDir.connections, { node = nodeB.id, cost = 1, left = nil, middle = nil, right = nil })
			cDir.count = cDir.count + 1
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Updated to handle both connection formats
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, connection in pairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				if targetNodeId == nodeB.id then
					table.remove(cDir.connections, i)
					cDir.count = cDir.count - 1
					break
				end
			end
		end
	end
end

function Node.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Updated to handle both connection formats and preserve door fields
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, connection in pairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				if targetNodeId == nodeB.id then
					local base = normalizeConnectionEntry(connection)
					base.cost = cost
					cDir.connections[i] = base
					break
				end
			end
		end
	end
end

--- Add penalty to connection when pathfinding fails (adds 100 cost each failure)
---@param nodeA table First node (source)
---@param nodeB table Second node (destination)
function Node.AddFailurePenalty(nodeA, nodeB, penalty)
	penalty = penalty or 100
	if not nodeA or not nodeB then
		return
	end

	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	-- Resolve area IDs for both nodes (supports fine points)

	-- Prefer parentArea when present to avoid mixing fine point IDs with area IDs
	local function resolveAreaId(n)
		if not n then
			return nil
		end

		if n.parentArea then
			return n.parentArea
		end

		return n.id
	end

	-- Helper to apply penalty in one direction for area connections
	local function applyAreaPenalty(fromAreaId, toAreaId)
		if not (fromAreaId and toAreaId) then
			return false
		end
		for _, cDir in pairs(nodes[fromAreaId] and nodes[fromAreaId].c or {}) do
			if cDir and cDir.connections then
				for i, connection in pairs(cDir.connections) do
					local targetNodeId = getConnectionNodeId(connection)
					if targetNodeId == toAreaId then
						local currentCost = getConnectionCost(connection)
						local newCost = currentCost + penalty
						local base = normalizeConnectionEntry(connection)
						base.cost = newCost
						cDir.connections[i] = base
						Log:Debug(
							"Added failure penalty to connection %d -> %d: %.1f -> %.1f",
							fromAreaId,
							toAreaId,
							currentCost,
							newCost
						)
						return true
					end
				end
			end
		end
		return false
	end

	-- Helper to apply penalty for fine point neighbors
	local function applyFinePenalty(fromNode, toNode)
		if not fromNode.neighbors then
			return false
		end
		for _, neighbor in ipairs(fromNode.neighbors) do
			if
				neighbor.point
				and (
					neighbor.point == toNode
					or (neighbor.point.id == toNode.id and neighbor.point.parentArea == toNode.parentArea)
				)
			then
				local currentCost = neighbor.cost or 1
				local newCost = currentCost + penalty
				neighbor.cost = newCost
				Log:Debug(
					"Added fine failure penalty to point %d (area %s) -> %d (area %s): %.1f -> %.1f",
					fromNode.id or -1,
					fromNode.parentArea or "?",
					toNode.id or -1,
					toNode.parentArea or "?",
					currentCost,
					newCost
				)
				return true
			end
		end
		return false
	end

	local function applyPenalty(fromNode, toNode)
		-- First try area-level penalty
		local fromArea = resolveAreaId(fromNode)
		local toArea = resolveAreaId(toNode)
		local appliedArea = applyAreaPenalty(fromArea, toArea)

		-- Then fine-point penalty if applicable
		local appliedFine = applyFinePenalty(fromNode, toNode)

		-- Debug if no connection was updated
		if not appliedArea and not appliedFine then
			Log:Warn(
				"Skipping penalty for invalid connection: %s->%s",
				tostring(fromArea or fromNode.id),
				tostring(toArea or toNode.id)
			)
		end
	end

	-- Apply penalty both directions to discourage repeated failure
	applyPenalty(nodeA, nodeB)
	applyPenalty(nodeB, nodeA)
end

--- Get adjacent nodes with accessibility checks (expensive, for pathfinding)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of accessible adjacent nodes
--- NOTE: This function is EXPENSIVE due to accessibility checks.
--- Use GetAdjacentNodesSimple for pathfinding after setup validation is complete.
function Node.GetAdjacentNodes(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for _, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode and targetNode.pos then
					-- Use centralized accessibility check (EXPENSIVE)
					if isNodeAccessible(node, targetNode, true) then
						table.insert(adjacent, targetNode)
					end
				end
			end
		end
	end
	return adjacent
end

--- Get adjacent nodes without accessibility checks (fast, for finding connections)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of connected adjacent nodes with costs
--- NOTE: This function is FAST and should be used for pathfinding.
--- Assumes connections are already validated during setup time.
--- Returns: { {node = targetNode, cost = connectionCost}, ... }
function Node.GetAdjacentNodesSimple(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for _, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local connectionCost = getConnectionCost(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode and targetNode.pos then
					-- Return node WITH cost for direct use in pathfinding
					table.insert(adjacent, {
						node = targetNode,
						cost = connectionCost,
					})
				end
			end
		end
	end
	return adjacent
end

--- Get adjacent nodes as simple array (for backward compatibility with non-pathfinding uses)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of adjacent node objects only
function Node.GetAdjacentNodesOnly(node, nodes)
	local adjacent = {}
	local adjacentWithCost = Node.GetAdjacentNodesSimple(node, nodes)

	for _, neighborData in ipairs(adjacentWithCost) do
		table.insert(adjacent, neighborData.node)
	end

	return adjacent
end

--- Fast, zero logic - just returns whatever the nav-file says
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of adjacent node objects (raw connections)
function Node.GetAdjacentNodesRaw(node, nodes)
	local out = {}
	if not node or not node.c then
		return out
	end

	for _, dir in pairs(node.c) do
		if dir and dir.connections then
			for _, connection in pairs(dir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode then
					out[#out + 1] = targetNode
				end
			end
		end
	end
	return out
end

--- Slow but safe - uses isNodeAccessible / walkable checks
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of accessible adjacent node objects
function Node.GetAdjacentNodesClean(node, nodes)
	local out = {}
	if not node or not node.c then
		return out
	end

	for _, dir in pairs(node.c) do
		if dir and dir.connections then
			for _, connection in pairs(dir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode and isNodeAccessible(node, targetNode, true) then
					out[#out + 1] = targetNode
				end
			end
		end
	end
	return out
end

function Node.LoadFile(navFile)
	local full = "tf/" .. navFile
	local navData, err = tryLoadNavFile(full)
	if not navData and err == "File not found" then
		Log:Warn("Nav file not found, attempting to generate...")
		generateNavFile()
		navData, err = tryLoadNavFile(full)
		if not navData then
			Log:Error("Failed to load or parse generated nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		elseif not navData then
			Log:Error("Failed to load nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		end
	end

	local navNodes = processNavData(navData)
	Node.SetNodes(navNodes)
	-- Ensure all connections use enriched structure { node, cost, left, middle, right }
	Node.NormalizeConnections()
	-- Build doors and prune unreachable connections
	Node.BuildDoorsForConnections()

	-- Fix: Count nodes properly for hash table
	local nodeCount = 0
	for _ in pairs(navNodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Successfully loaded %d navigation nodes", nodeCount)

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		pruneInvalidConnections(navNodes)
	else
		Log:Info("Connection cleanup is disabled in settings")
	end

	return true
end

function Node.LoadNavFile()
	local mf = engine.GetMapName()
	if mf and mf ~= "" then
		Node.LoadFile(string.gsub(mf, ".bsp", ".nav"))
	else
		Log:Warn("No map name available for nav file loading")
		Node.SetNodes({})
	end
end

function Node.Setup()
	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Log:Info("Setting up navigation for map: %s", mapName)
		Node.LoadNavFile()
		-- Subnodes/hierarchical network removed for simplicity & maintainability
		-- Pathfinding now uses only main areas and enriched connections
	else
		Log:Info("No valid map loaded, initializing empty navigation nodes")
		-- Initialize empty nodes table to prevent crashes when no map is loaded
		Node.SetNodes({})
	end
end

--- Find the closest fine point within an area to a given position
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest point or nil if not found
function Node.GetClosestAreaPoint(areaId, position)
	local points = Node.GetAreaPoints(areaId)
	if not points then
		return nil
	end

	local closest, minDist = nil, math.huge
	for _, point in pairs(points) do
		local dist = (point.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = point
		end
	end

	return closest
end

--- Clear cached fine points for all areas (useful when settings change)
function Node.ClearAreaPoints()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	local clearedCount = 0
	for _, area in pairs(nodes) do
		if area.finePoints then
			area.finePoints = nil
			clearedCount = clearedCount + 1
		end
	end

	Log:Info("Cleared fine points cache for %d areas", clearedCount)
end

--- Get hierarchical pathfinding data (for HPA* algorithm)
---@return table|nil Hierarchical structure or nil if not available
function Node.GetHierarchicalData()
	return G.Navigation.hierarchical
end

--- Get closest edge point in an area to a given position (for HPA* pathfinding)
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest edge point or nil if not found
function Node.GetClosestEdgePoint(areaId, position)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return nil
	end

	local areaInfo = G.Navigation.hierarchical.areas[areaId]
	local closest, minDist = nil, math.huge

	for _, edgePoint in pairs(areaInfo.edgePoints) do
		local dist = (edgePoint.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = edgePoint
		end
	end

	return closest
end

--- Get all inter-area connections from a specific area (for HPA* pathfinding)
---@param areaId number The area ID
---@return table[] Array of inter-area connections
function Node.GetInterAreaConnections(areaId)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return {}
	end

	return G.Navigation.hierarchical.areas[areaId].interAreaConnections or {}
end

-- Register OnDraw callback for background connection processing
local function OnDrawConnectionProcessing()
	ProfilerBeginSystem("node_connection_draw")

	Node.ProcessConnectionsBackground()

	ProfilerEndSystem()
end

callbacks.Unregister("Draw", "Node.ConnectionProcessing")
callbacks.Register("Draw", "Node.ConnectionProcessing", OnDrawConnectionProcessing)

--- Recalculate all connection costs based on current walking mode
function Node.RecalculateConnectionCosts()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	local recalculatedCount = 0
	local smoothMode = G.Menu.Main.WalkableMode == "Smooth"

	Log:Info("Recalculating connection costs for %s walking mode", G.Menu.Main.WalkableMode)

	-- Recalculate regular node connections
	for nodeId, node in pairs(nodes) do
		if node and node.c then
			for dir, connectionDir in pairs(node.c) do
				if connectionDir and connectionDir.connections then
					for i, connection in ipairs(connectionDir.connections) do
						local targetNodeId = getConnectionNodeId(connection)
						local targetNode = nodes[targetNodeId]

						if targetNode and type(connection) == "table" then
							local baseCost = connection.cost or 1
							local heightDiff = targetNode.pos.z - node.pos.z

							-- Reset to base cost first
							local newCost = baseCost

							-- Add height penalty for smooth mode
							if smoothMode and heightDiff > 18 then
								local heightPenalty = math.floor(heightDiff / 18) * 10
								newCost = newCost + heightPenalty
							end

							connection.cost = newCost
							recalculatedCount = recalculatedCount + 1
						end
					end
				end
			end
		end
	end

	-- Recalculate inter-area fine point connections
	if G.Navigation.hierarchical and G.Navigation.hierarchical.areas then
		for areaId, areaInfo in pairs(G.Navigation.hierarchical.areas) do
			if areaInfo.points then
				for _, point in ipairs(areaInfo.points) do
					if point.neighbors then
						for _, neighbor in ipairs(point.neighbors) do
							if neighbor.point and neighbor.cost then
								local baseDist = (point.pos - neighbor.point.pos):Length()
								local heightDiff = math.abs(neighbor.point.pos.z - point.pos.z)

								-- Reset to base distance
								local newCost = baseDist

								-- Add height penalty for smooth mode
								if smoothMode and heightDiff > 18 then
									local heightPenalty = math.floor(heightDiff / 18) * 10
									newCost = newCost + heightPenalty
								end

								neighbor.cost = newCost
								recalculatedCount = recalculatedCount + 1
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Recalculated %d connection costs for %s mode", recalculatedCount, G.Menu.Main.WalkableMode)
end

return Node

end)
__bundle_register("MedBot.Utils.SourceNav", function(require, _LOADED, __bundle_register, __bundle_modules)
-- author : https://github.com/sapphyrus
-- ported to tf2 by moonverse

local unpack = table.unpack
local struct = {
    unpack = string.unpack,
    pack = string.pack
}

local struct_buffer_mt = {
    __index = {
        seek = function(self, seek_val, seek_mode)
            if seek_mode == nil or seek_mode == "CUR" then
                self.offset = self.offset + seek_val
            elseif seek_mode == "END" then
                self.offset = self.len + seek_val
            elseif seek_mode == "SET" then
                self.offset = seek_val
            end
        end,
        unpack = function(self, format_str)
            local unpacked = { struct.unpack(format_str, self.raw, self.offset) }

            if self.size_cache[format_str] == nil then
                self.size_cache[format_str] = struct.pack(format_str, unpack(unpacked)):len()
            end
            self.offset = self.offset + self.size_cache[format_str]

            return unpack(unpacked)
        end,
        unpack_vec = function(self)
            local x, y, z = self:unpack("fff")
            return {
                x = x,
                y = y,
                z = z
            }
        end
    }
}

local function struct_buffer(raw)
    return setmetatable({
        raw = raw,
        len = raw:len(),
        size_cache = {},
        offset = 1
    }, struct_buffer_mt)
end

-- cache
local navigation_mesh_cache = {}

-- use checksum so we dont have to keep the whole thing in memory
local function crc32(s, lt)
    -- return crc32 checksum of string as an integer
    -- use lookup table lt if provided or create one on the fly
    -- if lt is empty, it is initialized.
    lt = lt or {}
    local b, crc, mask
    if not lt[1] then -- setup table
        for i = 1, 256 do
            crc = i - 1
            for _ = 1, 8 do -- eight times
                mask = -(crc & 1)
                crc = (crc >> 1) ~ (0xedb88320 & mask)
            end
            lt[i] = crc
        end
    end

    -- compute the crc
    crc = 0xffffffff
    for i = 1, #s do
        b = string.byte(s, i)
        crc = (crc >> 8) ~ lt[((crc ~ b) & 0xFF) + 1]
    end
    return ~crc & 0xffffffff
end

local function parse(raw, use_cache)
    local checksum
    if use_cache == nil or use_cache then
        checksum = crc32(raw)
        if navigation_mesh_cache[checksum] ~= nil then
            return navigation_mesh_cache[checksum]
        end
    end

    local buf = struct_buffer(raw)

    local self = {}
    self.magic, self.major, self.minor, self.bspsize, self.analyzed, self.places_count = buf:unpack("IIIIbH")

    assert(self.magic == 0xFEEDFACE, "invalid magic, expected 0xFEEDFACE")
    assert(self.major == 16, "invalid major version, expected 16")

    -- place names
    self.places = {}
    for i = 1, self.places_count do
        local place = {}
        place.name_length = buf:unpack("H")

        -- read but ignore null byte
        place.name = buf:unpack(string.format("c%db", place.name_length - 1))

        self.places[i] = place
    end

    -- areas
    self.has_unnamed_areas, self.areas_count = buf:unpack("bI")
    self.areas = {}
    for i = 1, self.areas_count do
        local area = {}
        area.id, area.flags = buf:unpack("II")

        area.north_west = buf:unpack_vec()
        area.south_east = buf:unpack_vec()

        area.north_east_z, area.south_west_z = buf:unpack("ff")

        -- connections
        area.connections = {}
        for dir = 1, 4 do
            local connections_dir = {}
            connections_dir.count = buf:unpack("I")

            connections_dir.connections = {}
            for i = 1, connections_dir.count do
                local target
                target = buf:unpack("I")
                connections_dir.connections[i] = target
            end
            area.connections[dir] = connections_dir
        end

        -- hiding spots
        area.hiding_spots_count = buf:unpack("B")
        area.hiding_spots = {}
        for i = 1, area.hiding_spots_count do
            local hiding_spot = {}
            hiding_spot.id = buf:unpack("I")
            hiding_spot.location = buf:unpack_vec()
            hiding_spot.flags = buf:unpack("b")
            area.hiding_spots[i] = hiding_spot
        end

        -- encounter paths
        area.encounter_paths_count = buf:unpack("I")
        area.encounter_paths = {}
        for i = 1, area.encounter_paths_count do
            local encounter_path = {}
            encounter_path.from_id, encounter_path.from_direction, encounter_path.to_id, encounter_path.to_direction,
                encounter_path.spots_count =
            buf:unpack("IBIBB")

            encounter_path.spots = {}
            for i = 1, encounter_path.spots_count do
                encounter_path.spots[i] = {}
                encounter_path.spots[i].order_id, encounter_path.spots[i].distance = buf:unpack("IB")
            end
            area.encounter_paths[i] = encounter_path
        end

        area.place_id = buf:unpack("H")

        -- ladders
        area.ladders = {}
        for i = 1, 2 do
            area.ladders[i] = {}
            area.ladders[i].connection_count = buf:unpack("I")

            area.ladders[i].connections = {}
            for i = 1, area.ladders[i].connection_count do
                area.ladders[i].connections[i] = buf:unpack("I")
            end
        end

        area.earliest_occupy_time_first_team, area.earliest_occupy_time_second_team = buf:unpack("ff")
        area.light_intensity_north_west, area.light_intensity_north_east, area.light_intensity_south_east,
            area.light_intensity_south_west =
        buf:unpack("ffff")

        -- visible areas
        area.visible_areas = {}
        area.visible_area_count = buf:unpack("I")
        for i = 1, area.visible_area_count do
            area.visible_areas[i] = {}
            area.visible_areas[i].id, area.visible_areas[i].attributes = buf:unpack("Ib")
        end
        area.inherit_visibility_from_area_id = buf:unpack("I")

        -- NOTE: Differnet value in CSGO/TF2
        -- garbage?
        self.garbage = buf:unpack('I')

        self.areas[i] = area
    end

    -- ladders
    self.ladders_count = buf:unpack("I")
    self.ladders = {}
    for i = 1, self.ladders_count do
        local ladder = {}
        ladder.id, ladder.width = buf:unpack("If")

        ladder.top = buf:unpack_vec()
        ladder.bottom = buf:unpack_vec()

        ladder.length, ladder.direction = buf:unpack("fI")

        ladder.top_forward_area_id, ladder.top_left_area_id, ladder.top_right_area_id, ladder.top_behind_area_id =
        buf:unpack("IIII")
        ladder.bottom_area_id = buf:unpack("I")

        self.ladders[i] = ladder
    end

    if checksum ~= nil and navigation_mesh_cache[checksum] == nil then
        navigation_mesh_cache[checksum] = self
    end

    return self
end

return {
    parse = parse
}

end)
__bundle_register("MedBot.Utils.Config", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local G = require("MedBot.Utils.Globals")

local Common = require("MedBot.Common")
local json = require("MedBot.Utils.Json")
local Default_Config = require("MedBot.Utils.DefaultConfig")

-- Optional profiler support
local Profiler = nil
do
        local loaded, mod = pcall(require, "Profiler")
        if loaded then
                Profiler = mod
        end
end

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

local Config = {}

local Log = Common.Log
local Notify = Common.Notify
Log.Level = 0

local script_name = GetScriptName():match("([^/\\]+)%.lua$")
local folder_name = string.format([[Lua %s]], script_name)

--[[ Helper Functions ]]
function Config.GetFilePath()
	-- Note: filesystem.CreateDirectory() returns true only if it created a new directory,
	-- not if the directory already exists. The function succeeds in both cases, but
	-- returns different boolean values.
	local CreatedDirectory, fullPath = filesystem.CreateDirectory(folder_name)
	return fullPath .. "/config.cfg"
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
	for key, value in pairs(expectedMenu) do
		if loadedMenu[key] == nil then
			return false
		end
		if type(value) == "table" then
			local result = checkAllKeysExist(value, loadedMenu[key])
			if not result then
				return false
			end
		end
	end
	return true
end

--[[ Configuration Functions ]]
function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or Default_Config
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "w")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local serializedConfig = json.encode(cfgTable)
		file:write(serializedConfig)
		file:close()
		printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
		Common.Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
	else
		local errorMessage = "Failed to open: " .. shortFilePath
		printc(255, 0, 0, 255, errorMessage)
		Common.Notify.Simple("Error", errorMessage, 5)
	end
end

function Config.LoadCFG()
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "r")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local content = file:read("*a")
		file:close()
		local loadedCfg = json.decode(content)
		if loadedCfg and checkAllKeysExist(Default_Config, loadedCfg) and not input.IsButtonDown(KEY_LSHIFT) then
			printc(100, 183, 0, 255, "Success Loading Config: Path: " .. shortFilePath)
			Common.Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
			G.Menu = loadedCfg
		else
			local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config."
				or "Config is outdated or invalid. Resetting to default."
			printc(255, 0, 0, 255, warningMessage)
			Common.Notify.Simple("Warning", warningMessage, 5)
			Config.CreateCFG(Default_Config)
			G.Menu = Default_Config
		end
	else
		local warningMessage = "Config file not found. Creating a new config."
		printc(255, 0, 0, 255, warningMessage)
		Common.Notify.Simple("Warning", warningMessage, 5)
		Config.CreateCFG(Default_Config)
		G.Menu = Default_Config
	end

	-- Set G.Config with key settings for other modules
	G.Config = G.Config or {}
	G.Config.AutoFetch = G.Menu.Main.AutoFetch -- Pull from Menu settings
end

--load on load
Config.LoadCFG()

-- Save configuration automatically when the script unloads
local function ConfigAutoSaveOnUnload()
        ProfilerBeginSystem("config_unload")

        print("[CONFIG] Unloading script, saving configuration...")

	-- Save the current configuration state
	if G.Menu then
		Config.CreateCFG(G.Menu)
	else
		printc(255, 0, 0, 255, "[CONFIG] Warning: Unable to save config, G.Menu is nil")
        end

        ProfilerEndSystem()
end

callbacks.Register("Unload", "ConfigAutoSaveOnUnload", ConfigAutoSaveOnUnload)

return Config

end)
__bundle_register("MedBot.Modules.SmartJump", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field
---@class SmartJump
local SmartJump = {}

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")

-- Optional profiler support
local Profiler = nil
do
	local loaded, mod = pcall(require, "Profiler")
	if loaded then
		Profiler = mod
	end
end

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

local Log = Common.Log.new("SmartJump")
Log.Level = 0 -- Default log level

-- Utility wrapper to respect debug toggle
local function DebugLog(...)
	if G.Menu.SmartJump and G.Menu.SmartJump.Debug then
		Log:Debug(...)
	end
end

-- Constants
local GRAVITY = 800 -- Gravity per second squared
local JUMP_FORCE = 277 -- Initial vertical boost for a duck jump
local MAX_JUMP_HEIGHT = Vector3(0, 0, 72) -- Maximum jump height vector
local HITBOX_MIN = Vector3(-24, -24, 0)
local HITBOX_MAX = Vector3(24, 24, 82) -- Default hitbox (standing)
local MAX_WALKABLE_ANGLE = 45 -- Maximum angle considered walkable

-- State Definitions (matching user's exact logic)
local STATE_IDLE = "STATE_IDLE"
local STATE_PREPARE_JUMP = "STATE_PREPARE_JUMP"
local STATE_CTAP = "STATE_CTAP"
local STATE_ASCENDING = "STATE_ASCENDING"
local STATE_DESCENDING = "STATE_DESCENDING"

-- Initialize SmartJump's own menu settings and state
if not G.Menu.SmartJump then
	G.Menu.SmartJump = {}
end
if G.Menu.SmartJump.Enable == nil then
	G.Menu.SmartJump.Enable = true -- Default to enabled
end
if G.Menu.SmartJump.Debug == nil then
	G.Menu.SmartJump.Debug = false -- Disable debug logs by default
end

-- Initialize jump state
if not G.SmartJump then
	G.SmartJump = {}
end
if not G.SmartJump.jumpState then
	G.SmartJump.jumpState = STATE_IDLE
end

-- Initialize visual debug variables
G.SmartJump.PredPos = Vector3(0, 0, 0)
G.SmartJump.JumpPeekPos = Vector3(0, 0, 0)
G.SmartJump.lastAngle = nil

-- Function to normalize a vector
local function NormalizeVector(vector)
	local length = vector:Length()
	if length == 0 then
		return vector
	end
	return Vector3(vector.x / length, vector.y / length, vector.z / length)
end

-- Rotate vector by yaw angle
local function RotateVectorByYaw(vector, yaw)
	local rad = math.rad(yaw)
	local cos, sin = math.cos(rad), math.sin(rad)
	return Vector3(cos * vector.x - sin * vector.y, sin * vector.x + cos * vector.y, vector.z)
end

-- Function to check if surface is walkable
local function isSurfaceWalkable(normal)
	local vUp = Vector3(0, 0, 1)
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	return angle < MAX_WALKABLE_ANGLE
end

-- Helper function to check if the player is on the ground
local function isPlayerOnGround(player)
	local pFlags = player:GetPropInt("m_fFlags")
	return (pFlags & FL_ONGROUND) == FL_ONGROUND
end

-- Helper function to check if the player is ducking
local function isPlayerDucking(player)
	return (player:GetPropInt("m_fFlags") & FL_DUCKING) == FL_DUCKING
end

-- Calculate strafe angle (matching user's logic)
local function CalcStrafe(player)
	if not player then
		return 0
	end

	local angle = player:EstimateAbsVelocity():Angles()
	local delta = 0
	if G.SmartJump.lastAngle then
		delta = angle.y - G.SmartJump.lastAngle
		delta = Common.Math.NormalizeAngle(delta)
	end
	G.SmartJump.lastAngle = angle.y
	return delta
end

-- Function to calculate the jump peak (user's exact logic)
local function GetJumpPeak(horizontalVelocityVector, startPos)
	-- Calculate the time to reach the jump peak
	local timeToPeak = JUMP_FORCE / GRAVITY

	-- Calculate horizontal velocity length
	local horizontalVelocity = horizontalVelocityVector:Length()

	-- Calculate distance traveled horizontally during time to peak
	local distanceTravelled = horizontalVelocity * timeToPeak

	-- Calculate peak position vector
	local peakPosVector = startPos + NormalizeVector(horizontalVelocityVector) * distanceTravelled

	-- Calculate direction to peak position
	local directionToPeak = NormalizeVector(peakPosVector - startPos)

	return peakPosVector, directionToPeak
end

-- Smart velocity calculation (user's exact logic + bot movement support)
local function SmartVelocity(cmd, pLocal)
	if not pLocal then
		return Vector3(0, 0, 0)
	end

	-- Calculate the player's movement direction
	local moveDir = Vector3(cmd.forwardmove, -cmd.sidemove, 0)

	-- If the bot is moving and there's no manual input, use the bot's movement direction
	if moveDir:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		-- Convert bot's world movement direction to local movement commands
		local viewAngles = engine.GetViewAngles()
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()

		-- Project bot movement direction onto view forward/right vectors
		local forwardComponent = G.BotMovementDirection:Dot(forward)
		local rightComponent = G.BotMovementDirection:Dot(right)

		-- Create movement vector in command space (note: sidemove is negated in the original code)
		moveDir = Vector3(forwardComponent * 450, -rightComponent * 450, 0) -- 450 is typical max speed
		DebugLog("SmartJump: Using bot movement direction (%.1f, %.1f)", forwardComponent, rightComponent)
	end

	local viewAngles = engine.GetViewAngles()
	local rotatedMoveDir = RotateVectorByYaw(moveDir, viewAngles.yaw)
	local normalizedMoveDir = NormalizeVector(rotatedMoveDir)
	local vel = pLocal:EstimateAbsVelocity()

	-- Normalize moveDir if its length isn't 0, then ensure velocity matches the intended movement direction
	if moveDir:Length() > 0 then
		local onGround = isPlayerOnGround(pLocal)
		if onGround then
			-- Calculate the intended speed based on input magnitude
			local intendedSpeed = math.max(1, vel:Length()) -- Ensure the speed is at least 1
			-- Adjust the player's velocity to match the intended direction and speed
			vel = normalizedMoveDir * intendedSpeed
		end
	else
		-- If there's no input, return zero velocity
		vel = Vector3(0, 0, 0)
	end
	return vel
end

-- Smart jump detection logic (user's exact logic)
local function SmartJumpDetection(cmd, pLocal)
	if not pLocal then
		return false
	end

	-- Gather input and player data
	local pLocalPos = pLocal:GetAbsOrigin()
	local velVec = SmartVelocity(cmd, pLocal)
	local horizontalVel = velVec:Length()
	if horizontalVel <= 1 then
		return false -- no meaningful movement
	end
	local horizontalDir = NormalizeVector(velVec)
	local onGround = isPlayerOnGround(pLocal)
	if not onGround then
		return false
	end

	-- Adjust hitbox based on ducking state
	local ducking = isPlayerDucking(pLocal)
	local hitboxMax = ducking and Vector3(23.99, 23.99, 62) or HITBOX_MAX

	-- First pass: detect obstacle using full jump range
	local peakTime = JUMP_FORCE / GRAVITY
	local peakDist = horizontalVel * peakTime
	local peakPos = pLocalPos + horizontalDir * peakDist
	local trace1 = engine.TraceHull(pLocalPos, peakPos, HITBOX_MIN, hitboxMax, MASK_PLAYERSOLID_BRUSHONLY)
	if trace1.fraction >= 1 then
		return false -- no obstacle to jump
	end

	-- Measure obstacle height
	local obstaclePoint = trace1.endpos
	local obstacleHeight = obstaclePoint.z - pLocalPos.z

	-- Compute time to reach obstacle height (ascending)
	local V0 = JUMP_FORCE
	local disc = V0 * V0 - 2 * GRAVITY * obstacleHeight
	if disc <= 0 then
		return false -- obstacle too high to reach
	end
	local timeToHeight = (V0 - math.sqrt(disc)) / GRAVITY

	-- Calculate minimal horizontal distance to jump ahead
	local neededDist = horizontalVel * timeToHeight
	local refinedPeek = pLocalPos + horizontalDir * neededDist
	G.SmartJump.JumpPeekPos = refinedPeek

	-- Second pass: prepare jump clearance
	local startUp = obstaclePoint + MAX_JUMP_HEIGHT
	local forwardPoint = startUp + horizontalDir * 1
	local forwardTrace = engine.TraceHull(startUp, forwardPoint, HITBOX_MIN, hitboxMax, MASK_PLAYERSOLID_BRUSHONLY)
	G.SmartJump.JumpPeekPos = forwardTrace.endpos

	-- Trace down to check landing
	local traceDown = engine.TraceHull(
		G.SmartJump.JumpPeekPos,
		G.SmartJump.JumpPeekPos - MAX_JUMP_HEIGHT,
		HITBOX_MIN,
		hitboxMax,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	G.SmartJump.JumpPeekPos = traceDown.endpos

	if traceDown.fraction > 0 and traceDown.fraction < 0.75 then
		local normal = traceDown.plane
		if isSurfaceWalkable(normal) then
			return true
		end
	end
	return false
end

-- Main SmartJump execution with state machine (user's exact logic with improvements)
function SmartJump.Main(cmd)
	local pLocal = entities.GetLocalPlayer()

	if not pLocal or not pLocal:IsAlive() then
		-- Reset state when player is invalid
		G.SmartJump.jumpState = STATE_IDLE
		G.ShouldJump = false
		G.ObstacleDetected = false
		G.RequestEmergencyJump = false
		return false
	end

	-- Check SmartJump's own enable setting
	if not G.Menu.SmartJump.Enable then
		G.SmartJump.jumpState = STATE_IDLE
		G.ShouldJump = false
		G.ObstacleDetected = false
		G.RequestEmergencyJump = false
		return false
	end

	-- Cache player state
	local onGround = isPlayerOnGround(pLocal)
	local ducking = isPlayerDucking(pLocal)
	local viewOffset = pLocal:GetPropVector("m_vecViewOffset[0]").z

	-- Initialize jump cooldown if not set
	if not G.SmartJump.lastJumpTime then
		G.SmartJump.lastJumpTime = 0
	end

	-- Add cooldown to prevent spam jumping (30 ticks = 0.5 seconds)
	local currentTick = globals.TickCount()
	local jumpCooldown = currentTick - G.SmartJump.lastJumpTime < 30

	-- Handle emergency jump request from stuck detection
	local shouldJump = false
	if G.RequestEmergencyJump and not jumpCooldown then
		shouldJump = true
		G.RequestEmergencyJump = false
		G.LastSmartJumpAttempt = globals.TickCount()
		G.SmartJump.jumpState = STATE_PREPARE_JUMP
		G.SmartJump.lastJumpTime = currentTick
		Log:Info("SmartJump: Processing emergency jump request")
	end

	-- Get bot movement intent for better detection
	local hasMovementIntent = false
	local moveDir = Vector3(cmd.forwardmove, -cmd.sidemove, 0)

	-- Check if bot is actually trying to move
	if moveDir:Length() > 0 or (G.BotIsMoving and G.BotMovementDirection and G.BotMovementDirection:Length() > 0) then
		hasMovementIntent = true
	end

	-- FIXED: Much more conservative edge case detection
	-- Only trigger if ALL conditions are met:
	-- 1. Player is on ground and actually ducking (not just low viewOffset)
	-- 2. Has movement intent (trying to walk somewhere)
	-- 3. Not in jump cooldown
	-- 4. Not already in a jump state
	-- 5. Actually detects an obstacle ahead
	if onGround and ducking and hasMovementIntent and not jumpCooldown and G.SmartJump.jumpState == STATE_IDLE then
		-- Only trigger if SmartJumpDetection actually finds an obstacle
		local obstacleDetected = SmartJumpDetection(cmd, pLocal)
		if obstacleDetected then
			G.SmartJump.jumpState = STATE_PREPARE_JUMP
			G.SmartJump.lastJumpTime = currentTick
			DebugLog("SmartJump: Crouched movement with obstacle detected, initiating jump")
		else
			-- If no obstacle detected while crouched, just stay idle
			DebugLog("SmartJump: Crouched movement but no obstacle detected, staying idle")
		end
	end

	-- State machine for CTAP and jumping (user's exact logic)
	if G.SmartJump.jumpState == STATE_IDLE then
		-- STATE_IDLE: Waiting for jump commands
		-- Only check for smart jump if we have movement intent and no cooldown
		if onGround and hasMovementIntent and not jumpCooldown then
			local smartJumpDetected = SmartJumpDetection(cmd, pLocal)

			if smartJumpDetected or shouldJump then
				G.SmartJump.jumpState = STATE_PREPARE_JUMP
				G.SmartJump.lastJumpTime = currentTick
				DebugLog("SmartJump: IDLE -> PREPARE_JUMP (obstacle detected)")
			end
		end
	elseif G.SmartJump.jumpState == STATE_PREPARE_JUMP then
		-- STATE_PREPARE_JUMP: Start crouching
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
		G.SmartJump.jumpState = STATE_CTAP
		DebugLog("SmartJump: PREPARE_JUMP -> CTAP (ducking)")
		return true
	elseif G.SmartJump.jumpState == STATE_CTAP then
		-- STATE_CTAP: Uncrouch and jump
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		cmd:SetButtons(cmd.buttons | IN_JUMP)
		G.SmartJump.jumpState = STATE_ASCENDING
		DebugLog("SmartJump: CTAP -> ASCENDING (unduck + jump)")
		return true
	elseif G.SmartJump.jumpState == STATE_ASCENDING then
		-- STATE_ASCENDING: Player is moving upwards
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		local velocity = pLocal:EstimateAbsVelocity()
		if velocity.z <= 0 then
			G.SmartJump.jumpState = STATE_DESCENDING
			DebugLog("SmartJump: ASCENDING -> DESCENDING (velocity.z <= 0)")
		end
		return true
	elseif G.SmartJump.jumpState == STATE_DESCENDING then
		-- STATE_DESCENDING: Player is falling down
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)

		-- Use prediction for bhop detection, but only if we have movement intent
		if hasMovementIntent then
			local WLocal = Common.WPlayer.GetLocal()
			if WLocal then
				local strafeAngle = CalcStrafe(pLocal)
				local predData = Common.TF2.Prediction.Player(WLocal, 1, strafeAngle, nil)
				if predData then
					G.SmartJump.PredPos = predData.pos[1]

					if not predData.onGround[1] and not onGround then
						-- Only bhop if there's still an obstacle and not in cooldown
						if not jumpCooldown then
							local bhopJump = SmartJumpDetection(cmd, pLocal)
							if bhopJump then
								cmd:SetButtons(cmd.buttons & ~IN_DUCK)
								cmd:SetButtons(cmd.buttons | IN_JUMP)
								G.SmartJump.jumpState = STATE_PREPARE_JUMP
								G.SmartJump.lastJumpTime = currentTick
								DebugLog("SmartJump: DESCENDING -> PREPARE_JUMP (bhop with obstacle)")
								return true
							end
						end
					else
						-- Landed safely, return to idle
						G.SmartJump.jumpState = STATE_IDLE
						DebugLog("SmartJump: DESCENDING -> IDLE (landed)")
					end
				end
			else
				-- Fallback without prediction
				if onGround then
					G.SmartJump.jumpState = STATE_IDLE
					DebugLog("SmartJump: DESCENDING -> IDLE (fallback - landed)")
				end
			end
		else
			-- No movement intent, land and return to idle
			if onGround then
				G.SmartJump.jumpState = STATE_IDLE
				DebugLog("SmartJump: DESCENDING -> IDLE (no movement intent)")
			end
		end
		return true
	end

	-- Safety timeout to prevent getting stuck in any state
	if not G.SmartJump.stateStartTime then
		G.SmartJump.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - G.SmartJump.stateStartTime > 132 then -- 2 seconds timeout
		Log:Warn("SmartJump: State timeout, resetting to IDLE from %s", G.SmartJump.jumpState)
		G.SmartJump.jumpState = STATE_IDLE
		G.SmartJump.stateStartTime = nil
	end

	-- Reset state timer when state changes
	local currentState = G.SmartJump.jumpState
	if G.SmartJump.lastState ~= currentState then
		G.SmartJump.stateStartTime = globals.TickCount()
		G.SmartJump.lastState = currentState
	end

	G.ShouldJump = shouldJump
	return shouldJump
end

-- Simplified version that matches Movement.lua usage pattern
function SmartJump.Execute(cmd)
	return SmartJump.Main(cmd)
end

-- Check if emergency jump should be performed
function SmartJump.ShouldEmergencyJump(currentTick, stuckTicks)
	local timeSinceLastSmartJump = currentTick - (G.LastSmartJumpAttempt or 0)
	local timeSinceLastEmergencyJump = currentTick - (G.LastEmergencyJump or 0)

	local shouldEmergency = stuckTicks > 132
		and timeSinceLastSmartJump > 200
		and timeSinceLastEmergencyJump > 300
		and G.ObstacleDetected

	if shouldEmergency then
		G.LastEmergencyJump = currentTick
		Log:Info("Emergency jump triggered - stuck for %d ticks", stuckTicks)
	end

	return shouldEmergency
end

-- Export the GetJumpPeak function for debugging/visualization
SmartJump.GetJumpPeak = GetJumpPeak

-- Standalone CreateMove callback for SmartJump (works independently of MedBot)
local function OnCreateMoveStandalone(cmd)
	ProfilerBeginSystem("smartjump_move")

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		ProfilerEndSystem()
		return
	end

	if not G.Menu.SmartJump.Enable then
		ProfilerEndSystem()
		return
	end

	-- Run SmartJump state machine
	SmartJump.Main(cmd)

	-- Note: The state machine handles all button inputs directly in SmartJump.Main()
	-- No need to apply additional jump commands here

	ProfilerEndSystem()
end

-- Visual debugging (matching user's exact visual logic)
local function OnDrawSmartJump()
	ProfilerBeginSystem("smartjump_draw")

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not G.Menu.SmartJump.Enable then
		ProfilerEndSystem()
		return
	end

	-- Draw prediction position (red square)
	local screenPos = client.WorldToScreen(G.SmartJump.PredPos)
	if screenPos then
		draw.Color(255, 0, 0, 255)
		draw.FilledRect(screenPos[1] - 5, screenPos[2] - 5, screenPos[1] + 5, screenPos[2] + 5)
	end

	-- Draw jump peek position (green square)
	local screenpeekpos = client.WorldToScreen(G.SmartJump.JumpPeekPos)
	if screenpeekpos then
		draw.Color(0, 255, 0, 255)
		draw.FilledRect(screenpeekpos[1] - 5, screenpeekpos[2] - 5, screenpeekpos[1] + 5, screenpeekpos[2] + 5)
	end

	-- Draw 3D hitbox at jump peek position
	local minPoint = HITBOX_MIN + G.SmartJump.JumpPeekPos
	local maxPoint = HITBOX_MAX + G.SmartJump.JumpPeekPos

	local vertices = {
		Vector3(minPoint.x, minPoint.y, minPoint.z), -- Bottom-back-left
		Vector3(minPoint.x, maxPoint.y, minPoint.z), -- Bottom-front-left
		Vector3(maxPoint.x, maxPoint.y, minPoint.z), -- Bottom-front-right
		Vector3(maxPoint.x, minPoint.y, minPoint.z), -- Bottom-back-right
		Vector3(minPoint.x, minPoint.y, maxPoint.z), -- Top-back-left
		Vector3(minPoint.x, maxPoint.y, maxPoint.z), -- Top-front-left
		Vector3(maxPoint.x, maxPoint.y, maxPoint.z), -- Top-front-right
		Vector3(maxPoint.x, minPoint.y, maxPoint.z), -- Top-back-right
	}

	-- Convert 3D coordinates to 2D screen coordinates
	for i, vertex in ipairs(vertices) do
		vertices[i] = client.WorldToScreen(vertex)
	end

	-- Draw lines between vertices to visualize the box
	if
		vertices[1]
		and vertices[2]
		and vertices[3]
		and vertices[4]
		and vertices[5]
		and vertices[6]
		and vertices[7]
		and vertices[8]
	then
		draw.Color(0, 255, 255, 255) -- Cyan color for hitbox

		-- Draw front face
		draw.Line(vertices[1][1], vertices[1][2], vertices[2][1], vertices[2][2])
		draw.Line(vertices[2][1], vertices[2][2], vertices[3][1], vertices[3][2])
		draw.Line(vertices[3][1], vertices[3][2], vertices[4][1], vertices[4][2])
		draw.Line(vertices[4][1], vertices[4][2], vertices[1][1], vertices[1][2])

		-- Draw back face
		draw.Line(vertices[5][1], vertices[5][2], vertices[6][1], vertices[6][2])
		draw.Line(vertices[6][1], vertices[6][2], vertices[7][1], vertices[7][2])
		draw.Line(vertices[7][1], vertices[7][2], vertices[8][1], vertices[8][2])
		draw.Line(vertices[8][1], vertices[8][2], vertices[5][1], vertices[5][2])

		-- Draw connecting lines
		draw.Line(vertices[1][1], vertices[1][2], vertices[5][1], vertices[5][2])
		draw.Line(vertices[2][1], vertices[2][2], vertices[6][1], vertices[6][2])
		draw.Line(vertices[3][1], vertices[3][2], vertices[7][1], vertices[7][2])
		draw.Line(vertices[4][1], vertices[4][2], vertices[8][1], vertices[8][2])
	end

	-- Draw current state info
	draw.Color(255, 255, 255, 255)
	draw.Text(10, 100, "SmartJump State: " .. (G.SmartJump.jumpState or "UNKNOWN"))

	ProfilerEndSystem()
end

-- Register callbacks
callbacks.Unregister("CreateMove", "SmartJump.Standalone")
callbacks.Register("CreateMove", "SmartJump.Standalone", OnCreateMoveStandalone)

callbacks.Unregister("Draw", "SmartJump.Visual")
callbacks.Register("Draw", "SmartJump.Visual", OnDrawSmartJump)

return SmartJump

end)
__bundle_register("MedBot.WorkManager", function(require, _LOADED, __bundle_register, __bundle_modules)
local WorkManager = {}
WorkManager.works = {}
WorkManager.sortedIdentifiers = {}
WorkManager.workLimit = 1
WorkManager.executedWorks = 0

local function getCurrentTick()
	return globals.TickCount()
end

--- Adds work to the WorkManager and executes it if possible
--- @param func function The function to be executed
--- @param args table The arguments to pass to the function
--- @param delay number The delay (in ticks) before the function should be executed
--- @param identifier string A unique identifier for the work
function WorkManager.addWork(func, args, delay, identifier)
	local currentTime = getCurrentTick()
	args = args or {}

	-- Check if the work already exists
	if WorkManager.works[identifier] then
		-- Update existing work details (function, delay, args)
		WorkManager.works[identifier].func = func
		WorkManager.works[identifier].delay = delay or 1
		WorkManager.works[identifier].args = args
		WorkManager.works[identifier].wasExecuted = false
	else
		-- Add new work
		WorkManager.works[identifier] = {
			func = func,
			delay = delay,
			args = args,
			lastExecuted = currentTime,
			wasExecuted = false,
			result = nil,
		}
		-- Insert identifier and sort works based on their delay, in descending order
		table.insert(WorkManager.sortedIdentifiers, identifier)
		table.sort(WorkManager.sortedIdentifiers, function(a, b)
			return WorkManager.works[a].delay > WorkManager.works[b].delay
		end)
	end

	-- Attempt to execute the work immediately if within the work limit
	if WorkManager.executedWorks < WorkManager.workLimit then
		local entry = WorkManager.works[identifier]
		if not entry.wasExecuted and currentTime - entry.lastExecuted >= entry.delay then
			-- Execute the work
			entry.result = { func(table.unpack(args)) }
			entry.wasExecuted = true
			entry.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1
			return table.unpack(entry.result)
		end
	end

	-- Return cached result if the work cannot be executed immediately
	local entry = WorkManager.works[identifier]
	return table.unpack(entry.result or {})
end

--- Attempts to execute work if conditions are met
--- @param delay number The delay (in ticks) before the function should be executed again
--- @param identifier string A unique identifier for the work
--- @return boolean Whether the work was executed
function WorkManager.attemptWork(delay, identifier)
	local currentTime = getCurrentTick()

	-- Check if the work already exists and was executed recently
	if WorkManager.works[identifier] and currentTime - WorkManager.works[identifier].lastExecuted < delay then
		return false
	end

	-- If the work does not exist or the delay has passed, create/update the work entry
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = delay,
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime
	end

	return true
end

--- Processes the works based on their priority
function WorkManager.processWorks()
	local currentTime = getCurrentTick()
	WorkManager.executedWorks = 0

	for _, identifier in ipairs(WorkManager.sortedIdentifiers) do
		local work = WorkManager.works[identifier]
		if not work.wasExecuted and currentTime - work.lastExecuted >= work.delay then
			-- Execute the work
			work.result = { work.func(table.unpack(work.args)) }
			work.wasExecuted = true
			work.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1

			-- Stop if the work limit is reached
			if WorkManager.executedWorks >= WorkManager.workLimit then
				break
			end
		end
	end
end

return WorkManager

end)
__bundle_register("MedBot.Navigation", function(require, _LOADED, __bundle_register, __bundle_modules)
---@alias ConnectionObj { node: integer, cost: number, left: Vector3|nil, middle: Vector3|nil, right: Vector3|nil }
---@alias ConnectionDir { count: integer, connections: ConnectionObj[] }
---@alias Node { pos: Vector3, id: integer, c: { [1]: ConnectionDir, [2]: ConnectionDir, [3]: ConnectionDir, [4]: ConnectionDir } }
---@class Pathfinding
---@field pathFound boolean
---@field pathFailed boolean

--[[
PERFORMANCE OPTIMIZATION STRATEGY:
- Heavy validation (accessibility checks) happens at setup time via pruneInvalidConnections()
- Pathfinding uses Node.GetAdjacentNodesSimple() for speed (no expensive trace checks)
- Invalid connections are removed during setup, so pathfinding can trust remaining connections
- This moves computational load to beginning rather than during gameplay
]]

local Navigation = {}

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Node = require("MedBot.Modules.Node")
local Visuals = require("MedBot.Visuals")
local AStar = require("MedBot.Utils.A-Star")
local Lib = Common.Lib
local Log = Lib.Utils.Logger.new("MedBot")
Log.Level = 0

-- Constants
local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local DROP_HEIGHT = 144 -- Define your constants outside the function
local Jump_Height = 72 --duck jump height
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable
local GRAVITY = 800 -- Gravity in units per second squared
local MIN_STEP_SIZE = 5 -- Minimum step size in units
local preferredSteps = 10 --prefered number oif steps for simulations
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local TICK_RATE = 66

local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)

-- Add a connection between two nodes
function Navigation.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end
	Node.AddConnection(nodeA, nodeB)
	Node.AddConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end
	Node.RemoveConnection(nodeA, nodeB)
	Node.RemoveConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	-- Use Node module's implementation to avoid duplication
	Node.AddCostToConnection(nodeA, nodeB, cost)
end

--[[
-- Perform a trace hull down from the given position to the ground
---@param position Vector3 The start position of the trace
---@param hullSize table The size of the hull
---@return Vector3 The normal of the ground at that point
local function traceHullDown(position, hullSize)
	local endPos = position - Vector3(0, 0, DROP_HEIGHT) -- Adjust the distance as needed
	local traceResult = engine.TraceHull(position, endPos, hullSize.min, hullSize.max, MASK_PLAYERSOLID_BRUSHONLY)
	return traceResult.plane -- Directly using the plane as the normal
end

-- Perform a trace line down from the given position to the ground
---@param position Vector3 The start position of the trace
---@return Vector3 The hit position
local function traceLineDown(position)
	local endPos = position - Vector3(0, 0, DROP_HEIGHT)
	local traceResult = engine.TraceLine(position, endPos, TRACE_MASK)
	return traceResult.endpos
end

-- Calculate the remaining two corners based on the adjusted corners and ground normal
---@param corner1 Vector3 The first adjusted corner
---@param corner2 Vector3 The second adjusted corner
---@param normal Vector3 The ground normal
---@param height number The height of the rectangle
---@return table The remaining two corners
local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()

	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)

	local function rotateAroundNormal(vector, angle)
		local cosTheta = math.cos(angle)
		local sinTheta = math.sin(angle)
		return Vector3(
			(cosTheta + (1 - cosTheta) * normal.x ^ 2) * vector.x
				+ ((1 - cosTheta) * normal.x * normal.y - normal.z * sinTheta) * vector.y
				+ ((1 - cosTheta) * normal.x * normal.z + normal.y * sinTheta) * vector.z,
			((1 - cosTheta) * normal.x * normal.y + normal.z * sinTheta) * vector.x
				+ (cosTheta + (1 - cosTheta) * normal.y ^ 2) * vector.y
				+ ((1 - cosTheta) * normal.y * normal.z - normal.x * sinTheta) * vector.z,
			((1 - cosTheta) * normal.x * normal.z - normal.y * sinTheta) * vector.x
				+ ((1 - cosTheta) * normal.y * normal.z + normal.x * sinTheta) * vector.y
				+ (cosTheta + (1 - cosTheta) * normal.z ^ 2) * vector.z
		)
	end

	local rotatedHeightVector = rotateAroundNormal(heightVector, math.pi / 2)

	local corner3 = corner1 + rotatedHeightVector * (height / widthLength)
	local corner4 = corner2 + rotatedHeightVector * (height / widthLength)

	return { corner3, corner4 }
end

-- Fixes a node by adjusting its height based on TraceHull and TraceLine results
-- Moves the node 18 units up and traces down to find a new valid position
---@param nodeId integer The index of the node in the Nodes table
---@return Node The fixed node
function Navigation.FixNode(nodeId)
	local nodes = G.Navigation.nodes
	local node = nodes[nodeId]
	if not node or not node.pos then
		print("Invalid node " .. tostring(nodeId) .. ", skipping FixNode")
		return nil
	end
	if node.fixed then
		return node
	end

	local upVector = Vector3(0, 0, 72)
	local downVector = Vector3(0, 0, -72)
	-- Fix center position
	local traceCenter = engine.TraceHull(node.pos + upVector, node.pos + downVector, HULL_MIN, HULL_MAX, TRACE_MASK)
	if traceCenter and traceCenter.fraction > 0 then
		node.pos = traceCenter.endpos
		node.z = traceCenter.endpos.z
	else
		node.pos = node.pos + upVector
		node.z = node.z + 72
	end
	-- Fix two known corners (nw, se) via line traces
	for _, cornerKey in ipairs({ "nw", "se" }) do
		local c = node[cornerKey]
		if c then
			local world = Vector3(c.x, c.y, c.z)
			local trace = engine.TraceLine(world + upVector, world + downVector, TRACE_MASK)
			if trace and trace.fraction < 1 then
				node[cornerKey] = trace.endpos
			else
				node[cornerKey] = world + upVector
			end
		end
	end
	-- Compute remaining corners
	local normal = getGroundNormal(node.pos)
	local height = math.abs(node.se.z - node.nw.z)
	local rem = calculateRemainingCorners(node.nw, node.se, normal, height)
	node.ne = rem[1]
	node.sw = rem[2]
	node.fixed = true
	return node
end

-- Adjust all nodes by fixing their positions and adding missing corners.
function Navigation.FixAllNodes()
	local nodes = Navigation.GetNodes()
	for id in pairs(nodes) do
		Navigation.FixNode(id)
	end
end
]]

function Navigation.Setup()
	if engine.GetMapName() then
		Node.Setup()
		if Visuals and Visuals.BuildGrid then
			Visuals.BuildGrid()
		end
		Navigation.ClearPath()
	end
end

-- Get the current path
---@return Node[]|nil
function Navigation.GetCurrentPath()
	return G.Navigation.path
end

-- Clear the current path
function Navigation.ClearPath()
	G.Navigation.path = {}
	G.Navigation.currentNodeIndex = 1
	-- Also clear door/center/goal waypoints to avoid stale movement/visuals
	G.Navigation.waypoints = {}
	G.Navigation.currentWaypointIndex = 1
end

-- Set the current path
---@param path Node[]
function Navigation.SetCurrentPath(path)
	if not path then
		Log:Error("Failed to set path, it's nil")
		return
	end
	G.Navigation.path = path
	-- Use weak values to avoid strong retention of node objects (nodes table holds strong refs)
	pcall(setmetatable, G.Navigation.path, { __mode = "v" })
	G.Navigation.currentNodeIndex = 1 -- Start from the first node (start) and work towards goal
	-- Build door-aware waypoint list for precise movement and visuals
	--ProfilerBegin and ProfilerEnd are not available here, so rely on caller's profiling
	Navigation.BuildDoorWaypointsFromPath()
end

-- Remove the current node from the path (we've reached it)
function Navigation.RemoveCurrentNode()
	G.Navigation.currentNodeTicks = 0
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Remove the first node (current node we just reached)
		table.remove(G.Navigation.path, 1)
		-- currentNodeIndex stays at 1 since we always target the first node in the remaining path
		G.Navigation.currentNodeIndex = 1
		-- Rebuild door waypoints to reflect new leading edge
		Navigation.BuildDoorWaypointsFromPath()
	end
end

-- Function to increment the current node ticks
function Navigation.increment_ticks()
	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
end

-- Function to increment the current node ticks
function Navigation.ResetTickTimer()
	G.Navigation.currentNodeTicks = 0
end

-- Build waypoints: for each edge A->B, add the door target then B center
function Navigation.BuildDoorWaypointsFromPath()
	-- reuse existing table to avoid churn
	if not G.Navigation.waypoints then
		G.Navigation.waypoints = {}
	else
		for i = #G.Navigation.waypoints, 1, -1 do
			G.Navigation.waypoints[i] = nil
		end
	end
	G.Navigation.currentWaypointIndex = 1
	local path = G.Navigation.path
	if not path or #path == 0 then
		return
	end
	for i = 1, #path - 1 do
		local a, b = path[i], path[i + 1]
		if a and b and a.pos and b.pos then
			-- Collect all available door points for this edge
			local entry = Node.GetConnectionEntry(a, b)
			if entry and (entry.left or entry.middle or entry.right) then
				local points = {}
				if entry.left then
					table.insert(points, entry.left)
				end
				if entry.middle then
					table.insert(points, entry.middle)
				end
				if entry.right then
					table.insert(points, entry.right)
				end
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = a.id,
					toId = b.id,
					points = points,
					dir = entry.dir,
				})
			else
				-- Fallback: use Node helper for a single door target
				local single = Node.GetDoorTargetPoint(a, b)
				if single then
					table.insert(
						G.Navigation.waypoints,
						{ kind = "door", fromId = a.id, toId = b.id, points = { single } }
					)
				end
			end
			table.insert(G.Navigation.waypoints, { pos = b.pos, kind = "center", areaId = b.id })
		end
	end
	-- Append final precise goal position if available, so we walk to the actual target
	local goalPos = G.Navigation.goalPos
	if goalPos then
		table.insert(G.Navigation.waypoints, { pos = goalPos, kind = "goal" })
	end
end

function Navigation.GetCurrentWaypoint()
	local wpList = G.Navigation.waypoints
	local idx = G.Navigation.currentWaypointIndex or 1
	if wpList and idx and wpList[idx] then
		return wpList[idx]
	end
	return nil
end

function Navigation.AdvanceWaypoint()
	local wpList = G.Navigation.waypoints
	local idx = G.Navigation.currentWaypointIndex or 1
	if not (wpList and wpList[idx]) then
		return
	end
	local current = wpList[idx]
	-- If we reached a center of the next area, advance the area path too
	if current.kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
		-- path[1] is previous area; popping it moves us into the new area
		Navigation.RemoveCurrentNode()
	end
	G.Navigation.currentWaypointIndex = idx + 1
end

function Navigation.SkipWaypoints(count)
	local wpList = G.Navigation.waypoints
	if not wpList then
		return
	end
	local idx = (G.Navigation.currentWaypointIndex or 1) + (count or 1)
	if idx < 1 then
		idx = 1
	end
	if idx > #wpList + 1 then
		idx = #wpList + 1
	end
	-- If we skip over a center, reflect area progression
	local current = G.Navigation.waypoints[G.Navigation.currentWaypointIndex or 1]
	if current and current.kind ~= "center" then
		for j = (G.Navigation.currentWaypointIndex or 1), math.min(idx - 1, #wpList) do
			if wpList[j].kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
				Navigation.RemoveCurrentNode()
			end
		end
	end
	G.Navigation.currentWaypointIndex = idx
end

-- Function to convert degrees to radians
local function degreesToRadians(degrees)
	return degrees * math.pi / 180
end

-- Checks for an obstruction between two points using a hull trace.
local function isPathClear(startPos, endPos)
	local traceResult = engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, MASK_PLAYERSOLID_BRUSHONLY)
	return traceResult
end

-- Checks if the ground is stable at a given position.
local function isGroundStable(position)
	local groundTraceResult = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START,
		position + GROUND_TRACE_OFFSET_END,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	return groundTraceResult.fraction < 1
end

-- Function to get the ground normal at a given position
local function getGroundNormal(position)
	local groundTraceResult = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START,
		position + GROUND_TRACE_OFFSET_END,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	return groundTraceResult.plane
end

-- Precomputed up vector and max slope angle in radians
local MAX_SLOPE_ANGLE_RAD = degreesToRadians(MAX_SLOPE_ANGLE)

-- Function to get forward speed by class
function Navigation.GetMaxSpeed(entity)
	return entity:GetPropFloat("m_flMaxspeed")
end

-- Function to compute the move direction
local function ComputeMove(pCmd, a, b)
	local diff = b - a
	if diff:Length() == 0 then
		return Vector3(0, 0, 0)
	end

	local x = diff.x
	local y = diff.y
	local vSilent = Vector3(x, y, 0)

	local ang = vSilent:Angles()
	local cYaw = pCmd:GetViewAngles().yaw
	local yaw = math.rad(ang.y - cYaw)
	local move = Vector3(math.cos(yaw), -math.sin(yaw), 0)

	local maxSpeed = Navigation.GetMaxSpeed(G.pLocal.entity) + 1
	return move * maxSpeed
end

-- Function to implement fast stop
local function FastStop(pCmd, pLocal)
	local velocity = pLocal:GetVelocity()
	velocity.z = 0
	local speed = velocity:Length2D()

	if speed < 1 then
		pCmd:SetForwardMove(0)
		pCmd:SetSideMove(0)
		return
	end

	local accel = 5.5
	local maxSpeed = Navigation.GetMaxSpeed(G.pLocal.entity)
	local playerSurfaceFriction = 1.0
	local max_accelspeed = accel * (1 / TICK_RATE) * maxSpeed * playerSurfaceFriction

	local wishspeed
	if speed - max_accelspeed <= -1 then
		wishspeed = max_accelspeed / (speed / (accel * (1 / TICK_RATE)))
	else
		wishspeed = max_accelspeed
	end

	local ndir = (velocity * -1):Angles()
	ndir.y = pCmd:GetViewAngles().y - ndir.y
	ndir = ndir:ToVector()

	pCmd:SetForwardMove(ndir.x * wishspeed)
	pCmd:SetSideMove(ndir.y * wishspeed)
end

-- Function to make the player walk to a destination smoothly and stop at the destination
function Navigation.WalkTo(pCmd, pLocal, pDestination)
	local localPos = pLocal:GetAbsOrigin()
	local distVector = pDestination - localPos
	local dist = distVector:Length()
	local currentSpeed = Navigation.GetMaxSpeed(pLocal)

	local distancePerTick = math.max(10, math.min(currentSpeed / TICK_RATE, 450)) --in case we tracvel faster then we are close to target

	if dist > distancePerTick then --if we are further away we walk normaly at max speed
		local result = ComputeMove(pCmd, localPos, pDestination)
		pCmd:SetForwardMove(result.x)
		pCmd:SetSideMove(result.y)
	else
		FastStop(pCmd, pLocal)
	end
end

---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetClosestNode(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetClosestNode")
		return nil
	end
	local n = Node.GetClosestNode(pos)
	if not n then
		return nil
	end
	return n
end

-- Main pathfinding function - FIXED TO USE DUAL A* SYSTEM
---@param startNode Node
---@param goalNode Node
function Navigation.FindPath(startNode, goalNode)
	if not startNode or not startNode.pos then
		Log:Error("Navigation.FindPath: invalid start node")
		return Navigation
	end
	if not goalNode or not goalNode.pos then
		Log:Error("Navigation.FindPath: invalid goal node")
		return Navigation
	end

	local horizontalDistance = math.abs(goalNode.pos.x - startNode.pos.x) + math.abs(goalNode.pos.y - startNode.pos.y)
	local verticalDistance = math.abs(goalNode.pos.z - startNode.pos.z)

	-- Simple A* pathfinding on main areas only (subnodes removed)
	G.Navigation.path = AStar.NormalPath(startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodesSimple)

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Error("Failed to find path from %d to %d!", startNode.id, goalNode.id)
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false
	else
		Log:Info("Simple A* path found from %d to %d with %d nodes", startNode.id, goalNode.id, #G.Navigation.path)
		Navigation.pathFound = true
		Navigation.pathFailed = false
		pcall(setmetatable, G.Navigation.path, { __mode = "v" })
		-- Refresh waypoints to reflect current door usage
		Navigation.BuildDoorWaypointsFromPath()
	end

	return Navigation
end

-- A* internal navigation for smooth movement within larger areas
function Navigation.GetInternalPath(startPos, endPos, maxDistance)
	maxDistance = maxDistance or 200 -- Maximum distance to consider internal navigation

	local distance = (endPos - startPos):Length()
	if distance < 50 then
		return nil -- Too close, direct movement is fine
	end

	if distance > maxDistance then
		return nil -- Too far, use regular pathfinding
	end

	-- Check if we're in the same area and have hierarchical data
	if G.Navigation.hierarchical then
		local startArea, endArea = nil, nil

		-- Find which areas contain our start and end positions
		for areaId, areaInfo in pairs(G.Navigation.hierarchical.areas) do
			local areaNode = G.Navigation.nodes[areaId]
			if areaNode then
				local distToStart = (areaNode.pos - startPos):Length()
				local distToEnd = (areaNode.pos - endPos):Length()

				-- Check if positions are within reasonable distance of area center
				if distToStart < 150 then
					startArea = areaInfo
				end
				if distToEnd < 150 then
					endArea = areaInfo
				end
			end
		end

		-- If both positions are in the same area, use fine points for internal navigation
		if startArea and endArea and startArea.id == endArea.id then
			-- Find closest fine points to start and end
			local startPoint = Node.GetClosestAreaPoint(startArea.id, startPos)
			local endPoint = Node.GetClosestAreaPoint(startArea.id, endPos)

			if startPoint and endPoint and startPoint.id ~= endPoint.id then
				-- Use A* on fine points for smooth internal navigation
				-- Subnodes removed: skip fine point A* and fall back to direct move
				return nil
			end
		end
	end

	return nil -- No internal path available
end

-- Find the best exit point from an area towards another area
function Navigation.FindBestAreaExitPoint(currentArea, nextArea, areaInfo)
	if not areaInfo or not areaInfo.edgePoints or #areaInfo.edgePoints == 0 then
		return nil
	end

	local bestPoint = nil
	local minDistance = math.huge

	-- Find edge point closest to the next area
	for _, edgePoint in ipairs(areaInfo.edgePoints) do
		local distance = (edgePoint.pos - nextArea.pos):Length()
		if distance < minDistance then
			minDistance = distance
			bestPoint = edgePoint
		end
	end

	return bestPoint
end

-- Find the best entry point into an area from another area
function Navigation.FindBestAreaEntryPoint(currentArea, prevArea, areaInfo)
	if not areaInfo or not areaInfo.edgePoints or #areaInfo.edgePoints == 0 then
		return nil
	end

	local bestPoint = nil
	local minDistance = math.huge

	-- Find edge point closest to the previous area
	for _, edgePoint in ipairs(areaInfo.edgePoints) do
		local distance = (edgePoint.pos - prevArea.pos):Length()
		if distance < minDistance then
			minDistance = distance
			bestPoint = edgePoint
		end
	end

	return bestPoint
end

return Navigation

end)
__bundle_register("MedBot.Utils.A-Star", function(require, _LOADED, __bundle_register, __bundle_modules)
local Heap = require("MedBot.Utils.Heap")

---@alias PathNode { id : integer, x : number, y : number, z : number }

---@class AStar
local AStar = {}

local function ManhattanDistance(nodeA, nodeB)
	return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

local function HeuristicCostEstimate(nodeA, nodeB)
	return ManhattanDistance(nodeA, nodeB)
end

local function reconstructPath(cameFrom, current)
	local totalPath = { current }
	while cameFrom[current] do
		current = cameFrom[current]
		table.insert(totalPath, 1, current) -- Insert at beginning to get start-to-goal order
	end
	return totalPath
end

-- Optimized A-Star using precomputed costs (primary algorithm for all pathfinding)
function AStar.NormalPath(start, goal, nodes, adjacentFun)
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)
	local closedSet = {}
	local gScore, fScore, cameFrom = {}, {}, {}
	gScore[start] = 0
	fScore[start] = HeuristicCostEstimate(start, goal)

	openSet:push({ node = start, fScore = fScore[start] })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local current = currentData.node

		if current.id == goal.id then
			return reconstructPath(cameFrom, current)
		end

		closedSet[current] = true

		-- adjacentFun now returns {node=targetNode, cost=connectionCost}
		for _, neighborData in ipairs(adjacentFun(current, nodes)) do
			local neighbor = neighborData.node
			local connectionCost = neighborData.cost

			if not closedSet[neighbor] then
				-- Calculate distance cost (Manhattan distance for efficiency)
				local distanceCost = HeuristicCostEstimate(current, neighbor)

				-- Total cost = distance + precomputed connection cost
				local totalMoveCost = distanceCost + connectionCost

				local tentativeGScore = gScore[current] + totalMoveCost

				if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
					cameFrom[neighbor] = current
					gScore[neighbor] = tentativeGScore
					fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
					openSet:push({ node = neighbor, fScore = fScore[neighbor] })
				end
			end
		end
	end

	return nil -- Path not found if loop exits
end

return AStar

end)
__bundle_register("MedBot.Utils.Heap", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Enhanced Heap implementation in Lua.
    Modifications made for robustness and preventing memory leaks.
    Credits: github.com/GlorifiedPig/Luafinding
]]

local Heap = {}
Heap.__index = Heap

-- Constructor for the heap.
-- @param compare? Function for comparison, defining the heap property. Defaults to a min-heap.
function Heap.new(compare)
	return setmetatable({
		_data = {},
		_size = 0,
		Compare = compare or function(a, b)
			return a < b
		end,
	}, Heap)
end

-- Helper function to maintain the heap property while inserting an element.
local function sortUp(heap, index)
	while index > 1 do
		local parentIndex = math.floor(index / 2)
		if heap.Compare(heap._data[index], heap._data[parentIndex]) then
			heap._data[index], heap._data[parentIndex] = heap._data[parentIndex], heap._data[index]
			index = parentIndex
		else
			break
		end
	end
end

-- Helper function to maintain the heap property after removing the root element.
local function sortDown(heap, index)
	while true do
		local leftIndex, rightIndex = 2 * index, 2 * index + 1
		local smallest = index

		if leftIndex <= heap._size and heap.Compare(heap._data[leftIndex], heap._data[smallest]) then
			smallest = leftIndex
		end
		if rightIndex <= heap._size and heap.Compare(heap._data[rightIndex], heap._data[smallest]) then
			smallest = rightIndex
		end

		if smallest ~= index then
			heap._data[index], heap._data[smallest] = heap._data[smallest], heap._data[index]
			index = smallest
		else
			break
		end
	end
end

-- Checks if the heap is empty.
function Heap:empty()
	return self._size == 0
end

-- Clears the heap, allowing Lua's garbage collector to reclaim memory.
function Heap:clear()
	for i = 1, self._size do
		self._data[i] = nil
	end
	self._size = 0
end

-- Adds an item to the heap.
-- @param item The item to be added.
function Heap:push(item)
	self._size = self._size + 1
	self._data[self._size] = item
	sortUp(self, self._size)
end

-- Removes and returns the root element of the heap.
function Heap:pop()
	if self._size == 0 then
		return nil
	end
	local root = self._data[1]
	self._data[1] = self._data[self._size]
	self._data[self._size] = nil -- Clear the reference to the removed item
	self._size = self._size - 1
	if self._size > 0 then
		sortDown(self, 1)
	end
	return root
end

return Heap

end)
return __bundle_require("__root")