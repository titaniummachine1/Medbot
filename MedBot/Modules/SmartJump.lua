---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")

-- Use MedBot's globals instead of Movement.Globals
local G = require("MedBot.Utils.Globals")

local SmartJump = {}

local Math = lnxLib.Utils.Math
local Prediction = lnxLib.TF2.Prediction
local WPlayer = lnxLib.TF2.WPlayer

-- Internal variables (for debugging or auxiliary calculations)
local lastAngle = nil ---@type number
local predictedPosition = Vector3(0, 0, 0)
local jumpPeakPosition = Vector3(0, 0, 0)

-- Constants
local JUMP_FRACTION = 0.75 -- Fraction of the jump to consider for landing
local HITBOX_MIN = Vector3(-23.99, -23.99, 0)
local HITBOX_MAX = Vector3(23.99, 23.99, 62) -- always assume ducking
local MAX_JUMP_HEIGHT = Vector3(0, 0, 72) -- Maximum jump height vector
local STEP_HEIGHT = Vector3(0, 0, 18) -- Step height (simulate stepping up)
local MAX_WALKABLE_ANGLE = 45 -- Maximum angle considered walkable
local GRAVITY = 800 -- Gravity per second squared
local JUMP_FORCE = 277 -- Initial vertical boost for a duck jump

-- Rotates a vector by a yaw (in degrees)
local function RotateVectorByYaw(vector, yaw)
	local rad = math.rad(yaw)
	local cosYaw, sinYaw = math.cos(rad), math.sin(rad)
	return Vector3(cosYaw * vector.x - sinYaw * vector.y, sinYaw * vector.x + cosYaw * vector.y, vector.z)
end

-- Normalizes a vector (if nonzero)
local function Normalize(vec)
	local len = vec:Length()
	if len == 0 then
		return vec
	end
	return vec / len
end

-- Returns whether a surface is walkable (its normal's angle is below MAX_WALKABLE_ANGLE)
local function IsSurfaceWalkable(normal)
	local upVector = Vector3(0, 0, 1)
	local angle = math.deg(math.acos(normal:Dot(upVector)))
	return angle < MAX_WALKABLE_ANGLE
end

-- (Optional) Calculates a strafe angle delta.
---@param player Entity?
local function CalcStrafe(player)
	if not player then
		return 0
	end
	local velocityAngle = player:EstimateAbsVelocity():Angles()
	local delta = 0
	if lastAngle then
		delta = Math.NormalizeAngle(velocityAngle.y - lastAngle)
	end
	lastAngle = velocityAngle.y
	return delta
end

-- Computes the peak jump position and its direction based on horizontal velocity.
local function GetJumpPeak(horizontalVelocity, startPos)
	local timeToPeak = JUMP_FORCE / GRAVITY -- time to reach peak height
	local horizontalSpeed = horizontalVelocity:Length() -- horizontal speed
	local distanceTravelled = horizontalSpeed * timeToPeak
	local peakPosition = startPos + Normalize(horizontalVelocity) * distanceTravelled
	local directionToPeak = Normalize(peakPosition - startPos)
	return peakPosition, directionToPeak
end

-- Adjusts the velocity based on the movement input in cmd.
local function AdjustVelocity(cmd)
	if not G.pLocal.entity then
		return Vector3(0, 0, 0)
	end

	local moveInput = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveInput:Length() == 0 then
		return G.pLocal.entity:EstimateAbsVelocity()
	end

	local viewAngles = engine.GetViewAngles()
	local rotatedMoveDir = RotateVectorByYaw(moveInput, viewAngles.yaw)
	local normalizedMoveDir = Normalize(rotatedMoveDir)

	local velocity = G.pLocal.entity:EstimateAbsVelocity()
	local intendedSpeed = math.max(10, velocity:Length())

	-- Check if on ground using MedBot's flag system
	local onGround = (G.pLocal.flags & FL_ONGROUND) ~= 0
	if onGround then
		velocity = normalizedMoveDir * intendedSpeed
	end

	return velocity
end

-- The main smart jump logic.
-- When called from MedBot's OnCreateMove it uses G.pLocal, G.pLocal.flags, etc.
-- It returns true if the conditions for a jump are met and sets G.ShouldJump accordingly.
function SmartJump.Main(cmd)
	local shouldJump = false

	if not G.pLocal.entity then
		G.ShouldJump = false
		return false
	end

	-- Check if smart jump is enabled in MedBot menu
	if not G.Menu.Movement.Smart_Jump then
		G.ShouldJump = false
		return false
	end

	-- Use MedBot's ground detection
	local onGround = (G.pLocal.flags & FL_ONGROUND) ~= 0

	if onGround then
		local adjustedVelocity = AdjustVelocity(cmd)
		local playerPosition = G.pLocal.entity:GetAbsOrigin()
		local jumpPeakPos, jumpDirection = GetJumpPeak(adjustedVelocity, playerPosition)
		jumpPeakPosition = jumpPeakPos -- update (for debugging/visuals)

		local horizontalDistanceToPeak = (jumpPeakPos - playerPosition):Length2D()
		local traceStartPos = playerPosition + STEP_HEIGHT
		local traceEndPos = traceStartPos + (jumpDirection * horizontalDistanceToPeak)

		local forwardTrace =
			engine.TraceHull(traceStartPos, traceEndPos, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)
		predictedPosition = forwardTrace.endpos

		if forwardTrace.fraction < 1 then
			local downwardTrace = engine.TraceHull(
				forwardTrace.endpos,
				forwardTrace.endpos - MAX_JUMP_HEIGHT,
				HITBOX_MIN,
				HITBOX_MAX,
				MASK_PLAYERSOLID_BRUSHONLY
			)
			local groundPosition = downwardTrace.endpos
			predictedPosition = groundPosition

			local landingPosition = groundPosition + (jumpDirection * 10)
			local landingDownwardTrace = engine.TraceHull(
				landingPosition + MAX_JUMP_HEIGHT,
				landingPosition,
				HITBOX_MIN,
				HITBOX_MAX,
				MASK_PLAYERSOLID_BRUSHONLY
			)
			predictedPosition = landingDownwardTrace.endpos

			if landingDownwardTrace.fraction > 0 and landingDownwardTrace.fraction < JUMP_FRACTION then
				if IsSurfaceWalkable(landingDownwardTrace.plane) then
					shouldJump = true
				end
			end
		end
	elseif (cmd.buttons & IN_JUMP) == IN_JUMP then
		shouldJump = true
	end

	G.ShouldJump = shouldJump
	return shouldJump
end

-- Export functions
SmartJump.CalcStrafe = CalcStrafe
SmartJump.GetJumpPeak = GetJumpPeak -- Export for debugging/visualization

return SmartJump
