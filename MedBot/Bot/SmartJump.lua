---@diagnostic disable: duplicate-set-field, undefined-field
---@class SmartJump
-- Detects when the player should jump to clear obstacles
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Utils.Globals")

local Log = Common.Log.new("SmartJump")
Log.Level = 0 -- Default log level

-- Alias for easier access to SmartJump state and constants
local SJ = G.SmartJump
local SJC = G.SmartJump.Constants

-- Utility wrapper to respect debug toggle
local function DebugLog(...)
	if G.Menu.SmartJump and G.Menu.SmartJump.Debug then
		Log:Debug(...)
	end
end

-- SmartJump module
local SmartJump = {}

-- Dynamic hitbox calculation using entity bounds
local function GetPlayerHitbox(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	return { mins, maxs }
end

-- Use Common.Normalize for vector normalization

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
	return angle < 55
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

-- Check if obstacle is jumpable and calculate minimum time needed
local function CheckJumpable(hitPos, moveDirection, hitbox)
	if not moveDirection then
		return false, 0
	end

	-- Move 1 unit forward from hit point
	local checkPos = hitPos + moveDirection * 1
	local abovePos = checkPos + SJC.MAX_JUMP_HEIGHT

	-- Trace down to find obstacle height
	local trace = engine.TraceHull(abovePos, checkPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	-- Check if surface is walkable when we land
	if isSurfaceWalkable(trace.plane) then
		-- Calculate actual obstacle height using (1 - fraction)
		local obstacleHeight = 72 * (1 - trace.fraction)
		if obstacleHeight > 18 then -- skip if obstacle is too small
			-- Calculate minimum time in air to achieve this height
			-- Jump velocity is 271 units/sec, gravity is 800 units/sec^2
			-- Height = v0*t - 0.5*g*t^2, solve for t when height >= obstacleHeight
			local jumpVel = SJC.JUMP_FORCE
			local gravity = SJC.GRAVITY
			local tickInterval = globals.TickInterval()

			-- Time to reach peak: t_peak = jumpVel / gravity
			local timeToPeak = jumpVel / gravity

			-- Height at time t: h = jumpVel*t - 0.5*gravity*t^2
			-- We need h >= obstacleHeight, find minimum t
			local minTicksNeeded = 0
			local maxTicks = math.ceil(timeToPeak / tickInterval)
			-- Convert to seconds for physics calculation
			for tick = 1, maxTicks do
				local t = tick * tickInterval  -- Convert tick to seconds
				-- Calculate height at time t (in units)
				-- jumpVel is in units/s, gravity in units/s²
				local height = jumpVel * t - 0.5 * gravity * t * t
				if height >= obstacleHeight then
					minTicksNeeded = tick
					break
				end
			end

			-- minTimeNeeded is already in ticks from our loop
			-- Add a small safety margin (1 tick) to ensure we clear the obstacle
			local minTicksNeeded = math.max(1, minTicksNeeded + 1)

			G.SmartJump.JumpPeekPos = trace.endpos
			return true, minTicksNeeded
		end
	end

	return false, 0
end

-- Ground-only movement simulation following swing prediction pattern
local function SimulateMovementTick(startPos, velocity, pLocal)
	local upVector = Vector3(0, 0, 1)
	local stepVector = Vector3(0, 0, 18)
	local hitbox = GetPlayerHitbox(pLocal)
	local deltaTime = globals.TickInterval()
	local moveDirection = Common.Normalize(velocity)

	-- Calculate target position
	local targetPos = startPos + (velocity * deltaTime)

	-- Step-up trace
	local startPostrace = engine.TraceHull(startPos + stepVector, startPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local downpstartPos = startPostrace.endpos

	-- Step-up trace
	local uptrace = engine.TraceHull(targetPos + stepVector, targetPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local downpostarget = uptrace.endpos

	-- Forward collision check
	local wallTrace = engine.TraceHull(downpstartPos, downpostarget, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if wallTrace.fraction ~= 0 then
		targetPos = wallTrace.endpos
	else --stop movement on wall
		targetPos = startPos
	end

	-- Snap down to ground
	local Groundtrace = engine.TraceHull(targetPos, targetPos - stepVector, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if Groundtrace.fraction < 1 then
		targetPos = Groundtrace.endpos
	else
		return nil, false, velocity, false, 0
	end

	local hitObstacle = wallTrace.fraction < 1
	local canJump = false
	local minJumpTicks = 30

	if hitObstacle then
		canJump, minJumpTicks = CheckJumpable(targetPos, moveDirection, hitbox)

		-- Wall sliding - slide along wall
		local wallNormal = wallTrace.plane
		local wallAngle = math.deg(math.acos(wallNormal:Dot(upVector)))

		if wallAngle > 55 then
			-- Steep wall - slide along it
			local velocityDot = velocity:Dot(wallNormal)
			velocity = velocity - wallNormal * velocityDot
		end
	end

	return targetPos, hitObstacle, velocity, canJump, minJumpTicks
end

-- Smart jump detection with proper tick-by-tick simulation
local function SmartJumpDetection(cmd, pLocal)
	-- Basic validation - fail fast
	if not pLocal or not isPlayerOnGround(pLocal) then
		return false
	end

	local pLocalPos = pLocal:GetAbsOrigin()
	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	local viewAngles = engine.GetViewAngles()

	-- Handle bot movement if no manual input
	if moveIntent:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()
		moveIntent = Vector3(
			G.BotMovementDirection:Dot(forward) * 450,
			-G.BotMovementDirection:Dot(right) * 450,
			0
		)
	end

	-- Rotate move intent by view angles
	local rotatedMoveIntent = RotateVectorByYaw(moveIntent, viewAngles.yaw)
	if rotatedMoveIntent:Length() <= 1 then
		return false -- No movement intent
	end

	-- Calculate movement direction and speed
	local moveDir = Common.Normalize(rotatedMoveIntent)
	local currentVel = pLocal:EstimateAbsVelocity()
	local horizontalSpeed = currentVel:Length()

	-- Use minimum speed if we have movement intent but low velocity
	if horizontalSpeed <= 1 then
		horizontalSpeed = rotatedMoveIntent:Length() > 1 and 450 or 0
	end

	if horizontalSpeed == 0 then
		return false -- Not moving fast enough
	end

	-- Initialize simulation
	local initialVelocity = moveDir * horizontalSpeed
	local jumpPeakTicks = math.ceil(SJC.JUMP_FORCE / SJC.GRAVITY / globals.TickInterval())
	local currentPos = pLocalPos
	local currentVelocity = initialVelocity

	-- Reset simulation path for visualization
	G.SmartJump.SimulationPath = { currentPos }

	-- Tick-by-tick simulation until we hit jumpable obstacle or reach peak time
	for tick = 1, jumpPeakTicks do
		local newPos, hitObstacle, newVelocity, canJump, minJumpTicks =
			SimulateMovementTick(currentPos, currentVelocity, pLocal)

		-- Stop simulation if no ground found (would be falling)
		if not newPos then
			DebugLog("SmartJump: Simulation stopped - no ground at tick %d", tick)
			break
		end

		-- Store simulation step for visualization
		table.insert(G.SmartJump.SimulationPath, newPos)
		-- Check if we hit a jumpable obstacle
		if hitObstacle and canJump then
			-- Only trigger if we are at the exact tick needed to clear the obstacle
			-- or later, but not before
			if tick <= minJumpTicks then
				G.SmartJump.PredPos = newPos
				G.SmartJump.HitObstacle = true
				DebugLog("SmartJump: Jumping at tick %d (needed: %d)", tick, minJumpTicks)
				return true
			else
				DebugLog("SmartJump: Obstacle detected at tick %d (need tick %d) -> Waiting", tick, minJumpTicks)
				return false
			end
		end

		-- Update simulation state for next tick
		currentPos = newPos
		currentVelocity = newVelocity
	end

	DebugLog("SmartJump: No obstacle within jump peak window")
	return false
end

-- Main SmartJump execution with state machine (user's exact logic with improvements)
function SmartJump.Main(cmd)
	-- Early return if SmartJump is disabled
	if not G.Menu.SmartJump.Enable then
		-- Reset state when disabled
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.ObstacleDetected = false
		SJ.RequestEmergencyJump = false
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() or pLocal:IsDormant() then
		-- Reset state when player is invalid
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.ObstacleDetected = false
		SJ.RequestEmergencyJump = false
		return false
	end

	-- Cache player state
	local onGround = isPlayerOnGround(pLocal)
	local ducking = isPlayerDucking(pLocal)

	-- Handle emergency jump request from stuck detection
	local shouldJump = false
	if G.RequestEmergencyJump then
		shouldJump = true
		G.RequestEmergencyJump = false
		G.LastSmartJumpAttempt = globals.TickCount()
		SJ.jumpState = SJC.STATE_PREPARE_JUMP
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
	-- 3. Not already in a jump state
	-- 4. Actually detects an obstacle ahead
	if onGround and ducking and hasMovementIntent and SJ.jumpState == SJC.STATE_IDLE then
		-- Only trigger if SmartJumpDetection actually finds an obstacle
		local obstacleDetected = SmartJumpDetection(cmd, pLocal)
		if obstacleDetected then
			SJ.jumpState = SJC.STATE_PREPARE_JUMP
			DebugLog("SmartJump: Crouched movement with obstacle detected, initiating jump")
		else
			-- If no obstacle detected while crouched, just stay idle
			DebugLog("SmartJump: Crouched movement but no obstacle detected, staying idle")
		end
	end

	-- State machine for CTAP and jumping (user's exact logic)
	if SJ.jumpState == SJC.STATE_IDLE then
		-- STATE_IDLE: Waiting for jump commands
		-- Only check for smart jump if we have movement intent
		if onGround and hasMovementIntent then
			local smartJumpDetected = SmartJumpDetection(cmd, pLocal)

			if smartJumpDetected or shouldJump then
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
				DebugLog("SmartJump: IDLE -> PREPARE_JUMP (obstacle detected)")
			end
		end
	elseif SJ.jumpState == SJC.STATE_PREPARE_JUMP then
		-- STATE_PREPARE_JUMP: Start crouching
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
		SJ.jumpState = SJC.STATE_CTAP
		DebugLog("SmartJump: PREPARE_JUMP -> CTAP (ducking)")
		return true
	elseif SJ.jumpState == SJC.STATE_CTAP then
		-- STATE_CTAP: Uncrouch and jump
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		cmd:SetButtons(cmd.buttons | IN_JUMP)
		SJ.jumpState = SJC.STATE_ASCENDING
		DebugLog("SmartJump: CTAP -> ASCENDING (unduck + jump)")
		return true
	elseif SJ.jumpState == SJC.STATE_ASCENDING then
		-- STATE_ASCENDING: Player is moving upwards
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		local velocity = pLocal:EstimateAbsVelocity()
		if velocity.z <= 0 then
			SJ.jumpState = SJC.STATE_DESCENDING
			DebugLog("SmartJump: ASCENDING -> DESCENDING (velocity.z <= 0)")
		end
		return true
	elseif SJ.jumpState == SJC.STATE_DESCENDING then
		-- STATE_DESCENDING: Player is falling down
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)

		-- Use our own simulation for bhop detection, not library prediction
		if hasMovementIntent then
			-- Only bhop if there's still an obstacle
			local bhopJump = SmartJumpDetection(cmd, pLocal)
			if bhopJump then
				cmd:SetButtons(cmd.buttons & ~IN_DUCK)
				cmd:SetButtons(cmd.buttons | IN_JUMP)
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
				DebugLog("SmartJump: DESCENDING -> PREPARE_JUMP (bhop with obstacle)")
				return true
			end

			-- Check if landed using onGround flag
			if onGround then
				SJ.jumpState = SJC.STATE_IDLE
				DebugLog("SmartJump: DESCENDING -> IDLE (landed)")
			end
		else
			-- No movement intent, land and return to idle
			if onGround then
				SJ.jumpState = SJC.STATE_IDLE
				DebugLog("SmartJump: DESCENDING -> IDLE (no movement intent)")
			end
		end
		return true
	end

	-- Safety timeout to prevent getting stuck in any state
	if not SJ.stateStartTime then
		SJ.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - SJ.stateStartTime > 132 then -- 2 seconds timeout
		Log:Warn("SmartJump: State timeout, resetting to IDLE from %s", SJ.jumpState)
		SJ.jumpState = SJC.STATE_IDLE
		SJ.stateStartTime = nil
	end

	-- Reset state timer when state changes
	local currentState = SJ.jumpState
	if SJ.lastState ~= currentState then
		SJ.stateStartTime = globals.TickCount()
		SJ.lastState = currentState
	end

	G.ShouldJump = shouldJump
	return shouldJump
end

-- Standalone CreateMove callback for SmartJump (works independently of MedBot)
local function OnCreateMoveStandalone(cmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
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
	if not pLocal or not G.Menu.SmartJump or not G.Menu.SmartJump.Enable then
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
