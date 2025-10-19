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

-- Predictive/no-overshoot WalkTo (superior implementation)
function MovementController.walkTo(cmd, player, dest)
	if not (cmd and player and dest) then
		return
	end

	local pos = player:GetAbsOrigin()
	if not pos then
		return
	end

	local tick = globals.TickInterval()
	if tick <= 0 then
		tick = 1 / 66.67
	end

	-- Current horizontal velocity (ignore Z) - this is per second, convert to per tick
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0
	local vel_per_tick = vel * tick -- displacement over this tick if we coast

	-- Get max acceleration for this tick
	local maxAccel = getGroundMaxDeltaV(player, tick)

	-- Vector from current position to destination
	local toDest = dest - pos
	toDest.z = 0
	local distToDest = toDest:Length()

	if distToDest < 1.5 then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
	end

	-- Counter-velocity steering: acceleration vector from tip of velocity vector to destination
	-- Place acceleration vector on tip of velocity vector (pos + vel_per_tick), pointing at destination
	local accelVector = toDest - vel_per_tick
	local accelLen = accelVector:Length()

	-- If destination is within reach of acceleration vector this tick, walk directly
	local maxAccelDist = maxAccel * tick
	if accelLen <= maxAccelDist then
		local moveVec = computeMove(cmd, pos, dest)
		cmd:SetForwardMove(moveVec.x)
		cmd:SetSideMove(moveVec.y)
		return
	end

	-- Direction of acceleration vector (this counters velocity and aims at destination)
	local accelDir = accelVector / accelLen

	-- Calculate required velocity change and clamp to physics limits
	local desiredAccel = accelDir * maxAccel

	-- Convert acceleration direction to movement inputs
	local accelEnd = pos + desiredAccel
	local moveVec = computeMove(cmd, pos, accelEnd)

	cmd:SetForwardMove(moveVec.x)
	cmd:SetSideMove(moveVec.y)
end

--- Handle camera rotation if LookingAhead is enabled AND walking is enabled
function MovementController.handleCameraRotation(userCmd, targetPos)
	if not G.Menu.Main.EnableWalking or not G.Menu.Main.LookingAhead then
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
