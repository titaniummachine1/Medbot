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

--[[ Algorithms ]]
local Greedy = require("MedBot.Algorithms.Greedy")

--[[ Bot Modules ]]
local StateHandler = require("MedBot.Bot.StateHandler")
local CircuitBreaker = require("MedBot.Bot.CircuitBreaker")
-- REMOVED: PathOptimizer - all skipping now handled by NodeSkipper
local MovementDecisions = require("MedBot.Bot.MovementDecisions")
local HealthLogic = require("MedBot.Bot.HealthLogic")

--[[ Additional Systems ]]
local SmartJump = require("MedBot.Bot.SmartJump")
require("MedBot.Bot.ISWalkableTest")
require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")

--[[ Setup ]]
local Lib = Common.Lib
local Notify, WPlayer = Lib.UI.Notify, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

-- Make algorithms globally accessible
G.Greedy = Greedy

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs

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
	elseif G.currentState == G.States.FOLLOWING then
		StateHandler.handleFollowingState(userCmd)
	elseif G.currentState == G.States.STUCK then
		-- Only run stuck logic if walking is enabled (manual override mode = no stuck logic)
		if G.Menu.Main.EnableWalking then
			StateHandler.handleStuckState(userCmd)
		else
			-- Manual mode: just transition back to MOVING, skipping still works
			G.currentState = G.States.MOVING
		end
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

-- Helper: Invalidate current path on game events
-- Forces immediate transition to IDLE for smooth repathing
local function invalidatePath(reason)
	if G.Navigation.path and #G.Navigation.path > 0 then
		Log:Info("Path invalidated: %s", reason)
		Navigation.ClearPath()
		G.currentState = G.States.IDLE
		-- Note: Next frame, IDLE state will generate new path immediately
	end
end

---@param event GameEvent
local function onGameEvent(event)
	local eventName = event:GetName()

	-- Map change - reload navigation
	if eventName == "game_newmap" then
		Log:Info("New map detected, reloading nav file...")
		Navigation.Setup()
		invalidatePath("map changed")
		return
	end

	-- Local player respawned
	if eventName == "localplayer_respawn" then
		invalidatePath("local player respawned")
		return
	end

	-- Player spawned (check if it's us)
	if eventName == "player_spawn" then
		local pLocal = entities.GetLocalPlayer()
		if pLocal then
			local userid = event:GetInt("userid")
			local localUserId = pLocal:GetPropInt("m_iUserID")
			if userid == localUserId then
				invalidatePath("player spawned")
			end
		end
		return
	end

	-- Player death - invalidate path to reconsider targets
	if eventName == "player_death" then
		local pLocal = entities.GetLocalPlayer()
		if pLocal then
			local victim = event:GetInt("userid")
			local localUserId = pLocal:GetPropInt("m_iUserID")

			if victim == localUserId then
				invalidatePath("bot died")
			else
				-- Someone else died - might be heal target
				invalidatePath("player died")
			end
		end
		return
	end

	-- Round events that affect objectives and spawns
	if eventName == "teamplay_round_start" then
		invalidatePath("round started")
		return
	end

	if eventName == "teamplay_round_active" then
		invalidatePath("round active")
		return
	end

	if eventName == "teamplay_round_restart_seconds" then
		invalidatePath("round restarting")
		return
	end

	if eventName == "teamplay_restart_round" then
		invalidatePath("round restart")
		return
	end

	if eventName == "teamplay_setup_finished" then
		invalidatePath("setup finished")
		return
	end

	if eventName == "teamplay_waiting_ends" then
		invalidatePath("waiting ended")
		return
	end

	-- CTF objective events
	if eventName == "ctf_flag_captured" then
		local cappingTeam = event:GetInt("capping_team")
		local cappingTeamScore = event:GetInt("capping_team_score")
		invalidatePath(string.format("flag captured by team %d (score: %d)", cappingTeam, cappingTeamScore))
		return
	end

	if eventName == "teamplay_flag_event" then
		local eventType = event:GetInt("eventtype")
		invalidatePath(string.format("flag event type %d", eventType))
		return
	end

	-- Control point events
	if eventName == "teamplay_point_captured" then
		local cp = event:GetInt("cp")
		local team = event:GetInt("team")
		invalidatePath(string.format("control point %d captured by team %d", cp, team))
		return
	end

	if eventName == "teamplay_point_unlocked" then
		invalidatePath("control point unlocked")
		return
	end

	if eventName == "teamplay_point_locked" then
		invalidatePath("control point locked")
		return
	end

	-- Payload events but it jsut makes things worse i belive
	--[[if eventName == "escort_progress" then
		invalidatePath("payload moved")
		return
	end]]

	-- Team changes
	if eventName == "localplayer_changeteam" then
		invalidatePath("team changed")
		return
	end

	if eventName == "teams_changed" then
		invalidatePath("teams changed")
		return
	end

	-- Arena events
	if eventName == "arena_round_start" then
		invalidatePath("arena round started")
		return
	end

	-- MvM events
	if eventName == "mvm_begin_wave" then
		invalidatePath("MvM wave started")
		return
	end

	if eventName == "mvm_wave_complete" then
		invalidatePath("MvM wave complete")
		return
	end

	if eventName == "mvm_wave_failed" then
		invalidatePath("MvM wave failed")
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
