-- fastplayers.lua ─────────────────────────────────────────────────────────
-- FastPlayers: Per-tick cached player lists for MedBot, now using LNXlib's WPlayer directly.
--
-- This version uses LNXlib's WPlayer as the player wrapper, removing the old custom WrappedPlayer.

--[[ Imports ]]
local G = require("MedBot.Core.Globals")
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
local WPlayer = Lib.TF2.WPlayer


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
---@return table[] -- WPlayer[]
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
			local wp = WPlayer.FromEntity(ent)
			if wp then
				table.insert(cachedAllPlayers, wp)
			end
		end
	end
	FastPlayers.AllUpdated = true
	return cachedAllPlayers
end

--- Returns the local player as a WPlayer instance, cached after first wrap.
---@return table|nil -- WPlayer|nil
function FastPlayers.GetLocal()
	if not cachedLocal then
		local rawLocal = entities.GetLocalPlayer()
		cachedLocal = rawLocal and WPlayer.FromEntity(rawLocal) or nil
	end
	return cachedLocal
end

--- Returns list of teammates, optionally excluding local player.
---@param excludeLocal boolean? exclude local player if true
---@return table[] -- WPlayer[]
function FastPlayers.GetTeammates(excludeLocal)
	if not FastPlayers.TeammatesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll(true)
		end
		cachedTeammates = {}
		local localWP = FastPlayers.GetLocal()
		local ex = excludeLocal and localWP or nil
		local myTeam = localWP and localWP:GetTeamNumber()
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() == myTeam and wp ~= ex then
					table.insert(cachedTeammates, wp)
				end
			end
		end
		FastPlayers.TeammatesUpdated = true
	end
	return cachedTeammates
end

--- Returns list of enemies (different team).
---@return table[] -- WPlayer[]
function FastPlayers.GetEnemies()
	if not FastPlayers.EnemiesUpdated then
		if not FastPlayers.AllUpdated then
			FastPlayers.GetAll()
		end
		cachedEnemies = {}
		local localWP = FastPlayers.GetLocal()
		local myTeam = localWP and localWP:GetTeamNumber()
		if myTeam then
			for _, wp in ipairs(cachedAllPlayers) do
				if wp:GetTeamNumber() ~= myTeam then
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
