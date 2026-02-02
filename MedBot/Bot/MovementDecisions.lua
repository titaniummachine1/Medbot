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
local PathValidator = require("MedBot.Navigation.isWalkable.IsWalkable")

local MovementDecisions = {}
local Log = Common.Log.new("MovementDecisions")

-- Log:Debug now automatically respects G.Menu.Main.Debug, no wrapper needed

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

	-- In FOLLOWING state we don't advance nodes based on reach distance
	if G.currentState == G.States.FOLLOWING then
		return result
	end

	local LocalOrigin = G.pLocal.Origin
	local horizontalDist = Common.Distance2D(LocalOrigin, targetPos)
	local verticalDist = math.abs(LocalOrigin.z - targetPos.z)

	-- Check if we've reached the target
	local reachedTarget = MovementDecisions.hasReachedTarget(LocalOrigin, targetPos, horizontalDist, verticalDist)

	-- Node skipping with WorkManager cooldown (1 tick normally, 132 ticks when stuck)
	if WorkManager.attemptWork(1, "node_skipping") then
		local NodeSkipper = require("MedBot.Bot.NodeSkipper")
		local skipped = NodeSkipper.TrySkipNode(LocalOrigin, function()
			Navigation.RemoveCurrentNode()
		end)
		if skipped then
			-- Skip was validated - don't do reach-based advancement on same tick
			reachedTarget = false
		end
	end

	if reachedTarget then
		Log:Debug("Reached target - advancing waypoint/node")

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

-- Reset distance tracking (call when path changes)
function MovementDecisions.resetDistanceTracking()
	previousDistance = nil
end

-- Decision: Handle node advancement
function MovementDecisions.advanceNode()
	previousDistance = nil -- Reset tracking when advancing nodes
	Log:Debug(tostring(G.Menu.Main.Skip_Nodes), #G.Navigation.path)

	if G.Menu.Navigation.Skip_Nodes then
		Log:Debug("=== REACHED TARGET - Advancing to next node (NORMAL PROGRESSION, NOT SKIP) ===")

		-- SINGLE SOURCE OF TRUTH: Validate we can reach NEXT node before advancing
		if #G.Navigation.path >= 2 then
			local PathValidator = require("MedBot.Navigation.isWalkable.IsWalkable")
			local nextNode = G.Navigation.path[2]
			local canReachNext = PathValidator.Path(G.pLocal.Origin, nextNode.pos)

			if not canReachNext then
				Log:Debug("BLOCKED: Wall between current and next node - triggering repath")
				Navigation.ClearPath()
				G.currentState = G.States.IDLE
				G.lastPathfindingTick = 0
				return false -- Force repath
			end
		end

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

-- Decision: Check stuck state: Simple walkability check with cooldown
function MovementDecisions.checkStuckState()
	-- Velocity/timeout checks ONLY when bot is walking autonomously
	if G.Menu.Main.EnableWalking then
		local pLocal = G.pLocal.entity
		if pLocal then
			-- Track how long we've been on the same node
			local currentNodeId = G.Navigation.path and G.Navigation.path[1] and G.Navigation.path[1].id
			if currentNodeId then
				if currentNodeId ~= G.Navigation.lastNodeId then
					G.Navigation.lastNodeId = currentNodeId
					G.Navigation.currentNodeTicks = 0
				else
					G.Navigation.currentNodeTicks = (G.Navigation.currentNodeTicks or 0) + 1
				end

				-- Stuck detection: If on same node for > 200 ticks (3 seconds), force repath
				if G.Navigation.currentNodeTicks > 200 then
					Log:Warn("STUCK: Same node for %d ticks, switching to STUCK state", G.Navigation.currentNodeTicks)
					G.currentState = G.States.STUCK
					G.Navigation.currentNodeTicks = 0
					return
				end
			end

			-- Velocity-based stuck detection
			local velocity = pLocal:EstimateAbsVelocity()
			if velocity and type(velocity.x) == "number" and type(velocity.y) == "number" then
				local speed2D = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

				-- Critical velocity threshold: < 50 = stuck
				if speed2D < 50 then
					G.Navigation.lowVelocityTicks = (G.Navigation.lowVelocityTicks or 0) + 1

					-- If velocity too low for 66 ticks (1 second), switch to STUCK state
					if G.Navigation.lowVelocityTicks > 66 then
						Log:Warn(
							"STUCK: Low velocity (%d) for %d ticks, entering STUCK state",
							speed2D,
							G.Navigation.lowVelocityTicks
						)
						G.currentState = G.States.STUCK
						G.Navigation.lowVelocityTicks = 0
					end
				else
					G.Navigation.lowVelocityTicks = 0
				end
			end
		end
	end

	-- Simple walkability check for ALL modes (with 33 tick cooldown)
	-- Only when NOT walking autonomously (walking mode has velocity checks)
	if not G.Menu.Main.EnableWalking then
		-- TEMPORARILY DISABLED to debug NodeSkipper traces (this was interfering with visualization)
		-- if WorkManager.attemptWork(33, "stuck_walkability_check") then
		-- 	local targetPos = MovementDecisions.getCurrentTarget()
		-- 	if targetPos then
		-- 		if not PathValidator.Path(G.pLocal.Origin, targetPos) then
		-- 			Log:Warn("STUCK: Path to current target not walkable, repathing")
		-- 			G.currentState = G.States.STUCK
		-- 		end
		-- 	end
		-- end
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

	-- ALWAYS execute movement at the end, regardless of decision outcomes
	MovementDecisions.executeMovement(userCmd)

	-- Handle SmartJump after walkTo
	MovementDecisions.handleSmartJump(userCmd)
end

return MovementDecisions
