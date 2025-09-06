-- Prediction.lua
-- Utility for simulating movement and timing jumps
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local Prediction = {}

-- Constants (must match SmartJump)
local GRAVITY = 800 -- units per second squared
local JUMP_FORCE = 277 -- initial vertical boost for duck jump
local HITBOX_MIN = Vector3(-23.99, -23.99, 0)
local HITBOX_MAX = Vector3(23.99, 23.99, 82)
local STEP_HEIGHT = 18 -- walkable step height
local SURFACE_LIMIT_ANGLE = 45 -- max walkable surface angle

local vUp = Vector3(0, 0, 1)

-- Check if a surface normal is walkable
local function isSurfaceWalkable(normal)
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	return angle < SURFACE_LIMIT_ANGLE
end

-- Helper: is player grounded
local function isPlayerOnGround(p)
	local flags = p:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

-- Simulate walking forward until hitting an obstacle too high to step
-- player: Entity, maxTicks: number of ticks to simulate (e.g. 33)
-- returns: tickIndex, obstacleHeight, surfaceNormal or nil if no obstacle
function Prediction.SimulateWalkUntilObstacle(player, maxTicks)
	local dt = globals.TickInterval()
	local pos = player:GetAbsOrigin()
	local vel = player:EstimateAbsVelocity()

	for tick = 1, maxTicks do
		if isPlayerOnGround(player) then
			-- Predict horizontal position
			local nextPos = pos + Vector3(vel.x, vel.y, 0) * dt
			-- Hull trace at step height
			local trace = engine.TraceHull(
				pos + Vector3(0, 0, STEP_HEIGHT),
				nextPos + Vector3(0, 0, STEP_HEIGHT),
				HITBOX_MIN,
				HITBOX_MAX,
				MASK_PLAYERSOLID_BRUSHONLY
			)
			if trace.fraction < 1 then
				-- Obstacle found
				local obstacleHeight = trace.endpos.z - pos.z
				return tick, obstacleHeight, trace.plane
			end
		end
		-- Advance physics
		pos = pos + vel * dt
		-- Gravity
		vel.z = vel.z - GRAVITY * dt
	end
	return nil
end

-- Simulate movement for jump peak ticks (tick-based like AutoPeek)
-- Returns: walked distance, final position, hit obstacle flag
function Prediction.SimulateMovementForJumpPeak(startPos, direction, speed)
	local peakTime = JUMP_FORCE / GRAVITY
	local peakTicks = math.ceil(peakTime / globals.TickInterval())

	local dirLen = direction:Length()
	if dirLen == 0 then
		return 0, startPos, false
	end
	local stepDir = direction / dirLen -- normalized

	local currentPos = startPos
	local walked = 0
	local stepSize = speed * globals.TickInterval() -- distance per simulated tick
	
	-- Clear and populate simulation path like AutoPeek's LineDrawList
	G.SmartJump.SimulationPath = {}
	table.insert(G.SmartJump.SimulationPath, startPos)
	if stepSize <= 0 then
		stepSize = 8 -- sensible fallback
	end

	-- Simulate for jump peak ticks (tick-based, not distance-based)
	for tick = 1, peakTicks do
		-- STEP 1: Step up 18 units to account for stairs / small ledges
		local stepUpPos = currentPos + Vector3(0, 0, STEP_HEIGHT)

		-- STEP 2: Forward trace from stepped-up position
		local forwardEnd = stepUpPos + stepDir * stepSize
		local fwdTrace = engine.TraceHull(stepUpPos, forwardEnd, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)

		if fwdTrace.fraction < 1.0 then
			-- Hit obstacle - return final position and obstacle flag
			return walked, currentPos, true
		end

		-- STEP 3: Drop down to find ground
		local dropStart = fwdTrace.endpos
		local dropEnd = dropStart - Vector3(0, 0, STEP_HEIGHT + 1)
		local dropTrace = engine.TraceHull(dropStart, dropEnd, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)
		if dropTrace.fraction >= 1.0 then
			-- No ground within step height => would fall; abort
			break
		end

		-- Update position on ground and distance walked
		currentPos = dropTrace.endpos
		walked = walked + stepSize
		
		-- Add current position to simulation path for visualization
		table.insert(G.SmartJump.SimulationPath, currentPos)
	end

	return walked, currentPos, false
end

-- Check if simulation hit obstacle and do SmartJump logic
-- Returns: canJump (bool), obstaclePos (Vector3), landingPos (Vector3) or nil
function Prediction.CheckJumpFromSimulation(finalPos, hitObstacle, moveDir)
	if not hitObstacle then
		return false, nil, nil -- No obstacle found
	end

	-- Do SmartJump logic on final position where obstacle was hit
	local jumpPeakPos = finalPos + Vector3(0, 0, 72) -- 72 units up for jump clearance

	-- Check for head clipping in roof
	local ceilingTrace = engine.TraceHull(finalPos, jumpPeakPos, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)
	if ceilingTrace.fraction == 0 then
		return false, nil, nil -- Head would clip roof
	end

	-- Move 1 unit forward from jump peak (no trace needed)
	local clearancePos = jumpPeakPos + moveDir * 1

	-- Trace down to find landing
	local downTrace = engine.TraceHull(
		clearancePos,
		clearancePos + Vector3(0, 0, -200),
		HITBOX_MIN,
		HITBOX_MAX,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	if downTrace.fraction < 1.0 and isSurfaceWalkable(downTrace.plane) then
		return true, finalPos, downTrace.endpos
	end

	return false, finalPos, nil -- No valid landing
end

-- Compute time to reach a given height with initial jump force
-- returns time (s) or nil if unreachable
function Prediction.TimeToClearHeight(height)
	local V0 = JUMP_FORCE
	local disc = V0 * V0 - 2 * GRAVITY * height
	if disc <= 0 then
		return nil
	end
	return (V0 - math.sqrt(disc)) / GRAVITY
end

-- Compute minimal horizontal distance to clear an obstacle of height h at speed v
-- v: horizontal speed, height: obstacle height
-- returns distance (units) or nil if unreachable
function Prediction.MinJumpDistance(v, height)
	local t = Prediction.TimeToClearHeight(height)
	if not t then
		return nil
	end
	return v * t
end

return Prediction
