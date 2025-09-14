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

-- Simple WalkTo that works wonders (from old Navigation.lua)
function MovementController.walkTo(cmd, player, dest)
	if not (cmd and player and dest) then
		return
	end

	local localPos = player:GetAbsOrigin()

	local result = computeMove(cmd, localPos, dest)
	cmd:SetForwardMove(result.x)
	cmd:SetSideMove(result.y)
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
