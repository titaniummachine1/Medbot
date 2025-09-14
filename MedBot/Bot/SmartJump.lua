local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Log = Common.Log.new("SmartJump")

Log.Level = 0
local SJ = G.SmartJump
local SJC = G.SmartJump.Constants

local function DebugLog(...)
	if G.Menu.SmartJump and G.Menu.SmartJump.Debug then
		Log:Debug(...)
	end
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function GetPlayerHitbox(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	return {
		mins,
		maxs,
	}
end

local function RotateVectorByYaw(vector, yaw)
	local rad = math.rad(yaw)
	local cos, sin = math.cos(rad), math.sin(rad)
	return Vector3(cos * vector.x - sin * vector.y, sin * vector.x + cos * vector.y, vector.z)
end

local function isSurfaceWalkable(normal)
	local vUp = Vector3(0, 0, 1)
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	return angle < 55
end

local function isPlayerOnGround(player)
	local pFlags = player:GetPropInt("m_fFlags")
	return pFlags & FL_ONGROUND == FL_ONGROUND
end

local function isPlayerDucking(player)
	return player:GetPropInt("m_fFlags") & FL_DUCKING == FL_DUCKING
end

local SmartJump = {}

-- ============================================================================
-- OBSTACLE DETECTION AND JUMP CALCULATION
-- ============================================================================

local function CheckJumpable(hitPos, moveDirection, hitbox)
	if not moveDirection then
		return false, 0
	end

	local checkPos = hitPos + moveDirection * 1
	local abovePos = checkPos + SJC.MAX_JUMP_HEIGHT

	-- Perform the trace and get detailed results
	local trace = engine.TraceHull(abovePos, checkPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	if isSurfaceWalkable(trace.plane) then
		-- FIXED: Calculate obstacle height from actual trace distance, not hardcoded 72
		local traceLength = (abovePos - checkPos):Length()
		local obstacleHeight = traceLength * (1 - trace.fraction)

		-- Debug output for troubleshooting
		local jumpMaxHeight = (SJC.JUMP_FORCE ^ 2) / (2 * SJC.GRAVITY)

		if obstacleHeight > 18 then
			G.SmartJump.LastObstacleHeight = hitPos.z + obstacleHeight
			local jumpVel = SJC.JUMP_FORCE
			local gravity = SJC.GRAVITY

			-- FIXED: Use exact physics equation instead of iteration
			-- Quadratic formula: height = jumpVel*t - 0.5*gravity*t^2
			-- Solve for t: t = (jumpVel - sqrt(jumpVel^2 - 2*gravity*obstacleHeight)) / gravity
			local discriminant = jumpVel ^ 2 - 2 * gravity * obstacleHeight
			local minTicksNeeded = 0

			if discriminant >= 0 then
				local t = (jumpVel - math.sqrt(discriminant)) / gravity
				local tickInterval = globals.TickInterval()
				minTicksNeeded = math.ceil(t / tickInterval)
			end

			G.SmartJump.JumpPeekPos = trace.endpos
			return true, minTicksNeeded
		end
	end
	return false, 0
end

-- ============================================================================
-- MOVEMENT SIMULATION
-- ============================================================================

local function SimulateMovementTick(startPos, velocity, pLocal)
	local upVector = Vector3(0, 0, 1)
	local stepVector = Vector3(0, 0, 18)
	local hitbox = GetPlayerHitbox(pLocal)
	local deltaTime = globals.TickInterval()
	local moveDirection = Common.Normalize(velocity)
	local targetPos = startPos + velocity * deltaTime

	local startPostrace = engine.TraceHull(startPos + stepVector, startPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local downpstartPos = startPostrace.endpos
	local uptrace = engine.TraceHull(targetPos + stepVector, targetPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local downpostarget = uptrace.endpos
	local wallTrace =
		engine.TraceHull(downpstartPos + stepVector, downpostarget + stepVector, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	if wallTrace.fraction ~= 0 then
		targetPos = wallTrace.endpos
	else
		targetPos = startPos
		return nil, false, velocity, false, 0
	end

	local Groundtrace = engine.TraceHull(targetPos, targetPos - stepVector * 2, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if Groundtrace.fraction < 1 then
		targetPos = Groundtrace.endpos
	else
		return nil, false, velocity, false, 0
	end

	Groundtrace = engine.TraceHull(targetPos, targetPos - stepVector, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
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
		local wallNormal = wallTrace.plane
		local wallAngle = math.deg(math.acos(wallNormal:Dot(upVector)))

		if wallAngle > 55 then
			local velocityDot = velocity:Dot(wallNormal)
			velocity = velocity - wallNormal * velocityDot
		end
	end

	return targetPos, hitObstacle, velocity, canJump, minJumpTicks
end
-- ============================================================================
-- SMART JUMP DETECTION
-- ============================================================================

local function SmartJumpDetection(cmd, pLocal)
	if not pLocal or (not isPlayerOnGround(pLocal)) then
		return false
	end

	local pLocalPos = pLocal:GetAbsOrigin()
	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	local viewAngles = engine.GetViewAngles()

	if moveIntent:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()
		moveIntent = Vector3(G.BotMovementDirection:Dot(forward) * 450, (-G.BotMovementDirection:Dot(right)) * 450, 0)
	end

	local rotatedMoveIntent = RotateVectorByYaw(moveIntent, viewAngles.yaw)
	if rotatedMoveIntent:Length() <= 1 then
		return false
	end

	local moveDir = Common.Normalize(rotatedMoveIntent)
	local currentVel = pLocal:EstimateAbsVelocity()
	local horizontalSpeed = currentVel:Length()

	if horizontalSpeed <= 1 then
		horizontalSpeed = rotatedMoveIntent:Length() > 1 and 450 or 0
	end

	if horizontalSpeed == 0 then
		return false
	end

	local initialVelocity = moveDir * horizontalSpeed
	local jumpPeakTicks = math.ceil(SJC.JUMP_FORCE / SJC.GRAVITY / globals.TickInterval())
	local currentPos = pLocalPos
	local currentVelocity = initialVelocity

	G.SmartJump.SimulationPath = {
		currentPos,
	}

	for tick = 1, jumpPeakTicks do
		local newPos, hitObstacle, newVelocity, canJump, minJumpTicks =
			SimulateMovementTick(currentPos, currentVelocity, pLocal)

		if not newPos then
			DebugLog("SmartJump: Simulation stopped - no ground at tick %d", tick)
			break
		end

		table.insert(G.SmartJump.SimulationPath, newPos)

		if hitObstacle and canJump then
			--print(tick, minJumpTicks)

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

		currentPos = newPos
		currentVelocity = newVelocity
	end

	DebugLog("SmartJump: No obstacle within jump peak window")
	return false
end
-- ============================================================================
-- MAIN SMART JUMP LOGIC
-- ============================================================================

function SmartJump.Main(cmd)
	if not G.Menu.SmartJump.Enable then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.ObstacleDetected = false
		SJ.RequestEmergencyJump = false
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or (not pLocal:IsAlive()) or pLocal:IsDormant() then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.ObstacleDetected = false
		SJ.RequestEmergencyJump = false
		return false
	end

	local onGround = isPlayerOnGround(pLocal)
	local ducking = isPlayerDucking(pLocal)
	local shouldJump = false

	if G.RequestEmergencyJump then
		shouldJump = true
		G.RequestEmergencyJump = false
		G.LastSmartJumpAttempt = globals.TickCount()
		SJ.jumpState = SJC.STATE_PREPARE_JUMP
		Log:Info("SmartJump: Processing emergency jump request")
	end

	local hasMovementIntent = false
	local moveDir = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveDir:Length() > 0 or G.BotIsMoving and G.BotMovementDirection and G.BotMovementDirection:Length() > 0 then
		hasMovementIntent = true
	end

	if onGround and ducking and hasMovementIntent and SJ.jumpState == SJC.STATE_IDLE then
		local obstacleDetected = SmartJumpDetection(cmd, pLocal)
		if obstacleDetected then
			SJ.jumpState = SJC.STATE_PREPARE_JUMP
			DebugLog("SmartJump: Crouched movement with obstacle detected, initiating jump")
		else
			DebugLog("SmartJump: Crouched movement but no obstacle detected, staying idle")
		end
	end

	if SJ.jumpState == SJC.STATE_IDLE then
		if onGround and hasMovementIntent then
			local smartJumpDetected = SmartJumpDetection(cmd, pLocal)
			if smartJumpDetected or shouldJump then
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
				DebugLog("SmartJump: IDLE -> PREPARE_JUMP (obstacle detected)")
			end
		end
	elseif SJ.jumpState == SJC.STATE_PREPARE_JUMP then
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
		SJ.jumpState = SJC.STATE_CTAP
		DebugLog("SmartJump: PREPARE_JUMP -> CTAP (ducking)")
	elseif SJ.jumpState == SJC.STATE_CTAP then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		cmd:SetButtons(cmd.buttons | IN_JUMP)
		SJ.jumpState = SJC.STATE_ASCENDING
		DebugLog("SmartJump: CTAP -> ASCENDING (unduck + jump)")
	elseif SJ.jumpState == SJC.STATE_ASCENDING then
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		local velocity = pLocal:EstimateAbsVelocity()
		local currentPos = pLocal:GetAbsOrigin()

		-- Check if we should unduck (improve duck grab logic)
		local shouldUnduck = velocity.z <= 0 -- Always unduck when falling

		-- If Duck_Grab is enabled and we have obstacle height info, do improved check
		if not shouldUnduck and G.Menu.Main.Duck_Grab and G.SmartJump.LastObstacleHeight then
			local playerHeight = currentPos.z

			-- Only consider unducking if we're above the obstacle
			if playerHeight > G.SmartJump.LastObstacleHeight then
				-- IMPROVED: Trace down from player position + obstacle height + 1
				local traceStart = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight + 1)
				local traceEnd = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight - 10)
				local hitbox = GetPlayerHitbox(pLocal)
				local obstacleTrace = engine.TraceHull(traceStart, traceEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

				-- If trace hits something, obstacle is still there - safe to unduck
				if obstacleTrace.fraction < 1 then
					shouldUnduck = true
					DebugLog("SmartJump: Unducking - obstacle confirmed at height %.1f", G.SmartJump.LastObstacleHeight)
				else
					DebugLog(
						"SmartJump: Staying ducked - no obstacle detected at height %.1f",
						G.SmartJump.LastObstacleHeight
					)
				end
			end
		end

		if shouldUnduck then
			SJ.jumpState = SJC.STATE_DESCENDING
			DebugLog("SmartJump: ASCENDING -> DESCENDING (improved duck grab check)")
		end
	elseif SJ.jumpState == SJC.STATE_DESCENDING then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)

		if hasMovementIntent then
			local bhopJump = SmartJumpDetection(cmd, pLocal)
			if bhopJump then
				cmd:SetButtons(cmd.buttons & ~IN_DUCK)
				cmd:SetButtons(cmd.buttons | IN_JUMP)
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
				DebugLog("SmartJump: DESCENDING -> PREPARE_JUMP (bhop with obstacle)")
			end

			if onGround then
				SJ.jumpState = SJC.STATE_IDLE
				DebugLog("SmartJump: DESCENDING -> IDLE (landed)")
			end
		elseif onGround then
			SJ.jumpState = SJC.STATE_IDLE
			DebugLog("SmartJump: DESCENDING -> IDLE (no movement intent)")
		end
	end

	if not SJ.stateStartTime then
		SJ.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - SJ.stateStartTime > 132 then
		Log:Warn("SmartJump: State timeout, resetting to IDLE from %s", SJ.jumpState)
		SJ.jumpState = SJC.STATE_IDLE
		SJ.stateStartTime = nil
	end

	local currentState = SJ.jumpState
	if SJ.lastState ~= currentState then
		SJ.stateStartTime = globals.TickCount()
		SJ.lastState = currentState
	end

	G.ShouldJump = shouldJump
	return shouldJump
end

-- ============================================================================
-- VISUALIZATION AND CALLBACKS
-- ============================================================================

local function OnCreateMoveStandalone(cmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or (not pLocal:IsAlive()) then
		return
	end
	SmartJump.Main(cmd)
end

local function OnDrawSmartJump()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not G.Menu.SmartJump or not G.Menu.SmartJump.Enable then
		return
	end

	local vHitbox = GetPlayerHitbox(pLocal)
	if G.SmartJump.PredPos then
		local screenPos = client.WorldToScreen(G.SmartJump.PredPos)
		if screenPos then
			draw.Color(255, 0, 0, 255)
			draw.FilledRect(screenPos[1] - 5, screenPos[2] - 5, screenPos[1] + 5, screenPos[2] + 5)
		end
	end

	if G.SmartJump.JumpPeekPos then
		local screenpeekpos = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if screenpeekpos then
			draw.Color(0, 255, 0, 255)
			draw.FilledRect(screenpeekpos[1] - 5, screenpeekpos[2] - 5, screenpeekpos[1] + 5, screenpeekpos[2] + 5)
		end

		local minPoint = vHitbox[1] + G.SmartJump.JumpPeekPos
		local maxPoint = vHitbox[2] + G.SmartJump.JumpPeekPos
		local vertices = {
			Vector3(minPoint.x, minPoint.y, minPoint.z),
			Vector3(minPoint.x, maxPoint.y, minPoint.z),
			Vector3(maxPoint.x, maxPoint.y, minPoint.z),
			Vector3(maxPoint.x, minPoint.y, minPoint.z),
			Vector3(minPoint.x, minPoint.y, maxPoint.z),
			Vector3(minPoint.x, maxPoint.y, maxPoint.z),
			Vector3(maxPoint.x, maxPoint.y, maxPoint.z),
			Vector3(maxPoint.x, minPoint.y, maxPoint.z),
		}

		for i, vertex in ipairs(vertices) do
			vertices[i] = client.WorldToScreen(vertex)
		end

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
			draw.Color(0, 255, 255, 255)
			draw.Line(vertices[1][1], vertices[1][2], vertices[2][1], vertices[2][2])
			draw.Line(vertices[2][1], vertices[2][2], vertices[3][1], vertices[3][2])
			draw.Line(vertices[3][1], vertices[3][2], vertices[4][1], vertices[4][2])
			draw.Line(vertices[4][1], vertices[4][2], vertices[1][1], vertices[1][2])
			draw.Line(vertices[5][1], vertices[5][2], vertices[6][1], vertices[6][2])
			draw.Line(vertices[6][1], vertices[6][2], vertices[7][1], vertices[7][2])
			draw.Line(vertices[7][1], vertices[7][2], vertices[8][1], vertices[8][2])
			draw.Line(vertices[8][1], vertices[8][2], vertices[5][1], vertices[5][2])
			draw.Line(vertices[1][1], vertices[1][2], vertices[5][1], vertices[5][2])
			draw.Line(vertices[2][1], vertices[2][2], vertices[6][1], vertices[6][2])
			draw.Line(vertices[3][1], vertices[3][2], vertices[7][1], vertices[7][2])
			draw.Line(vertices[4][1], vertices[4][2], vertices[8][1], vertices[8][2])
		end
	end

	if G.SmartJump.SimulationPath and #G.SmartJump.SimulationPath > 1 then
		for i = 1, #G.SmartJump.SimulationPath - 1 do
			local currentPos = G.SmartJump.SimulationPath[i]
			local nextPos = G.SmartJump.SimulationPath[i + 1]
			local currentScreen = client.WorldToScreen(currentPos)
			local nextScreen = client.WorldToScreen(nextPos)
			if currentScreen and nextScreen then
				local alpha = math.floor(100 + i / #G.SmartJump.SimulationPath * 155)
				draw.Color(0, 150, 255, alpha)
				draw.Line(currentScreen[1], currentScreen[2], nextScreen[1], nextScreen[2])
			end
		end
	end

	if G.SmartJump.JumpPeekPos then
		local landingScreen = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if landingScreen then
			draw.Color(0, 255, 255, 255)
			draw.FilledRect(landingScreen[1] - 4, landingScreen[2] - 4, landingScreen[1] + 4, landingScreen[2] + 4)
		end
	end

	draw.Color(255, 255, 255, 255)
	draw.Text(10, 100, "SmartJump State: " .. (G.SmartJump.jumpState or "UNKNOWN"))

	if G.SmartJump.HitObstacle then
		draw.Text(10, 120, "Obstacle Detected: YES")
	else
		draw.Text(10, 120, "Obstacle Detected: NO")
	end
end

-- ============================================================================
-- MODULE INITIALIZATION
-- ============================================================================

callbacks.Unregister("CreateMove", "SmartJump.Standalone")
callbacks.Register("CreateMove", "SmartJump.Standalone", OnCreateMoveStandalone)
callbacks.Unregister("Draw", "SmartJump.Visual")
callbacks.Register("Draw", "SmartJump.Visual", OnDrawSmartJump)

return SmartJump
