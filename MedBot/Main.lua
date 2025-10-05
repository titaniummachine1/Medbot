--[[ 
MedBot Main Entry Point - Minimal and modular design following black box principles
Delegates all complex logic to focused modules with single responsibilities
]]

--[[ Annotations ]]
---@alias NavConnection { count: integer, connections: integer[] }
---@alias NavNode { id: integer, x: number, y: number, z: number, c: { [1]: NavConnection, [2]: NavConnection, [3]: NavConnection, [4]: NavConnection } }

--[[ Core Dependencies ]]
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local WorkManager = require("MedBot.WorkManager")

--[[ Bot Modules ]]
local StateHandler = require("MedBot.Bot.StateHandler")
local CircuitBreaker = require("MedBot.Bot.CircuitBreaker")
-- REMOVED: PathOptimizer - all skipping now handled by NodeSkipper
local MovementDecisions = require("MedBot.Bot.MovementDecisions")
local HealthLogic = require("MedBot.Bot.HealthLogic")

--[[ Additional Systems ]]
local SmartJump = require("MedBot.Bot.SmartJump")
require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")

--[[ Setup ]]
local Lib = Common.Lib
local Notify, WPlayer = Lib.UI.Notify, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs

-- Helper function: Check if we've reached the target with optimized distance calculation
local function hasReachedTarget(origin, targetPos, touchDistance, touchHeight)
	if not origin or not targetPos then
		return false
	end

	local horizontalDist = Common.Distance2D(origin, targetPos)
	local verticalDist = math.abs(origin.z - targetPos.z)

	return (horizontalDist < touchDistance) and (verticalDist <= touchHeight)
end

-- Initialize current state
G.currentState = G.States.IDLE

--[[ Main Bot Logic - Minimal Entry Point ]]
-- Delegates all complex logic to focused modules with single responsibilities

----@param userCmd UserCmd
local function onCreateMove(userCmd)
	-- Basic validation
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		G.currentState = G.States.IDLE
		Navigation.ClearPath()
		return
	end

	-- Bot disabled check
	if not G.Menu.Main.Enable then
		Navigation.ClearPath()
		G.BotIsMoving = false
		return
	end

	-- Update player state
	G.pLocal.entity = pLocal
	G.pLocal.flags = pLocal:GetPropInt("m_fFlags")
	G.pLocal.Origin = pLocal:GetAbsOrigin()

	-- Handle user input (returns true if user is controlling)
	if StateHandler.handleUserInput(userCmd) then
		return
	end

	-- Periodic maintenance
	local currentTick = globals.TickCount()

	-- Health logic
	HealthLogic.HandleSelfHealing(pLocal)

	-- State machine delegation
	if G.currentState == G.States.IDLE then
		StateHandler.handleIdleState()
	elseif G.currentState == G.States.PATHFINDING then
		StateHandler.handlePathfindingState()
	elseif G.currentState == G.States.MOVING then
		MovementDecisions.handleMovingState(userCmd)
	elseif G.currentState == G.States.STUCK then
		StateHandler.handleStuckState(userCmd)
	end

	-- Work management
	WorkManager.processWorks()
end

--[[ Event Handlers ]]

---@param ctx DrawModelContext
local function onDrawModel(ctx)
	if ctx:GetModelName():find("medkit") then
		local entity = ctx:GetEntity()
		G.World.healthPacks[entity:GetIndex()] = entity:GetAbsOrigin()
	end
end

---@param event GameEvent
local function onGameEvent(event)
	local eventName = event:GetName()

	-- Map change - reload navigation
	if eventName == "game_newmap" then
		Log:Info("New map detected, reloading nav file...")
		Navigation.Setup()
		return
	end

	-- CTF Flag captured - repath since objectives changed
	if eventName == "ctf_flag_captured" then
		local cappingTeam = event:GetInt("capping_team")
		local cappingTeamScore = event:GetInt("capping_team_score")
		Log:Info(
			"CTF Flag captured by team %d (score: %d) - repathing due to objective change",
			cappingTeam,
			cappingTeamScore
		)

		-- Force bot to repath and reconsider target
		if G.currentState == G.States.MOVING or G.currentState == G.States.IDLE then
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0
			if G.Navigation.path then
				G.Navigation.path = {} -- Clear current path to force recalculation
			end
		end
		return
	end

	-- Teamplay flag events (general flag state changes)
	if eventName == "teamplay_flag_event" then
		local eventType = event:GetInt("eventtype")
		Log:Info("Flag event type %d - repathing due to objective change", eventType)

		-- Force bot to repath for any flag event
		if G.currentState == G.States.MOVING or G.currentState == G.States.IDLE then
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0
			if G.Navigation.path then
				G.Navigation.path = {}
			end
		end
		return
	end

	-- Player death - might need to repath if target is dead
	if eventName == "player_death" then
		local victim = event:GetInt("userid")
		local attacker = event:GetInt("attacker")
		local pLocal = entities.GetLocalPlayer()
		if pLocal then
			local localUserId = pLocal:GetPropInt("m_iUserID")
			if victim == localUserId then
				Log:Info("Bot died - clearing path and resetting state")
				G.currentState = G.States.IDLE
				G.lastPathfindingTick = 0
				if G.Navigation.path then
					G.Navigation.path = {}
				end
			end
		end
		return
	end

	-- Round restart - objectives reset
	if eventName == "teamplay_round_restart_seconds" then
		Log:Info("Round restarting - clearing path and resetting state")
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		if G.Navigation.path then
			G.Navigation.path = {}
		end
		return
	end
end

--[[ Initialization ]]

-- Ensure SmartJump callback runs BEFORE MedBot's callback
callbacks.Unregister("CreateMove", "ZMedBot.CreateMove")
callbacks.Unregister("DrawModel", "MedBot.DrawModel")
callbacks.Unregister("FireGameEvent", "MedBot.FireGameEvent")

callbacks.Register("CreateMove", "ZMedBot.CreateMove", onCreateMove) -- Z prefix ensures it runs after SmartJump
callbacks.Register("DrawModel", "MedBot.DrawModel", onDrawModel)
callbacks.Register("FireGameEvent", "MedBot.FireGameEvent", onGameEvent)

-- Initialize navigation if a valid map is loaded
Notify.Alert("MedBot loaded!")
if entities.GetLocalPlayer() then
	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Navigation.Setup()
	else
		Log:Info("Skipping navigation setup - no valid map loaded")
		G.Navigation.nodes = {}
	end

	if G.Menu.Main.CleanupConnections then
		Log:Info("Connection cleanup enabled - this may cause temporary frame drops")
	else
		Log:Info("Connection cleanup is disabled in settings (recommended for performance)")
	end
end

Log:Info("MedBot modular system initialized - %d modules loaded", 7)
