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
-- Dynamic hitbox calculation using entity bounds
local function GetPlayerHitbox(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	return { mins, maxs }
end
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

-- Check if obstacle is jumpable and calculate minimum time needed
local function CheckJumpable(hitPos, moveDirection, hitbox, currentTick)
	if not moveDirection then
		return false, 0
	end

	-- Move 1 unit forward from hit point
	local checkPos = hitPos + moveDirection * 1
	local abovePos = checkPos + Vector3(0, 0, 72)

	-- Trace down to find obstacle height
	local trace = engine.TraceHull(abovePos, checkPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	-- Fraction 0 = inside wall, can't jump
	if trace.fraction == 0 then
		return false, 0
	end

	-- Calculate actual obstacle height using (1 - fraction)
	local obstacleHeight = 72 * (1 - trace.fraction)

	-- Check if surface is walkable when we land
	if trace.fraction > 0 and isSurfaceWalkable(trace.plane) then
		-- Calculate minimum time in air to achieve this height
		-- Jump velocity is 271 units/sec, gravity is 800 units/sec^2
		-- Height = v0*t - 0.5*g*t^2, solve for t when height >= obstacleHeight
		local jumpVel = 271
		local gravity = 800
		local tickInterval = globals.TickInterval()

		-- Time to reach peak: t_peak = jumpVel / gravity
		local timeToPeak = jumpVel / gravity

		-- Height at time t: h = jumpVel*t - 0.5*gravity*t^2
		-- We need h >= obstacleHeight, find minimum t
		local minTimeNeeded = 0
		for t = 0, timeToPeak, tickInterval do
			local height = jumpVel * t - 0.5 * gravity * t * t
			if height >= obstacleHeight then
				minTimeNeeded = t
				break
			end
		end

		-- Convert to ticks and add safety margin
		local minTicksNeeded = math.ceil(minTimeNeeded / tickInterval)

		G.SmartJump.JumpPeekPos = trace.endpos
		return true, minTicksNeeded
	end

	return false, 0
end

-- Simplified movement simulation: step up -> move forward -> check obstacle jump -> wall sliding -> step down
local function SimulateMovementTick(startPos, velocity, stepHeight, pLocal, onGroundInput)
	local upVector = Vector3(0, 0, 1)
	local stepVector = Vector3(0, 0, stepHeight or 18)
	local hitbox = GetPlayerHitbox(pLocal)
	local deltaTime = globals.TickInterval()
	local moveDirection = NormalizeVector(velocity)
	local onGround = onGroundInput or true

	-- Store original Z position to prevent elevation accumulation
	local originalZ = startPos.z

	-- Step 1: Move up by step height (temporary elevation)
	local elevatedPos = startPos + stepVector

	-- Step 2: Move forward at elevated position
	local forwardDistance = velocity:Length() * deltaTime
	local targetPos = elevatedPos + moveDirection * forwardDistance

	local forwardTrace = engine.TraceHull(elevatedPos, targetPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local hitObstacle = forwardTrace.fraction < 1
	local currentPos = forwardTrace.endpos
	local currentVelocity = velocity
	local shouldJump = false

	-- Step 3: Check for obstacle jump if we hit something
	local canJump = false
	local minJumpTicks = 0
	if hitObstacle then
		canJump, minJumpTicks = CheckJumpable(forwardTrace.endpos, moveDirection, hitbox, 0)
		shouldJump = canJump
	end

	-- Step 4: Apply wall sliding if we hit obstacle but can't jump
	if hitObstacle and not shouldJump then
		local wallNormal = forwardTrace.plane
		local wallAngle = math.deg(math.acos(wallNormal:Dot(upVector)))

		if wallAngle > 55 then
			-- Steep wall - slide along it
			local velocityDot = currentVelocity:Dot(wallNormal)
			currentVelocity = currentVelocity - wallNormal * velocityDot
			currentPos = forwardTrace.endpos - wallNormal * 1
		else
			-- Normal wall - move 1 unit into it
			currentPos = forwardTrace.endpos - wallNormal * 1
		end
	else
		-- No obstacle hit, use target position
		currentPos = targetPos
	end

	-- Step 5: Step down to ground level - CRITICAL: Prevent elevation accumulation
	-- Trace down from current position to find ground, extending well beyond step height
	local maxStepDown = Vector3(0, 0, stepHeight + 72) -- Look much further down
	local stepDownTrace = engine.TraceHull(currentPos, currentPos - maxStepDown, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	if stepDownTrace.fraction < 1 then
		-- Hit ground - check if it's within reasonable step height
		local groundNormal = stepDownTrace.plane
		local groundAngle = math.deg(math.acos(groundNormal:Dot(upVector)))
		local distanceToGround = maxStepDown:Length() * stepDownTrace.fraction

		if distanceToGround <= stepHeight then
			-- Ground is within step height - normal stepping
			if groundAngle < 45 then
				-- Walkable ground - snap to it
				currentPos = stepDownTrace.endpos
				onGround = true
			elseif groundAngle > 55 then
				-- Too steep - check if jumpable, otherwise slide
				if not shouldJump then
					local groundCanJump, groundMinTicks = CheckJumpable(currentPos, moveDirection, hitbox, 0)
					if groundCanJump then
						shouldJump = true
						minJumpTicks = groundMinTicks
					else
						-- Slide along steep surface
						local velocityDot = currentVelocity:Dot(groundNormal)
						currentVelocity = currentVelocity - groundNormal * velocityDot
						currentPos = stepDownTrace.endpos
						onGround = false
					end
				else
					-- Jumping over steep surface - stay elevated but limit to original + step height
					local maxAllowedZ = originalZ + stepHeight
					currentPos = Vector3(currentPos.x, currentPos.y, math.min(currentPos.z, maxAllowedZ))
					onGround = false
				end
			else
				-- Moderate slope - stop movement and snap to surface
				currentVelocity = Vector3(0, 0, 0)
				currentPos = stepDownTrace.endpos
				onGround = true
			end
		else
			-- Ground is too far down - we're falling or jumping
			-- Limit maximum elevation to prevent flying into ceiling
			local maxAllowedZ = originalZ + stepHeight
			if currentPos.z > maxAllowedZ then
				currentPos = Vector3(currentPos.x, currentPos.y, maxAllowedZ)
			end
			onGround = false
		end
	else
		-- No ground found - limit elevation and mark as airborne
		local maxAllowedZ = originalZ + stepHeight
		currentPos = Vector3(currentPos.x, currentPos.y, math.min(currentPos.z, maxAllowedZ))
		onGround = false
	end

	-- Apply gravity if not on ground
	if not onGround then
		local gravity = 800
		currentVelocity.z = currentVelocity.z - gravity * deltaTime
	end

	return currentPos, hitObstacle, currentVelocity, shouldJump, onGround, minJumpTicks
end

-- Check if we can jump over obstacle at current position
local function CanJumpOverObstacle(pos, moveDir, obstacleHeight, pLocal)
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

	-- Get dynamic hitbox for local player
	local vHitbox = GetPlayerHitbox(pLocal)

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

-- Smart jump detection with proper tick-by-tick simulation
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

	-- Rotate move intent by view angles to get world space direction
	local viewAngles = engine.GetViewAngles()
	local rotatedMoveIntent = RotateVectorByYaw(moveIntent, viewAngles.yaw)

	-- Only proceed if there's actual movement intent
	if rotatedMoveIntent:Length() <= 1 then
		return false
	end

	local moveDir = NormalizeVector(rotatedMoveIntent)
	local currentVel = pLocal:EstimateAbsVelocity()
	local horizontalSpeed = currentVel:Length()

	if horizontalSpeed <= 1 then
		return false
	end

	-- Set initial velocity: move intent direction with current speed
	local initialVelocity = moveDir * horizontalSpeed

	-- Calculate jump peak time in ticks
	local jumpPeakTicks = math.ceil(0.34 / globals.TickInterval()) -- ~271/800 seconds

	-- Initialize simulation path for visualization
	G.SmartJump.SimulationPath = { pLocalPos }

	local currentPos = pLocalPos
	local currentVelocity = initialVelocity
	local hitObstacle = false
	local onGroundState = isPlayerOnGround(pLocal)

	-- Tick-by-tick simulation until we hit jumpable obstacle or reach peak time
	for tick = 1, jumpPeakTicks do
		local newPos, wallHit, newVelocity, shouldJump, newOnGround, minJumpTicks =
			SimulateMovementTick(currentPos, currentVelocity, 18, pLocal, onGroundState)

		-- Store simulation step for visualization
		table.insert(G.SmartJump.SimulationPath, newPos)

		-- Check if we hit jumpable obstacle
		if wallHit and shouldJump then
			hitObstacle = true

			-- Late jump timing: jump when we have minimum ticks needed to clear obstacle
			local remainingTicks = jumpPeakTicks - tick

			if remainingTicks <= minJumpTicks then
				-- Perfect late jump timing
				G.SmartJump.PredPos = newPos
				G.SmartJump.HitObstacle = true
				DebugLog("SmartJump: Late jump at tick %d, minTicks: %d", tick, minJumpTicks)
				return true
			end
		end

		-- Update simulation state for next tick
		currentPos = newPos
		currentVelocity = newVelocity
		onGroundState = newOnGround
	end

	-- Store final simulation results
	G.SmartJump.PredPos = currentPos
	G.SmartJump.HitObstacle = hitObstacle

	DebugLog("SmartJump: Simulation complete, no jumpable obstacle found")
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

		-- Use our own simulation for bhop detection, not library prediction
		if hasMovementIntent then
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

			-- Check if landed using onGround flag
			if onGround then
				G.SmartJump.jumpState = STATE_IDLE
				DebugLog("SmartJump: DESCENDING -> IDLE (landed)")
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

	-- Get dynamic hitbox for visualization
	local vHitbox = GetPlayerHitbox(pLocal)
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

		-- Draw 3D hitbox at jump peek position (cyan AABB)
		local minPoint = vHitbox[1] + G.SmartJump.JumpPeekPos
		local maxPoint = vHitbox[2] + G.SmartJump.JumpPeekPos

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
