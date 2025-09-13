--[[
Movement Controller - Handles physics-accurate player movement
Superior WalkTo implementation with predictive/no-overshoot logic
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local MovementController = {}
local Log = Common.Log.new("MovementController")

-- Constants for physics-accurate movement
local MAX_SPEED = 450 -- Maximum speed the player can move
local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180

-- Ground-physics helpers (synced with server convars)
local DEFAULT_GROUND_FRICTION = 4 -- fallback for sv_friction
local DEFAULT_SV_ACCELERATE = 10 -- fallback for sv_accelerate

local function getGroundFriction()
	local ok, val = pcall(client.GetConVar, "sv_friction")
	if ok and val and val > 0 then
		return val
	end
	return DEFAULT_GROUND_FRICTION
end

local function getGroundMaxDeltaV(player, tick)
	tick = (tick and tick > 0) and tick or 1 / 66.67
	local svA = client.GetConVar("sv_accelerate") or 0
	if svA <= 0 then
		svA = DEFAULT_SV_ACCELERATE
	end

	local cap = player and player:GetPropFloat("m_flMaxspeed") or MAX_SPEED
	if not cap or cap <= 0 then
		cap = MAX_SPEED
	end

	return svA * cap * tick
end

-- Computes the move vector between two points
local function computeMove(userCmd, a, b)
	local dx, dy = b.x - a.x, b.y - a.y

	local targetYaw = (math.atan(dy, dx) + TWO_PI) % TWO_PI
	local _, currentYaw = userCmd:GetViewAngles()
	currentYaw = currentYaw * DEG_TO_RAD

	local yawDiff = (targetYaw - currentYaw + math.pi) % TWO_PI - math.pi

	return Vector3(math.cos(yawDiff) * MAX_SPEED, math.sin(-yawDiff) * MAX_SPEED, 0)
end

--[[
    Primary movement function with predictive movement and no-overshoot logic
    @param cmd - User command to modify
    @param player - Player entity
    @param dest - Destination vector
    @return boolean - True if movement was applied, false otherwise
]]
function MovementController.walkTo(cmd, player, dest)
	-- Check if walking is enabled
	if G and G.Menu and G.Menu.Main and G.Menu.Main.EnableWalking == false then
		-- Clear movement commands if walking is disabled
		if cmd then
			cmd:SetForwardMove(0)
			cmd:SetSideMove(0)
			cmd:SetUpMove(0)
			cmd:SetButtons(0)
		end
		return false
	end

	-- Validate inputs
	if not (cmd and player and dest) then
		return false
	end

	-- Get current position and validate
	local pos = player:GetAbsOrigin()
	if not pos then
		return false
	end

	-- Get tick interval with fallback
	local tick = globals.TickInterval()
	if tick <= 0 then
		tick = 1 / 66.67 -- Default to 66.67 tickrate if invalid
	end

	-- Get current horizontal velocity
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0 -- Ignore vertical velocity for ground movement

	-- Predict movement with drag
	local drag = math.max(0, 1 - (getGroundFriction() or 5.2) * tick) -- Default friction if nil
	local velNext = vel * drag
	local predicted = Vector3(pos.x + velNext.x * tick, pos.y + velNext.y * tick, pos.z)

	-- Calculate remaining distance to target after prediction
	local need = dest - predicted
	need.z = 0 -- Keep movement horizontal
	local dist = need:Length()

	-- Stop if we're close enough to the destination
	local stopDistance = 1.5 -- Units to consider as "reached"
	if dist < stopDistance then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return true
	end

	-- Velocity we need at start of next tick to land on dest
	local deltaV = (need / tick) - velNext
	local deltaLen = deltaV:Length()
	if deltaLen < 0.1 then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	-- Accel clamp from sv_accelerate
	local aMax = getGroundMaxDeltaV(player, tick)
	local accelDir = deltaV / deltaLen
	local accelLen = math.min(deltaLen, aMax)

	-- wishspeed proportional to allowed Δv
	local wishSpeed = math.max(MAX_SPEED * (accelLen / aMax), 20)

	-- Overshoot guard
	local maxNoOvershoot = dist / tick
	wishSpeed = math.min(wishSpeed, maxNoOvershoot)
	if wishSpeed < 5 then
		wishSpeed = 0
	end

	-- Convert accelDir into local move inputs
	local dirEnd = pos + accelDir
	local moveVec = computeMove(cmd, pos, dirEnd)
	local fwd = (moveVec.x / MAX_SPEED) * wishSpeed
	local side = (moveVec.y / MAX_SPEED) * wishSpeed

	cmd:SetForwardMove(fwd)
	cmd:SetSideMove(side)
end

-- Handle camera rotation if LookingAhead is enabled
function MovementController.handleCameraRotation(userCmd, targetPos)
	if not G.Menu.Main.LookingAhead then
		return
	end

	local Lib = Common.Lib
	local WPlayer = Lib.TF2.WPlayer
	local pLocalWrapped = WPlayer.GetLocal()
	local angles = Lib.Utils.Math.PositionAngles(pLocalWrapped:GetEyePos(), targetPos)
	angles.x = 0

	local currentAngles = userCmd.viewangles
	local deltaAngles = { x = angles.x - currentAngles.x, y = angles.y - currentAngles.y }
	deltaAngles.y = ((deltaAngles.y + 180) % 360) - 180
	angles = EulerAngles(
		currentAngles.x + deltaAngles.x * 0.05,
		currentAngles.y + deltaAngles.y * G.Menu.Main.smoothFactor,
		0
	)
	engine.SetViewAngles(angles)
end

return MovementController
