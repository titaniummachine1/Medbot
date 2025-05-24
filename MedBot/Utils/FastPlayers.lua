-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Simplified per-tick cached player lists for MedBot.

--[[ Imports ]]
--local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local WrappedPlayer = require("MedBot.Utils.WrappedPlayer")

--[[ Module Declaration ]]
local FastPlayers = {}

--[[ Local Caches ]]
local cachedAllPlayers, cachedTeammates, cachedEnemies, cachedLocal

FastPlayers.AllUpdated = false
FastPlayers.TeammatesUpdated = false
FastPlayers.EnemiesUpdated = false

--[[ Private: Reset per-tick caches ]]
local function ResetCaches()
	cachedAllPlayers = nil
	cachedTeammates = nil
	cachedEnemies = nil
	cachedLocal = nil
	FastPlayers.AllUpdated = false
	FastPlayers.TeammatesUpdated = false
	FastPlayers.EnemiesUpdated = false
end

--[[ Simplified validity check ]]
local function isValidPlayer(ent, excludeEnt)
	return ent and ent:IsValid() and ent:IsAlive() and not ent:IsDormant() and ent ~= excludeEnt
end

--[[ Public API ]]

--- Returns list of valid, non-dormant players once per tick.
---@param excludeLocal boolean? exclude local player if true
---@return WrappedPlayer[]
function FastPlayers.GetAll(excludeLocal)
	if FastPlayers.AllUpdated then
		return cachedAllPlayers
	end
	-- Determine entity to skip (local player)
	local skipEnt = excludeLocal and entities.GetLocalPlayer() or nil
	cachedAllPlayers = {}
	-- Gather valid players
	for _, ent in pairs(entities.FindByClass("CTFPlayer") or {}) do
		if isValidPlayer(ent, skipEnt) then
			local wp = WrappedPlayer.FromEntity(ent)
			if wp then
				table.insert(cachedAllPlayers, wp)
			end
		end
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a WrappedPlayer instance, cached after first wrap.
---@return WrappedPlayer?
function FastPlayers.GetLocal()
	if not cachedLocal then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WrappedPlayer.FromEntity(rawLocal) or nil
	end
	return cachedLocal
end

--- Returns list of teammates, optionally excluding local player.
---@param excludeLocal boolean? exclude local player if true
---@return WrappedPlayer[]
function FastPlayers.GetTeammates(excludeLocal)
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll(true)
		end
		cachedTeammates = {}
		local localWP = FastPlayers.GetLocal()
		local ex = excludeLocal and localWP or nil
		local myTeam = localWP and localWP:GetRawEntity():GetTeamNumber()
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				local ent = wp:GetRawEntity()
				if ent and ent:GetTeamNumber() == myTeam and wp ~= ex then
					table.insert(cachedTeammates, wp)
				end
			end
		end
		FastPlayers.TeammatesUpdated = true
	end
	return cachedTeammates
end

--- Returns list of enemies (different team).
---@return WrappedPlayer[]
function FastPlayers.GetEnemies()
	if not FastPlayers.EnemiesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		cachedEnemies = {}
		local localWP = FastPlayers.GetLocal()
		local myTeam = localWP and localWP:GetRawEntity():GetTeamNumber()
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				local ent = wp:GetRawEntity()
				if ent and ent:GetTeamNumber() ~= myTeam then
					table.insert(cachedEnemies, wp)
				end
			end
		end
		FastPlayers.EnemiesUpdated = true
	end
	return cachedEnemies
end

-- Reset caches at the start of every CreateMove tick.
callbacks.Register("CreateMove", "FastPlayers_ResetCaches", ResetCaches)

return FastPlayers
