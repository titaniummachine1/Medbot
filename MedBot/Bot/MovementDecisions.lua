--[[
Movement Decision System - Composition-based bot behavior
Handles all movement decisions while ensuring walkTo is always called
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local MovementController = require("MedBot.Bot.MovementController")
local SmartJump = require("MedBot.Bot.SmartJump")
local WorkManager = require("MedBot.WorkManager")
local ISWalkable = require("MedBot.Navigation.ISWalkable")

local MovementDecisions = {}
local Log = Common.Log.new("MovementDecisions")

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs
local WALKABILITY_CHECK_COOLDOWN = 5 -- ticks (~83ms) between expensive walkability checks

-- Decision: Check if we've reached the target and advance waypoints/nodes
function MovementDecisions.checkDistanceAndAdvance(userCmd)
	local result = { shouldContinue = true }

	-- Throttled distance calculation
	if not WorkManager.attemptWork(DISTANCE_CHECK_COOLDOWN, "distance_check") then
		return result -- Skip this frame's distance check
	end

	-- Get current target position
	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		result.shouldContinue = false
		return result
	end

	local LocalOrigin = G.pLocal.Origin
	local horizontalDist = Common.Distance2D(LocalOrigin, targetPos)
	local verticalDist = math.abs(LocalOrigin.z - targetPos.z)

	-- Check if we've reached the target
	if MovementDecisions.hasReachedTarget(LocalOrigin, targetPos, horizontalDist, verticalDist) then
		Log:Debug("Reached target - advancing waypoint/node")

		-- Handle node skipping logic when we reach a node
		-- REMOVED: Old skipping logic - now using passive distance-based skipping in NodeSkipper.CheckContinuousSkip

		-- Advance waypoint or node
		if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
			Navigation.AdvanceWaypoint()
			-- If no more waypoints, we're done
			if not Navigation.GetCurrentWaypoint() then
				Navigation.ClearPath()
				Log:Info("Reached end of waypoint path")
				result.shouldContinue = false
				G.currentState = G.States.IDLE
				G.lastPathfindingTick = 0
			end
		else
			-- Fallback to node-based advancement
			MovementDecisions.advanceNode()
		end
	end

	-- Handle continuous node skipping logic
	local NodeSkipper = require("MedBot.Bot.NodeSkipper")
	local nodesToSkip = NodeSkipper.CheckContinuousSkip(LocalOrigin)

	if nodesToSkip > 0 then
		Log:Debug("NodeSkipper decided to skip %d nodes", nodesToSkip)

		-- Skip the requested number of nodes
		for i = 1, nodesToSkip do
			Navigation.RemoveCurrentNode()
		end

		-- Node(s) were skipped, get new target
		targetPos = MovementDecisions.getCurrentTarget()
		if not targetPos then
			result.shouldContinue = false
			return result
		end
	end

	return result
end

-- Helper: Get current target position
function MovementDecisions.getCurrentTarget()
	if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
		local currentWaypoint = Navigation.GetCurrentWaypoint()
		if currentWaypoint then
			return currentWaypoint.pos
		end
	end

	-- Fallback to path node
	if G.Navigation.path and #G.Navigation.path > 0 then
		local currentNode = G.Navigation.path[1]
		return currentNode and currentNode.pos
	end

	return nil
end

-- Helper: Check if we've reached the target
function MovementDecisions.hasReachedTarget(origin, targetPos, horizontalDist, verticalDist)
	return (horizontalDist < G.Misc.NodeTouchDistance) and (verticalDist <= G.Misc.NodeTouchHeight)
end

-- Decision: Handle node advancement
function MovementDecisions.advanceNode()
	Log:Debug(
		"Node advancement - Skip_Nodes = %s, path length = %d",
		tostring(G.Menu.Main.Skip_Nodes),
		#G.Navigation.path
	)

	if G.Menu.Main.Skip_Nodes then
		Log:Debug("Removing current node (Skip Nodes enabled)")
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()
		-- Reset node skipping timer when manually advancing
		Navigation.ResetNodeSkipping()

		if #G.Navigation.path == 0 then
			Navigation.ClearPath()
			Log:Info("Reached end of path")
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0
			return false -- Don't continue
		end
	else
		Log:Debug("Skip Nodes disabled - not removing node")
		if #G.Navigation.path <= 1 then
			Navigation.ClearPath()
			Log:Info("Reached final node (Skip Nodes disabled)")
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0
			return false -- Don't continue
		end
	end

	return true -- Continue moving
end

-- Decision: Check if bot is stuck
function MovementDecisions.checkStuckState()
	-- Increment stuck counter
	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1

	-- Check if stuck (2 seconds = 132 ticks)
	if G.Navigation.currentNodeTicks > 132 then
		Log:Warn("Bot stuck for 2 seconds - transitioning to STUCK state")
		G.currentState = G.States.STUCK
		return false -- Don't continue movement
	end

	return true -- Continue moving
end

-- Decision: Handle speed penalties and optimization
function MovementDecisions.handleSpeedOptimization()
	if G.Navigation.path and #G.Navigation.path > 1 then
		-- Speed penalty check (moved from NodeSkipper - this is stuck detection, not skipping)
		local currentTick = globals.TickCount()
		if not G.__lastSpeedCheckTick then
			G.__lastSpeedCheckTick = currentTick
		end

		-- Check every 33 ticks (~0.5s at 66fps)
		if currentTick - G.__lastSpeedCheckTick >= 33 then
			G.__lastSpeedCheckTick = currentTick

			-- Get current player speed
			local pLocal = entities.GetLocalPlayer()
			if pLocal then
				local velocity = pLocal:EstimateAbsVelocity() or Vector3(0, 0, 0)
				local speed = velocity:Length2D()

				-- Only trigger if speed is below 50
				if speed < 50 then
					Log:Debug("Speed penalty check triggered - speed: %.1f", speed)

					local targetPos = MovementDecisions.getCurrentTarget()
					if targetPos and not ISWalkable.Path(G.pLocal.Origin, targetPos) then
						Log:Debug("Direct path to target not walkable - adding penalty")

						-- Add penalty to connection
						if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
							local currentNode = G.Navigation.path[1]
							local nextNode = G.Navigation.path[2]
							if currentNode and nextNode then
								G.CircuitBreaker.addConnectionFailure(currentNode, nextNode)
							end
						end

						-- Force repath
						if G.StateHandler and G.StateHandler.forceRepath then
							G.StateHandler.forceRepath()
							Log:Debug("Forced repath due to unwalkable connection")
						end
					end
				end
			end
		end
	end
end

-- Decision: Handle debug logging (throttled)
function MovementDecisions.handleDebugLogging()
	-- Throttled debug logging
	G.__lastMoveDebugTick = G.__lastMoveDebugTick or 0
	local now = globals.TickCount()

	if now - G.__lastMoveDebugTick > DEBUG_LOG_COOLDOWN then
		local targetPos = MovementDecisions.getCurrentTarget()
		if targetPos then
			local pathLen = G.Navigation.path and #G.Navigation.path or 0
			Log:Debug("MOVING: pathLen=%d", pathLen)
		end
		G.__lastMoveDebugTick = now
	end
end

-- Decision: Handle SmartJump execution
function MovementDecisions.handleSmartJump(userCmd)
	SmartJump.Main(userCmd)
end

-- Movement Execution: Always called at the end
function MovementDecisions.executeMovement(userCmd)
	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		Log:Warn("No target position available for movement")
		return
	end

	-- Always execute movement regardless of decision cooldowns
	if G.Menu.Main.EnableWalking then
		MovementController.walkTo(userCmd, G.pLocal.entity, targetPos)
	else
		userCmd:SetForwardMove(0)
		userCmd:SetSideMove(0)
	end
end

-- Main composition function: Run all decisions then always execute movement
function MovementDecisions.handleMovingState(userCmd)
	-- Early validation
	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	-- Update movement direction for SmartJump
	local targetPos = MovementDecisions.getCurrentTarget()
	if targetPos then
		local LocalOrigin = G.pLocal.Origin
		local direction = targetPos - LocalOrigin
		G.BotMovementDirection = direction:Length() > 0 and Common.Normalize(direction) or Vector3(0, 0, 0)
		G.BotIsMoving = true
		G.Navigation.currentTargetPos = targetPos
	end

	-- Handle camera rotation
	MovementController.handleCameraRotation(userCmd, targetPos)

	-- Run all decision components (these don't affect movement execution)
	MovementDecisions.handleDebugLogging()
	MovementDecisions.checkDistanceAndAdvance(userCmd)
	MovementDecisions.checkStuckState()
	MovementDecisions.handleSpeedOptimization()

	-- ALWAYS execute movement at the end, regardless of decision outcomes
	MovementDecisions.executeMovement(userCmd)

	-- Handle SmartJump after walkTo
	MovementDecisions.handleSmartJump(userCmd)
end

return MovementDecisions
