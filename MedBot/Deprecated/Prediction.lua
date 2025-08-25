-- Prediction.lua
-- Utility for simulating movement and timing jumps
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")

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
