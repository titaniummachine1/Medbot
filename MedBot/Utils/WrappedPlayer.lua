--[[ WrappedPlayer.lua ]]
-- A proper wrapper for player entities using LNXlib's WPlayer

--[[ Imports ]]
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found in WrappedPlayer!")
local WPlayer = Lib.TF2.WPlayer
assert(WPlayer, "WPlayer not found in LNXlib!")

---@class WrappedPlayer
---@field _basePlayer table Base WPlayer from LNXlib
---@field _rawEntity Entity Raw entity object
local WrappedPlayer = {}
WrappedPlayer.__index = WrappedPlayer

--- Creates a new WrappedPlayer from a TF2 entity
---@param entity Entity The entity to wrap
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromEntity(entity)
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return nil
	end
	local base = WPlayer.FromEntity(entity)
	if not base then
		return nil
	end
	local self = setmetatable({}, WrappedPlayer)
	self._basePlayer = base
	self._rawEntity = entity
	return self
end

--- Create WrappedPlayer from index
---@param index number The entity index
---@return WrappedPlayer|nil The wrapped player or nil if invalid
function WrappedPlayer.FromIndex(index)
	local entity = entities.GetByIndex(index)
	return entity and WrappedPlayer.FromEntity(entity) or nil
end

--- Returns the underlying raw entity
function WrappedPlayer:GetRawEntity()
	return self._rawEntity
end

--- Returns the base WPlayer from LNXlib
function WrappedPlayer:GetBasePlayer()
	return self._basePlayer
end

-- Forward all missing methods to the base player
setmetatable(WrappedPlayer, {
	__index = function(tbl, key)
		local v = rawget(tbl, key)
		if v ~= nil then
			return v
		end
		local fn = WPlayer[key]
		if type(fn) == "function" then
			return function(self, ...)
				return fn(self._basePlayer, ...)
			end
		end
		return fn
	end,
})

--- Returns SteamID64 via Common utility
---@return string|number The player's SteamID64
function WrappedPlayer:GetSteamID64()
	local ent = self._rawEntity
	local idx = ent:GetIndex()
	local info = assert(client.GetPlayerInfo(idx), "Failed to get player info")
	return info.IsBot and info.UserID or assert(steam.ToSteamID64(info.SteamID), "SteamID conversion failed")
end

--- Check if player is on ground via m_fFlags
---@return boolean
function WrappedPlayer:IsOnGround()
	local flags = self._basePlayer:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

--- Eye position
---@return Vector3
function WrappedPlayer:GetEyePos()
	return self._basePlayer:GetAbsOrigin() + self._basePlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
end

--- Eye angles
---@return EulerAngles
function WrappedPlayer:GetEyeAngles()
	local ang = self._basePlayer:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	return EulerAngles(ang.x, ang.y, ang.z)
end

--- Returns the view offset from the player's origin as a Vector3
---@return Vector3 The player's view offset
function WrappedPlayer:GetViewOffset()
	return self._basePlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
end

--- Returns the world position the player is looking at by tracing a ray
---@return Vector3|nil The look position or nil if trace failed
function WrappedPlayer:GetLookPos()
	local eyePos = self:GetEyePos()
	local eyeAng = self:GetEyeAngles()
	local targetPos = eyePos + eyeAng:Forward() * 8192
	local tr = engine.TraceLine(eyePos, targetPos, MASK_SHOT)
	return tr and tr.endpos or nil
end

--- Returns the player's observer mode
---@return number The observer mode
function WrappedPlayer:GetObserverMode()
	return self._basePlayer:GetPropInt("m_iObserverMode")
end

--- Returns the player's observer target wrapper
---@return WrappedPlayer|nil The observer target or nil
function WrappedPlayer:GetObserverTarget()
	local target = self._basePlayer:GetPropEntity("m_hObserverTarget")
	return target and WrappedPlayer.FromEntity(target) or nil
end

--- Returns the next attack time
---@return number The next attack time
function WrappedPlayer:GetNextAttack()
	return self._basePlayer:GetPropFloat("m_flNextAttack")
end

return WrappedPlayer
