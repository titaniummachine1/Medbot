---@diagnostic disable: duplicate-set-field, undefined-field
---@class SmartJump
-- Detects when the player should jump to clear obstacles
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Utils.Globals")
local Prediction = require("MedBot.Deprecated.Prediction")

local Log = Common.Log.new("SmartJump")
Log.Level = 0 -- Default log level

-- Utility wrapper to respect debug toggle
local function DebugLog(...)
	if G.Menu.SmartJump and G.Menu.SmartJump.Debug then
		Log:Debug(...)
	end
end

-- SmartJump module
local SmartJump = {}

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

-- Initialize jump state (ensure all fields exist)
if not G.SmartJump then
	G.SmartJump = {}
end
if not G.SmartJump.jumpState then
	G.SmartJump.jumpState = STATE_IDLE
end
if not G.SmartJump.SimulationPath then
	G.SmartJump.SimulationPath = {}
end
if not G.SmartJump.PredPos then
	G.SmartJump.PredPos = nil
end
if not G.SmartJump.JumpPeekPos then
	G.SmartJump.JumpPeekPos = nil
end
if not G.SmartJump.HitObstacle then
	G.SmartJump.HitObstacle = false
end
if not G.SmartJump.lastAngle then
	G.SmartJump.lastAngle = nil
end
if not G.SmartJump.stateStartTime then
	G.SmartJump.stateStartTime = 0
end
if not G.SmartJump.lastState then
	G.SmartJump.lastState = nil
end
if not G.SmartJump.lastJumpTime then
	G.SmartJump.lastJumpTime = 0
end

-- Visual debug variables initialized above

-- Function to normalize a vector
local function NormalizeVector(vector)
	local length = vector:Length()
	return length == 0 and nil or vector / length
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

-- Tick-by-tick movement simulation with proper velocity physics
local function SimulateMovementTick(startPos, velocity, stepHeight)
	local vUp = Vector3(0, 0, 1)
	local vStep = Vector3(0, 0, stepHeight or 18)
	local vHitbox = { Vector3(-24, -24, 0), Vector3(24, 24, 82) }
	local MASK_PLAYERSOLID = 33636363

	local dt = globals.TickInterval()
	local targetPos = startPos + velocity * dt

	-- Step 1: Move up by step height
	local stepUpPos = startPos + vStep

	-- ALWAYS check for jump opportunities first, regardless of wall collision
	local shouldJump = false
	local moveDir = NormalizeVector(velocity)
	if moveDir then
		-- Check if there's an obstacle ahead that requires jumping
		local forwardTrace =
			engine.TraceHull(stepUpPos, stepUpPos + moveDir * 32, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
		if forwardTrace.fraction < 1 then
			-- Found obstacle - move 1 unit forward from hit point, then up 72 units, then trace down
			-- This guarantees we collide with obstacle from above
			local hitPoint = forwardTrace.endpos
			local forwardFromHit = hitPoint + moveDir * 1
			local aboveObstacle = forwardFromHit + Vector3(0, 0, 72)

			-- Trace down from above obstacle to measure height
			local downTrace = engine.TraceHull(
				aboveObstacle,
				forwardFromHit - Vector3(0, 0, 18),
				vHitbox[1],
				vHitbox[2],
				MASK_PLAYERSOLID
			)

			if downTrace.fraction < 0.75 then
				-- Obstacle is higher than step height (>18 units)
				local obstacleHeight = 72 * (1 - downTrace.fraction)

				-- Only jump if obstacle is worth jumping over (>18 units)
				if obstacleHeight > 18 then
					-- Check if we can clear obstacle by jumping
					local jumpPos = forwardFromHit + Vector3(0, 0, 72)

					-- Check if we're clear at jump height
					local clearTrace = engine.TraceHull(jumpPos, jumpPos, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
					if clearTrace.fraction > 0 then
						-- Check if we can land after clearing obstacle
						local landTrace = engine.TraceHull(
							jumpPos,
							jumpPos - Vector3(0, 0, 72 + 18),
							vHitbox[1],
							vHitbox[2],
							MASK_PLAYERSOLID
						)

						-- If we can land and surface is walkable
						if landTrace.fraction > 0 and landTrace.fraction < 1 then
							local groundAngle = math.deg(math.acos(landTrace.plane:Dot(Vector3(0, 0, 1))))
							if groundAngle < 45 then -- Walkable surface
								shouldJump = true
							else
								-- Landing surface too steep - try 10 units further into obstacle
								local forwardFromHit10 = hitPoint + moveDir * 24
								local jumpPos10 = forwardFromHit10 + Vector3(0, 0, 72)

								-- Check if we're clear at jump height (10 units further)
								local clearTrace10 =
									engine.TraceHull(jumpPos10, jumpPos10, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
								if clearTrace10.fraction > 0 then
									-- Check landing 10 units further
									local landTrace10 = engine.TraceHull(
										jumpPos10,
										jumpPos10 - Vector3(0, 0, 72 + 18),
										vHitbox[1],
										vHitbox[2],
										MASK_PLAYERSOLID
									)

									-- If we can land and surface is walkable at 10 units
									if landTrace10.fraction > 0 and landTrace10.fraction < 1 then
										local groundAngle10 =
											math.deg(math.acos(landTrace10.plane:Dot(Vector3(0, 0, 1))))
										if groundAngle10 < 45 then -- Walkable surface at 10 units
											shouldJump = true
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Step 2: Forward collision check
	local wallTrace = engine.TraceHull(stepUpPos, targetPos + vStep, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
	local hitWall = wallTrace.fraction < 1
	local finalPos = targetPos
	local newVelocity = velocity

	if hitWall and not shouldJump then
		-- Apply wall sliding logic (matching swing prediction)
		local normal = wallTrace.plane
		local angle = math.deg(math.acos(normal:Dot(vUp)))

		-- Check the wall angle (same as swing prediction)
		if angle > 55 then
			-- Wall too steep - slide along it and lose velocity
			local dot = velocity:Dot(normal)
			newVelocity = velocity - normal * dot
			-- Move only 1 unit into obstacle by default
			finalPos = wallTrace.endpos + normal * 1
		else
			-- Wall angle <= 55 degrees - move 1 unit into obstacle
			finalPos = wallTrace.endpos + wallTrace.plane * 1
		end
	end

	-- Step 3: Ground collision (step down) - only if not jumping, matching swing prediction logic
	if not shouldJump then
		-- Don't step down if we're in-air (simplified check)
		local downStep = vStep

		local groundTrace =
			engine.TraceHull(finalPos + vStep, finalPos - downStep, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
		local onGround = false
		if groundTrace.fraction < 1 then
			-- We'll hit the ground - check ground angle (same as swing prediction)
			local normal = groundTrace.plane
			local angle = math.deg(math.acos(normal:Dot(vUp)))

			-- Check the ground angle (matching swing prediction logic)
			if angle < 45 then
				-- Walkable surface - land on it
				finalPos = groundTrace.endpos
				onGround = true
			elseif angle < 55 then
				-- Too steep to walk but not steep enough to slide - stop movement
				newVelocity = Vector3(0, 0, 0)
				onGround = true
			else
				-- Very steep surface - slide along it
				local dot = newVelocity:Dot(normal)
				newVelocity = newVelocity - normal * dot
				onGround = true
			end
		end

		-- Apply gravity if not on ground (matching swing prediction)
		if not onGround then
			local gravity = 800 -- TF2 gravity
			newVelocity.z = newVelocity.z - gravity * dt
		end
	end

	return finalPos, hitWall, newVelocity, shouldJump
end

-- Check if we can jump over obstacle at current position
local function CanJumpOverObstacle(pos, moveDir, obstacleHeight)
	local vHitbox = { Vector3(-24, -24, 0), Vector3(24, 24, 82) }
	local MASK_PLAYERSOLID = 33636363
	local jumpHeight = 72 -- Max jump height
	local stepHeight = 18 -- Normal step height

	-- Only jump if obstacle is higher than step height (>18 units)
	if obstacleHeight and obstacleHeight > stepHeight then
		-- Obstacle is high enough to require jumping
	else
		return false -- Can step over, no need to jump
	end

	-- Move up jump height first, then move 1 unit into wall
	local jumpPos = pos + Vector3(0, 0, jumpHeight)
	local forwardPos = jumpPos + moveDir * 1

	-- Check if we're inside wall at jump height (trace fraction 0 means inside solid)
	local wallCheckTrace = engine.TraceHull(forwardPos, forwardPos, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
	if wallCheckTrace.fraction == 0 then
		return false -- Still inside wall at jump height, cannot clear
	end

	-- Check if we can land after clearing obstacle
	local landTrace = engine.TraceHull(
		forwardPos,
		forwardPos - Vector3(0, 0, jumpHeight + 18),
		vHitbox[1],
		vHitbox[2],
		MASK_PLAYERSOLID
	)

	-- If trace fraction is 0, we cannot jump this obstacle
	if landTrace.fraction == 0 then
		return false
	end

	if landTrace.fraction < 1 then
		local landingPos = landTrace.endpos
		local groundAngle = math.deg(math.acos(landTrace.plane:Dot(Vector3(0, 0, 1))))
		if groundAngle < 45 then -- Walkable surface
			return true, landingPos
		end
	end

	return false
end

-- Smart jump detection with improved tick-by-tick simulation
local function SmartJumpDetection(cmd, pLocal)
	-- Basic validation - fail fast
	if not pLocal then
		return false
	end
	if not isPlayerOnGround(pLocal) then
		return false
	end

	local pLocalPos = pLocal:GetAbsOrigin()

	-- Get move intent direction from cmd
	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveIntent:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		-- Use bot movement direction if no manual input
		local viewAngles = engine.GetViewAngles()
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()
		local forwardComponent = G.BotMovementDirection:Dot(forward)
		local rightComponent = G.BotMovementDirection:Dot(right)
		moveIntent = Vector3(forwardComponent * 450, -rightComponent * 450, 0)
	end

	if moveIntent:Length() == 0 then
		return false
	end

	-- Use move intent direction with current velocity magnitude
	local viewAngles = engine.GetViewAngles()
	local rotatedMoveIntent = RotateVectorByYaw(moveIntent, viewAngles.yaw)
	local moveDir = NormalizeVector(rotatedMoveIntent)
	local currentVel = pLocal:EstimateAbsVelocity()
	local horizontalSpeed = currentVel:Length()

	if horizontalSpeed <= 1 then
		return false
	end

	-- Set initial velocity: move intent direction with current speed
	local initialVelocity = moveDir * horizontalSpeed

	local maxSimTicks = 33 -- ~0.5 seconds

	-- Initialize simulation path for visualization
	G.SmartJump.SimulationPath = { pLocalPos }

	local currentPos = pLocalPos
	local currentVelocity = initialVelocity
	local hitObstacle = false

	-- Tick-by-tick simulation until jump peak time
	for tick = 1, maxSimTicks do
		local newPos, wallHit, newVelocity, shouldJump = SimulateMovementTick(currentPos, currentVelocity, 18)

		-- Store simulation step for visualization
		table.insert(G.SmartJump.SimulationPath, newPos)

		if wallHit then
			hitObstacle = true

			if shouldJump then
				-- Calculate minimum tick needed to achieve obstacle height
				local moveDir = NormalizeVector(currentVelocity)
				if moveDir then
					-- Get actual obstacle height from the simulation tick
					local obstacleHeight = hitObstacle and 72 or 36 -- Default estimation

					-- Calculate minimum time needed to reach obstacle height
					-- Using jump physics: height = 0.5 * gravity * time^2, solve for time
					local gravity = 800 -- TF2 gravity
					local timeToReachHeight = math.sqrt(2 * obstacleHeight / gravity)
					local minJumpTick = math.ceil(timeToReachHeight / globals.TickInterval())

					-- Only jump if current tick <= minimum tick needed
					if tick <= minJumpTick then
						local jumpHeight = 72
						local jumpPos = currentPos + Vector3(0, 0, jumpHeight)
						local forwardPos = jumpPos + moveDir * 32 -- Move forward to landing area

						-- Find landing position
						local vHitbox = { Vector3(-24, -24, 0), Vector3(24, 24, 82) }
						local MASK_PLAYERSOLID = 33636363
						local landTrace = engine.TraceHull(
							forwardPos,
							forwardPos - Vector3(0, 0, jumpHeight + 18),
							vHitbox[1],
							vHitbox[2],
							MASK_PLAYERSOLID
						)

						if landTrace.fraction < 1 then
							G.SmartJump.JumpPeekPos = landTrace.endpos
							-- Update simulation path to show jump arc
							table.insert(G.SmartJump.SimulationPath, jumpPos)
							table.insert(G.SmartJump.SimulationPath, landTrace.endpos)
						end

						G.SmartJump.PredPos = currentPos
						G.SmartJump.HitObstacle = true

						DebugLog(
							"SmartJump: Jump at tick %d (min needed: %d), pos=%s",
							tick,
							minJumpTick,
							tostring(currentPos)
						)
						return true
					else
						-- Set visuals but don't jump yet - too early
						G.SmartJump.PredPos = currentPos
						G.SmartJump.HitObstacle = true
						DebugLog("SmartJump: Too early to jump - tick %d > min needed %d", tick, minJumpTick)
					end
				end
			else
				-- No jump needed (obstacle <=18 units) or can't jump - continue simulation
				DebugLog("SmartJump: No jump needed at tick %d, continuing simulation", tick)
			end
		end

		currentPos = newPos
		currentVelocity = newVelocity
	end

	-- Store final simulation results
	G.SmartJump.PredPos = currentPos
	G.SmartJump.HitObstacle = hitObstacle

	DebugLog("SmartJump: Simulation complete, hitObstacle=%s, finalPos=%s", tostring(hitObstacle), tostring(currentPos))
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
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	if not G.Menu.SmartJump.Enable then
		return
	end

	-- Run SmartJump state machine
	SmartJump.Main(cmd)

	-- Note: The state machine handles all button inputs directly in SmartJump.Main()
	-- No need to apply additional jump commands here
end

-- Visual debugging (matching user's exact visual logic)
local function OnDrawSmartJump()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not G.Menu.SmartJump.Enable then
		return
	end
	if G.SmartJump.PredPos then
		-- Draw prediction position (red square)
		local screenPos = client.WorldToScreen(G.SmartJump.PredPos)
		if screenPos then
			draw.Color(255, 0, 0, 255)
			draw.FilledRect(screenPos[1] - 5, screenPos[2] - 5, screenPos[1] + 5, screenPos[2] + 5)
		end
	end

	-- Draw jump peek position (green square)
	if G.SmartJump.JumpPeekPos then
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
	end

	-- Draw full simulation path as connected lines
	if G.SmartJump.SimulationPath and #G.SmartJump.SimulationPath > 1 then
		for i = 1, #G.SmartJump.SimulationPath - 1 do
			local currentPos = G.SmartJump.SimulationPath[i]
			local nextPos = G.SmartJump.SimulationPath[i + 1]

			local currentScreen = client.WorldToScreen(currentPos)
			local nextScreen = client.WorldToScreen(nextPos)

			if currentScreen and nextScreen then
				-- Blue gradient - darker at start, brighter at end
				local alpha = math.floor(100 + (i / #G.SmartJump.SimulationPath) * 155)
				draw.Color(0, 150, 255, alpha)
				draw.Line(currentScreen[1], currentScreen[2], nextScreen[1], nextScreen[2])
			end
		end
	end

	-- Draw jump landing position if available
	if G.SmartJump.JumpPeekPos then
		local landingScreen = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if landingScreen then
			draw.Color(0, 255, 255, 255) -- Cyan for landing
			draw.FilledRect(landingScreen[1] - 4, landingScreen[2] - 4, landingScreen[1] + 4, landingScreen[2] + 4)
		end
	end

	-- Draw current state info
	draw.Color(255, 255, 255, 255)
	draw.Text(10, 100, "SmartJump State: " .. (G.SmartJump.jumpState or "UNKNOWN"))
	if G.SmartJump.HitObstacle then
		draw.Text(10, 120, "Obstacle Detected: YES")
	else
		draw.Text(10, 120, "Obstacle Detected: NO")
	end
end

-- Register callbacks
callbacks.Unregister("CreateMove", "SmartJump.Standalone")
callbacks.Register("CreateMove", "SmartJump.Standalone", OnCreateMoveStandalone)

callbacks.Unregister("Draw", "SmartJump.Visual")
callbacks.Register("Draw", "SmartJump.Visual", OnDrawSmartJump)

return SmartJump
