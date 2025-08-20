---@diagnostic disable: duplicate-set-field, undefined-field
---@class SmartJump
local SmartJump = {}

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")

-- Profiler disabled to prevent crashes
local Profiler = nil

-- Disable all profiler functions to prevent crashes
local function ProfilerBeginSystem(name) end
local function ProfilerEndSystem() end

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
