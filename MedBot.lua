local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = {[{}] = true}

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
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

-- Profiler removed - not used

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
require("MedBot.Bot.OptimizedISWalkableTest")
require("MedBot.Bot.IsNavigableTest")
require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")

--[[ Setup ]]
local Lib = Common.Lib
local Notify, WPlayer = Lib.UI.Notify, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

-- Make modules globally accessible
G.Greedy = Greedy
G.Navigation = Navigation

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs

-- Initialize current state
G.currentState = G.States.IDLE

--[[ Main Bot Logic - Minimal Entry Point ]]
-- Delegates all complex logic to focused modules with single responsibilities

----@param userCmd UserCmd
local function onCreateMove(userCmd)
	-- Profiler removed

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

-- Profiler removed

--[[ Initialization ]]

-- Ensure SmartJump callback runs BEFORE MedBot's callback
callbacks.Unregister("CreateMove", "ZMedBot.CreateMove")
callbacks.Unregister("DrawModel", "MedBot.DrawModel")
callbacks.Unregister("FireGameEvent", "MedBot.FireGameEvent")
callbacks.Unregister("Draw", "MedBot.ProfilerDraw")

callbacks.Register("CreateMove", "ZMedBot.CreateMove", onCreateMove) -- Z prefix ensures it runs after SmartJump
callbacks.Register("DrawModel", "MedBot.DrawModel", onDrawModel)
callbacks.Register("FireGameEvent", "MedBot.FireGameEvent", onGameEvent)
-- Profiler removed

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

end)
__bundle_register("MedBot.Menu", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[debug commands
    client.SetConVar("cl_vWeapon_sway_interp",              0)             -- Set cl_vWeapon_sway_interp to 0
    client.SetConVar("cl_jiggle_bone_framerate_cutoff", 0)             -- Set cl_jiggle_bone_framerate_cutoff to 0
    client.SetConVar("cl_bobcycle",                     10000)         -- Set cl_bobcycle to 10000
    client.SetConVar("sv_cheats", 1)                                    -- debug fast setup
    client.SetConVar("mp_disable_respawn_times", 1)
    client.SetConVar("mp_respawnwavetime", -1)
    client.SetConVar("mp_teams_unbalance_limit", 1000)

    -- debug command: ent_fire !picker Addoutput "health 99999" --superbot
]]
local MenuModule = {}

-- Import globals
local G = require("MedBot.Core.Globals")
-- local Node = require("MedBot.Navigation.Node")  -- Temporarily disabled
-- local Visuals = require("MedBot.Visuals")       -- Temporarily disabled

-- Try loading TimMenu
---@type boolean, table
local menuLoaded, TimMenu = pcall(require, "TimMenu")
assert(menuLoaded, "TimMenu not found, please install it!")

-- Draw the menu
local function OnDrawMenu()
	-- Only draw when the Lmaobox menu is open
	if not gui.IsMenuOpen() then
		return
	end

	-- Begin the menu and store the result
	if not TimMenu.Begin("MedBot Control") then
		return
	end
	-- Tab control
	G.Menu.Tab = TimMenu.TabControl("MedBotTabs", { "Main", "Navigation", "Visuals" }, G.Menu.Tab)
	TimMenu.NextLine()

	if G.Menu.Tab == "Main" then
		-- Bot Control Section
		TimMenu.BeginSector("Bot Control")
		G.Menu.Main.Enable = TimMenu.Checkbox("Enable Pathfinding", G.Menu.Main.Enable)
		TimMenu.Tooltip("Enables the main bot functionality")
		TimMenu.NextLine()

		-- Add Enable Walking toggle
		-- Initialize EnableWalking to true if not set
		if G.Menu.Main.EnableWalking == nil then
			G.Menu.Main.EnableWalking = true
		end
		local newWalkingValue = TimMenu.Checkbox("Enable Walking", G.Menu.Main.EnableWalking)
		-- Only update if value changed to avoid flickering
		if newWalkingValue ~= G.Menu.Main.EnableWalking then
			G.Menu.Main.EnableWalking = newWalkingValue
		end
		TimMenu.Tooltip("Enable/disable bot movement (pathfinding still works)")
		TimMenu.NextLine()

		G.Menu.Main.SelfHealTreshold = TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
		TimMenu.NextLine()

		G.Menu.Main.LookingAhead = TimMenu.Checkbox("Auto Rotate Camera", G.Menu.Main.LookingAhead or false)
		TimMenu.Tooltip("Enable automatic camera rotation towards target node (disable for manual camera control)")
		TimMenu.NextLine()

		G.Menu.Main.smoothFactor = G.Menu.Main.smoothFactor or 0.1
		G.Menu.Main.smoothFactor = TimMenu.Slider("Smooth Factor", G.Menu.Main.smoothFactor, 0.01, 1, 0.01)
		TimMenu.Tooltip("Camera rotation smoothness (only when Auto Rotate Camera is enabled)")
		TimMenu.EndSector()

		TimMenu.NextLine()

		-- Smart Jump (works independently of MedBot enable state)
		G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable)
		TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")
		TimMenu.EndSector()
	elseif G.Menu.Tab == "Navigation" then
		-- Movement & Pathfinding Section
		TimMenu.BeginSector("Pathfinding Settings")
		-- Store previous value to detect changes
		local prevSkipNodes = G.Menu.Navigation.Skip_Nodes
		G.Menu.Navigation.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Navigation.Skip_Nodes)
		-- Only update if value changed to avoid flickering
		if G.Menu.Navigation.Skip_Nodes ~= prevSkipNodes then
			-- Clear path to force recalculation with new setting
			if G.Navigation then
				G.Navigation.path = {}
			end
		end
		TimMenu.Tooltip("Allow skipping nodes when direct path is walkable (handles all optimization)")
		TimMenu.NextLine()

		-- Max Skip Range slider
		G.Menu.Main.MaxSkipRange = G.Menu.Main.MaxSkipRange or 500
		G.Menu.Main.MaxSkipRange = TimMenu.Slider("Max Skip Range", G.Menu.Main.MaxSkipRange, 100, 2000, 50)
		TimMenu.Tooltip("Maximum distance to skip nodes in units (default: 500)")
		TimMenu.NextLine()

		-- Max Nodes To Skip slider
		G.Menu.Main.MaxNodesToSkip = G.Menu.Main.MaxNodesToSkip or 3
		G.Menu.Main.MaxNodesToSkip = TimMenu.Slider("Max Nodes To Skip", G.Menu.Main.MaxNodesToSkip, 1, 10, 1)
		TimMenu.Tooltip("Maximum nodes to skip per tick (default: 3)")
		TimMenu.NextLine()

		-- Stop Distance slider for FOLLOWING state
		G.Menu.Navigation.StopDistance = G.Menu.Navigation.StopDistance or 50
		G.Menu.Navigation.StopDistance = TimMenu.Slider("Stop Distance", G.Menu.Navigation.StopDistance, 20, 200, 5)
		TimMenu.Tooltip("Distance to stop from dynamic targets like payload (FOLLOWING state)")
		TimMenu.NextLine()

		G.Menu.Navigation.WalkableMode = G.Menu.Navigation.WalkableMode or "Smooth"
		local walkableModes = { "Smooth", "Aggressive" }
		-- Get current mode as index number
		local currentModeIndex = (G.Menu.Navigation.WalkableMode == "Aggressive") and 2 or 1

		-- TimMenu.Selector expects a number, not a table
		local selectedIndex = TimMenu.Selector("Walkable Mode", currentModeIndex, walkableModes)

		-- Update the mode based on selection
		if selectedIndex == 1 then
			G.Menu.Navigation.WalkableMode = "Smooth"
		elseif selectedIndex == 2 then
			G.Menu.Navigation.WalkableMode = "Aggressive"
		end

		TimMenu.Tooltip("Smooth uses 18-unit steps, Aggressive allows 72-unit jumps")
		TimMenu.EndSector()

		TimMenu.NextLine()

		-- Advanced Navigation Settings
		TimMenu.BeginSector("Advanced Settings")
		G.Menu.Navigation.CleanupConnections =
			TimMenu.Checkbox("Cleanup Invalid Connections", G.Menu.Navigation.CleanupConnections or false)
		TimMenu.Tooltip("Clean up navigation connections on map load (DISABLE if causing performance issues)")
		TimMenu.NextLine()

		-- Connection processing status display
		if G.Menu.Navigation.CleanupConnections then
			local status = { isProcessing = false }
			if status.isProcessing then
				local phaseNames = {
					[1] = "Basic validation",
					[2] = "Expensive fallback",
					[3] = "Stair patching",
					[4] = "Fine point stitching",
				}
				TimMenu.Text(
					string.format(
						"Processing Connections: Phase %d (%s)",
						status.currentPhase,
						phaseNames[status.currentPhase] or "Unknown"
					)
				)
				TimMenu.NextLine()
				TimMenu.Text(
					string.format(
						"Progress: %d/%d nodes (FPS: %.1f)",
						status.processedNodes,
						status.totalNodes,
						status.currentFPS
					)
				)
				TimMenu.NextLine()
				TimMenu.Text(
					string.format(
						"Found: %d connections, Expensive: %d, Fine points: %d",
						status.connectionsFound,
						status.expensiveChecksUsed,
						status.finePointConnectionsAdded
					)
				)
				TimMenu.NextLine()
			end
		end

		TimMenu.EndSector()
	elseif G.Menu.Tab == "Visuals" then
		-- Visual Settings Section
		TimMenu.BeginSector("Visual Settings")
		G.Menu.Visuals.Debug_Mode = TimMenu.Checkbox("Debug Mode", G.Menu.Visuals.Debug_Mode or false)
		TimMenu.Tooltip("Enable debug visuals and verbose logging for troubleshooting")
		TimMenu.NextLine()
		-- Initialize only if nil (not false)
		if G.Menu.Visuals.EnableVisuals == nil then
			G.Menu.Visuals.EnableVisuals = true
		end
		G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
		TimMenu.NextLine()

		-- Draw depth for flood-fill visualization (controls how far from player to render navmesh)
		G.Menu.Visuals.connectionDepth = G.Menu.Visuals.connectionDepth or 10
		G.Menu.Visuals.connectionDepth = TimMenu.Slider("Draw Depth", G.Menu.Visuals.connectionDepth, 1, 50, 1)
		TimMenu.Tooltip(
			"How many connection steps away from player to visualize (1 = only current node, 50 = maximum range). Controls flood-fill rendering of all navmesh elements except path arrows."
		)
		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()

		-- Display Section
		TimMenu.BeginSector("Display Options")

		-- Multi-selection combo for all visual elements
		local visualElements = { "Areas", "Doors", "Wall Corners", "Connections", "D2D Connections" }
		local visualSelections = {
			G.Menu.Visuals.showAreas or false,
			G.Menu.Visuals.showDoors or false,
			G.Menu.Visuals.showCornerConnections or false,
			G.Menu.Visuals.showConnections == nil and true or G.Menu.Visuals.showConnections, -- Default ON
			G.Menu.Visuals.showD2D or false,
		}

		local newSelections = TimMenu.Combo("Visual Elements", visualSelections, visualElements)

		-- Update state based on selections
		G.Menu.Visuals.showAreas = newSelections[1]
		G.Menu.Visuals.showDoors = newSelections[2]
		G.Menu.Visuals.showCornerConnections = newSelections[3]
		G.Menu.Visuals.showConnections = newSelections[4]
		G.Menu.Visuals.showD2D = newSelections[5]
		TimMenu.NextLine()

		-- Additional visual options
		G.Menu.Visuals.showAgentBoxes = G.Menu.Visuals.showAgentBoxes or false
		G.Menu.Visuals.showAgentBoxes = TimMenu.Checkbox("Show Agent Boxes", G.Menu.Visuals.showAgentBoxes)

		G.Menu.Visuals.drawPath = G.Menu.Visuals.drawPath or false
		G.Menu.Visuals.drawPath = TimMenu.Checkbox("Draw Path", G.Menu.Visuals.drawPath)
		TimMenu.NextLine()

		G.Menu.Visuals.memoryUsage = G.Menu.Visuals.memoryUsage or false
		G.Menu.Visuals.memoryUsage = TimMenu.Checkbox("Show Memory Usage", G.Menu.Visuals.memoryUsage)
		TimMenu.NextLine()

		G.Menu.Visuals.showNodeIds = G.Menu.Visuals.showNodeIds or false
		G.Menu.Visuals.showNodeIds = TimMenu.Checkbox("Show Node IDs", G.Menu.Visuals.showNodeIds)
		TimMenu.Tooltip("Display node ID numbers on the map for debugging")
		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()

		-- SmartJump Visualization Section
		TimMenu.BeginSector("SmartJump Visuals")

		G.Menu.Visuals.showSmartJump = G.Menu.Visuals.showSmartJump or false
		G.Menu.Visuals.showSmartJump = TimMenu.Checkbox("Show SmartJump", G.Menu.Visuals.showSmartJump)
		TimMenu.Tooltip("Display SmartJump simulation path and landing prediction")
		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()

		-- ISWalkable Test Section
		TimMenu.BeginSector("ISWalkable Test")

		-- Initialize ISWalkableTest menu variables
		if G.Menu.Visuals.ISWalkableTest == nil then
			G.Menu.Visuals.ISWalkableTest = false
		end

		G.Menu.Visuals.ISWalkableTest = TimMenu.Checkbox("ISWalkable Test", G.Menu.Visuals.ISWalkableTest)
		TimMenu.Tooltip("Enable ISWalkable testing suite (hold SHIFT to set target position)")
		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()

		-- Optimized ISWalkable Test Section
		TimMenu.BeginSector("Optimized ISWalkable Test")

		-- Initialize OptimizedISWalkableTest menu variables
		if G.Menu.Visuals.OptimizedISWalkableTest == nil then
			G.Menu.Visuals.OptimizedISWalkableTest = false
		end

		G.Menu.Visuals.OptimizedISWalkableTest =
			TimMenu.Checkbox("Optimized ISWalkable Test", G.Menu.Visuals.OptimizedISWalkableTest)
		TimMenu.Tooltip("EXPERIMENTAL: Navmesh-optimized ISWalkable (hold F to test)")
		TimMenu.NextLine()

		TimMenu.EndSector()
		TimMenu.NextLine()

		-- IsNavigable Test Section
		TimMenu.BeginSector("IsNavigable Test")

		-- Initialize IsNavigableTest menu variables
		if G.Menu.Visuals.IsNavigableTest == nil then
			G.Menu.Visuals.IsNavigableTest = false
		end

		G.Menu.Visuals.IsNavigableTest = TimMenu.Checkbox("IsNavigable Test", G.Menu.Visuals.IsNavigableTest)
		TimMenu.Tooltip("Test node-based navigation skipping (hold F to test)")
		TimMenu.NextLine()

		TimMenu.EndSector()
	end

	-- Always end the menu if we began it
	TimMenu.End()
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule

end)
__bundle_register("MedBot.Core.Globals", function(require, _LOADED, __bundle_register, __bundle_modules)
local DefaultConfig = require("MedBot.Utils.DefaultConfig")
-- Define the G module
local G = {}

G.Menu = DefaultConfig

G.Default = {
	entity = nil,
	index = 1,
	team = 1,
	Class = 1,
	flags = 1,
	OnGround = true,
	Origin = Vector3(0, 0, 0),
	ViewAngles = EulerAngles(90, 0, 0),
	Viewheight = Vector3(0, 0, 75),
	VisPos = Vector3(0, 0, 75),
	vHitbox = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 45) },
}

G.pLocal = G.Default

G.World_Default = {
	players = {},
	healthPacks = {}, -- Stores positions of health packs
	spawns = {}, -- Stores positions of spawn points
	payloads = {}, -- Stores payload entities in payload maps
	flags = {}, -- Stores flag entities in CTF maps (implicitly included in the logic)
}

G.World = G.World_Default

G.Misc = {
	NodeTouchDistance = 12,
	NodeTouchHeight = 82,
	workLimit = 1,
}

G.Navigation = {
	path = nil,
	nodes = nil,
	currentNodeIndex = 1, -- Current node we're moving towards (1 = first node in path)
	currentNodeTicks = 0,
	stuckStartTick = nil, -- Track when we first entered stuck state
	FirstAgentNode = 1,
	SecondAgentNode = 2,
	lastKnownTargetPosition = nil, -- Remember last position of follow target
	goalPos = nil, -- Current goal world position
	goalNodeId = nil, -- Closest node to the goal position
	navMeshUpdated = false, -- Set when navmesh is rebuilt
	-- Node skipping system
	lastSkipCheckTick = 0, -- Last tick when we performed skip check
	nextNodeCloser = false, -- Flag indicating if next node is closer
}

-- SmartJump configuration
G.Menu.SmartJump = {
	Enable = true,
	Debug = false,
}

-- SmartJump runtime state and constants
G.SmartJump = G.SmartJump
	or {
		-- Constants (must be defined first)
		Constants = {
			GRAVITY = 800, -- Gravity per second squared
			JUMP_FORCE = 271, -- Initial vertical boost for a duck jump
			MAX_JUMP_HEIGHT = Vector3(0, 0, 72), -- Maximum jump height vector
			MAX_WALKABLE_ANGLE = 45, -- Maximum angle considered walkable

			-- State definitions
			STATE_IDLE = "STATE_IDLE",
			STATE_PREPARE_JUMP = "STATE_PREPARE_JUMP",
			STATE_CTAP = "STATE_CTAP",
			STATE_ASCENDING = "STATE_ASCENDING",
			STATE_DESCENDING = "STATE_DESCENDING",
		},

		-- Runtime state
		jumpState = "STATE_IDLE",
		ShouldJump = false,
		LastSmartJumpAttempt = 0,
		LastEmergencyJump = 0,
		ObstacleDetected = false,
		RequestEmergencyJump = false,

		-- Movement state
		SimulationPath = {},
		PredPos = nil,
		JumpPeekPos = nil,
		HitObstacle = false,
		lastAngle = nil,
		stateStartTime = 0,
		lastState = nil,
		lastJumpTime = 0,
		LastObstacleHeight = 0,
	}

-- Bot movement tracking (for SmartJump integration)
G.BotIsMoving = false -- Track if bot is actively moving
G.BotMovementDirection = Vector3(0, 0, 0) -- Bot's intended movement direction

-- Memory management and cache tracking
G.Cache = {
	lastCleanup = 0,
	cleanupInterval = 500, -- Clean up every 500 ticks (~8 seconds) instead of 2000
	maxCacheSize = 1000, -- Maximum number of cached items
}

G.Tasks = {
	None = 0,
	Objective = 1,
	Follow = 2,
	Health = 3,
	Medic = 4,
	Goto = 5,
}

G.Current_Tasks = {}
G.Current_Task = G.Tasks.Objective

G.Benchmark = {
	MemUsage = 0,
}

-- Define states
G.States = {
	IDLE = "IDLE",
	PATHFINDING = "PATHFINDING",
	MOVING = "MOVING",
	STUCK = "STUCK",
	FOLLOWING = "FOLLOWING", -- Direct following of dynamic target on same node
}

G.currentState = nil
G.prevState = nil -- Track previous bot state
G.wasManualWalking = false -- Track if user manually walked last tick

return G

end)
__bundle_register("MedBot.Utils.DefaultConfig", function(require, _LOADED, __bundle_register, __bundle_modules)
local defaultconfig
defaultconfig = {
	Tab = "Main",
	Tabs = {
		Main = true,
		Navigation = false,
		Settings = false,
		Visuals = false,
		Movement = false,
	},

	Main = {
		Enable = true,
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
		LookingAhead = true, -- Enable automatic camera rotation towards target node
		Duck_Grab = true,
	},
	Navigation = {
		Skip_Nodes = true, --skips nodes if it can go directly to ones closer to target.
		StopDistance = 50, -- Distance to stop from target when following (FOLLOWING state)
		WalkableMode = "Smooth", -- "Smooth" uses 18-unit steps, "Aggressive" allows 72-unit jumps
		CleanupConnections = true, -- Cleanup invalid connections during map load (disable to prevent crashes)
		AllowExpensiveChecks = true, -- Allow expensive walkability checks for proper stair/ramp connections
	},
	Visuals = {
		EnableVisuals = true,
		connectionDepth = 4, -- Flood-fill depth: how many connection steps from player to visualize (1-50)
		memoryUsage = false,
		drawPath = true, -- Draws the path to the current goal
		showConnections = true, -- Show area↔door triangle connections
		showAreas = true, -- Show area outlines
		showDoors = true, -- Show door lines (cyan)
		showCornerConnections = false, -- Show wall corner points (orange)
		showD2D = false, -- Show door-to-door connections (light blue)
		showNodeIds = false, -- Show node ID numbers for debugging
		showAgentBoxes = false, -- Show agent boxes
		showSmartJump = false, -- Show SmartJump hitbox and trajectory visualization
		ISWalkableTest = false, -- ISWalkable test suite toggle
		Debug_Mode = false, -- Master debug toggle for visuals and debug logging
	},
	Movement = {
		lookatpath = true, -- Look at where we are walking
		smoothLookAtPath = true, -- Set this to true to enable smooth look at path
		Smart_Jump = true, -- jumps perfectly before obstacle to be at peek of jump height when at colision point
	},
	SmartJump = {
		Enable = true,
		Debug = false,
	},
}

return defaultconfig

end)
__bundle_register("MedBot.Utils.Config", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local G = require("MedBot.Core.Globals")

local Common = require("MedBot.Core.Common")
local json = require("MedBot.Utils.Json")
local Default_Config = require("MedBot.Utils.DefaultConfig")

local Config = {}

local Log = Common.Log
local Notify = Common.Notify
Log.Level = 0

local script_name = GetScriptName():match("([^/\\]+)%.lua$")
local folder_name = string.format([[Lua %s]], script_name)

--[[ Helper Functions ]]
function Config.GetFilePath()
	-- Note: filesystem.CreateDirectory() returns true only if it created a new directory,
	-- not if the directory already exists. The function succeeds in both cases, but
	-- returns different boolean values.
	local CreatedDirectory, fullPath = filesystem.CreateDirectory(folder_name)
	return fullPath .. "/config.cfg"
end

local function checkAllKeysExist(expectedMenu, loadedMenu)
	for key, value in pairs(expectedMenu) do
		if loadedMenu[key] == nil then
			return false
		end
		if type(value) == "table" then
			local result = checkAllKeysExist(value, loadedMenu[key])
			if not result then
				return false
			end
		end
	end
	return true
end

--[[ Configuration Functions ]]
function Config.CreateCFG(cfgTable)
	cfgTable = cfgTable or Default_Config
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "w")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local serializedConfig = json.encode(cfgTable)
		file:write(serializedConfig)
		file:close()
		printc(100, 183, 0, 255, "Success Saving Config: Path: " .. shortFilePath)
		Common.Notify.Simple("Success! Saved Config to:", shortFilePath, 5)
	else
		local errorMessage = "Failed to open: " .. shortFilePath
		printc(255, 0, 0, 255, errorMessage)
		Common.Notify.Simple("Error", errorMessage, 5)
	end
end

function Config.LoadCFG()
	local filepath = Config.GetFilePath()
	local file = io.open(filepath, "r")
	local shortFilePath = filepath:match(".*\\(.*\\.*)$")
	if file then
		local content = file:read("*a")
		file:close()
		local loadedCfg = json.decode(content)
		if loadedCfg and checkAllKeysExist(Default_Config, loadedCfg) and not input.IsButtonDown(KEY_LSHIFT) then
			printc(100, 183, 0, 255, "Success Loading Config: Path: " .. shortFilePath)
			Common.Notify.Simple("Success! Loaded Config from", shortFilePath, 5)
			G.Menu = loadedCfg
		else
			local warningMessage = input.IsButtonDown(KEY_LSHIFT) and "Creating a new config."
				or "Config is outdated or invalid. Resetting to default."
			printc(255, 0, 0, 255, warningMessage)
			Common.Notify.Simple("Warning", warningMessage, 5)
			Config.CreateCFG(Default_Config)
			G.Menu = Default_Config
		end
	else
		local warningMessage = "Config file not found. Creating a new config."
		printc(255, 0, 0, 255, warningMessage)
		Common.Notify.Simple("Warning", warningMessage, 5)
		Config.CreateCFG(Default_Config)
		G.Menu = Default_Config
	end

	-- Set G.Config with key settings for other modules
	G.Config = G.Config or {}
	G.Config.AutoFetch = G.Menu.Main.AutoFetch -- Pull from Menu settings
end

--load on load
Config.LoadCFG()

-- Save configuration automatically when the script unloads
local function ConfigAutoSaveOnUnload()
	print("[CONFIG] Unloading script, saving configuration...")

	-- Save the current configuration state
	if G.Menu then
		Config.CreateCFG(G.Menu)
	else
		printc(255, 0, 0, 255, "[CONFIG] Warning: Unable to save config, G.Menu is nil")
	end
end

callbacks.Register("Unload", "ConfigAutoSaveOnUnload", ConfigAutoSaveOnUnload)

return Config

end)
__bundle_register("MedBot.Utils.Json", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
David Kolf's JSON module for Lua 5.1 - 5.4

Version 2.6


For the documentation see the corresponding readme.txt or visit
<http://dkolf.de/src/dkjson-lua.fsl/>.

You can contact the author by sending an e-mail to 'david' at the
domain 'dkolf.de'.


Copyright (C) 2010-2021 David Heiko Kolf

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

---@alias JsonState { indent : boolean?, keyorder : integer[]?, level : integer?, buffer : string[]?, bufferlen : integer?, tables : table[]?, exception : function? }

-- global dependencies:
local pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset =
    pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
    string.rep, string.gsub, string.sub, string.byte, string.char,
    string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat

---@class Json
local json = { version = "dkjson 2.6.1 L" }

local _ENV = nil -- blocking globals in Lua 5.2 and later

json.null = setmetatable({}, {
    __tojson = function() return "null" end
})

local function isarray(tbl)
    local max, n, arraylen = 0, 0, 0
    for k, v in pairs(tbl) do
        if k == 'n' and type(v) == 'number' then
            arraylen = v
            if v > max then
                max = v
            end
        else
            if type(k) ~= 'number' or k < 1 or floor(k) ~= k then
                return false
            end
            if k > max then
                max = k
            end
            n = n + 1
        end
    end
    if max > 10 and max > arraylen and max > n * 2 then
        return false -- don't create an array with too many holes
    end
    return true, max
end

local escapecodes = {
    ["\""] = "\\\"",
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t"
}

local function escapeutf8(uchar)
    local value = escapecodes[uchar]
    if value then
        return value
    end
    local a, b, c, d = strbyte(uchar, 1, 4)
    a, b, c, d = a or 0, b or 0, c or 0, d or 0
    if a <= 0x7f then
        value = a
    elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
        value = (a - 0xc0) * 0x40 + b - 0x80
    elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
        value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
    elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
        value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
    else
        return ""
    end
    if value <= 0xffff then
        return strformat("\\u%.4x", value)
    elseif value <= 0x10ffff then
        -- encode as UTF-16 surrogate pair
        value = value - 0x10000
        local highsur, lowsur = 0xD800 + floor(value / 0x400), 0xDC00 + (value % 0x400)
        return strformat("\\u%.4x\\u%.4x", highsur, lowsur)
    else
        return ""
    end
end

local function fsub(str, pattern, repl)
    -- gsub always builds a new string in a buffer, even when no match
    -- exists. First using find should be more efficient when most strings
    -- don't contain the pattern.
    if strfind(str, pattern) then
        return gsub(str, pattern, repl)
    else
        return str
    end
end

local function quotestring(value)
    -- based on the regexp "escapable" in https://github.com/douglascrockford/JSON-js
    value = fsub(value, "[%z\1-\31\"\\\127]", escapeutf8)
    if strfind(value, "[\194\216\220\225\226\239]") then
        value = fsub(value, "\194[\128-\159\173]", escapeutf8)
        value = fsub(value, "\216[\128-\132]", escapeutf8)
        value = fsub(value, "\220\143", escapeutf8)
        value = fsub(value, "\225\158[\180\181]", escapeutf8)
        value = fsub(value, "\226\128[\140-\143\168-\175]", escapeutf8)
        value = fsub(value, "\226\129[\160-\175]", escapeutf8)
        value = fsub(value, "\239\187\191", escapeutf8)
        value = fsub(value, "\239\191[\176-\191]", escapeutf8)
    end
    return "\"" .. value .. "\""
end
json.quotestring = quotestring

local function replace(str, o, n)
    local i, j = strfind(str, o, 1, true)
    if i then
        return strsub(str, 1, i - 1) .. n .. strsub(str, j + 1, -1)
    else
        return str
    end
end

-- locale independent num2str and str2num functions
local decpoint, numfilter

local function updatedecpoint()
    decpoint = strmatch(tostring(0.5), "([^05+])")
    -- build a filter that can be used to remove group separators
    numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str(num)
    return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function str2num(str)
    local num = tonumber(replace(str, ".", decpoint))
    if not num then
        updatedecpoint()
        num = tonumber(replace(str, ".", decpoint))
    end
    return num
end

local function addnewline2(level, buffer, buflen)
    buffer[buflen + 1] = "\n"
    buffer[buflen + 2] = strrep("  ", level)
    buflen = buflen + 2
    return buflen
end

function json.addnewline(state)
    if state.indent then
        state.bufferlen = addnewline2(state.level or 0,
            state.buffer, state.bufferlen or #(state.buffer))
    end
end

local encode2 -- forward declaration

local function addpair(key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
    local kt = type(key)
    if kt ~= 'string' and kt ~= 'number' then
        return nil, "type '" .. kt .. "' is not supported as a key by JSON."
    end
    if prev then
        buflen = buflen + 1
        buffer[buflen] = ","
    end
    if indent then
        buflen = addnewline2(level, buffer, buflen)
    end
    buffer[buflen + 1] = quotestring(key)
    buffer[buflen + 2] = ":"
    return encode2(value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
    local buflen = state.bufferlen
    if type(res) == 'string' then
        buflen = buflen + 1
        buffer[buflen] = res
    end
    return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
    defaultmessage = defaultmessage or reason
    local handler = state.exception
    if not handler then
        return nil, defaultmessage
    else
        state.bufferlen = buflen
        local ret, msg = handler(reason, value, state, defaultmessage)
        if not ret then return nil, msg or defaultmessage end
        return appendcustom(ret, buffer, state)
    end
end

function json.encodeexception(reason, value, state, defaultmessage)
    return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function(value, indent, level, buffer, buflen, tables, globalorder, state)
    local valtype = type(value)
    local valmeta = getmetatable(value)
    valmeta = type(valmeta) == 'table' and valmeta -- only tables
    local valtojson = valmeta and valmeta.__tojson
    if valtojson then
        if tables[value] then
            return exception('reference cycle', value, state, buffer, buflen)
        end
        tables[value] = true
        state.bufferlen = buflen
        local ret, msg = valtojson(value, state)
        if not ret then return exception('custom encoder failed', value, state, buffer, buflen, msg) end
        tables[value] = nil
        buflen = appendcustom(ret, buffer, state)
    elseif value == nil then
        buflen = buflen + 1
        buffer[buflen] = "null"
    elseif valtype == 'number' then
        local s
        if value ~= value or value >= huge or -value >= huge then
            -- This is the behaviour of the original JSON implementation.
            s = "null"
        else
            s = num2str(value)
        end
        buflen = buflen + 1
        buffer[buflen] = s
    elseif valtype == 'boolean' then
        buflen = buflen + 1
        buffer[buflen] = value and "true" or "false"
    elseif valtype == 'string' then
        buflen = buflen + 1
        buffer[buflen] = quotestring(value)
    elseif valtype == 'table' then
        if tables[value] then
            return exception('reference cycle', value, state, buffer, buflen)
        end
        tables[value] = true
        level = level + 1
        local isa, n = isarray(value)
        if n == 0 and valmeta and valmeta.__jsontype == 'object' then
            isa = false
        end
        local msg
        if isa then -- JSON array
            buflen = buflen + 1
            buffer[buflen] = "["
            for i = 1, n do
                buflen, msg = encode2(value[i], indent, level, buffer, buflen, tables, globalorder, state)
                if not buflen then return nil, msg end
                if i < n then
                    buflen = buflen + 1
                    buffer[buflen] = ","
                end
            end
            buflen = buflen + 1
            buffer[buflen] = "]"
        else -- JSON object
            local prev = false
            buflen = buflen + 1
            buffer[buflen] = "{"
            local order = valmeta and valmeta.__jsonorder or globalorder
            if order then
                local used = {}
                n = #order
                for i = 1, n do
                    local k = order[i]
                    local v = value[k]
                    if v ~= nil then
                        used[k] = true
                        buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
                        prev = true -- add a seperator before the next element
                    end
                end
                for k, v in pairs(value) do
                    if not used[k] then
                        buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
                        if not buflen then return nil, msg end
                        prev = true -- add a seperator before the next element
                    end
                end
            else -- unordered
                for k, v in pairs(value) do
                    buflen, msg = addpair(k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
                    if not buflen then return nil, msg end
                    prev = true -- add a seperator before the next element
                end
            end
            if indent then
                buflen = addnewline2(level - 1, buffer, buflen)
            end
            buflen = buflen + 1
            buffer[buflen] = "}"
        end
        tables[value] = nil
    else
        return exception('unsupported type', value, state, buffer, buflen,
            "type '" .. valtype .. "' is not supported by JSON.")
    end
    return buflen
end

---Encodes a lua table to a JSON string.
---@param value any
---@param state JsonState
---@return string|boolean
function json.encode(value, state)
    state = state or {}
    local oldbuffer = state.buffer
    local buffer = oldbuffer or {}
    state.buffer = buffer
    updatedecpoint()
    local ret, msg = encode2(value, state.indent, state.level or 0,
        buffer, state.bufferlen or 0, state.tables or {}, state.keyorder, state)
    if not ret then
        error(msg, 2)
    elseif oldbuffer == buffer then
        state.bufferlen = ret
        return true
    else
        state.bufferlen = nil
        state.buffer = nil
        return concat(buffer)
    end
end

local function loc(str, where)
    local line, pos, linepos = 1, 1, 0
    while true do
        pos = strfind(str, "\n", pos, true)
        if pos and pos < where then
            line = line + 1
            linepos = pos
            pos = pos + 1
        else
            break
        end
    end
    return "line " .. line .. ", column " .. (where - linepos)
end

local function unterminated(str, what, where)
    return nil, strlen(str) + 1, "unterminated " .. what .. " at " .. loc(str, where)
end

local function scanwhite(str, pos)
    while true do
        pos = strfind(str, "%S", pos)
        if not pos then return nil end
        local sub2 = strsub(str, pos, pos + 1)
        if sub2 == "\239\187" and strsub(str, pos + 2, pos + 2) == "\191" then
            -- UTF-8 Byte Order Mark
            pos = pos + 3
        elseif sub2 == "//" then
            pos = strfind(str, "[\n\r]", pos + 2)
            if not pos then return nil end
        elseif sub2 == "/*" then
            pos = strfind(str, "*/", pos + 2)
            if not pos then return nil end
            pos = pos + 2
        else
            return pos
        end
    end
end

local escapechars = {
    ["\""] = "\"",
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t"
}

local function unichar(value)
    if value < 0 then
        return nil
    elseif value <= 0x007f then
        return strchar(value)
    elseif value <= 0x07ff then
        return strchar(0xc0 + floor(value / 0x40),
            0x80 + (floor(value) % 0x40))
    elseif value <= 0xffff then
        return strchar(0xe0 + floor(value / 0x1000),
            0x80 + (floor(value / 0x40) % 0x40),
            0x80 + (floor(value) % 0x40))
    elseif value <= 0x10ffff then
        return strchar(0xf0 + floor(value / 0x40000),
            0x80 + (floor(value / 0x1000) % 0x40),
            0x80 + (floor(value / 0x40) % 0x40),
            0x80 + (floor(value) % 0x40))
    else
        return nil
    end
end

local function scanstring(str, pos)
    local lastpos = pos + 1
    local buffer, n = {}, 0
    while true do
        local nextpos = strfind(str, "[\"\\]", lastpos)
        if not nextpos then
            return unterminated(str, "string", pos)
        end
        if nextpos > lastpos then
            n = n + 1
            buffer[n] = strsub(str, lastpos, nextpos - 1)
        end
        if strsub(str, nextpos, nextpos) == "\"" then
            lastpos = nextpos + 1
            break
        else
            local escchar = strsub(str, nextpos + 1, nextpos + 1)
            local value
            if escchar == "u" then
                value = tonumber(strsub(str, nextpos + 2, nextpos + 5), 16)
                if value then
                    local value2
                    if 0xD800 <= value and value <= 0xDBff then
                        -- we have the high surrogate of UTF-16. Check if there is a
                        -- low surrogate escaped nearby to combine them.
                        if strsub(str, nextpos + 6, nextpos + 7) == "\\u" then
                            value2 = tonumber(strsub(str, nextpos + 8, nextpos + 11), 16)
                            if value2 and 0xDC00 <= value2 and value2 <= 0xDFFF then
                                value = (value - 0xD800) * 0x400 + (value2 - 0xDC00) + 0x10000
                            else
                                value2 = nil -- in case it was out of range for a low surrogate
                            end
                        end
                    end
                    value = value and unichar(value)
                    if value then
                        if value2 then
                            lastpos = nextpos + 12
                        else
                            lastpos = nextpos + 6
                        end
                    end
                end
            end
            if not value then
                value = escapechars[escchar] or escchar
                lastpos = nextpos + 2
            end
            n = n + 1
            buffer[n] = value
        end
    end
    if n == 1 then
        return buffer[1], lastpos
    elseif n > 1 then
        return concat(buffer), lastpos
    else
        return "", lastpos
    end
end

local scanvalue -- forward declaration

local function scantable(what, closechar, str, startpos, nullval, objectmeta, arraymeta)
    local tbl, n = {}, 0
    local pos = startpos + 1
    if what == 'object' then
        setmetatable(tbl, objectmeta)
    else
        setmetatable(tbl, arraymeta)
    end
    while true do
        pos = scanwhite(str, pos)
        if not pos then return unterminated(str, what, startpos) end
        local char = strsub(str, pos, pos)
        if char == closechar then
            return tbl, pos + 1
        end
        local val1, err
        val1, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
        if err then return nil, pos, err end
        pos = scanwhite(str, pos)
        if not pos then return unterminated(str, what, startpos) end
        char = strsub(str, pos, pos)
        if char == ":" then
            if val1 == nil then
                return nil, pos, "cannot use nil as table index (at " .. loc(str, pos) .. ")"
            end
            pos = scanwhite(str, pos + 1)
            if not pos then return unterminated(str, what, startpos) end
            local val2
            val2, pos, err = scanvalue(str, pos, nullval, objectmeta, arraymeta)
            if err then return nil, pos, err end
            tbl[val1] = val2
            pos = scanwhite(str, pos)
            if not pos then return unterminated(str, what, startpos) end
            char = strsub(str, pos, pos)
        else
            n = n + 1
            tbl[n] = val1
        end
        if char == "," then
            pos = pos + 1
        end
    end
end

scanvalue = function(str, pos, nullval, objectmeta, arraymeta)
    pos = pos or 1
    pos = scanwhite(str, pos)
    if not pos then
        return nil, strlen(str) + 1, "no valid JSON value (reached the end)"
    end
    local char = strsub(str, pos, pos)
    if char == "{" then
        return scantable('object', "}", str, pos, nullval, objectmeta, arraymeta)
    elseif char == "[" then
        return scantable('array', "]", str, pos, nullval, objectmeta, arraymeta)
    elseif char == "\"" then
        return scanstring(str, pos)
    else
        local pstart, pend = strfind(str, "^%-?[%d%.]+[eE]?[%+%-]?%d*", pos)
        if pstart then
            local number = str2num(strsub(str, pstart, pend))
            if number then
                return number, pend + 1
            end
        end
        pstart, pend = strfind(str, "^%a%w*", pos)
        if pstart then
            local name = strsub(str, pstart, pend)
            if name == "true" then
                return true, pend + 1
            elseif name == "false" then
                return false, pend + 1
            elseif name == "null" then
                return nullval, pend + 1
            end
        end
        return nil, pos, "no valid JSON value at " .. loc(str, pos)
    end
end

local function optionalmetatables(...)
    if select("#", ...) > 0 then
        return ...
    else
        return { __jsontype = 'object' }, { __jsontype = 'array' }
    end
end

---@param str string
---@param pos integer?
---@param nullval any?
---@param ... table?
function json.decode(str, pos, nullval, ...)
    local objectmeta, arraymeta = optionalmetatables(...)
    return scanvalue(str, pos, nullval, objectmeta, arraymeta)
end

return json

end)
__bundle_register("MedBot.Core.Common", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

--[[ Imports ]]
-- Use literal require to allow luabundle to treat it as an external/static require
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 1.0, "LNXlib version is too old, please update it!")

Common.Lib = Lib
Common.Notify = Lib.UI.Notify
Common.TF2 = Lib.TF2
Common.Math = Lib.Utils.Math
Common.Conversion = Lib.Utils.Conversion
Common.WPlayer = Lib.TF2.WPlayer
Common.PR = Lib.TF2.PlayerResource
Common.Helpers = Lib.TF2.Helpers

-- Import G module at file scope
local G = require("MedBot.Core.Globals")

-- Safe logging system (replaces LNX Logger)
local function safePrint(msg)
	local success, err = pcall(print, msg)
	if not success then
		-- Fallback: try again
		pcall(print, "LOG ERROR")
	end
end

local Logger = {}
Logger.__index = Logger

function Logger.new(moduleName)
	local self = setmetatable({}, Logger)
	self.moduleName = moduleName or "MedBot"
	return self
end

function Logger:Info(msg, ...)
	local success, formatted = pcall(string.format, "[Info  %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Info] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

function Logger:Warn(msg, ...)
	local success, formatted = pcall(string.format, "[Warn  %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Warn] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

function Logger:Debug(msg, ...)
	-- Only print debug messages if debug is enabled in menu
	if not (G.Menu.Visuals and G.Menu.Visuals.Debug_Mode) then
		return -- Skip debug output when debug is disabled
	end

	local success, formatted = pcall(string.format, "[Debug %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Debug] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

function Logger:Error(msg, ...)
	local success, formatted = pcall(string.format, "[Error %s] %s: " .. msg, os.date("%H:%M:%S"), self.moduleName, ...)
	if success then
		safePrint(formatted)
	else
		safePrint("[Error] " .. self.moduleName .. ": " .. tostring(msg))
	end
end

Common.Log = Logger

-- JSON support
local JSON = {}
function JSON.parse(str)
	-- Simple JSON parser for basic objects/arrays
	if not str or str == "" then
		return nil
	end

	-- Remove whitespace
	str = str:gsub("%s+", "")

	-- Handle simple object
	if str:match("^{.-}$") then
		local result = {}
		for k, v in str:gmatch('"([^"]+)":([^,}]+)') do
			if v:match('^".*"$') then
				result[k] = v:sub(2, -2) -- Remove quotes
			elseif v == "true" then
				result[k] = true
			elseif v == "false" then
				result[k] = false
			elseif tonumber(v) then
				result[k] = tonumber(v)
			end
		end
		return result
	end

	return nil
end

function JSON.stringify(obj)
	if type(obj) ~= "table" then
		return tostring(obj)
	end

	local parts = {}
	for k, v in pairs(obj) do
		local key = '"' .. tostring(k) .. '"'
		local value
		if type(v) == "string" then
			value = '"' .. v .. '"'
		elseif type(v) == "boolean" then
			value = tostring(v)
		else
			value = tostring(v)
		end
		table.insert(parts, key .. ":" .. value)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

Common.JSON = JSON

local vectorDivide = vector.Divide
local vectorLength = vector.Length
local vectorDistance = vector.Distance

--- Normalize vector using in-place :Normalize() (fastest method)
function Common.Normalize(vec)
	return vectorDivide(vec, vectorLength(vec)) -- Return the normalized vector
end

-- Distance2d posibly slower then distance 3D due to mroe instructions in lua then single call in cpp lib of dist 3d
function Common.Distance2D(a, b)
	return (a - b):Length2D()
end

--distance3D check proly fastest posible in lua
function Common.Distance3D(a, b)
	return vectorDistance(a, b)
end

--- Cross product of two vectors
function Common.Cross(a, b)
	return a:Cross(b)
end

--- Dot product of two vectors
function Common.Dot(a, b)
	return a:Dot(b)
end

-- Arrow line drawing function (moved from Visuals.lua and ISWalkable.lua)
function Common.DrawArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	assert(start_pos and end_pos, "Common.DrawArrowLine: start_pos and end_pos are required")
	assert(
		arrowhead_length and arrowhead_width,
		"Common.DrawArrowLine: arrowhead_length and arrowhead_width are required"
	)

	-- If invert is true, swap start_pos and end_pos
	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	-- Calculate direction from start to end
	local direction = end_pos - start_pos
	local direction_length = direction:Length()

	-- Skip drawing if positions are identical (valid case when waypoints overlap)
	if direction_length == 0 then
		return
	end

	-- Normalize the direction vector safely
	local normalized_direction = direction / direction_length

	-- Calculate the arrow base position by moving back from end_pos in the direction of start_pos
	local arrow_base = end_pos - normalized_direction * arrowhead_length

	-- Calculate the perpendicular vector for the arrow width using cross product
	-- This works for any direction including vertical traces
	local up = Vector3(0, 0, 1)
	local perpendicular = normalized_direction:Cross(up)
	if perpendicular:Length() < 0.001 then
		-- Direction is vertical, use arbitrary horizontal perpendicular
		perpendicular = Vector3(1, 0, 0)
	end
	perpendicular = Common.Normalize(perpendicular) * (arrowhead_width / 2)

	-- Convert world positions to screen positions
	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	-- Only draw if all screen positions are valid
	if w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2 then
		-- Set color before drawing
		draw.Color(255, 255, 255, 255) -- White for arrows

		-- Draw the line from start to the base of the arrow (not all the way to the end)
		draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])

		-- Draw the sides of the arrowhead
		draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
		draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])

		-- Optionally, draw the base of the arrowhead to close it
		draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
	end
end

function Common.VectorToString(vec)
	if not vec then
		return "nil"
	end
	return string.format("(%.1f, %.1f, %.1f)", vec.x, vec.y, vec.z)
end

-- Dynamic hull size functions (access via Common for consistency)
function Common.GetPlayerHull()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		-- Fallback to hardcoded values if no player
		return {
			Min = Vector3(-24, -24, 0),
			Max = Vector3(24, 24, 82),
		}
	end

	-- Get dynamic hull size from player
	return {
		Min = pLocal:GetPropVector("m_vecMins") or Vector3(-24, -24, 0),
		Max = pLocal:GetPropVector("m_vecMaxs") or Vector3(24, 24, 82),
	}
end

function Common.GetHullMin()
	return Common.GetPlayerHull().Min
end

function Common.GetHullMax()
	return Common.GetPlayerHull().Max
end

-- Trace hull utilities (centralized for consistency)
Common.Trace = {}

function Common.Trace.Hull(startPos, endPos, hullMin, hullMax, mask, shouldHitEntity)
	assert(startPos and endPos, "Trace.Hull: startPos and endPos are required")
	assert(hullMin and hullMax, "Trace.Hull: hullMin and hullMax are required")

	local mask = mask or MASK_PLAYERSOLID
	local shouldHitEntity = shouldHitEntity or function(entity)
		return entity ~= entities.GetLocalPlayer()
	end

	return engine.TraceHull(startPos, endPos, hullMin, hullMax, mask, shouldHitEntity)
end

function Common.Trace.PlayerHull(startPos, endPos, shouldHitEntity)
	local hull = Common.GetPlayerHull()
	return Common.Trace.Hull(startPos, endPos, hull.Min, hull.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

-- Drawing utilities (centralized for consistency)
Common.Drawing = {}

function Common.Drawing.SetColor(r, g, b, a)
	draw.Color(r, g, b, a)
end

function Common.Drawing.DrawLine(x1, y1, x2, y2)
	draw.Line(x1, y1, x2, y2)
end

function Common.Drawing.WorldToScreen(worldPos)
	return client.WorldToScreen(worldPos)
end

function Common.Drawing.Draw3DBox(size, pos)
	local halfSize = size / 2
	-- Recompute corners every call to ensure correct size; caching caused wrong sizes
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = Common.Drawing.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			Common.Drawing.DrawLine(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

-- Dynamic values cache (updated periodically to avoid repeated cvar calls)
Common.Dynamic = {
	LastUpdate = 0,
	UpdateInterval = 1.0, -- Update every second
	Values = {},
}

function Common.Dynamic.Update()
	local currentTime = globals.RealTime()
	if currentTime - Common.Dynamic.LastUpdate < Common.Dynamic.UpdateInterval then
		return -- Not time to update yet
	end

	Common.Dynamic.LastUpdate = currentTime

	-- Update dynamic values from cvars and player properties
	local pLocal = entities.GetLocalPlayer()
	if pLocal then
		Common.Dynamic.Values.MaxSpeed = pLocal:GetPropFloat("m_flMaxspeed") or 450
		Common.Dynamic.Values.StepSize = pLocal:GetPropFloat("localdata", "m_flStepSize") or 18
		Common.Dynamic.Values.HullMin = pLocal:GetPropVector("m_vecMins") or Vector3(-24, -24, 0)
		Common.Dynamic.Values.HullMax = pLocal:GetPropVector("m_vecMaxs") or Vector3(24, 24, 82)
	end

	Common.Dynamic.Values.Gravity = client.GetConVar("sv_gravity") or 800
	Common.Dynamic.Values.TickInterval = globals.TickInterval()
end

function Common.Dynamic.GetMaxSpeed()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.MaxSpeed or 450
end

function Common.Dynamic.GetStepSize()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.StepSize or 18
end

function Common.Dynamic.GetGravity()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.Gravity or 800
end

function Common.Dynamic.GetTickInterval()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.TickInterval or (1 / 66.67)
end

function Common.Dynamic.GetHullMin()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.HullMin or Vector3(-24, -24, 0)
end

function Common.Dynamic.GetHullMax()
	Common.Dynamic.Update()
	return Common.Dynamic.Values.HullMax or Vector3(24, 24, 82)
end

-- Performance optimization utilities
Common.Cache = {}
local cacheStorage = {} -- Separate storage to avoid polluting Cache namespace

function Common.Cache.GetOrCompute(key, computeFunc, ttl)
	local currentTime = globals.RealTime()
	local cached = cacheStorage[key]

	if cached and (currentTime - cached.time) < (ttl or 1.0) then
		return cached.value
	end

	local value = computeFunc()
	cacheStorage[key] = { value = value, time = currentTime }
	return value
end

function Common.Cache.Clear()
	cacheStorage = {} -- Clear the storage, not the module table
end

-- Optimized math operations
function Common.Math.Clamp(value, min, max)
	return math.max(min, math.min(max, value))
end

function Common.Math.DistanceSquared(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Debug logging wrapper (deprecated - Logger:Debug now handles menu check automatically)
function Common.DebugLog(level, ...)
	if G.Menu.Visuals and G.Menu.Visuals.Debug_Mode then
		Common.Log[level](...)
	end
end

return Common

end)
__bundle_register("MedBot.Visuals", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local PathValidator = require("MedBot.Navigation.isWalkable.IsWalkable")
local MathUtils = require("MedBot.Utils.MathUtils")

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Log = Common.Log.new("Visuals")

-- Flood-fill algorithm to collect nodes within connection depth from player
local function collectNodesByConnectionDepth(playerPos, maxDepth)
	local nodes = G.Navigation.nodes
	if not nodes then
		return {}
	end

	-- Get closest area to player (fast center-distance check, not expensive containment check)
	local startNode = Node.GetClosestNode(playerPos)
	if not startNode then
		return {}
	end

	local visited = {}
	local toVisit = {}
	local result = {}

	-- Initialize with start node at depth 0
	toVisit[1] = { node = startNode, depth = 0 }
	visited[startNode.id] = true
	result[startNode.id] = { node = startNode, depth = 0 }

	local currentIndex = 1
	local maxNodes = 1000 -- Safety limit to prevent infinite loops

	while currentIndex <= #toVisit and #result < maxNodes do
		local current = toVisit[currentIndex]
		local node = current.node
		local depth = current.depth

		-- Stop if we've reached maximum depth
		if depth >= maxDepth then
			break
		end

		-- Get adjacent nodes
		local adjacentNodes = Node.GetAdjacentNodesOnly(node, nodes)
		for _, adjacentNode in ipairs(adjacentNodes) do
			if not visited[adjacentNode.id] then
				visited[adjacentNode.id] = true
				result[adjacentNode.id] = { node = adjacentNode, depth = depth + 1 }

				-- Add to visit queue for next depth level
				table.insert(toVisit, { node = adjacentNode, depth = depth + 1 })
			end
		end

		currentIndex = currentIndex + 1
	end

	return result
end

--[[ Functions ]]
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	-- Recompute corners every call to ensure correct size; caching caused wrong sizes
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

local UP_VECTOR = Vector3(0, 0, 1)

-- 1×1 white texture for filled polygons
local white_texture_fill = draw.CreateTextureRGBA(string.char(0xff, 0xff, 0xff, 0xff), 1, 1)

-- fillPolygon(vertices: {{x,y}}, r,g,b,a): filled convex polygon
local function fillPolygon(vertices, r, g, b, a)
	draw.Color(r, g, b, a)
	local n = #vertices
	local cords, rev = {}, {}
	local sum = 0
	local v1x, v1y = vertices[1][1], vertices[1][2]
	local function cross(a, b)
		return (b[1] - a[1]) * (v1y - a[2]) - (b[2] - a[2]) * (v1x - a[1])
	end
	for i, v in ipairs(vertices) do
		cords[i] = { v[1], v[2], 0, 0 }
		rev[n - i + 1] = cords[i]
		local nxt = vertices[i % n + 1]
		sum = sum + cross(v, nxt)
	end
	draw.TexturedPolygon(white_texture_fill, (sum < 0 and rev or cords), true)
end

-- Easy color configuration for area rendering
local AREA_FILL_COLOR = { 55, 255, 155, 12 } -- r, g, b, a for filled area
local AREA_OUTLINE_COLOR = { 255, 255, 255, 77 } -- r, g, b, a for area outline

local function OnDraw()
	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 0, 0, 255)

	local me = entities.GetLocalPlayer()
	if not me then
		return
	end
	-- Master enable switch for visuals
	if not G.Menu.Visuals.EnableVisuals then
		return
	end

	local p = me:GetAbsOrigin()

	-- Collect visible nodes using flood-fill from player position
	local connectionDepth = G.Menu.Visuals.connectionDepth or 10
	local allReachableNodes = collectNodesByConnectionDepth(p, connectionDepth)

	-- Filter to only nodes within the actual depth limit (not just reachable through flood-fill)
	local filteredNodes = {}
	for id, entry in pairs(allReachableNodes) do
		if entry.depth <= connectionDepth then
			local node = entry.node
			local scr = client.WorldToScreen(node.pos)
			if scr then
				filteredNodes[id] = { node = node, screen = scr, depth = entry.depth }
			end
		end
	end

	local currentY = 120
	-- Draw memory usage if enabled in config
	if G.Menu.Visuals.memoryUsage then
		draw.SetFont(Fonts.Verdana) -- Ensure font is set before drawing text
		draw.Color(255, 255, 255, 200)
		-- Get current memory usage directly for real-time display
		local currentMemKB = collectgarbage("count")
		local memMB = currentMemKB / 1024
		draw.Text(10, currentY, string.format("Memory: %.2f MB", memMB))
		currentY = currentY + 20
	end
	G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
	if G.Navigation.currentNodeIndex == nil then
		return
	end

	-- Agent visualization removed - back to simple node skipping
	-- No complex agent visualization needed for distance-based skipping

	-- Show connections between nav nodes with triangle visualization for doors
	if G.Menu.Visuals.showConnections then
		local drawnDoorTriangles = {} -- Track which door groups we've drawn
		local doorConvergencePoints = {} -- Store convergence points (direction to area center)
		local CONVERGENCE_OFFSET = 7 -- Units in front of middle door point

		-- Helper: Check if connection is bidirectional (area→door AND door→area)
		local function isBidirectional(areaNode, doorBaseId)
			local doorMiddle = G.Navigation.nodes[doorBaseId .. "_middle"]
			if not doorMiddle or not doorMiddle.c then
				return false
			end

			-- Check if door has connection back to area
			for _, d in pairs(doorMiddle.c) do
				if d.connections then
					for _, c in ipairs(d.connections) do
						local aid = (type(c) == "table") and c.node or c
						if aid == areaNode.id then
							return true
						end
					end
				end
			end
			return false
		end

		-- First pass: Draw door triangles (area→door connections) and store convergence
		for id, entry in pairs(filteredNodes) do
			local node = entry.node

			-- Only process area nodes (not doors)
			if not node.isDoor then
				for dir = 1, 4 do
					local cDir = node.c[dir]
					if cDir and cDir.connections then
						for _, conn in ipairs(cDir.connections) do
							local nid = (type(conn) == "table") and conn.node or conn
							local doorNode = G.Navigation.nodes and G.Navigation.nodes[nid]

							-- Only draw if connected to a door and door is visible
							if doorNode and doorNode.isDoor and filteredNodes[nid] then
								-- Extract door base ID
								local doorBaseId = doorNode.id:match("^(.+)_[^_]+$")
								if doorBaseId and not drawnDoorTriangles[doorBaseId .. "_to_" .. id] then
									drawnDoorTriangles[doorBaseId .. "_to_" .. id] = true

									-- Get all door points
									local leftNode = G.Navigation.nodes[doorBaseId .. "_left"]
									local middleNode = G.Navigation.nodes[doorBaseId .. "_middle"]
									local rightNode = G.Navigation.nodes[doorBaseId .. "_right"]

									local areaPos = node.pos + UP_VECTOR

									if middleNode and middleNode.pos then
										local middlePos = middleNode.pos + UP_VECTOR

										-- Check if connection is bidirectional
										local bidirectional = isBidirectional(node, doorBaseId)

										-- For one-way, find the target area this connection leads to
										local targetAreaPos = nil
										if not bidirectional and doorNode.c then
											for _, d in pairs(doorNode.c) do
												if d.connections then
													for _, c in ipairs(d.connections) do
														local aid = (type(c) == "table") and c.node or c
														if aid ~= node.id then -- Not the source area
															local targetArea = G.Navigation.nodes[aid]
															if targetArea and not targetArea.isDoor then
																targetAreaPos = targetArea.pos + UP_VECTOR
																break
															end
														end
													end
												end
												if targetAreaPos then
													break
												end
											end
										end

										-- Choose color: RED for one-directional, YELLOW for bidirectional
										local r, g, b, a = 255, 255, 0, 160 -- Default yellow
										if not bidirectional then
											r, g, b, a = 255, 50, 50, 140 -- Red for one-way
										end

										-- For one-way connections, draw red line from source area center to door middle
										if not bidirectional then
											draw.Color(r, g, b, a)
											local sa = client.WorldToScreen(areaPos)
											local sm = client.WorldToScreen(middlePos)
											if sa and sm then
												draw.Line(sa[1], sa[2], sm[1], sm[2])
											end
										end

										-- Check if door has sides or just middle
										local hasLeftRight = (leftNode and leftNode.pos)
											or (rightNode and rightNode.pos)

										if hasLeftRight then
											-- For one-way: triangle points to TARGET area, for two-way: points to SOURCE area
											local triangleTargetPos = bidirectional and areaPos
												or (targetAreaPos or areaPos)

											-- Calculate convergence point in front of middle (direction to triangle target)
											local dirToTarget = Common.Normalize(triangleTargetPos - middlePos)
											local convergencePos = middlePos + dirToTarget * CONVERGENCE_OFFSET

											-- Store convergence point only for bidirectional (D2D needs both ways)
											if bidirectional then
												local key = doorBaseId .. "_to_" .. id
												doorConvergencePoints[key] = convergencePos
											end

											-- Draw triangle: left→convergence, right→convergence (color based on direction)
											draw.Color(r, g, b, a)

											if leftNode and leftNode.pos then
												local leftPos = leftNode.pos + UP_VECTOR
												local s1 = client.WorldToScreen(leftPos)
												local s2 = client.WorldToScreen(convergencePos)
												if s1 and s2 then
													draw.Line(s1[1], s1[2], s2[1], s2[2])
												end
											end

											if rightNode and rightNode.pos then
												local rightPos = rightNode.pos + UP_VECTOR
												local s1 = client.WorldToScreen(rightPos)
												local s2 = client.WorldToScreen(convergencePos)
												if s1 and s2 then
													draw.Line(s1[1], s1[2], s2[1], s2[2])
												end
											end

											-- Draw line from convergence point to triangle target (source for bidirectional, target for one-way)
											local sc = client.WorldToScreen(convergencePos)
											local st = client.WorldToScreen(triangleTargetPos)
											if sc and st then
												draw.Line(sc[1], sc[2], st[1], st[2])
											end
										else
											-- Narrow door - for one-way use target area, for two-way use source area
											local narrowTargetPos = bidirectional and areaPos
												or (targetAreaPos or areaPos)

											-- Store middle as convergence only for bidirectional
											if bidirectional then
												local key = doorBaseId .. "_to_" .. id
												doorConvergencePoints[key] = middlePos
											end

											draw.Color(r, g, b, a)
											local sm = client.WorldToScreen(middlePos)
											local st = client.WorldToScreen(narrowTargetPos)
											if sm and st then
												draw.Line(sm[1], sm[2], st[1], st[2])
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end

		-- Second pass: Draw door-to-door using SAME convergence points (area center direction)
		if G.Menu.Visuals.showD2D then
			local drawnDoorPairs = {}

			for id, entry in pairs(filteredNodes) do
				local doorNode1 = entry.node

				if doorNode1.isDoor then
					local doorBase1 = doorNode1.id:match("^(.+)_[^_]+$")

					for dir = 1, 4 do
						local cDir = doorNode1.c[dir]
						if cDir and cDir.connections then
							for _, conn in ipairs(cDir.connections) do
								local nid = (type(conn) == "table") and conn.node or conn
								local doorNode2 = G.Navigation.nodes and G.Navigation.nodes[nid]

								if doorNode2 and doorNode2.isDoor and filteredNodes[nid] then
									local doorBase2 = doorNode2.id:match("^(.+)_[^_]+$")

									-- Create unique pair key (sorted to avoid duplicates)
									local pairKey = (doorBase1 < doorBase2) and (doorBase1 .. "_" .. doorBase2)
										or (doorBase2 .. "_" .. doorBase1)

									if not drawnDoorPairs[pairKey] then
										drawnDoorPairs[pairKey] = true

										-- Find which areas each door connects to (find shared area)
										-- Door1 connects to areaA and areaB, Door2 connects to areaC and areaD
										-- We want the side of each door facing the SHARED area
										local sharedAreaId = nil

										-- Get all area connections for both doors
										local areas1 = {}
										local areas2 = {}

										if doorNode1.c then
											for _, d in pairs(doorNode1.c) do
												if d.connections then
													for _, c in ipairs(d.connections) do
														local aid = (type(c) == "table") and c.node or c
														local areaNode = G.Navigation.nodes[aid]
														if areaNode and not areaNode.isDoor then
															areas1[aid] = true
														end
													end
												end
											end
										end

										if doorNode2.c then
											for _, d in pairs(doorNode2.c) do
												if d.connections then
													for _, c in ipairs(d.connections) do
														local aid = (type(c) == "table") and c.node or c
														local areaNode = G.Navigation.nodes[aid]
														if areaNode and not areaNode.isDoor then
															areas2[aid] = true
														end
													end
												end
											end
										end

										-- Find shared area
										for aid, _ in pairs(areas1) do
											if areas2[aid] then
												sharedAreaId = aid
												break
											end
										end

										if sharedAreaId then
											-- Use convergence points facing the shared area
											local key1 = doorBase1 .. "_to_" .. sharedAreaId
											local key2 = doorBase2 .. "_to_" .. sharedAreaId
											local convergence1 = doorConvergencePoints[key1]
											local convergence2 = doorConvergencePoints[key2]

											if convergence1 and convergence2 then
												draw.Color(100, 200, 255, 120) -- Light blue for door-to-door

												local s1 = client.WorldToScreen(convergence1)
												local s2 = client.WorldToScreen(convergence2)
												if s1 and s2 then
													draw.Line(s1[1], s1[2], s2[1], s2[2])
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Draw corner connections from node-level data (if enabled)
	if G.Menu.Visuals.showCornerConnections then
		local wallCornerCount = 0
		local allCornerCount = 0

		for id, entry in pairs(filteredNodes) do
			local node = entry.node

			-- Draw wall corners (orange squares)
			if node.wallCorners then
				for _, cornerPoint in ipairs(node.wallCorners) do
					wallCornerCount = wallCornerCount + 1
					local cornerScreen = client.WorldToScreen(cornerPoint)
					if cornerScreen then
						draw.Color(255, 165, 0, 200) -- Orange for wall corners
						draw.FilledRect(
							cornerScreen[1] - 3,
							cornerScreen[2] - 3,
							cornerScreen[1] + 3,
							cornerScreen[2] + 3
						)
					end
				end
			end
		end
	end

	-- Draw Doors as cyan lines between door points (elevated 1 unit)
	if G.Menu.Visuals.showDoors then
		local drawnDoors = {} -- Track drawn door groups to avoid duplicates
		local UP_OFFSET = Vector3(0, 0, 1)

		for id, entry in pairs(filteredNodes) do
			local doorNode = entry.node
			if doorNode and doorNode.isDoor then
				-- Extract door base ID (e.g., "4229_4231" from "4229_4231_left")
				local doorId = doorNode.id
				local doorBaseId = doorId:match("^(.+)_[^_]+$") -- Remove last suffix

				if doorBaseId and not drawnDoors[doorBaseId] then
					drawnDoors[doorBaseId] = true

					-- Find all 3 door points (left, middle, right) for this door
					local doorPoints = {}
					for _, suffix in ipairs({ "_left", "_middle", "_right" }) do
						local pointId = doorBaseId .. suffix
						local pointNode = G.Navigation.nodes[pointId]
						if pointNode and pointNode.pos then
							table.insert(doorPoints, pointNode.pos + UP_OFFSET)
						end
					end

					-- Draw cyan line between min and max points
					if #doorPoints >= 2 then
						-- Find min and max points (leftmost and rightmost)
						local minPoint = doorPoints[1]
						local maxPoint = doorPoints[1]

						for _, pt in ipairs(doorPoints) do
							if (pt - doorPoints[1]):Length() > (maxPoint - doorPoints[1]):Length() then
								maxPoint = pt
							end
						end

						local screen1 = client.WorldToScreen(minPoint)
						local screen2 = client.WorldToScreen(maxPoint)

						if screen1 and screen2 then
							draw.Color(0, 255, 255, 200) -- Cyan for doors
							draw.Line(screen1[1], screen1[2], screen2[1], screen2[2])
						end
					end
				end
			end
		end
	end

	-- Fill and outline areas using fixed corners from Navigation
	if G.Menu.Visuals.showAreas then
		for id, entry in pairs(filteredNodes) do
			local node = entry.node
			-- Skip door nodes - they don't have area corners
			if not node.isDoor then
				-- Collect the four corner vectors from the node
				local worldCorners = { node.nw, node.ne, node.se, node.sw }
				if worldCorners[1] and worldCorners[2] and worldCorners[3] and worldCorners[4] then
					local scr = {}
					local ok = true
					for i, corner in ipairs(worldCorners) do
						local s = client.WorldToScreen(corner)
						if not s then
							ok = false
							break
						end
						scr[i] = { s[1], s[2] }
					end
					-- Only draw if all corners are visible on screen
					if ok then
						-- filled polygon
						fillPolygon(scr, table.unpack(AREA_FILL_COLOR))
						-- outline
						draw.Color(table.unpack(AREA_OUTLINE_COLOR))
						for i = 1, 4 do
							local a = scr[i]
							local b = scr[i % 4 + 1]
							draw.Line(a[1], a[2], b[1], b[2])
						end
					end
				end
			end
		end
	end

	-- Draw node IDs if enabled
	if G.Menu.Visuals.showNodeIds then
		draw.SetFont(Fonts.Verdana)
		for id, entry in pairs(filteredNodes) do
			local node = entry.node
			if not node.isDoor then -- Only show IDs for area nodes, not door nodes
				local scr = client.WorldToScreen(node.pos + UP_VECTOR)
				if scr then
					draw.Color(255, 255, 255, 255)
					draw.Text(scr[1], scr[2], tostring(node.id))
				end
			end
		end
	end

	-- Fine points removed
	if false then
		-- Track drawn inter-area connections to avoid duplicates
		local drawnInterConnections = {}
		local drawnIntraConnections = {}

		for id, entry in pairs(filteredNodes) do
			local points = Node.GetAreaPoints(id)
			if points then
				-- First pass: draw connections if enabled
				for _, point in ipairs(points) do
					local screenPos = client.WorldToScreen(point.pos)
					if screenPos then
						for _, neighbor in ipairs(point.neighbors) do
							local neighborScreenPos = client.WorldToScreen(neighbor.point.pos)
							if neighborScreenPos then
								if neighbor.isInterArea and G.Menu.Visuals.showInterConnections then
									-- Orange for inter-area connections
									local connectionKey = string.format(
										"%d_%d-%d_%d",
										point.parentArea,
										point.id,
										neighbor.point.parentArea,
										neighbor.point.id
									)
									if not drawnInterConnections[connectionKey] then
										draw.Color(255, 165, 0, 180) -- Orange for inter-area connections
										draw.Line(
											screenPos[1],
											screenPos[2],
											neighborScreenPos[1],
											neighborScreenPos[2]
										)
										drawnInterConnections[connectionKey] = true
									end
								elseif not neighbor.isInterArea then
									-- Intra-area connections with different colors based on type
									local connectionKey = string.format(
										"%d_%d-%d_%d",
										math.min(point.id, neighbor.point.id),
										point.parentArea,
										math.max(point.id, neighbor.point.id),
										neighbor.point.parentArea
									)
									if not drawnIntraConnections[connectionKey] then
										if
											point.isEdge
											and neighbor.point.isEdge
											and G.Menu.Visuals.showEdgeConnections
										then
											draw.Color(0, 150, 255, 140) -- Bright blue for edge-to-edge connections
											draw.Line(
												screenPos[1],
												screenPos[2],
												neighborScreenPos[1],
												neighborScreenPos[2]
											)
											drawnIntraConnections[connectionKey] = true
										elseif G.Menu.Visuals.showIntraConnections then
											draw.Color(0, 100, 200, 60) -- Blue for regular intra-area connections
											draw.Line(
												screenPos[1],
												screenPos[2],
												neighborScreenPos[1],
												neighborScreenPos[2]
											)
											drawnIntraConnections[connectionKey] = true
										end
									end
								end
							end
						end
					end
				end

				-- Second pass: draw points (so they appear on top of lines) - REMOVED: Using wall corners only
				-- for _, point in ipairs(points) do
				--     local screenPos = client.WorldToScreen(point.pos)
				--     if screenPos then
				--         -- Color-code points: yellow for edge points, blue for regular points
				--         if point.isEdge then
				--             draw.Color(255, 255, 0, 220) -- Yellow for edge points
				--             draw.FilledRect(screenPos[1] - 2, screenPos[2] - 2, screenPos[1] + 2, screenPos[2] + 2)
				--         else
				--             draw.Color(0, 150, 255, 180) -- Light blue for regular points
				--             draw.FilledRect(screenPos[1] - 1, screenPos[2] - 1, screenPos[1] + 1, screenPos[2] + 1)
				--         end
				--     end
				-- end
			end
		end

		-- Show fine point statistics for areas with points
		local finePointStats = {}
		for id, entry in pairs(filteredNodes) do
			local points = Node.GetAreaPoints(id)
			if points and #points > 1 then -- Only count areas with multiple points
				local edgeCount = 0
				local interConnections = 0
				local intraConnections = 0
				local isolatedPoints = 0
				for _, point in ipairs(points) do
					if point.isEdge then
						edgeCount = edgeCount + 1
					end
					if #point.neighbors == 0 then
						isolatedPoints = isolatedPoints + 1
					end
					for _, neighbor in ipairs(point.neighbors) do
						if neighbor.isInterArea then
							interConnections = interConnections + 1
						else
							intraConnections = intraConnections + 1
						end
					end
				end
				table.insert(finePointStats, {
					id = id,
					totalPoints = #points,
					edgePoints = edgeCount,
					interConnections = interConnections,
					intraConnections = intraConnections,
					isolatedPoints = isolatedPoints,
				})
			end
		end
	end

	-- Draw SmartJump simulation visualization (controlled by menu)
	if
		G.Menu.Visuals.showSmartJump
		and G.SmartJump
		and G.SmartJump.SimulationPath
		and type(G.SmartJump.SimulationPath) == "table"
		and #G.SmartJump.SimulationPath > 1
	then
		-- Draw simulation path lines like AutoPeek's LineDrawList
		local pathCount = #G.SmartJump.SimulationPath
		for i = 1, pathCount - 1 do
			local startPos = G.SmartJump.SimulationPath[i]
			local endPos = G.SmartJump.SimulationPath[i + 1]

			-- Guard clause: ensure positions are valid Vector3 objects
			if startPos and endPos then
				local startScreen = client.WorldToScreen(startPos)
				local endScreen = client.WorldToScreen(endPos)

				if startScreen and endScreen then
					-- Color gradient like AutoPeek (brighter at end)
					local brightness = math.floor(100 + (155 * (i / pathCount)))
					draw.Color(brightness, brightness, 255, 200) -- Blue gradient
					draw.Line(startScreen[1], startScreen[2], endScreen[1], endScreen[2])
				end
			end
		end

		-- Draw jump landing position if available (controlled by menu)
		if G.Menu.Visuals.showSmartJump and G.SmartJump and G.SmartJump.JumpPeekPos and G.SmartJump.PredPos then
			local jumpPos = G.SmartJump.JumpPeekPos
			local predPos = G.SmartJump.PredPos
			local jumpScreen = client.WorldToScreen(jumpPos)
			local predScreen = client.WorldToScreen(predPos)

			if jumpScreen and predScreen then
				draw.Color(255, 255, 0, 180) -- Yellow jump arc
				draw.Line(predScreen[1], predScreen[2], jumpScreen[1], jumpScreen[2])
			end
		end
	end

	-- Draw only the actual-followed path using door-aware waypoints, with a live target arrow
	if G.Menu.Visuals.drawPath then
		local wps = G.Navigation.waypoints
		if wps and #wps > 0 then
			-- Only draw waypoints from current position onward (don't show past waypoints)
			local currentIdx = G.Navigation.currentWaypointIndex or 1
			if currentIdx < 1 then
				currentIdx = 1
			end

			-- Draw segments from current waypoint to the end
			for i = currentIdx, #wps - 1 do
				local a, b = wps[i], wps[i + 1]
				local aPos = a.pos
				local bPos = b.pos
				if not aPos and a.kind == "door" and a.points and #a.points > 0 then
					aPos = a.points[math.ceil(#a.points / 2)]
				end
				if not bPos and b.kind == "door" and b.points and #b.points > 0 then
					bPos = b.points[math.ceil(#b.points / 2)]
				end
				if aPos and bPos then
					draw.Color(255, 255, 255, 255) -- white route
					Common.DrawArrowLine(aPos, bPos, 18, 12, false)
				end
			end
		end
	end

	-- Draw direct white arrow from player to current target (the position we're walking to)
	if G.Menu.Visuals.drawPath then
		local localPos = G.pLocal and G.pLocal.Origin
		local targetPos = G.Navigation.currentTargetPos
		if localPos and targetPos then
			draw.Color(255, 255, 255, 220) -- White arrow to current target
			Common.DrawArrowLine(localPos, targetPos, 18, 12, false)
		end
	end

	-- Draw wall corners (orange points)
	if G.Menu.Visuals.showCornerConnections then
		for id, entry in pairs(filteredNodes) do
			local node = entry.node
			if node.wallCorners then
				for _, cornerPoint in ipairs(node.wallCorners) do
					local cornerScreen = client.WorldToScreen(cornerPoint)
					if cornerScreen then
						-- Draw orange square for wall corners
						draw.Color(255, 165, 0, 200) -- Orange for wall corners
						draw.FilledRect(
							cornerScreen[1] - 3,
							cornerScreen[2] - 3,
							cornerScreen[1] + 3,
							cornerScreen[2] + 3
						)
					end
				end
			end
		end
	end

	-- Draw PathValidator debug traces if enabled
	PathValidator.DrawDebugTraces()
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals

end)
__bundle_register("MedBot.Utils.MathUtils", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
MedBot Math Utilities Module
Consolidated math functions used across the codebase
--]]

local MathUtils = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local DEG_TO_RAD = math.pi / 180
local RAD_TO_DEG = 180 / math.pi

-- ============================================================================
-- VECTOR MATH UTILITIES
-- ============================================================================

---Linear interpolation between two values
---@param a number Start value
---@param b number End value
---@param t number Interpolation factor (0-1)
---@return number Interpolated value
function MathUtils.Lerp(a, b, t)
	return a + (b - a) * t
end

---Linear interpolation between two Vector3 values
---@param a Vector3 Start vector
---@param b Vector3 End vector
---@param t number Interpolation factor (0-1)
---@return Vector3 Interpolated vector
function MathUtils.LerpVec(a, b, t)
	return Vector3(MathUtils.Lerp(a.x, b.x, t), MathUtils.Lerp(a.y, b.y, t), MathUtils.Lerp(a.z, b.z, t))
end

---Clamp a value between min and max
---@param value number Value to clamp
---@param min number Minimum value
---@param max number Maximum value
---@return number Clamped value
function MathUtils.Clamp(value, min, max)
	return math.max(min, math.min(max, value))
end

---Clamp a Vector3 between min and max values
---@param vec Vector3 Vector to clamp
---@param min number Minimum value
---@param max number Maximum value
---@return Vector3 Clamped vector
function MathUtils.ClampVec(vec, min, max)
	return Vector3(MathUtils.Clamp(vec.x, min, max), MathUtils.Clamp(vec.y, min, max), MathUtils.Clamp(vec.z, min, max))
end

---Convert degrees to radians
---@param degrees number Angle in degrees
---@return number Angle in radians
function MathUtils.DegToRad(degrees)
	return degrees * DEG_TO_RAD
end

---Convert radians to degrees
---@param radians number Angle in radians
---@return number Angle in degrees
function MathUtils.RadToDeg(radians)
	return radians * RAD_TO_DEG
end

---Calculate 2D distance between two Vector3 points
---@param a Vector3 First point
---@param b Vector3 Second point
---@return number Distance between points
function MathUtils.Distance2D(a, b)
	return (a - b):Length2D()
end

---Calculate 3D distance between two Vector3 points
---@param a Vector3 First point
---@param b Vector3 Second point
---@return number Distance between points
function MathUtils.Distance(a, b)
	return (a - b):Length()
end

---Rotate a vector around the Y axis by the given angle (in radians)
---@param vector Vector3 Vector to rotate
---@param angle number Rotation angle in radians
---@return Vector3 Rotated vector
function MathUtils.RotateVectorByYaw(vector, angle)
	local cos = math.cos(angle)
	local sin = math.sin(angle)
	return Vector3(cos * vector.x - sin * vector.y, sin * vector.x + cos * vector.y, vector.z)
end

---Get the angle between two vectors
---@param a Vector3 First vector
---@param b Vector3 Second vector
---@return number Angle in radians
function MathUtils.AngleBetweenVectors(a, b)
	local dot = a:Dot(b)
	local lenA = a:Length()
	local lenB = b:Length()
	if lenA == 0 or lenB == 0 then
		return 0
	end
	local cos = dot / (lenA * lenB)
	return math.acos(MathUtils.Clamp(cos, -1, 1))
end

---Get the angle between two vectors (in degrees)
---@param a Vector3 First vector
---@param b Vector3 Second vector
---@return number Angle in degrees
function MathUtils.AngleBetweenVectorsDeg(a, b)
	return MathUtils.RadToDeg(MathUtils.AngleBetweenVectors(a, b))
end

-- ============================================================================
-- GEOMETRY UTILITIES
-- ============================================================================

---Calculate the normal of a triangle given three points
---@param p1 Vector3 First point
---@param p2 Vector3 Second point
---@param p3 Vector3 Third point
---@return Vector3 Normal vector
function MathUtils.CalculateTriangleNormal(p1, p2, p3)
	local u = p2 - p1
	local v = p3 - p1
	return Vector3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
end

---Check if a point is inside a triangle
---@param point Vector3 Point to check
---@param tri1 Vector3 Triangle vertex 1
---@param tri2 Vector3 Triangle vertex 2
---@param tri3 Vector3 Triangle vertex 3
---@return boolean True if point is inside triangle
function MathUtils.IsPointInTriangle(point, tri1, tri2, tri3)
	local function sign(p1, p2, p3)
		return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
	end

	local d1 = sign(point, tri1, tri2)
	local d2 = sign(point, tri2, tri3)
	local d3 = sign(point, tri3, tri1)

	local has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
	local has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)

	return not (has_neg and has_pos)
end

---Calculate the area of a triangle
---@param p1 Vector3 Triangle vertex 1
---@param p2 Vector3 Triangle vertex 2
---@param p3 Vector3 Triangle vertex 3
---@return number Triangle area
function MathUtils.TriangleArea(p1, p2, p3)
	local a = MathUtils.Distance(p1, p2)
	local b = MathUtils.Distance(p2, p3)
	local c = MathUtils.Distance(p3, p1)
	local s = (a + b + c) / 2
	return math.sqrt(s * (s - a) * (s - b) * (s - c))
end

-- ============================================================================
-- INTERPOLATION AND EASING
-- ============================================================================

---Smooth step function (0-1 range)
---@param t number Input value (0-1)
---@return number Smooth stepped value
function MathUtils.SmoothStep(t)
	t = MathUtils.Clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

---Smooth step function with custom edges
---@param t number Input value
---@param edge0 number Lower edge
---@param edge1 number Upper edge
---@return number Smooth stepped value
function MathUtils.SmoothStepRange(t, edge0, edge1)
	local x = (t - edge0) / (edge1 - edge0)
	return MathUtils.SmoothStep(MathUtils.Clamp(x, 0, 1))
end

---Quadratic easing in (acceleration from zero velocity)
---@param t number Input value (0-1)
---@return number Eased value
function MathUtils.EaseInQuad(t)
	return t * t
end

---Quadratic easing out (deceleration to zero velocity)
---@param t number Input value (0-1)
---@return number Eased value
function MathUtils.EaseOutQuad(t)
	return t * (2 - t)
end

---Quadratic easing in-out
---@param t number Input value (0-1)
---@return number Eased value
function MathUtils.EaseInOutQuad(t)
	if t < 0.5 then
		return 2 * t * t
	else
		return -1 + (4 - 2 * t) * t
	end
end

-- ============================================================================
-- ARRAY AND TABLE UTILITIES
-- ============================================================================

---Find the minimum value in an array
---@param array number[] Array of numbers
---@return number Minimum value
function MathUtils.Min(array)
	local min = array[1]
	for i = 2, #array do
		if array[i] < min then
			min = array[i]
		end
	end
	return min
end

---Find the maximum value in an array
---@param array number[] Array of numbers
---@return number Maximum value
function MathUtils.Max(array)
	local max = array[1]
	for i = 2, #array do
		if array[i] > max then
			max = array[i]
		end
	end
	return max
end

---Calculate the average of an array
---@param array number[] Array of numbers
---@return number Average value
function MathUtils.Average(array)
	local sum = 0
	for _, value in ipairs(array) do
		sum = sum + value
	end
	return sum / #array
end

---Calculate the median of an array
---@param array number[] Array of numbers
---@return number Median value
function MathUtils.Median(array)
	local temp = {}
	for _, value in ipairs(array) do
		table.insert(temp, value)
	end
	table.sort(temp)

	local count = #temp
	if count % 2 == 0 then
		return (temp[count / 2] + temp[count / 2 + 1]) / 2
	else
		return temp[math.ceil(count / 2)]
	end
end

---Round a number to the nearest integer
---@param value number Value to round
---@return integer Rounded integer
function MathUtils.Round(value)
	return math.floor(value + 0.5)
end

---Round a number to specified decimal places
---@param value number Value to round
---@param decimals number Number of decimal places
---@return number Rounded number
function MathUtils.RoundTo(value, decimals)
	local mult = 10 ^ decimals
	return math.floor(value * mult + 0.5) / mult
end

return MathUtils

end)
__bundle_register("MedBot.Navigation.isWalkable.IsWalkable", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Path Validation Module - Uses trace hulls to check if path A→B is walkable
-- This is NOT movement execution, just validation logic
-- Ported from A_standstillDummy.lua (working reference implementation)
local PathValidator = {}
local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local MaxSpeed = 450
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval()
local MAX_SURFACE_ANGLE = 45
local MAX_ITERATIONS = 37

-- Debug mode: set at load time, never changes
local DEBUG_TRACES = false

-- Debug storage
local hullTraces = {}
local lineTraces = {}
local currentTickLogged = -1

-- Trace functions (set at load based on DEBUG_TRACES)
local TraceHullFunc
local TraceLineFunc

-- Wrap trace hull to log positions for debug visualization
local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()

	if currentTick > currentTickLogged then
		hullTraces = {}
		lineTraces = {}
		currentTickLogged = currentTick
	end

	local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask, filter)

	table.insert(hullTraces, {
		startPos = startPos,
		endPos = result.endpos,
		tick = currentTick,
	})

	return result
end

-- Wrap trace line to log positions for debug visualization
local function traceLineWrapper(startPos, endPos, mask, filter)
	local currentTick = globals.TickCount()

	if currentTick > currentTickLogged then
		hullTraces = {}
		lineTraces = {}
		currentTickLogged = currentTick
	end

	local result = engine.TraceLine(startPos, endPos, mask, filter)

	table.insert(lineTraces, {
		startPos = startPos,
		endPos = result.endpos,
		tick = currentTick,
	})

	return result
end

-- Initialize trace functions based on debug mode at load time
if DEBUG_TRACES then
	TraceHullFunc = traceHullWrapper
	TraceLineFunc = traceLineWrapper
else
	TraceHullFunc = engine.TraceHull
	TraceLineFunc = engine.TraceLine
end

-- Filter function for traces
local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

local function Normalize(vec)
	return vec / vec:Length()
end

local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)
	direction.z = direction.z - surfaceNormal.z * dotProduct

	return Normalize(direction)
end

-- Main walkability check - ported from A_standstillDummy.lua
function PathValidator.IsWalkable(startPos, goalPos)
	-- Clear trace tables for debugging
	hullTraces = {}
	lineTraces = {}
	local blocked = false

	-- Initialize variables
	local currentPos = startPos

	-- Adjust start position to ground level
	local startGroundTrace = TraceHullFunc(
		startPos + STEP_HEIGHT_Vector,
		startPos - MAX_FALL_DISTANCE_Vector,
		PLAYER_HULL.Min,
		PLAYER_HULL.Max,
		MASK_PLAYERSOLID,
		shouldHitEntity
	)

	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(goalPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, goalPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		-- Calculate distance to goal and update direction
		local distanceToGoal = (currentPos - goalPos):Length()
		local direction = lastDirection

		-- Calculate next position
		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check
		local wallTrace = TraceHullFunc(
			lastPos + STEP_HEIGHT_Vector,
			NextPos + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)
		currentPos = wallTrace.endpos

		if wallTrace.fraction == 0 then
			blocked = true -- Path is blocked by a wall
		end

		-- Ground collision with segmentation
		local totalDistance = (currentPos - lastPos):Length()
		local numSegments = math.max(1, math.floor(totalDistance / MIN_STEP_SIZE))

		for seg = 1, numSegments do
			local t = seg / numSegments
			local segmentPos = lastPos + (currentPos - lastPos) * t
			local segmentTop = segmentPos + STEP_HEIGHT_Vector
			local segmentBottom = segmentPos - MAX_FALL_DISTANCE_Vector

			local groundTrace = TraceHullFunc(
				segmentTop,
				segmentBottom,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)

			if groundTrace.fraction == 1 then
				return false -- No ground beneath; path is unwalkable
			end

			if groundTrace.fraction > STEP_FRACTION or seg == numSegments then
				-- Adjust position to ground
				direction = adjustDirectionToSurface(direction, groundTrace.plane)
				currentPos = groundTrace.endpos
				blocked = false
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, goalPos)
		if blocked or currentDistance > MaxDistance then
			return false
		elseif currentDistance < 24 then
			local verticalDist = math.abs(goalPos.z - currentPos.z)
			if verticalDist < 24 then
				return true -- Goal is within reach; path is walkable
			else
				return false -- Goal is too far vertically; path is unwalkable
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	return false -- Max iterations reached without finding a path
end

-- Debug visualization - call once per frame
function PathValidator.DrawDebugTraces()
	if not DEBUG_TRACES then
		return
	end

	-- Draw hull traces as blue arrows
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end

	-- Draw line traces as white lines
	for _, trace in ipairs(lineTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(255, 255, 255, 255)
			local w2s_start = client.WorldToScreen(trace.startPos)
			local w2s_end = client.WorldToScreen(trace.endPos)
			if w2s_start and w2s_end then
				draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
			end
		end
	end
end

-- Toggle debug (for runtime switching if needed)
function PathValidator.SetDebug(enabled)
	DEBUG_TRACES = enabled
end

return PathValidator

end)
__bundle_register("MedBot.Navigation.Node", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Node.lua  ·  Clean Node API following black box principles
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local SetupOrchestrator = require("MedBot.Navigation.Setup.SetupOrchestrator")
local Phase3_KDTree = require("MedBot.Navigation.Setup.Phase3_KDTree")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local ConnectionBuilder = require("MedBot.Navigation.ConnectionBuilder")

local Log = Common.Log.new("Node")
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

-- Setup and loading - uses explicit phase orchestration
function Node.Setup()
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return
	end

	-- Explicit flow: Phase1 → Phase2 → SET GLOBAL → Phase3 → Phase4
	SetupOrchestrator.ExecuteFullSetup()
end

function Node.ResetSetup()
	G.Navigation.navMeshUpdated = false
	Log:Info("Navigation setup state reset")
end

function Node.LoadNavFile()
	return SetupOrchestrator.ExecuteFullSetup()
end

function Node.LoadFile(navFile)
	return SetupOrchestrator.ExecuteFullSetup(navFile)
end

-- Node management
function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes and G.Navigation.nodes[id] or nil
end

-- Height check: calculate relative height using node normal (for stairs/slopes)
-- Get Z at position on node's plane, then check height difference
local function getZOnPlane(px, py, nw, ne, sw)
	local v1 = ne - nw
	local v2 = sw - nw
	local normal = Common.Cross(v1, v2)
	if normal.z == 0 then
		return nw.z
	end
	return nw.z - (normal.x * (px - nw.x) + normal.y * (py - nw.y)) / normal.z
end

-- Check if position is within area's horizontal bounds (X/Y) with height limit
-- Uses precomputed bounds from Phase2_Normalize for speed
local function isWithinAreaBounds(pos, node)
	if not node._minX or not node.pos then
		return false
	end

	-- Fast horizontal bounds check using precomputed values (>= for border inclusion)
	local inHorizontalBounds = pos.x >= node._minX
		and pos.x <= node._maxX
		and pos.y >= node._minY
		and pos.y <= node._maxY
	if not inHorizontalBounds then
		return false
	end

	local groundZ = getZOnPlane(pos.x, pos.y, node.nw, node.ne, node.sw)
	local heightAbovePlane = pos.z - groundZ

	-- Allow up to 72 units above plane, up to 5 units below plane
	if heightAbovePlane > 72 or heightAbovePlane < -5 then
		return false
	end

	return true
end

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end

	-- Pure KD-tree search for maximum speed - just return closest by center
	if G.Navigation.kdTree then
		local nearest = Phase3_KDTree.FindNearest(G.Navigation.kdTree, pos)
		if nearest then
			return nearest.node
		end
	end

	-- Fallback: Brute force scan
	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		if not node.isDoor then
			local dist = (node.pos - pos):Length()
			if dist < closestDist then
				closestNode, closestDist = node, dist
			end
		end
	end

	return closestNode
end

-- Get minimum distance from position to area (checks center + all 4 corners)
local function getMinDistanceToArea(pos, node)
	if not node.pos or not node.nw or not node.ne or not node.sw or not node.se then
		return math.huge
	end

	-- Calculate distance to center + all 4 corners
	local distCenter = (node.pos - pos):Length()
	local distNW = (node.nw - pos):Length()
	local distNE = (node.ne - pos):Length()
	local distSW = (node.sw - pos):Length()
	local distSE = (node.se - pos):Length()

	-- Return minimum distance
	return math.min(distCenter, distNW, distNE, distSW, distSE)
end

-- Get area at position - accurate containment check
-- Uses KD-tree to find nearest candidates, checks up to 10 for containment
function Node.GetAreaAtPosition(pos)
	if not G.Navigation.nodes then
		return nil
	end

	-- Use KD-tree for efficient nearest neighbor search
	if G.Navigation.kdTree then
		-- Get 10 nearest candidates by center distance
		local nearest = Phase3_KDTree.FindKNearest(G.Navigation.kdTree, pos, 10)

		-- Check each candidate for containment using precomputed bounds
		for _, candidate in ipairs(nearest) do
			if isWithinAreaBounds(pos, candidate.node) then
				Log:Debug("GetAreaAtPosition: Found containing area %s", candidate.id)
				return candidate.node
			end
		end

		-- No containing area found in top 10, return closest by center
		if nearest[1] then
			Log:Debug("GetAreaAtPosition: No containing area in top 10, using closest %s", nearest[1].id)
			return nearest[1].node
		end
	end

	-- Fallback: Brute force scan with multi-point distance
	local closestNode, closestMinDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		if not node.isDoor then
			-- Check containment first
			if isWithinAreaBounds(pos, node) then
				return node
			end
			-- Track closest for fallback
			local minDist = getMinDistanceToArea(pos, node)
			if minDist < closestMinDist then
				closestNode, closestMinDist = node, minDist
			end
		end
	end

	return closestNode
end

-- Connection utilities
function Node.GetConnectionNodeId(connection)
	return ConnectionUtils.GetNodeId(connection)
end

---@param node Node The node to check
---@return boolean True if the node is a door node
function Node.IsDoorNode(node)
	return node and node.isDoor == true
end

function Node.GetConnectionCost(connection)
	return ConnectionUtils.GetCost(connection)
end

function Node.GetConnectionEntry(nodeA, nodeB)
	return ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
end

function Node.GetDoorTargetPoint(areaA, areaB)
	return ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
end

-- Connection management
function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			table.insert(dir.connections, { node = nodeB.id, cost = 1 })
			dir.count = #dir.connections
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for i = #dir.connections, 1, -1 do
				local targetId = ConnectionUtils.GetNodeId(dir.connections[i])
				if targetId == nodeB.id then
					table.remove(dir.connections, i)
				end
			end
			dir.count = #dir.connections
		end
	end
end

-- Door-aware adjacency: handles areas, doors, and door-to-door connections
function Node.GetAdjacentNodesSimple(node, nodes)
	local neighbors = {}

	if not node.c then
		return neighbors
	end

	for dirId, dir in pairs(node.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				local targetNode = nodes[targetId]

				if targetNode then
					-- Simple adjacency - just return connected nodes
					local cost = (node.pos - targetNode.pos):Length()
					table.insert(neighbors, {
						node = targetNode,
						cost = cost,
					})
				end
			end
		end
	end

	return neighbors
end

-- Optimized version for when only nodes are needed (no cost data)
function Node.GetAdjacentNodesOnly(node, nodes)
	if not node or not node.c or not nodes then
		return {}
	end

	local adjacent = {}
	local count = 0

	-- FIX: Use pairs() for named directional keys, not ipairs()
	for _, dir in pairs(node.c) do
		local connections = dir.connections
		if connections then
			for i = 1, #connections do
				local targetId = ConnectionUtils.GetNodeId(connections[i])
				local targetNode = nodes[targetId]
				if targetNode then
					count = count + 1
					adjacent[count] = targetNode
				end
			end
		end
	end

	return adjacent
end

-- CleanupConnections removed - AccessibilityChecker was disabled (used area centers, not edges)

function Node.NormalizeConnections()
	ConnectionBuilder.NormalizeConnections()
end

function Node.BuildDoorsForConnections()
	ConnectionBuilder.BuildDoorsForConnections()
end

return Node

end)
__bundle_register("MedBot.Navigation.ConnectionBuilder", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  ConnectionBuilder.lua  ·  Facade for door system (delegates to Doors/)
--##########################################################################
--  This module now delegates to the modular door system in Doors/ subfolder.
--  Kept for backward compatibility with existing code.
--##########################################################################

local DoorBuilder = require("MedBot.Navigation.Doors.DoorBuilder")

local ConnectionBuilder = {}

-- Delegate all functions to DoorBuilder module
ConnectionBuilder.NormalizeConnections = DoorBuilder.NormalizeConnections
ConnectionBuilder.BuildDoorsForConnections = DoorBuilder.BuildDoorsForConnections
ConnectionBuilder.BuildDoorToDoorConnections = DoorBuilder.BuildDoorToDoorConnections
ConnectionBuilder.GetConnectionEntry = DoorBuilder.GetConnectionEntry
ConnectionBuilder.GetDoorTargetPoint = DoorBuilder.GetDoorTargetPoint

return ConnectionBuilder

end)
__bundle_register("MedBot.Navigation.Doors.DoorBuilder", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  DoorBuilder.lua  ·  Door system orchestration and connection management
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local DoorGeometry = require("MedBot.Navigation.Doors.DoorGeometry")

local DoorBuilder = {}

local Log = Common.Log.new("DoorBuilder")

-- ========================================================================
-- CONNECTION NORMALIZATION
-- ========================================================================

function DoorBuilder.NormalizeConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						dir.connections[i] = ConnectionUtils.NormalizeEntry(connection)
					end
				end
			end
		end
	end
	Log:Info("Normalized all connections to enriched format")
end

-- ========================================================================
-- DOOR BUILDING
-- ========================================================================

function DoorBuilder.BuildDoorsForConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local doorsBuilt = 0
	local processedPairs = {} -- Track processed area pairs to avoid duplicates
	local doorNodes = {} -- Store created door nodes

	-- Find all unique area-to-area connections
	-- Count total connections first for debugging
	local totalConnections = 0
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					totalConnections = totalConnections + #dir.connections
				end
			end
		end
	end
	Log:Info("Total area connections found: %d", totalConnections)

	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then -- Only process actual areas
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode and not targetNode.isDoor then
							-- Create unique pair key (sorted to avoid duplicates)
							local pairKey = nodeId < targetId and (nodeId .. "_" .. targetId)
								or (targetId .. "_" .. nodeId)

							if not processedPairs[pairKey] then
								processedPairs[pairKey] = true

								-- Find reverse direction (if exists) in ORIGINAL area graph
								local revDir = nil
								local hasReverse = false
								if targetNode.c then
									for tDirId, tDir in pairs(targetNode.c) do
										if tDir.connections then
											for _, tConn in ipairs(tDir.connections) do
												if ConnectionUtils.GetNodeId(tConn) == nodeId then
													hasReverse = true
													revDir = tDirId
													if G.Menu.Visuals and G.Menu.Visuals.Debug_Mode then
														Log:Debug(
															"Connection %s->%s: Found reverse (bidirectional)",
															nodeId,
															targetId
														)
													end
													break
												end
											end
											if hasReverse then
												break
											end
										end
									end
								end

								if not hasReverse then
									if G.Menu.Visuals and G.Menu.Visuals.Debug_Mode then
										Log:Debug("Connection %s->%s: No reverse found (one-way)", nodeId, targetId)
									end
								end

								-- Create SHARED doors (use canonical ordering for IDs)
								local door = DoorGeometry.CreateDoorForAreas(node, targetNode, dirId)
								if door then
									local fwdDir = dirId

									-- Use smaller nodeId first for canonical door IDs
									local doorPrefix = (nodeId < targetId) and (nodeId .. "_" .. targetId)
										or (targetId .. "_" .. nodeId)

									-- Create door nodes with bidirectional connections (if applicable)
									if door.left then
										local doorId = doorPrefix .. "_left"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.left,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										-- Add reverse connection if bidirectional
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end

									if door.middle then
										local doorId = doorPrefix .. "_middle"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.middle,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end

									if door.right then
										local doorId = doorPrefix .. "_right"
										doorNodes[doorId] = {
											id = doorId,
											pos = door.right,
											isDoor = true,
											areaId = nodeId,
											targetAreaId = targetId,
											c = {
												[fwdDir] = { connections = { targetId }, count = 1 },
											},
										}
										if hasReverse and revDir then
											doorNodes[doorId].c[revDir] = { connections = { nodeId }, count = 1 }
										end
										doorsBuilt = doorsBuilt + 1
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Add door nodes to graph
	for doorId, doorNode in pairs(doorNodes) do
		nodes[doorId] = doorNode
	end

	-- Build door-to-door connections FIRST (while area graph is intact)
	DoorBuilder.BuildDoorToDoorConnections()

	-- THEN replace area-to-area connections with area-to-door connections
	for nodeId, node in pairs(nodes) do
		if node.c and not node.isDoor then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					local newConnections = {}

					for _, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]

						if targetNode and not targetNode.isDoor then
							-- Find door nodes - try both orderings (canonical pair key)
							local doorPrefix1 = nodeId .. "_" .. targetId
							local doorPrefix2 = targetId .. "_" .. nodeId
							local foundDoors = false

							-- Try both possible door ID patterns
							for _, prefix in ipairs({ doorPrefix1, doorPrefix2 }) do
								for suffix in pairs({ _left = true, _middle = true, _right = true }) do
									local doorId = prefix .. suffix
									if nodes[doorId] then
										table.insert(newConnections, doorId)
										foundDoors = true
									end
								end
								if foundDoors then
									break
								end -- Found doors with this prefix
							end

							-- If no doors found, keep original connection
							if not foundDoors then
								table.insert(newConnections, connection)
							end
						else
							-- Keep non-area connections
							table.insert(newConnections, connection)
						end
					end

					dir.connections = newConnections
					dir.count = #newConnections
				end
			end
		end
	end

	Log:Info("Built " .. doorsBuilt .. " door nodes for connections")
end

-- ========================================================================
-- DOOR-TO-DOOR CONNECTIONS
-- ========================================================================

-- Determine spatial direction between two positions using NESW indices
-- Returns dirId (1=North, 2=East, 3=South, 4=West) compatible with nav mesh format
local function calculateSpatialDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y

	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 2 or 4 -- East=2, West=4
	else
		return (dy > 0) and 3 or 1 -- South=3, North=1
	end
end

-- Create optimized door-to-door connections
function DoorBuilder.BuildDoorToDoorConnections()
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	local connectionsAdded = 0
	local doorsByArea = {}

	-- Group doors by area for efficient lookup
	-- Only add door to an area if it connects BACK to that area (not one-way exit)
	for doorId, doorNode in pairs(nodes) do
		if doorNode.isDoor and doorNode.c then
			-- Check which areas this door connects TO
			for _, dir in pairs(doorNode.c) do
				if dir.connections then
					for _, conn in ipairs(dir.connections) do
						local connectedAreaId = ConnectionUtils.GetNodeId(conn)
						-- Add door to the area it connects to
						if not doorsByArea[connectedAreaId] then
							doorsByArea[connectedAreaId] = {}
						end
						table.insert(doorsByArea[connectedAreaId], doorNode)
					end
				end
			end
		end
	end

	-- Helper to calculate which side a door is on relative to an area
	local function getDoorSideForArea(doorPos, areaId)
		local area = nodes[areaId]
		if not area or not area.pos then
			return nil
		end

		local dx = doorPos.x - area.pos.x
		local dy = doorPos.y - area.pos.y

		if math.abs(dx) > math.abs(dy) then
			return (dx > 0) and 4 or 8 -- East=4, West=8
		else
			return (dy > 0) and 2 or 1 -- South=2, North=1
		end
	end

	-- Connect doors within each area (respecting one-way connections)
	for areaId, doors in pairs(doorsByArea) do
		for i = 1, #doors do
			local doorA = doors[i]

			for j = 1, #doors do
				if i ~= j then
					local doorB = doors[j]

					-- Calculate which side each door is on RELATIVE TO THIS AREA
					local sideA = getDoorSideForArea(doorA.pos, areaId)
					local sideB = getDoorSideForArea(doorB.pos, areaId)

					-- ONLY connect doors on DIFFERENT sides to avoid wall collisions
					if sideA and sideB and sideA ~= sideB then
						-- Check if BOTH doors are bidirectional (not one-way drops)
						-- One-way doors (dirCount == 1) should not participate in door-to-door
						local doorAIsBidirectional = false
						local doorBIsBidirectional = false

						if doorA.c then
							local dirCount = 0
							for _ in pairs(doorA.c) do
								dirCount = dirCount + 1
							end
							doorAIsBidirectional = (dirCount >= 2)
						end

						if doorB.c then
							local dirCount = 0
							for _ in pairs(doorB.c) do
								dirCount = dirCount + 1
							end
							doorBIsBidirectional = (dirCount >= 2)
						end

						-- Only create door-to-door if BOTH doors are bidirectional
						if doorAIsBidirectional and doorBIsBidirectional then
							local spatialDirAtoB = calculateSpatialDirection(doorA.pos, doorB.pos)

							if not doorA.c[spatialDirAtoB] then
								doorA.c[spatialDirAtoB] = { connections = {}, count = 0 }
							end

							-- Add A→B connection
							local alreadyConnected = false
							for _, conn in ipairs(doorA.c[spatialDirAtoB].connections) do
								if ConnectionUtils.GetNodeId(conn) == doorB.id then
									alreadyConnected = true
									break
								end
							end

							if not alreadyConnected then
								table.insert(doorA.c[spatialDirAtoB].connections, doorB.id)
								doorA.c[spatialDirAtoB].count = #doorA.c[spatialDirAtoB].connections
								connectionsAdded = connectionsAdded + 1
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Added " .. connectionsAdded .. " door-to-door connections for path optimization")
end

-- ========================================================================
-- UTILITY FUNCTIONS
-- ========================================================================

function DoorBuilder.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then
		return nil
	end

	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				if targetId == nodeB.id then
					-- Return connection info if it's a table, otherwise just the ID
					if type(connection) == "table" then
						return connection
					else
						-- For door connections (strings), return basic info
						return {
							nodeId = connection,
							isDoorConnection = true,
						}
					end
				end
			end
		end
	end
	return nil
end

function DoorBuilder.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then
		return nil
	end

	-- Find door nodes that connect areaA to areaB
	local nodes = G.Navigation.nodes
	if not nodes then
		return areaB.pos
	end

	-- Look for door nodes that have areaA as source and areaB as target
	local doorBaseId = areaA.id .. "_" .. areaB.id
	local doorPositions = {}

	-- Check all three door positions (left, middle, right)
	for _, suffix in ipairs({ "_left", "_middle", "_right" }) do
		local doorId = doorBaseId .. suffix
		local doorNode = nodes[doorId]
		if doorNode and doorNode.pos then
			table.insert(doorPositions, doorNode.pos)
		end
	end

	if #doorPositions > 0 then
		-- Find closest door position to destination
		local bestPos = doorPositions[1]
		local bestDist = (doorPositions[1] - areaB.pos):Length()

		for i = 2, #doorPositions do
			local dist = (doorPositions[i] - areaB.pos):Length()
			if dist < bestDist then
				bestPos = doorPositions[i]
				bestDist = dist
			end
		end

		return bestPos
	end

	return areaB.pos
end

return DoorBuilder

end)
__bundle_register("MedBot.Navigation.Doors.DoorGeometry", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  DoorGeometry.lua  ·  Door geometry generation from nav area edges
--##########################################################################

local Common = require("MedBot.Core.Common")

local DoorGeometry = {}

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72

local Log = Common.Log.new("DoorGeometry")

-- ========================================================================
-- GEOMETRY HELPERS
-- ========================================================================

-- Linear interpolation between two Vector3 points
local function lerpVec(a, b, t)
	return Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

-- Scalar lerp
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Convert dirId (nav mesh NESW index) to direction vector
-- Source Engine format: connectionData[4] in NESW order
local function dirIdToVector(dirId)
	if dirId == 1 then
		return 0, -1
	end -- North
	if dirId == 2 then
		return 1, 0
	end -- East
	if dirId == 3 then
		return 0, 1
	end -- South
	if dirId == 4 then
		return -1, 0
	end -- West
	return 0, 0 -- Invalid
end

-- Get the two corners of an area that face the given direction
local function getFacingEdgeCorners(area, dirX, dirY)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end

	if dirX == 1 then
		return area.ne, area.se
	end -- East
	if dirX == -1 then
		return area.sw, area.nw
	end -- West
	if dirY == 1 then
		return area.se, area.sw
	end -- South
	if dirY == -1 then
		return area.nw, area.ne
	end -- North

	return nil, nil
end

-- Compute scalar overlap on an axis and return segment [a1,a2] overlapped with [b1,b2]
local function overlap1D(a1, a2, b1, b2)
	if a1 > a2 then
		a1, a2 = a2, a1
	end
	if b1 > b2 then
		b1, b2 = b2, b1
	end
	local left = math.max(a1, b1)
	local right = math.min(a2, b2)
	if right <= left then
		return nil
	end
	return left, right
end

-- Determine which area owns the door based on edge heights
local function calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)
	local aZmax = math.max(a0.z, a1.z)
	local bZmax = math.max(b0.z, b1.z)

	if aZmax > bZmax + 0.5 then
		return "A", areaA.id
	elseif bZmax > aZmax + 0.5 then
		return "B", areaB.id
	else
		return "TIE", math.max(areaA.id, areaB.id)
	end
end

-- ========================================================================
-- DOOR GEOMETRY CALCULATION
-- ========================================================================

-- Calculate edge overlap and door geometry
local function calculateDoorGeometry(areaA, areaB, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(areaA, dirX, dirY)
	local b0, b1 = getFacingEdgeCorners(areaB, -dirX, -dirY)
	if not (a0 and a1 and b0 and b1) then
		return nil
	end

	local owner, ownerId = calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)

	return {
		a0 = a0,
		a1 = a1,
		b0 = b0,
		b1 = b1,
		owner = owner,
		ownerId = ownerId,
	}
end

-- Create door geometry for connection between two areas
function DoorGeometry.CreateDoorForAreas(areaA, areaB, dirId)
	if not (areaA and areaB and areaA.pos and areaB.pos) then
		return nil
	end

	-- Convert dirId from connection to direction vector
	local dirX, dirY = dirIdToVector(dirId)

	local geometry = calculateDoorGeometry(areaA, areaB, dirX, dirY)
	if not geometry then
		return nil
	end

	local a0, a1, b0, b1 = geometry.a0, geometry.a1, geometry.b0, geometry.b1

	-- Pick higher Z border as base (door stays at owner's boundary)
	local aMaxZ = math.max(a0.z, a1.z)
	local bMaxZ = math.max(b0.z, b1.z)
	local baseEdge0, baseEdge1
	if bMaxZ > aMaxZ + 0.5 then
		baseEdge0, baseEdge1 = b0, b1 -- Use B's edge (B is owner)
	else
		baseEdge0, baseEdge1 = a0, a1 -- Use A's edge (A is owner)
	end

	-- Determine shared axis: vertical edge (Y varies) or horizontal edge (X varies)
	local axis, constAxis
	if dirX ~= 0 then
		-- East/West connection → vertical shared edge → Y axis varies
		axis = "y"
		constAxis = "x"
	else
		-- North/South connection → horizontal shared edge → X axis varies
		axis = "x"
		constAxis = "y"
	end

	-- Pure 1D overlap on shared axis (common boundary)
	local aMin = math.min(a0[axis], a1[axis])
	local aMax = math.max(a0[axis], a1[axis])
	local bMin = math.min(b0[axis], b1[axis])
	local bMax = math.max(b0[axis], b1[axis])

	local overlapMin = math.max(aMin, bMin)
	local overlapMax = math.min(aMax, bMax)

	-- If overlap too small, create center-only door at center of smaller area's edge
	if overlapMax - overlapMin < HITBOX_WIDTH then
		-- Determine which area has smaller edge
		local aEdgeLen = aMax - aMin
		local bEdgeLen = bMax - bMin

		-- Use center of smaller edge for better door placement
		local centerPoint
		if aEdgeLen <= bEdgeLen then
			centerPoint = lerpVec(a0, a1, 0.5) -- A has smaller edge
		else
			centerPoint = lerpVec(b0, b1, 0.5) -- B has smaller edge
		end

		return {
			left = nil,
			middle = centerPoint,
			right = nil,
			owner = geometry.ownerId,
			needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
		}
	end

	-- Get area bounds on the door's varying axis
	local areaBoundsA = { min = aMin, max = aMax }
	local areaBoundsB = { min = bMin, max = bMax }

	-- Build door points ON the owner's edge line (stays on edge even if sloped)
	local function pointOnEdge(axisVal)
		-- Calculate interpolation factor along varying axis
		local t = (baseEdge1[axis] - baseEdge0[axis]) ~= 0
				and ((axisVal - baseEdge0[axis]) / (baseEdge1[axis] - baseEdge0[axis]))
			or 0.5
		t = math.max(0, math.min(1, t))

		-- Interpolate ALL components to stay on the edge line
		local pos = Vector3(
			lerp(baseEdge0.x, baseEdge1.x, t),
			lerp(baseEdge0.y, baseEdge1.y, t),
			lerp(baseEdge0.z, baseEdge1.z, t)
		)

		return pos
	end

	local overlapLeft = pointOnEdge(overlapMin)
	local overlapRight = pointOnEdge(overlapMax)

	-- STEP 1: Apply boundary clamping FIRST (shearing - stay within common area)
	local commonMin = math.max(areaBoundsA.min, areaBoundsB.min)
	local commonMax = math.min(areaBoundsA.max, areaBoundsB.max)

	-- Clamp left endpoint to common bounds and snap back to edge line
	local leftCoord = overlapLeft[axis]
	local rightCoord = overlapRight[axis]

	if leftCoord < commonMin then
		overlapLeft = pointOnEdge(commonMin) -- Recalculate to stay on edge
	elseif leftCoord > commonMax then
		overlapLeft = pointOnEdge(commonMax) -- Recalculate to stay on edge
	end

	-- Clamp right endpoint to common bounds and snap back to edge line
	if rightCoord < commonMin then
		overlapRight = pointOnEdge(commonMin) -- Recalculate to stay on edge
	elseif rightCoord > commonMax then
		overlapRight = pointOnEdge(commonMax) -- Recalculate to stay on edge
	end

	-- Calculate door width and middle point
	local finalWidth = (overlapRight - overlapLeft):Length2D()
	if finalWidth < HITBOX_WIDTH then
		-- Too narrow after clamping, use center of smaller area's edge
		local aEdgeLen = aMax - aMin
		local bEdgeLen = bMax - bMin

		local centerPoint
		if aEdgeLen <= bEdgeLen then
			centerPoint = lerpVec(a0, a1, 0.5) -- A has smaller edge
		else
			centerPoint = lerpVec(b0, b1, 0.5) -- B has smaller edge
		end

		return {
			left = nil,
			middle = centerPoint,
			right = nil,
			owner = geometry.ownerId,
			needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
		}
	end

	local middle = lerpVec(overlapLeft, overlapRight, 0.5)

	-- STEP 2: Wall avoidance - shrink door by 24 units from wall corners on door axis
	local WALL_CLEARANCE = 24

	-- Get current door bounds on varying axis
	local leftCoordFinal = overlapLeft[axis]
	local rightCoordFinal = overlapRight[axis]
	local minDoor = math.min(leftCoordFinal, rightCoordFinal)
	local maxDoor = math.max(leftCoordFinal, rightCoordFinal)

	-- Track how much to shrink from each side
	local shrinkFromMin = 0
	local shrinkFromMax = 0

	-- Check all wall corners from both areas
	for _, area in ipairs({ areaA, areaB }) do
		if area.wallCorners then
			for _, wallCorner in ipairs(area.wallCorners) do
				-- Get coordinates on both axes
				local cornerVaryingCoord = wallCorner[axis] -- Door varies on this axis

				-- Calculate closest point on door edge line to this corner
				local edgePoint = pointOnEdge(cornerVaryingCoord)

				-- FIRST: Check if wall corner is near the door edge line
				-- Calculate distance from corner to its projection on the edge
				local distToEdge = (wallCorner - edgePoint):Length2D()
				if distToEdge > WALL_CLEARANCE then
					goto continue_corner -- Corner is too far away from door edge
				end

				-- SECOND: Check distance to door endpoints on the VARYING axis
				local distToMin = math.abs(cornerVaryingCoord - minDoor)
				local distToMax = math.abs(cornerVaryingCoord - maxDoor)

				-- Shrink from min side if wall corner is within 24 units of it
				if distToMin < WALL_CLEARANCE then
					shrinkFromMin = math.max(shrinkFromMin, WALL_CLEARANCE - distToMin)
				end

				-- Shrink from max side if wall corner is within 24 units of it
				if distToMax < WALL_CLEARANCE then
					shrinkFromMax = math.max(shrinkFromMax, WALL_CLEARANCE - distToMax)
				end

				::continue_corner::
			end
		end
	end

	-- Apply shrinking to door endpoints and snap back to edge line
	if shrinkFromMin > 0 then
		local newCoord
		if leftCoordFinal < rightCoordFinal then
			newCoord = leftCoordFinal + shrinkFromMin
		else
			newCoord = leftCoordFinal - shrinkFromMin
		end
		overlapLeft = pointOnEdge(newCoord) -- Snap to edge line after shrinking
	end

	if shrinkFromMax > 0 then
		local newCoord
		if rightCoordFinal > leftCoordFinal then
			newCoord = rightCoordFinal - shrinkFromMax
		else
			newCoord = rightCoordFinal + shrinkFromMax
		end
		overlapRight = pointOnEdge(newCoord) -- Snap to edge line after shrinking
	end

	-- Recalculate width after wall avoidance
	local finalWidthAfterWalls = (overlapRight - overlapLeft):Length2D()

	-- Check if this is a narrow passage (< 48 units = bottleneck)
	local isNarrowPassage = finalWidthAfterWalls < (HITBOX_WIDTH * 2)

	return {
		left = isNarrowPassage and nil or overlapLeft,
		middle = middle, -- Always create middle door
		right = isNarrowPassage and nil or overlapRight,
		owner = geometry.ownerId,
		needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT,
	}
end

return DoorGeometry

end)
__bundle_register("MedBot.Navigation.ConnectionUtils", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  ConnectionUtils.lua  ·  Connection data handling utilities
--##########################################################################

local ConnectionUtils = {}

-- Extract node ID from connection (handles both integer and table format)
function ConnectionUtils.GetNodeId(connection)
	if type(connection) == "table" then
		return connection.node or connection.neighborId
	else
		return connection
	end
end

-- Extract cost from connection (handles both integer and table format)
function ConnectionUtils.GetCost(connection)
	if type(connection) == "table" then
		return connection.cost or 0
	else
		return 0
	end
end

-- Normalize a single connection entry to the enriched table form
function ConnectionUtils.NormalizeEntry(entry)
	if type(entry) == "table" then
		entry.node = entry.node or entry.neighborId
		entry.cost = entry.cost or 0
		if entry.left then
			entry.left = Vector3(entry.left.x, entry.left.y, entry.left.z)
		end
		if entry.middle then
			entry.middle = Vector3(entry.middle.x, entry.middle.y, entry.middle.z)
		end
		if entry.right then
			entry.right = Vector3(entry.right.x, entry.right.y, entry.right.z)
		end
		return entry
	else
		return { node = entry, cost = 0, left = nil, middle = nil, right = nil }
	end
end

return ConnectionUtils

end)
__bundle_register("MedBot.Navigation.Setup.Phase3_KDTree", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Phase3_KDTree.lua  ·  Build spatial index for fast nearest-neighbor queries
--##########################################################################

local Common = require("MedBot.Core.Common")

local Phase3_KDTree = {}

local Log = Common.Log.new("Phase3_KDTree")

--##########################################################################
--  LOCAL HELPERS
--##########################################################################

-- Simple 3D KD-tree implementation for fast nearest-neighbor search
-- Builds from nodes in G.Navigation.nodes (called after basic setup complete)

local function buildKDTree(nodes)
	-- Collect all non-door nodes into array
	local points = {}
	for id, node in pairs(nodes) do
		if not node.isDoor and node.pos then
			table.insert(points, {
				pos = node.pos,
				id = id,
				node = node,
			})
		end
	end

	if #points == 0 then
		Log:Warn("No valid nodes for KD-tree")
		return nil
	end

	-- Build tree recursively
	local function build(pointList, depth)
		if #pointList == 0 then
			return nil
		end

		-- Axis cycling: 0=x, 1=y, 2=z
		local axis = depth % 3
		local axisName = (axis == 0) and "x" or (axis == 1) and "y" or "z"

		-- Sort by current axis
		table.sort(pointList, function(a, b)
			return a.pos[axisName] < b.pos[axisName]
		end)

		local medianIdx = math.floor(#pointList / 2) + 1
		local median = pointList[medianIdx]

		-- Split into left/right
		local leftPoints = {}
		local rightPoints = {}
		for i = 1, #pointList do
			if i < medianIdx then
				table.insert(leftPoints, pointList[i])
			elseif i > medianIdx then
				table.insert(rightPoints, pointList[i])
			end
		end

		return {
			point = median,
			axis = axis,
			left = build(leftPoints, depth + 1),
			right = build(rightPoints, depth + 1),
		}
	end

	return build(points, 0)
end

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Build KD-tree spatial index for all area nodes
--- Called after basic setup (nodes in global) but before door generation
--- @return table KD-tree root node
function Phase3_KDTree.Execute(nodes)
	assert(type(nodes) == "table", "Phase3_KDTree.Execute: nodes must be table")

	Log:Info("Building KD-tree spatial index")

	local tree = buildKDTree(nodes)
	if tree then
		Log:Info("Phase 3 complete: KD-tree built")
	else
		Log:Warn("Phase 3: KD-tree build failed")
	end

	return tree
end

--- Find nearest neighbor using KD-tree
--- @param tree table KD-tree root
--- @param pos Vector3 query position
--- @return table|nil nearest point {pos, id, node}
function Phase3_KDTree.FindNearest(tree, pos)
	if not tree or not pos then
		return nil
	end

	local bestDistSq = math.huge
	local best = nil

	local function search(node, depth)
		if not node then
			return
		end

		local axis = node.axis
		local axisName = (axis == 0) and "x" or (axis == 1) and "y" or "z"
		local diff = pos[axisName] - node.point.pos[axisName]
		local distSq = (node.point.pos - pos):LengthSqr()

		if distSq < bestDistSq then
			bestDistSq = distSq
			best = node.point
		end

		-- Choose branch
		local first, second
		if diff < 0 then
			first, second = node.left, node.right
		else
			first, second = node.right, node.left
		end

		search(first, depth + 1)

		-- Check if we need to search other side
		if diff * diff < bestDistSq then
			search(second, depth + 1)
		end
	end

	search(tree, 0)
	return best
end

--- Find K nearest neighbors using KD-tree
--- @param tree table KD-tree root
--- @param pos Vector3 query position
--- @param k number maximum number of neighbors to find
--- @return table array of nearest points {pos, id, node}, sorted by distance
function Phase3_KDTree.FindKNearest(tree, pos, k)
	if not tree or not pos or k <= 0 then
		return {}
	end

	-- Max-heap to track K best candidates (farthest at top for easy eviction)
	local candidates = {}
	local count = 0

	local function addCandidate(point, distSq)
		if count < k then
			-- Add to heap
			count = count + 1
			candidates[count] = { point = point, distSq = distSq }
			-- Bubble up to maintain max-heap property
			local i = count
			while i > 1 do
				local parent = math.floor(i / 2)
				if candidates[parent].distSq >= candidates[i].distSq then
					break
				end
				candidates[parent], candidates[i] = candidates[i], candidates[parent]
				i = parent
			end
		elseif distSq < candidates[1].distSq then
			-- Replace farthest
			candidates[1] = { point = point, distSq = distSq }
			-- Heapify down
			local i = 1
			while true do
				local left = i * 2
				local right = left + 1
				local largest = i

				if left <= count and candidates[left].distSq > candidates[largest].distSq then
					largest = left
				end
				if right <= count and candidates[right].distSq > candidates[largest].distSq then
					largest = right
				end
				if largest == i then
					break
				end
				candidates[i], candidates[largest] = candidates[largest], candidates[i]
				i = largest
			end
		end
	end

	local function search(node, depth)
		if not node then
			return
		end

		local axis = node.axis
		local axisName = (axis == 0) and "x" or (axis == 1) and "y" or "z"
		local diff = pos[axisName] - node.point.pos[axisName]
		local distSq = (node.point.pos - pos):LengthSqr()

		addCandidate(node.point, distSq)

		-- Choose branch
		local first, second
		if diff < 0 then
			first, second = node.left, node.right
		else
			first, second = node.right, node.left
		end

		search(first, depth + 1)

		-- Check if we need to search other side
		-- Search other side if: (1) we don't have K candidates yet, or (2) hyperplane could have closer points
		local worstDistSq = count > 0 and candidates[1].distSq or math.huge
		if diff * diff < worstDistSq then
			search(second, depth + 1)
		end
	end

	search(tree, 0)

	-- Sort by distance (ascending) for return
	table.sort(candidates, function(a, b)
		return a.distSq < b.distSq
	end)

	-- Return just the points
	local result = {}
	for i = 1, count do
		result[i] = candidates[i].point
	end
	return result
end

return Phase3_KDTree

end)
__bundle_register("MedBot.Navigation.Setup.SetupOrchestrator", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  SetupOrchestrator.lua  ·  Coordinates all setup phases explicitly
--##########################################################################
--
--  Flow:
--    Phase1: Load raw nav file → nodes
--    Phase2: Normalize connections → nodes (enriched)
--    [SET G.Navigation.nodes = nodes]  <- BASIC SETUP COMPLETE
--    Phase3: Build KD-tree spatial index (uses global nodes)
--    Phase4: Wall corners + Door generation (uses global nodes)
--
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local Phase1_NavLoad = require("MedBot.Navigation.Setup.Phase1_NavLoad")
local Phase2_Normalize = require("MedBot.Navigation.Setup.Phase2_Normalize")
local Phase3_KDTree = require("MedBot.Navigation.Setup.Phase3_KDTree")
local Phase4_Doors = require("MedBot.Navigation.Setup.Phase4_Doors")

local SetupOrchestrator = {}

local Log = Common.Log.new("SetupOrchestrator")

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Execute full navigation setup with explicit data flow
--- @param navFilePath string|nil Optional nav file path, or auto-detect from map
--- @return boolean success
function SetupOrchestrator.ExecuteFullSetup(navFilePath)
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return true
	end

	-- Auto-detect nav file if not provided
	if not navFilePath then
		local mapName = engine.GetMapName()
		if not mapName or mapName == "" then
			Log:Error("No map name available and no nav file path provided")
			return false
		end
		navFilePath = "tf/" .. string.gsub(mapName, ".bsp", ".nav")
	end

	Log:Info("=== Starting Navigation Setup ===")
	Log:Info("Target: %s", navFilePath)

	-- ========================================================================
	-- PHASE 1: Load raw nav data
	-- ========================================================================
	local nodes, err = Phase1_NavLoad.Execute(navFilePath)
	if not nodes then
		Log:Error("Phase 1 failed: %s", err or "unknown error")

		-- Auto-generate if file not found
		if err == "File not found" then
			Log:Warning("Nav file not found, attempting generation...")
			local generated = SetupOrchestrator.TryGenerateNavFile()
			if generated then
				-- Retry once after generation
				nodes, err = Phase1_NavLoad.Execute(navFilePath)
			end
		end

		if not nodes then
			return false
		end
	end

	-- ========================================================================
	-- PHASE 2: Normalize connections (basic enrichment)
	-- ========================================================================
	nodes = Phase2_Normalize.Execute(nodes)

	-- ========================================================================
	-- BASIC SETUP COMPLETE - Set global for advanced phases
	-- ========================================================================
	G.Navigation.nodes = nodes

	-- Count nodes (dictionary table, # operator doesn't work)
	local nodeCount = 0
	for _ in pairs(nodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Basic setup complete: %d nodes ready", nodeCount)

	-- ========================================================================
	-- PHASE 3: Build KD-tree spatial index
	-- ========================================================================
	local kdTree = Phase3_KDTree.Execute(nodes)
	if kdTree then
		G.Navigation.kdTree = kdTree
	end

	-- ========================================================================
	-- PHASE 4: Advanced parsing (doors, wall corners)
	-- ========================================================================
	local success = Phase4_Doors.Execute()
	if not success then
		Log:Error("Phase 4 (advanced parsing) failed")
		-- Still mark as updated since basic setup worked
	end

	G.Navigation.navMeshUpdated = true
	Log:Info("=== Navigation Setup Complete ===")
	return true
end

--- Try to generate nav file using game commands
--- @return boolean success
function SetupOrchestrator.TryGenerateNavFile()
	local ok = pcall(function()
		client.RemoveConVarProtection("sv_cheats")
		client.RemoveConVarProtection("nav_generate")
		client.SetConVar("sv_cheats", "1")
		client.Command("nav_generate", true)
	end)

	if not ok then
		Log:Error("Failed to initiate nav generation")
		return false
	end

	Log:Info("Nav generation initiated, waiting...")

	-- Wait for generation (10 seconds)
	local startTime = os.time()
	repeat
	until os.time() - startTime > 10

	return true
end

--- Execute ONLY basic setup (Phases 1-2), no doors/KD-tree
--- Useful for testing or when advanced features not needed
--- @param navFilePath string|nil Optional nav file path
--- @return table|nil nodes
function SetupOrchestrator.ExecuteBasicSetup(navFilePath)
	if not navFilePath then
		local mapName = engine.GetMapName()
		if not mapName or mapName == "" then
			Log:Error("No map name available")
			return nil
		end
		navFilePath = "tf/" .. string.gsub(mapName, ".bsp", ".nav")
	end

	Log:Info("=== Starting Basic Navigation Setup ===")

	local nodes, err = Phase1_NavLoad.Execute(navFilePath)
	if not nodes then
		Log:Error("Phase 1 failed: %s", err or "unknown error")
		return nil
	end

	nodes = Phase2_Normalize.Execute(nodes)

	G.Navigation.nodes = nodes
	G.Navigation.navMeshUpdated = true

	-- Count nodes (dictionary table, # operator doesn't work)
	local nodeCount = 0
	for _ in pairs(nodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Basic setup complete: %d nodes", nodeCount)
	return nodes
end

return SetupOrchestrator

end)
__bundle_register("MedBot.Navigation.Setup.Phase4_Doors", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Phase4_Doors.lua  ·  Door generation, wall corners, and advanced connections
--##########################################################################

local Common = require("MedBot.Core.Common")
local WallCornerGenerator = require("MedBot.Navigation.WallCornerGenerator")
local DoorBuilder = require("MedBot.Navigation.Doors.DoorBuilder")

local Phase4_Doors = {}

local Log = Common.Log.new("Phase4_Doors")

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Execute advanced parsing: wall corners and door generation
--- Assumes nodes are already in G.Navigation.nodes (basic setup complete)
--- @return boolean success
function Phase4_Doors.Execute()
    Log:Info("Starting Phase 4: Advanced parsing (doors + wall corners)")

    -- Step 1: Detect wall corners (uses G.Navigation.nodes internally)
    local success = pcall(function()
        WallCornerGenerator.DetectWallCorners()
    end)

    if not success then
        Log:Error("Wall corner detection failed")
        -- Continue anyway - doors can work without corners
    else
        Log:Info("Wall corners detected")
    end

    -- Step 2: Build doors for connections (modifies G.Navigation.nodes)
    success = pcall(function()
        DoorBuilder.BuildDoorsForConnections()
    end)

    if not success then
        Log:Error("Door building failed")
        return false
    end

    Log:Info("Phase 4 complete: Doors and connections built")
    return true
end

return Phase4_Doors

end)
__bundle_register("MedBot.Navigation.WallCornerGenerator", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  WallCornerGenerator.lua · Detects wall corners for door clamping
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local WallCornerGenerator = {}

local Log = Common.Log.new("WallCornerGenerator")

-- Group neighbors by 4 directions for an area using existing dirId from connections
-- Source Engine nav format: connectionData[4] in NESW order (North, East, South, West)
local DIR_NAMES = { "north", "east", "south", "west" } -- dirId 1-4 maps to NESW

local function groupNeighborsByDirection(area, nodes)
	local neighbors = {
		north = {}, -- dirId = 1
		east = {},  -- dirId = 2
		south = {}, -- dirId = 3
		west = {},  -- dirId = 4
	}

	if not area.c then
		Log:Debug("groupNeighborsByDirection: area.c is nil for area %s", tostring(area.id))
		return neighbors
	end

	-- Use dirId to directly index direction name
	for dirId, dir in pairs(area.c) do
		if dir.connections then
			local dirName = DIR_NAMES[dirId]
			if dirName then
				for _, connection in ipairs(dir.connections) do
					local targetId = (type(connection) == "table") and connection.node or connection
					local neighbor = nodes[targetId]
					if neighbor then
						table.insert(neighbors[dirName], neighbor)
					end
				end
			end
		end
	end

	return neighbors
end

-- Check if point lies on neighbor's facing boundary using shared axis
-- Returns: proximity score (0.99 if at edge, 1.0 if perfectly within), and the neighbor
local function checkPointOnNeighborBoundary(point, neighbor, direction)
	if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
		return 0, nil
	end

	local tolerance = 2.0 -- Increased to handle minor nav mesh misalignments

	-- Determine shared axis and get neighbor's facing edge bounds
	local axis, corner1, corner2
	if direction == "north" then
		axis = "x"
		corner1, corner2 = neighbor.sw, neighbor.se -- Neighbor's south boundary
	elseif direction == "south" then
		axis = "x"
		corner1, corner2 = neighbor.nw, neighbor.ne -- Neighbor's north boundary
	elseif direction == "east" then
		axis = "y"
		corner1, corner2 = neighbor.sw, neighbor.nw -- Neighbor's west boundary
	elseif direction == "west" then
		axis = "y"
		corner1, corner2 = neighbor.se, neighbor.ne -- Neighbor's east boundary
	else
		return 0, nil
	end

	-- Get bounds on shared axis
	local minCoord = math.min(corner1[axis], corner2[axis])
	local maxCoord = math.max(corner1[axis], corner2[axis])
	local pointCoord = point[axis]

	-- Outside bounds entirely
	if pointCoord < minCoord - tolerance or pointCoord > maxCoord + tolerance then
		return 0, nil
	end

	-- Check if at edge (near min or max boundary)
	local distFromMin = math.abs(pointCoord - minCoord)
	local distFromMax = math.abs(pointCoord - maxCoord)

	if distFromMin < tolerance or distFromMax < tolerance then
		return 0.99, neighbor -- At edge
	else
		return 1.0, neighbor -- Perfectly within
	end
end

-- Get corner type and its two adjacent directions
-- Returns: dir1, dir2 (the two directions adjacent to this corner)
local function getCornerDirections(area, corner)
	if corner == area.nw then
		return "north", "west"
	elseif corner == area.ne then
		return "north", "east"
	elseif corner == area.se then
		return "south", "east"
	elseif corner == area.sw then
		return "south", "west"
	end
	return nil, nil
end

-- Get diagonal direction from two adjacent directions
local function getDiagonalDirection(dir1, dir2)
	if (dir1 == "north" and dir2 == "east") or (dir1 == "east" and dir2 == "north") then
		return "north", "east" -- NE diagonal
	elseif (dir1 == "north" and dir2 == "west") or (dir1 == "west" and dir2 == "north") then
		return "north", "west" -- NW diagonal
	elseif (dir1 == "south" and dir2 == "east") or (dir1 == "east" and dir2 == "south") then
		return "south", "east" -- SE diagonal
	elseif (dir1 == "south" and dir2 == "west") or (dir1 == "west" and dir2 == "south") then
		return "south", "west" -- SW diagonal
	end
	return nil, nil
end

function WallCornerGenerator.DetectWallCorners()
	local nodes = G.Navigation.nodes
	if not nodes then
		Log:Warn("No nodes available for wall corner detection")
		return
	end

	local wallCornerCount = 0
	local allCornerCount = 0
	local nodeCount = 0

	for nodeId, area in pairs(nodes) do
		nodeCount = nodeCount + 1
		if area.nw and area.ne and area.se and area.sw then
			-- Initialize wall corner storage on node
			area.wallCorners = {}
			area.allCorners = {}

			local neighbors = groupNeighborsByDirection(area, nodes)

			-- Debug: log neighbor counts for first few nodes
			if nodeCount <= 3 then
				local totalNeighbors = #neighbors.north + #neighbors.south + #neighbors.east + #neighbors.west
				Log:Debug(
					"Node %s has %d neighbors (N:%d S:%d E:%d W:%d)",
					tostring(nodeId),
					totalNeighbors,
					#neighbors.north,
					#neighbors.south,
					#neighbors.east,
					#neighbors.west
				)
			end

			-- Check all 4 corners individually
			local corners = { area.nw, area.ne, area.se, area.sw }
			for _, corner in ipairs(corners) do
				table.insert(area.allCorners, corner)
				allCornerCount = allCornerCount + 1

				-- Get the two adjacent directions for this corner
				local dir1, dir2 = getCornerDirections(area, corner)
				if not dir1 or not dir2 then
					goto continue_corner
				end

				-- FAST PATH: Check if either adjacent direction is empty
				local hasDir1 = neighbors[dir1] and #neighbors[dir1] > 0
				local hasDir2 = neighbors[dir2] and #neighbors[dir2] > 0

				if not hasDir1 or not hasDir2 then
					-- Corner is exposed (no neighbors on at least one side)
					table.insert(area.wallCorners, corner)
					wallCornerCount = wallCornerCount + 1
					goto continue_corner
				end

				-- COMPLEX PATH: Both directions have neighbors
				-- Calculate proximity score from neighbors on both adjacent sides
				local proximityScore = 0
				local neighborDir1 = nil -- Track which neighbor contributed from dir1
				local neighborDir2 = nil -- Track which neighbor contributed from dir2

				-- Check dir1 neighbors
				for _, neighbor in ipairs(neighbors[dir1]) do
					local score, contrib = checkPointOnNeighborBoundary(corner, neighbor, dir1)
					if score > 0 then
						proximityScore = proximityScore + score
						if not neighborDir1 then
							neighborDir1 = contrib -- Track first contributor
						end
					end
				end

				-- Check dir2 neighbors
				for _, neighbor in ipairs(neighbors[dir2]) do
					local score, contrib = checkPointOnNeighborBoundary(corner, neighbor, dir2)
					if score > 0 then
						proximityScore = proximityScore + score
						if not neighborDir2 then
							neighborDir2 = contrib -- Track first contributor
						end
					end
				end

				-- Classification based on proximity score:
				-- >= 2.0: Definitely inner corner (surrounded)
				-- 1.99: Need validation (might be concave)
				-- 1.98: Concave corner - do diagonal validation
				-- < 1.98: Wall corner

				local isWallCorner = false
				local reason = ""

				if proximityScore >= 2.0 then
					-- Perfectly surrounded, definitely inner corner
					isWallCorner = false
					reason = "surrounded"
				elseif proximityScore >= 1.99 then
					-- Very close to surrounded, assume inner corner
					isWallCorner = false
					reason = "almost_surrounded"
				elseif proximityScore == 1.98 then
					-- Concave corner case - do diagonal validation
					-- Check if diagonal neighbor exists and covers this corner
					local diagonalFound = false

					if neighborDir1 and neighborDir1.c and neighborDir2 then
						-- Get neighbors of neighborDir1 in dir2 direction
						local diagDir1, diagDir2 = getDiagonalDirection(dir1, dir2)
						if diagDir1 and diagDir2 then
							-- Check neighborDir1's connections in dir2 direction
							for dirId, dirData in pairs(neighborDir1.c) do
								if dirData.connections then
									for _, conn in ipairs(dirData.connections) do
										local connId = (type(conn) == "table") and conn.node or conn
										local diagNeighbor = nodes[connId]
										if diagNeighbor then
											-- Check if our corner lies on this diagonal neighbor
											local score1 = checkPointOnNeighborBoundary(corner, diagNeighbor, dir1)
											local score2 = checkPointOnNeighborBoundary(corner, diagNeighbor, dir2)
											if score1 > 0 or score2 > 0 then
												diagonalFound = true
												break
											end
										end
									end
								end
								if diagonalFound then
									break
								end
							end
						end
					end

					if diagonalFound then
						isWallCorner = false -- Part of diagonal group, inner corner
						reason = "diagonal_group"
					else
						isWallCorner = true -- Concave wall corner
						reason = "concave"
					end
				else
					-- Score < 1.98, definitely a wall corner
					isWallCorner = true
					reason = "low_score"
				end

				if isWallCorner then
					table.insert(area.wallCorners, corner)
					wallCornerCount = wallCornerCount + 1
				end

				::continue_corner::
			end
		end
	end

	Log:Info(
		"Processed %d nodes, detected %d wall corners out of %d total corners",
		nodeCount,
		wallCornerCount,
		allCornerCount
	)

	-- Console output for immediate visibility
	print("WallCornerGenerator: " .. wallCornerCount .. " wall corners found")

	-- Debug: log first few nodes with wall corners
	local debugCount = 0
	for nodeId, area in pairs(nodes) do
		if area.wallCorners and #area.wallCorners > 0 then
			debugCount = debugCount + 1
			if debugCount <= 3 then
				Log:Debug("Node %s has %d wall corners", tostring(nodeId), #area.wallCorners)
				for i, corner in ipairs(area.wallCorners) do
					Log:Debug("  Wall corner %d: (%.1f,%.1f,%.1f)", i, corner.x, corner.y, corner.z)
				end
			end
		end
	end
end

return WallCornerGenerator

end)
__bundle_register("MedBot.Navigation.Setup.Phase2_Normalize", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Phase2_Normalize.lua  ·  Normalize and enrich connection data
--##########################################################################

local Common = require("MedBot.Core.Common")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local Phase2_Normalize = {}

local Log = Common.Log.new("Phase2_Normalize")

--##########################################################################
--  LOCAL HELPERS
--##########################################################################

local function precomputeNodeBounds(node)
	if not node.nw or not node.ne or not node.sw or not node.se then
		return
	end

	-- Precompute horizontal bounds for fast containment checks
	node._minX = math.min(node.nw.x, node.ne.x, node.sw.x, node.se.x)
	node._maxX = math.max(node.nw.x, node.ne.x, node.sw.x, node.se.x)
	node._minY = math.min(node.nw.y, node.ne.y, node.sw.y, node.se.y)
	node._maxY = math.max(node.nw.y, node.ne.y, node.sw.y, node.se.y)
end

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Normalize all connections in the node graph and precompute bounds
--- @param nodes table areaId -> node mapping
--- @return table nodes (same table, modified in place)
function Phase2_Normalize.Execute(nodes)
	assert(type(nodes) == "table", "Phase2_Normalize.Execute: nodes must be table")

	local nodeCount = 0
	local connectionCount = 0

	for nodeId, node in pairs(nodes) do
		nodeCount = nodeCount + 1

		-- Precompute bounds for fast containment checks
		precomputeNodeBounds(node)

		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						dir.connections[i] = ConnectionUtils.NormalizeEntry(connection)
						connectionCount = connectionCount + 1
					end
				end
			end
		end
	end

	Log:Info("Phase 2 complete: %d nodes normalized with %d connections", nodeCount, connectionCount)
	return nodes
end

return Phase2_Normalize

end)
__bundle_register("MedBot.Navigation.Setup.Phase1_NavLoad", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Phase1_NavLoad.lua  ·  Load raw nav file and convert to node format
--##########################################################################

local Common = require("MedBot.Core.Common")
local SourceNav = require("MedBot.Utils.SourceNav")

local Phase1_NavLoad = {}

local Log = Common.Log.new("Phase1_NavLoad")

--##########################################################################
--  LOCAL HELPERS (NOT exported)
--##########################################################################

local function tryLoadNavFile(navFilePath)
    local file = io.open(navFilePath, "rb")
    if not file then
        return nil, "File not found"
    end
    local content = file:read("*a")
    file:close()
    local navData = SourceNav.parse(content)
    if not navData or #navData.areas == 0 then
        return nil, "Failed to parse nav file or no areas found."
    end
    return navData
end

local function processNavData(navData)
    local navNodes = {}
    for _, area in pairs(navData.areas) do
        local cX = (area.north_west.x + area.south_east.x) / 2
        local cY = (area.north_west.y + area.south_east.y) / 2
        local cZ = (area.north_west.z + area.south_east.z) / 2

        local ne_z = area.north_east_z or area.north_west.z
        local sw_z = area.south_west_z or area.south_east.z

        local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
        local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
        local ne = Vector3(area.south_east.x, area.north_west.y, ne_z)
        local sw = Vector3(area.north_west.x, area.south_east.y, sw_z)

        navNodes[area.id] = {
            pos = Vector3(cX, cY, cZ),
            id = area.id,
            c = area.connections,
            nw = nw,
            se = se,
            ne = ne,
            sw = sw,
        }
    end
    return navNodes
end

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Load nav file and convert to internal node format
--- Returns: nodes table (areaId -> node) or nil, error
function Phase1_NavLoad.Execute(navFilePath)
    assert(type(navFilePath) == "string", "Phase1_NavLoad.Execute: navFilePath must be string")

    Log:Info("Loading nav file: %s", navFilePath)

    local navData, err = tryLoadNavFile(navFilePath)
    if not navData then
        return nil, err
    end

    local nodes = processNavData(navData)
    Log:Info("Phase 1 complete: %d areas loaded", #navData.areas)

    return nodes
end

return Phase1_NavLoad

end)
__bundle_register("MedBot.Utils.SourceNav", function(require, _LOADED, __bundle_register, __bundle_modules)
-- author : https://github.com/sapphyrus
-- ported to tf2 by moonverse

local unpack = table.unpack
local struct = {
    unpack = string.unpack,
    pack = string.pack
}

local struct_buffer_mt = {
    __index = {
        seek = function(self, seek_val, seek_mode)
            if seek_mode == nil or seek_mode == "CUR" then
                self.offset = self.offset + seek_val
            elseif seek_mode == "END" then
                self.offset = self.len + seek_val
            elseif seek_mode == "SET" then
                self.offset = seek_val
            end
        end,
        unpack = function(self, format_str)
            local unpacked = { struct.unpack(format_str, self.raw, self.offset) }

            if self.size_cache[format_str] == nil then
                self.size_cache[format_str] = struct.pack(format_str, unpack(unpacked)):len()
            end
            self.offset = self.offset + self.size_cache[format_str]

            return unpack(unpacked)
        end,
        unpack_vec = function(self)
            local x, y, z = self:unpack("fff")
            return {
                x = x,
                y = y,
                z = z
            }
        end
    }
}

local function struct_buffer(raw)
    return setmetatable({
        raw = raw,
        len = raw:len(),
        size_cache = {},
        offset = 1
    }, struct_buffer_mt)
end

-- cache
local navigation_mesh_cache = {}

-- use checksum so we dont have to keep the whole thing in memory
local function crc32(s, lt)
    -- return crc32 checksum of string as an integer
    -- use lookup table lt if provided or create one on the fly
    -- if lt is empty, it is initialized.
    lt = lt or {}
    local b, crc, mask
    if not lt[1] then -- setup table
        for i = 1, 256 do
            crc = i - 1
            for _ = 1, 8 do -- eight times
                mask = -(crc & 1)
                crc = (crc >> 1) ~ (0xedb88320 & mask)
            end
            lt[i] = crc
        end
    end

    -- compute the crc
    crc = 0xffffffff
    for i = 1, #s do
        b = string.byte(s, i)
        crc = (crc >> 8) ~ lt[((crc ~ b) & 0xFF) + 1]
    end
    return ~crc & 0xffffffff
end

local function parse(raw, use_cache)
    local checksum
    if use_cache == nil or use_cache then
        checksum = crc32(raw)
        if navigation_mesh_cache[checksum] ~= nil then
            return navigation_mesh_cache[checksum]
        end
    end

    local buf = struct_buffer(raw)

    local self = {}
    self.magic, self.major, self.minor, self.bspsize, self.analyzed, self.places_count = buf:unpack("IIIIbH")

    assert(self.magic == 0xFEEDFACE, "invalid magic, expected 0xFEEDFACE")
    assert(self.major == 16, "invalid major version, expected 16")

    -- place names
    self.places = {}
    for i = 1, self.places_count do
        local place = {}
        place.name_length = buf:unpack("H")

        -- read but ignore null byte
        place.name = buf:unpack(string.format("c%db", place.name_length - 1))

        self.places[i] = place
    end

    -- areas
    self.has_unnamed_areas, self.areas_count = buf:unpack("bI")
    self.areas = {}
    for i = 1, self.areas_count do
        local area = {}
        area.id, area.flags = buf:unpack("II")

        area.north_west = buf:unpack_vec()
        area.south_east = buf:unpack_vec()

        area.north_east_z, area.south_west_z = buf:unpack("ff")

        -- connections
        area.connections = {}
        for dir = 1, 4 do
            local connections_dir = {}
            connections_dir.count = buf:unpack("I")

            connections_dir.connections = {}
            for i = 1, connections_dir.count do
                local target
                target = buf:unpack("I")
                connections_dir.connections[i] = target
            end
            area.connections[dir] = connections_dir
        end

        -- hiding spots
        area.hiding_spots_count = buf:unpack("B")
        area.hiding_spots = {}
        for i = 1, area.hiding_spots_count do
            local hiding_spot = {}
            hiding_spot.id = buf:unpack("I")
            hiding_spot.location = buf:unpack_vec()
            hiding_spot.flags = buf:unpack("b")
            area.hiding_spots[i] = hiding_spot
        end

        -- encounter paths
        area.encounter_paths_count = buf:unpack("I")
        area.encounter_paths = {}
        for i = 1, area.encounter_paths_count do
            local encounter_path = {}
            encounter_path.from_id, encounter_path.from_direction, encounter_path.to_id, encounter_path.to_direction,
                encounter_path.spots_count =
            buf:unpack("IBIBB")

            encounter_path.spots = {}
            for i = 1, encounter_path.spots_count do
                encounter_path.spots[i] = {}
                encounter_path.spots[i].order_id, encounter_path.spots[i].distance = buf:unpack("IB")
            end
            area.encounter_paths[i] = encounter_path
        end

        area.place_id = buf:unpack("H")

        -- ladders
        area.ladders = {}
        for i = 1, 2 do
            area.ladders[i] = {}
            area.ladders[i].connection_count = buf:unpack("I")

            area.ladders[i].connections = {}
            for i = 1, area.ladders[i].connection_count do
                area.ladders[i].connections[i] = buf:unpack("I")
            end
        end

        area.earliest_occupy_time_first_team, area.earliest_occupy_time_second_team = buf:unpack("ff")
        area.light_intensity_north_west, area.light_intensity_north_east, area.light_intensity_south_east,
            area.light_intensity_south_west =
        buf:unpack("ffff")

        -- visible areas
        area.visible_areas = {}
        area.visible_area_count = buf:unpack("I")
        for i = 1, area.visible_area_count do
            area.visible_areas[i] = {}
            area.visible_areas[i].id, area.visible_areas[i].attributes = buf:unpack("Ib")
        end
        area.inherit_visibility_from_area_id = buf:unpack("I")

        -- NOTE: Differnet value in CSGO/TF2
        -- garbage?
        self.garbage = buf:unpack('I')

        self.areas[i] = area
    end

    -- ladders
    self.ladders_count = buf:unpack("I")
    self.ladders = {}
    for i = 1, self.ladders_count do
        local ladder = {}
        ladder.id, ladder.width = buf:unpack("If")

        ladder.top = buf:unpack_vec()
        ladder.bottom = buf:unpack_vec()

        ladder.length, ladder.direction = buf:unpack("fI")

        ladder.top_forward_area_id, ladder.top_left_area_id, ladder.top_right_area_id, ladder.top_behind_area_id =
        buf:unpack("IIII")
        ladder.bottom_area_id = buf:unpack("I")

        self.ladders[i] = ladder
    end

    if checksum ~= nil and navigation_mesh_cache[checksum] == nil then
        navigation_mesh_cache[checksum] = self
    end

    return self
end

return {
    parse = parse
}

end)
__bundle_register("MedBot.Bot.IsNavigableTest", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    IsNavigable Test Suite
    Test module for node-based navigation skipping
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")

-- Test state variables
local TestState = {
	enabled = false,
	startPos = nil,
	currentPos = nil,
	isNavigable = false,
	showVisuals = true,

	-- Benchmark data
	benchmarkRecords = {},
	MAX_RECORDS = 66,
	averageMemoryUsage = 0,
	averageTimeUsage = 0,

	-- Visual data
	hullTraces = {},
	lineTraces = {},
}

-- Load Navigable module
local Navigable = require("MedBot.Navigation.isWalkable.isNavigable")

-- Constants
local Fonts = { Verdana = draw.CreateFont("Verdana", 14, 510) }

-- Benchmark functions
local function BenchmarkStart()
	local startMemory = collectgarbage("count")
	local startTime = os.clock()
	return startTime, startMemory
end

local function BenchmarkStop(startTime, startMemory)
	local stopTime = os.clock()
	local stopMemory = collectgarbage("count")

	local elapsedTime = math.max(stopTime - startTime, 0)
	local memoryDelta = math.abs(stopMemory - startMemory)

	table.insert(TestState.benchmarkRecords, 1, { time = elapsedTime, memory = memoryDelta })
	if #TestState.benchmarkRecords > TestState.MAX_RECORDS then
		table.remove(TestState.benchmarkRecords)
	end

	local totalTime, totalMemory = 0, 0
	for _, record in ipairs(TestState.benchmarkRecords) do
		totalTime = totalTime + record.time
		totalMemory = totalMemory + record.memory
	end

	TestState.averageTimeUsage = totalTime / #TestState.benchmarkRecords
	TestState.averageMemoryUsage = totalMemory / #TestState.benchmarkRecords
end

-- Normalize vector
local function Normalize(vec)
	return vec / vec:Length()
end

-- Arrow line drawing function
local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	local direction = end_pos - start_pos
	local min_acceptable_length = arrowhead_length + (arrowhead_width / 2)
	if direction:Length() < min_acceptable_length then
		local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
		if not (w2s_start and w2s_end) then
			return
		end
		draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		return
	end

	local normalized_direction = Normalize(direction)
	local arrow_base = end_pos - normalized_direction * arrowhead_length
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp2[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- Draw 3D box at position
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

-- CreateMove callback
local function OnCreateMove(Cmd)
	-- Check menu state first
	if not G.Menu.Visuals.IsNavigableTest then
		return
	end

	-- Set enabled and initialize startPos if needed
	if not TestState.enabled then
		TestState.enabled = true
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() and not TestState.startPos then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	TestState.currentPos = pLocal:GetAbsOrigin()

	-- Shift to reset position
	if input.IsButtonDown(KEY_LSHIFT) then
		TestState.startPos = TestState.currentPos
		return
	end

	-- Only run test when F key is held
	if not input.IsButtonDown(KEY_F) then
		return
	end

	-- Only run test if we have both positions and they're far enough apart
	if TestState.startPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		-- Get current node for start position
		local startNode = Node.GetAreaAtPosition(TestState.currentPos)

		if startNode then
			local startTime, startMemory = BenchmarkStart()
			local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
			TestState.isNavigable =
			Navigable.CanSkip(TestState.currentPos, TestState.startPos, startNode, true, allowJump)
			BenchmarkStop(startTime, startMemory)
		else
			TestState.isNavigable = false
		end
	end
end

-- Draw callback
local function OnDraw()
	-- Check menu state first
	if not G.Menu.Visuals.IsNavigableTest then
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 255, 255, 255)

	-- Draw target position box
	if TestState.startPos then
		Draw3DBox(10, TestState.startPos)
	end

	-- Draw navigability test and arrow
	if TestState.startPos and TestState.currentPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		if TestState.isNavigable then
			draw.Color(0, 255, 0, 255)
		else
			draw.Color(255, 0, 0, 255)
		end
		ArrowLine(TestState.currentPos, TestState.startPos, 10, 20, false)
	end

	-- Draw benchmark info
	draw.Color(255, 255, 255, 255)
	draw.Text(20, 120, string.format("IsNavigable Test: %s", G.Menu.Visuals.IsNavigableTest and "ON" or "OFF"))
	draw.Text(20, 150, string.format("Memory usage: %.2f KB", TestState.averageMemoryUsage))
	draw.Text(20, 180, string.format("Time usage: %.2f ms", TestState.averageTimeUsage * 1000))
	draw.Text(20, 210, string.format("Result: %s", TestState.isNavigable and "NAVIGABLE" or "NOT NAVIGABLE"))
	draw.Text(20, 240, "Press SHIFT to set start | Hold F to test")

	-- Draw debug traces from Navigable module
	Navigable.DrawDebugTraces()
end

-- Toggle function
local function ToggleTest()
	TestState.enabled = not TestState.enabled
	if TestState.enabled then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
		print("IsNavigable Test Suite: ENABLED")
		client.Command('play "ui/buttonclick"', true)
	else
		print("IsNavigable Test Suite: DISABLED")
		client.Command('play "ui/buttonclick_release"', true)
	end
end

-- Public API
local IsNavigableTest = {
	Toggle = ToggleTest,
	IsEnabled = function()
		return TestState.enabled
	end,
	GetState = function()
		return TestState
	end,
}

-- Auto-register callbacks
callbacks.Register("CreateMove", "IsNavigableTest_CreateMove", OnCreateMove)
callbacks.Register("Draw", "IsNavigableTest_Draw", OnDraw)

-- Add to global for easy access
G.IsNavigableTest = IsNavigableTest

print("IsNavigable Test Suite loaded. Use G.IsNavigableTest.Toggle() to enable/disable.")

return IsNavigableTest

end)
__bundle_register("MedBot.Navigation.isWalkable.isNavigable", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]

local vectordivide = vector.Divide
local vectorLength = vector.Length

local Navigable = {}
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local JUMP_HEIGHT = 72
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local JUMP_HEIGHT_Vector = Vector3(0, 0, JUMP_HEIGHT)
local FORWARD_STEP = 100 -- Max distance per forward trace
local HILL_THRESHOLD = 4 -- 0.5x step height for significant elevation changes

local MaxSpeed = 450
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval()
local MAX_SURFACE_ANGLE = 55
local MAX_ITERATIONS = 37
local TOLERANCE = 10.0

-- Debug
local DEBUG_MODE = true -- Set to true for debugging (enables traces)
local hullTraces = {}
local currentTickLogged = -1

local engineTraceHull = engine.TraceHull

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		currentTickLogged = currentTick
	end
	local result = engineTraceHull(startPos, endPos, minHull, maxHull, mask)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end


local TraceHull = DEBUG_MODE and traceHullWrapper or engineTraceHull

-- Helper: Get surface angle from normal-- curently unused
local function getSurfaceAngle(surfaceNormal)
	if not surfaceNormal then
		return 0
	end
	return math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))
end


-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Common.Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	-- Project horizontal direction onto sloped surface
	-- 1. Get right vector perpendicular to horizontal direction
	local right = direction:Cross(UP_VECTOR)
	if right:Length() < 0.0001 then
		-- Direction is straight up/down, return as-is
		return direction
	end
	right = Common.Normalize(right)

	-- 2. Get forward direction on surface (perpendicular to both right and surface normal)
	local forward = right:Cross(surfaceNormal)
	forward = Common.Normalize(forward)

	-- 3. Ensure forward points in same general direction as input
	if forward:Dot(direction) < 0 then
		forward = forward * -1
	end

	return forward
end

-- Find where ray exits node bounds
-- Returns: exitPoint, exitDist, exitDir (1=N, 2=E, 3=S, 4=W)
local function findNodeExit(startPos, dir, node)
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY
	local exitDir = nil

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
			exitDir = 2 -- East
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
			exitDir = 4 -- West
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
			exitDir = 3 -- South
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
			exitDir = 1 -- North
		end
	end

	if tMin == math.huge then
		return nil, nil, nil
	end
	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- Calculate ground Z position from node quad geometry (no engine call)
local function getGroundZFromQuad(pos, node)
	if not (node.nw and node.ne and node.sw and node.se) then
		return nil, nil
	end

	local nw, ne, sw, se = node.nw, node.ne, node.sw, node.se

	-- Determine which triangle contains the point
	-- Split quad into: Triangle1(nw,ne,se) and Triangle2(nw,se,sw)
	local dx = pos.x - nw.x
	local dy = pos.y - nw.y
	local dx_ne = ne.x - nw.x
	local dy_se = se.y - nw.y

	local inTriangle1 = (dx / dx_ne + dy / dy_se) <= 1.0

	local v0, v1, v2
	if inTriangle1 then
		-- Triangle: nw, ne, se
		v0, v1, v2 = nw, ne, se
	else
		-- Triangle: nw, se, sw
		v0, v1, v2 = nw, se, sw
	end

	-- Barycentric interpolation for Z
	local denom = (v1.y - v2.y) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.y - v2.y)
	if math.abs(denom) < 0.0001 then
		return v0.z, UP_VECTOR -- Degenerate triangle, use first vertex
	end

	local w0 = ((v1.y - v2.y) * (pos.x - v2.x) + (v2.x - v1.x) * (pos.y - v2.y)) / denom
	local w1 = ((v2.y - v0.y) * (pos.x - v2.x) + (v0.x - v2.x) * (pos.y - v2.y)) / denom
	local w2 = 1.0 - w0 - w1

	local z = w0 * v0.z + w1 * v1.z + w2 * v2.z

	-- Calculate normal from cross product
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local normal = edge1:Cross(edge2)
	normal = Common.Normalize(normal)
	if not normal then
		normal = UP_VECTOR
	end

	return z, normal
end

-- Helper: Check if horizontal point is within node bounds (with tolerance)
local function isPointInNodeBounds(point, node, tolerance)
	tolerance = tolerance or 0
	local inX = point.x >= (node._minX - tolerance) and point.x <= (node._maxX + tolerance)
	local inY = point.y >= (node._minY - tolerance) and point.y <= (node._maxY + tolerance)
	return inX and inY
end

-- Helper: Check if exit point is valid for neighbor connection
-- Tolerance only on opposite axis to shared edge
-- Z check: down up to 450, up to jump/step height based on allowJump
local function isValidNeighborConnection(currentNode, candidateNode, exitPoint, exitDir, allowJump)
	local EDGE_TOLERANCE = 16.0 -- Increased for edge alignment
	local maxUp = allowJump and JUMP_HEIGHT or STEP_HEIGHT

	-- Get ground Z at exit point for both nodes
	local currentZ = getGroundZFromQuad(exitPoint, currentNode)
	local candidateZ = getGroundZFromQuad(exitPoint, candidateNode)

	if not currentZ or not candidateZ then
		if DEBUG_MODE then
			print(string.format("[IsNavigable]   FAIL: No ground Z - currentZ=%s, candidateZ=%s", tostring(currentZ),
				tostring(candidateZ)))
		end
		return false
	end

	-- Check Z height difference
	local zDiff = candidateZ - currentZ
	if zDiff > maxUp or zDiff < -MAX_FALL_DISTANCE then
		if DEBUG_MODE then
			print(string.format("[IsNavigable]   FAIL: Z diff %.1f outside range [%.1f, %.1f]", zDiff, -
			MAX_FALL_DISTANCE, maxUp))
		end
		return false
	end

	-- Check bounds based on exit direction (tolerance only on opposite axis)
	if exitDir == 2 or exitDir == 4 then -- East/West - shared X edge
		-- X must be at the edge (with tolerance), Y can have tolerance
		local atXEdge = (exitPoint.x >= candidateNode._minX - EDGE_TOLERANCE and exitPoint.x <= candidateNode._maxX + EDGE_TOLERANCE)
		local inY = exitPoint.y >= (candidateNode._minY - TOLERANCE) and exitPoint.y <= (candidateNode._maxY + TOLERANCE)
		if DEBUG_MODE then
			print(string.format(
				"[IsNavigable]   E/W check: exit=(%.1f,%.1f), node bounds=[%.1f,%.1f,%.1f,%.1f], atXEdge=%s, inY=%s",
				exitPoint.x, exitPoint.y, candidateNode._minX, candidateNode._maxX, candidateNode._minY,
				candidateNode._maxY,
				tostring(atXEdge), tostring(inY)))
		end
		return atXEdge and inY
	else -- North/South - shared Y edge
		-- Y must be at the edge (with tolerance), X can have tolerance
		local atYEdge = (exitPoint.y >= candidateNode._minY - EDGE_TOLERANCE and exitPoint.y <= candidateNode._maxY + EDGE_TOLERANCE)
		local inX = exitPoint.x >= (candidateNode._minX - TOLERANCE) and exitPoint.x <= (candidateNode._maxX + TOLERANCE)
		if DEBUG_MODE then
			print(string.format(
				"[IsNavigable]   N/S check: exit=(%.1f,%.1f), node bounds=[%.1f,%.1f,%.1f,%.1f], atYEdge=%s, inX=%s",
				exitPoint.x, exitPoint.y, candidateNode._minX, candidateNode._maxX, candidateNode._minY,
				candidateNode._maxY,
				tostring(atYEdge), tostring(inX)))
		end
		return atYEdge and inX
	end
end

-- Helper: Find neighbor node through connections/doors from exit point
local function findNeighborAtExit(currentNode, exitPoint, exitDir, nodes, respectDoors, allowJump)
	local dirData = currentNode.c[exitDir]
	if not dirData or not dirData.connections then
		return nil
	end

	local connCount = #dirData.connections
	-- TOLERANCE removed - using Z-based height checks in isValidNeighborConnection

	-- Determine search direction based on exit position
	local searchForward = true
	if exitDir == 2 or exitDir == 4 then -- East/West (X axis)
		local midX = (currentNode._minX + currentNode._maxX) * 0.5
		searchForward = exitPoint.x < midX
	else -- North/South (Y axis)
		local midY = (currentNode._minY + currentNode._maxY) * 0.5
		searchForward = exitPoint.y < midY
	end

	local start, finish, step = 1, connCount, 1
	if not searchForward then
		start, finish, step = connCount, 1, -1
	end

	for i = start, finish, step do
		local connection = dirData.connections[i]
		local targetId = (type(connection) == "table") and (connection.node or connection.id) or connection
		local candidate = nodes[targetId]

		if not candidate then
			goto continue
		end

		-- Area node with bounds
		if candidate._minX and candidate._maxX and candidate._minY and candidate._maxY then
			local checkNode = candidate

			-- If respecting doors, find door between currentNode and candidate
			if respectDoors then
				for _, conn in ipairs(dirData.connections) do
					local tid = (type(conn) == "table") and (conn.node or conn.id) or conn
					local door = nodes[tid]
					if door and not door._minX and door.c then
						-- Check if door connects to candidate
						for _, ddir in pairs(door.c) do
							if ddir.connections then
								for _, dconn in ipairs(ddir.connections) do
									local did = (type(dconn) == "table") and (dconn.node or dconn.id) or dconn
									if did == candidate.id then
										checkNode = door
										break
									end
								end
							end
							if checkNode == door then
								break
							end
						end
						if checkNode == door then
							break
						end
					end
				end
			end

			local inBounds = isValidNeighborConnection(currentNode, checkNode, exitPoint, exitDir, allowJump)
			if DEBUG_MODE then
				print(
					string.format(
						"[IsNavigable]   Check area=%d via %s, bounds=[%.1f,%.1f,%.1f,%.1f], exit=(%.1f,%.1f), inBounds=%s",
						candidate.id,
						(checkNode == candidate and "area" or "door"),
						checkNode._minX,
						checkNode._maxX,
						checkNode._minY,
						checkNode._maxY,
						exitPoint.x,
						exitPoint.y,
						tostring(inBounds)
					)
				)
			end

			if inBounds then
				return candidate
			end

			-- Door node - traverse through to find area on other side
		elseif candidate.c then
			if DEBUG_MODE then
				print(string.format("[IsNavigable]   Conn %d: Door %s, traversing...", i, tostring(targetId)))
			end
			for doorDir, doorDirData in pairs(candidate.c) do
				if doorDirData.connections then
					for _, doorConn in ipairs(doorDirData.connections) do
						local areaId = (type(doorConn) == "table") and (doorConn.node or doorConn.id) or doorConn
						local areaNode = nodes[areaId]

						if DEBUG_MODE then
							print(
								string.format(
									"[IsNavigable]     Door dir %s -> area %s (exists=%s, hasBounds=%s)",
									tostring(doorDir),
									tostring(areaId),
									tostring(areaNode ~= nil),
									tostring(areaNode and areaNode._minX ~= nil)
								)
							)
						end

						if areaId ~= currentNode.id and areaNode and areaNode._minX then
							local inBounds = isValidNeighborConnection(currentNode, areaNode, exitPoint, exitDir,
								allowJump)
							if DEBUG_MODE then
								print(
									string.format(
										"[IsNavigable]       Check area %s inBounds=%s, bounds=[%.1f,%.1f,%.1f,%.1f]",
										tostring(areaId),
										tostring(inBounds),
										areaNode._minX,
										areaNode._maxX,
										areaNode._minY,
										areaNode._maxY
									)
								)
							end
							if inBounds then
								return areaNode
							end
						end
					end
				end
			end
		end

		::continue::
	end

	return nil
end

-- Helper: Trace through waypoints (Phase 2)
-- allowJump: if true, will attempt jump (72 units) when hitting obstacles
local function traceWaypoints(waypoints, allowJump)
	local ANGLE_CHANGE_THRESHOLD = 15 -- degrees
	local traceStart = waypoints[1]
	local traceCount = 0

	for i = 2, #waypoints do
		local currentWp = waypoints[i]
		local prevWp = waypoints[i - 1]

		-- Calculate angle change between consecutive normals
		local angleChange = 0
		if prevWp.normal and currentWp.normal then
			local dotProduct = prevWp.normal:Dot(currentWp.normal)
			dotProduct = math.max(-1, math.min(1, dotProduct))
			angleChange = math.deg(math.acos(dotProduct))
		end

		-- Check if this is last waypoint or angle changed significantly
		local isLastWaypoint = (i == #waypoints)
		local zDiff = math.abs(currentWp.pos.z - prevWp.pos.z)
		local shouldTrace = isLastWaypoint or angleChange > ANGLE_CHANGE_THRESHOLD or zDiff > 8

		if shouldTrace then
			-- Calculate horizontal direction from trace start to current
			local toTarget = currentWp.pos - traceStart.pos
			local horizDir = Vector3(toTarget.x, toTarget.y, 0)
			horizDir = Common.Normalize(horizDir)

			-- Adjust direction using trace start's surface normal
			local traceDir = horizDir
			if traceStart.normal then
				traceDir = adjustDirectionToSurface(horizDir, traceStart.normal)
				if DEBUG_MODE then
					print(string.format(
						"[IsNavigable] Trace using start normal (%.2f, %.2f, %.2f) -> dir (%.2f, %.2f, %.2f)",
						traceStart.normal.x, traceStart.normal.y, traceStart.normal.z,
						traceDir.x, traceDir.y, traceDir.z))
				end
			else
				if DEBUG_MODE then
					print(string.format("[IsNavigable] Trace using flat direction (no start normal)"))
				end
			end
			-- Calculate trace endpoint
			local traceDist = (currentWp.pos - traceStart.pos):Length()
			local traceEnd = traceStart.pos + traceDir * traceDist

			-- Check if going significantly downward - if so, don't add upward step offset to end
			local zDiff = currentWp.pos.z - traceStart.pos.z
			local isGoingDown = zDiff < -8

			local stepHeightVec = Vector3(0, 0, STEP_HEIGHT)
			local jumpHeightVec = Vector3(0, 0, JUMP_HEIGHT)
			local traceSuccess = false

			-- Store the base Z for this segment to prevent height accumulation
			local baseZ = traceStart.pos.z
			local currentTracePos = traceStart.pos
			local currentTraceNormal = traceStart.normal

			-- Try step height first, then jump height if needed
			local stepHeights = { STEP_HEIGHT, JUMP_HEIGHT }
			local currentStepIndex = 1
			local maxRetries = 3
			local retryCount = 0
			local hitNode = nil
			local lastTracePos = nil -- Track last position to detect no progress

			while currentStepIndex <= #stepHeights and retryCount < maxRetries do
				local stepH = stepHeights[currentStepIndex]
				local stepVec = Vector3(0, 0, stepH)
				local useJump = (stepH == JUMP_HEIGHT)

				-- Skip jump attempt if not allowed
				if useJump and not allowJump then
					break
				end

				-- Calculate trace endpoint based on current position
				local toTarget = traceEnd - currentTracePos
				local remainingDist = toTarget:Length()
				if remainingDist < 0.001 then
					traceSuccess = true
					break
				end

				local traceDir = Common.Normalize(toTarget)
				local currentTraceEnd = currentTracePos + traceDir * remainingDist

				-- Forward trace with current step height
				-- When going down, don't add step offset to end (follow slope naturally)
				local traceStartPos = currentTracePos + stepVec
				local traceEndPos = isGoingDown and currentTraceEnd or (currentTraceEnd + stepVec)
				local trace = TraceHull(
					traceStartPos,
					traceEndPos,
					PLAYER_HULL.Min,
					PLAYER_HULL.Max,
					MASK_SHOT_HULL
				)

				traceCount = traceCount + 1

				if trace.fraction >= 0.99 then
					-- Clear path - reached destination
					traceSuccess = true
					break
				end

				-- Hit something - find what node/area the hit is in
				local hitPos = trace.endpos
				local nodes = G.Navigation and G.Navigation.nodes

				if nodes then
					hitNode = Node.GetAreaAtPosition(hitPos)
				end

				if not hitNode then
					-- No valid node at hit position - try next step height
					if DEBUG_MODE then
						print(string.format("[IsNavigable] Hit at (%.1f, %.1f, %.1f) not on navmesh, trying next...",
							hitPos.x, hitPos.y, hitPos.z))
					end
					currentStepIndex = currentStepIndex + 1
					retryCount = retryCount + 1
					goto continue_retry
				end

				-- Adjust to ground on the hit node's navmesh
				local groundZ, groundNormal = getGroundZFromQuad(hitPos, hitNode)

				if not groundZ then
					-- No ground on this node - try next step height
					if DEBUG_MODE then
						print(string.format("[IsNavigable] No ground on node %d at hit, trying next...", hitNode.id))
					end
					currentStepIndex = currentStepIndex + 1
					retryCount = retryCount + 1
					goto continue_retry
				end

				-- Check if surface angle is too steep for this step height
				if groundNormal then
					local surfaceAngle = math.deg(math.acos(groundNormal:Dot(UP_VECTOR)))
					if surfaceAngle > MAX_SURFACE_ANGLE then
						if DEBUG_MODE then
							print(string.format("[IsNavigable] Surface too steep (%.1f° > %.1f°), trying next step height...",
								surfaceAngle, MAX_SURFACE_ANGLE))
						end
						currentStepIndex = currentStepIndex + 1
						retryCount = retryCount + 1
						goto continue_retry
					end
				end

				-- Clamp Z to prevent climbing too high
				local maxAllowedZ = baseZ + stepH
				if groundZ > maxAllowedZ then
					if DEBUG_MODE then
						print(string.format("[IsNavigable] Ground too high (%.1f > %.1f), clamping", groundZ, maxAllowedZ))
					end
					groundZ = maxAllowedZ
				end

				local groundPos = Vector3(hitPos.x, hitPos.y, groundZ)

				if DEBUG_MODE then
					print(string.format("[IsNavigable] Hit on node %d, adjusted to (%.1f, %.1f, %.1f)", hitNode.id,
						groundPos.x, groundPos.y, groundPos.z))
				end

				-- Check if we're making progress (XY must change)
				local dx = groundPos.x - currentTracePos.x
				local dy = groundPos.y - currentTracePos.y
				local horizDist = math.sqrt(dx * dx + dy * dy)
				if horizDist < 0.5 then
					-- No progress - try next step height
					if DEBUG_MODE then
						print(string.format("[IsNavigable] No progress made (horiz=%.2f), trying next step height...",
							horizDist))
					end
					currentStepIndex = currentStepIndex + 1
					retryCount = retryCount + 1
					goto continue_retry
				end

				-- If using jump, check if we changed nodes
				if useJump then
					local nodeAtGround = Node.GetAreaAtPosition(groundPos)
					if nodeAtGround and nodeAtGround.id == hitNode.id then
						-- Same node - jump didn't get us past the obstacle
						if DEBUG_MODE then
							print(string.format("[IsNavigable] Jump failed: still on node %d, giving up", hitNode.id))
						end
						return false
					else
						-- Different node - jump succeeded
						if DEBUG_MODE then
							print(string.format("[IsNavigable] Jump success: moved to node %d from node %d",
								nodeAtGround and nodeAtGround.id or -1, hitNode.id))
						end
					end
				end

				-- Update position and continue with same step height (retry)
				currentTracePos = groundPos
				currentTraceNormal = groundNormal
				retryCount = retryCount + 1

				::continue_retry::
			end

			if not traceSuccess then
				if DEBUG_MODE then
					print(
						string.format(
							"[IsNavigable] FAIL: Entity blocking segment (trace %d, angle=%.1f°)",
							traceCount,
							angleChange
						)
					)
				end
				return false
			end

			-- Start next trace segment from current waypoint
			traceStart = currentWp
		end
	end

	if DEBUG_MODE then
		print(
			string.format(
				"[IsNavigable] SUCCESS: Path clear with %d traces (from %d waypoints)",
				traceCount,
				#waypoints
			)
		)
	end

	return true
end

-- MAIN FUNCTION - Two phases: 1) verify path through nodes, 2) trace with surface pitch
-- allowJump: if true, will use jump height (72) when step height (18) fails
function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors, allowJump)
	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	-- ============ PHASE 1: Verify path through nodes ============
	local currentPos = startPos
	local currentNode = startNode
	local waypoints = {} -- Waypoints for Phase 2

	-- Get starting ground Z
	local startZ, startNormal = getGroundZFromQuad(startPos, startNode)
	if startZ then
		currentPos = Vector3(startPos.x, startPos.y, startZ)
	end

	-- Add start waypoint
	table.insert(waypoints, {
		pos = currentPos,
		node = startNode,
		normal = startNormal,
	})

	-- Traverse to destination (no traces - just verify path exists)
	for iteration = 1, MAX_ITERATIONS do
		-- Check if goal reached
		if isPointInNodeBounds(goalPos, currentNode) then
			table.insert(waypoints, { pos = goalPos, node = currentNode, normal = nil })
			return traceWaypoints(waypoints, allowJump)
		end

		-- Find where we exit current node toward goal
		local toGoal = goalPos - currentPos
		-- Horizontal direction to destination (only X/Y matters for heading)
		local horizDir = Vector3(toGoal.x, toGoal.y, 0)
		horizDir = Common.Normalize(horizDir)

		-- Get ground normal at current position
		local groundZ, groundNormal = getGroundZFromQuad(currentPos, currentNode)

		-- Adjust direction to follow surface - only Z changes based on slope
		local dir = horizDir
		if groundNormal then
			dir = adjustDirectionToSurface(horizDir, groundNormal)
		end

		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, dir, currentNode)

		if not exitPoint or not exitDir then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			return false
		end

		if DEBUG_MODE then
			local dirNames = { [1] = "N", [2] = "E", [3] = "S", [4] = "W" }
			print(
				string.format(
					"[IsNavigable] Exit via %s at (%.1f, %.1f)",
					dirNames[exitDir] or "?",
					exitPoint.x,
					exitPoint.y
				)
			)
		end

		-- Find neighbor
		local neighborNode = findNeighborAtExit(currentNode, exitPoint, exitDir, nodes, respectDoors, allowJump)

		if not neighborNode then
			if DEBUG_MODE then
				print(
					string.format(
						"[IsNavigable] FAIL: No neighbor found at exit (%.1f, %.1f)",
						exitPoint.x,
						exitPoint.y
					)
				)
			end
			return false
		end

		-- Calculate entry point clamped to neighbor bounds
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))

		local entryZ, entryNormal = getGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)

		if not entryZ then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: No ground geometry at entry to node %d", neighborNode.id))
			end
			return false
		end

		local entryPos = Vector3(entryX, entryY, entryZ)

		-- Add intermediate waypoint if Z changes significantly (for slopes/hills)
		local zDiff = math.abs(entryZ - currentPos.z)
		if zDiff > 8 then
			-- Create intermediate waypoint at exit point with interpolated Z
			local exitZ = getGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				local exitPos = Vector3(exitPoint.x, exitPoint.y, exitZ)
				local _, exitNormal = getGroundZFromQuad(exitPoint, currentNode)
				table.insert(waypoints, { pos = exitPos, node = currentNode, normal = exitNormal })
				if DEBUG_MODE then
					print(string.format("[IsNavigable] Added slope waypoint at exit (Z=%.1f)", exitZ))
				end
			end
		end

		table.insert(waypoints, { pos = entryPos, node = neighborNode, normal = entryNormal })

		if DEBUG_MODE then
			print(string.format("[IsNavigable] Crossed to node %d (Z=%.1f)", neighborNode.id, entryZ))
		end

		currentPos = entryPos
		currentNode = neighborNode
	end

	if DEBUG_MODE then
		print(string.format("[IsNavigable] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
	end
	return false
end

-- Debug
function Navigable.DrawDebugTraces()
	if not DEBUG_MODE then
		return
	end
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_MODE = enabled
end

return Navigable

end)
__bundle_register("MedBot.Bot.OptimizedISWalkableTest", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Optimized ISWalkable Test Suite
    EXPERIMENTAL - Navmesh-based optimization using Greedy pathfinding
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local G = require("MedBot.Core.Globals")

-- Test state variables
local TestState = {
	enabled = false,
	startPos = nil,
	currentPos = nil,
	isWalkable = false,
	showVisuals = true,

	-- Benchmark data
	benchmarkRecords = {},
	MAX_RECORDS = 66,
	averageMemoryUsage = 0,
	averageTimeUsage = 0,

	-- Visual data
	hullTraces = {},
	lineTraces = {},
	greedyNodes = {}, -- Store greedy path nodes for cyan visualization
	samplePoints = {}, -- Store navmesh sample points for yellow visualization
}

-- Constants
local MAX_SPEED = 450
local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local MAX_FALL_DISTANCE = 250
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MAX_SPEED * globals.TickInterval()
local MAX_SURFACE_ANGLE = 45
local MAX_ITERATIONS = 37

-- Benchmark functions
local function BenchmarkStart()
	local startMemory = collectgarbage("count")
	local startTime = os.clock()
	return startTime, startMemory
end

local function BenchmarkStop(startTime, startMemory)
	local stopTime = os.clock()
	local stopMemory = collectgarbage("count")

	local elapsedTime = math.max(stopTime - startTime, 0)
	local memoryDelta = math.abs(stopMemory - startMemory)

	table.insert(TestState.benchmarkRecords, 1, { time = elapsedTime, memory = memoryDelta })
	if #TestState.benchmarkRecords > TestState.MAX_RECORDS then
		table.remove(TestState.benchmarkRecords)
	end

	local totalTime, totalMemory = 0, 0
	for _, record in ipairs(TestState.benchmarkRecords) do
		totalTime = totalTime + record.time
		totalMemory = totalMemory + record.memory
	end

	TestState.averageTimeUsage = totalTime / #TestState.benchmarkRecords
	TestState.averageMemoryUsage = totalMemory / #TestState.benchmarkRecords
end

-- Helper functions
local function shouldHitEntity(entity)
	local pLocal = entities.GetLocalPlayer()
	return entity ~= pLocal
end

local function Normalize(vec)
	return vec / vec:Length()
end

local function performTraceHull(startPos, endPos)
	local result =
		engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
	table.insert(TestState.hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

-- OPTIMIZED ISWalkable using Greedy pathfinding
local function IsWalkable(startPos, goalPos)
	-- Clear trace tables for debugging
	TestState.hullTraces = {}
	TestState.lineTraces = {}
	TestState.greedyNodes = {}
	TestState.samplePoints = {}

	-- Get greedy path for navmesh-based validation
	local greedyPath = G.Greedy.FindPathFast(startPos, goalPos, 20)

	-- Store greedy node positions for cyan visualization
	local pathNodes = {}
	for _, nodeId in ipairs(greedyPath) do
		local node = G.Navigation.GetNode(nodeId)
		if node then
			local nodePos = Vector3(node.x, node.y, node.z)
			table.insert(TestState.greedyNodes, nodePos)
			table.insert(pathNodes, node)
		end
	end

	-- OPTIMIZED: Simple quad-to-quad boundary checks (no iteration)
	if #pathNodes < 2 then
		return false -- Need at least 2 nodes to check
	end

	-- Check wall collision between each adjacent quad pair
	for i = 1, #pathNodes - 1 do
		local nodeA = pathNodes[i]
		local nodeB = pathNodes[i + 1]

		local posA = Vector3(nodeA.x, nodeA.y, nodeA.z)
		local posB = Vector3(nodeB.x, nodeB.y, nodeB.z)

		-- Store sample points for visualization
		table.insert(TestState.samplePoints, posA)
		table.insert(TestState.samplePoints, posB)

		-- One wall trace per quad boundary at step height
		local wallTrace = performTraceHull(posA + STEP_HEIGHT_Vector, posB + STEP_HEIGHT_Vector)

		if wallTrace.fraction == 0 then
			return false -- Path blocked at this boundary
		end
	end

	-- Check final segment from last node to goal
	local lastNode = pathNodes[#pathNodes]
	local lastPos = Vector3(lastNode.x, lastNode.y, lastNode.z)

	-- Check if goal is reasonable distance from path
	local distToGoal = (lastPos - goalPos):Length()
	if distToGoal > 500 then
		return false -- Goal too far from navmesh path
	end

	-- Final wall check to goal
	local finalTrace = performTraceHull(lastPos + STEP_HEIGHT_Vector, goalPos + STEP_HEIGHT_Vector)
	if finalTrace.fraction == 0 then
		return false -- Final segment blocked
	end

	return true -- Path is walkable
end

-- Visual functions
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	local direction = end_pos - start_pos
	local min_acceptable_length = arrowhead_length + (arrowhead_width / 2)
	if direction:Length() < min_acceptable_length then
		local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
		if not (w2s_start and w2s_end) then
			return
		end
		draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		return
	end

	local normalized_direction = Normalize(direction)
	local arrow_base = end_pos - normalized_direction * arrowhead_length
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- Main test functions
local function OnCreateMove(Cmd)
	-- Check menu state
	if not G.Menu.Visuals.OptimizedISWalkableTest then
		TestState.enabled = false
		return
	end

	-- Set enabled and initialize startPos if needed
	if not TestState.enabled then
		TestState.enabled = true
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() and not TestState.startPos then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	TestState.currentPos = pLocal:GetAbsOrigin()

	-- Shift to reset position
	if input.IsButtonDown(KEY_LSHIFT) then
		TestState.startPos = TestState.currentPos
		return
	end

	-- Don't interfere with movement
	if Cmd:GetForwardMove() ~= 0 or Cmd:GetSideMove() ~= 0 then
		return
	end

	-- Only run test when F key is held
	if not input.IsButtonDown(KEY_F) then
		return
	end

	-- Only run test if we have both positions and they're far enough apart
	if TestState.startPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		local startTime, startMemory = BenchmarkStart()
		TestState.isWalkable = IsWalkable(TestState.currentPos, TestState.startPos)
		BenchmarkStop(startTime, startMemory)
	end
end

--never inside funciton
local Fonts = { Verdana = draw.CreateFont("Verdana", 14, 510) }

local function OnDraw()
	-- Check menu state first
	if not G.Menu.Visuals.OptimizedISWalkableTest then
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 255, 255, 255)

	-- Draw target position box
	if TestState.startPos then
		Draw3DBox(10, TestState.startPos)
	end

	-- Draw walkability test and arrow
	if TestState.startPos and TestState.currentPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		if TestState.isWalkable then
			draw.Color(0, 255, 0, 255)
		else
			draw.Color(255, 0, 0, 255)
		end
		ArrowLine(TestState.currentPos, TestState.startPos, 10, 20, false)
	end

	-- Draw benchmark info
	draw.Color(255, 255, 255, 255)
	draw.Text(
		20,
		120,
		string.format("Optimized ISWalkable Test: %s", G.Menu.Visuals.OptimizedISWalkableTest and "ON" or "OFF")
	)
	draw.Text(20, 150, string.format("Memory usage: %.2f KB", TestState.averageMemoryUsage))
	draw.Text(20, 180, string.format("Time usage: %.2f ms", TestState.averageTimeUsage * 1000))
	draw.Text(20, 210, string.format("Result: %s", TestState.isWalkable and "WALKABLE" or "NOT WALKABLE"))
	draw.Text(20, 240, string.format("Greedy Nodes: %d", #TestState.greedyNodes))
	draw.Text(20, 270, string.format("Sample Points: %d", #TestState.samplePoints))
	draw.Text(20, 300, "Press SHIFT to set start | Hold F to test")

	-- Draw greedy path nodes (navmesh quads) in cyan
	if #TestState.greedyNodes > 0 then
		draw.Color(0, 255, 255, 255) -- Cyan for greedy path nodes
		for _, nodePos in ipairs(TestState.greedyNodes) do
			Draw3DBox(8, nodePos)
		end
	else
		draw.Color(255, 255, 255, 255)
		draw.Text(20, 330, "No greedy path nodes found")
	end

	-- Draw navmesh sample points in yellow
	if #TestState.samplePoints > 0 then
		draw.Color(255, 255, 0, 255) -- Yellow for sample points
		for _, samplePos in ipairs(TestState.samplePoints) do
			Draw3DBox(4, samplePos)
		end
	end

	-- Draw debug traces
	for _, trace in ipairs(TestState.lineTraces) do
		draw.Color(255, 255, 255, 255)
		local w2s_start, w2s_end = client.WorldToScreen(trace.startPos), client.WorldToScreen(trace.endPos)
		if w2s_start and w2s_end then
			draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		end
	end

	for _, trace in ipairs(TestState.hullTraces) do
		draw.Color(0, 50, 255, 255)
		ArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
	end
end

-- Toggle function
local function ToggleTest()
	TestState.enabled = not TestState.enabled
	if TestState.enabled then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
		print("Optimized ISWalkable Test Suite: ENABLED")
		client.Command('play "ui/buttonclick"', true)
	else
		print("Optimized ISWalkable Test Suite: DISABLED")
		client.Command('play "ui/buttonclick_release"', true)
	end
end

-- Public API
local OptimizedISWalkableTest = {
	Toggle = ToggleTest,
	IsEnabled = function()
		return TestState.enabled
	end,
	GetState = function()
		return TestState
	end,
}

-- Auto-register callbacks
callbacks.Register("CreateMove", "OptimizedISWalkableTest_CreateMove", OnCreateMove)
callbacks.Register("Draw", "OptimizedISWalkableTest_Draw", OnDraw)

-- Add to global for easy access
G.OptimizedISWalkableTest = OptimizedISWalkableTest

print("Optimized ISWalkable Test Suite loaded. Use G.OptimizedISWalkableTest.Toggle() to enable/disable.")

return OptimizedISWalkableTest

end)
__bundle_register("MedBot.Bot.ISWalkableTest", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    ISWalkable Test Suite
    Standalone testing module for ISWalkable optimization
    Mimics the visual toggle system from A_standstillDummy.lua
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local Fonts = { Verdana = draw.CreateFont("Verdana", 14, 510) }
local G = require("MedBot.Core.Globals")

-- Test state variables
local TestState = {
	enabled = false,
	startPos = nil,
	currentPos = nil,
	isWalkable = false,
	showVisuals = true,

	-- Benchmark data
	benchmarkRecords = {},
	MAX_RECORDS = 66,
	averageMemoryUsage = 0,
	averageTimeUsage = 0,

	-- Visual data
	hullTraces = {},
	lineTraces = {},
}

-- Constants
local MAX_SPEED = 450
local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local MAX_FALL_DISTANCE = 250
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MAX_SPEED * globals.TickInterval()
local MAX_SURFACE_ANGLE = 45
local MAX_ITERATIONS = 37

-- Benchmark functions
local function BenchmarkStart()
	local startMemory = collectgarbage("count")
	local startTime = os.clock()
	return startTime, startMemory
end

local function BenchmarkStop(startTime, startMemory)
	local stopTime = os.clock()
	local stopMemory = collectgarbage("count")

	local elapsedTime = math.max(stopTime - startTime, 0)
	local memoryDelta = math.abs(stopMemory - startMemory)

	table.insert(TestState.benchmarkRecords, 1, { time = elapsedTime, memory = memoryDelta })
	if #TestState.benchmarkRecords > TestState.MAX_RECORDS then
		table.remove(TestState.benchmarkRecords)
	end

	local totalTime, totalMemory = 0, 0
	for _, record in ipairs(TestState.benchmarkRecords) do
		totalTime = totalTime + record.time
		totalMemory = totalMemory + record.memory
	end

	TestState.averageTimeUsage = totalTime / #TestState.benchmarkRecords
	TestState.averageMemoryUsage = totalMemory / #TestState.benchmarkRecords
end

-- ISWalkable implementation (optimized version from dummy)
local function shouldHitEntity(entity)
	local pLocal = entities.GetLocalPlayer()
	return entity ~= pLocal
end

local function Normalize(vec)
	return vec / vec:Length()
end

local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

local function performTraceHull(startPos, endPos)
	local result =
		engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
	table.insert(TestState.hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)
	direction.z = direction.z - surfaceNormal.z * dotProduct
	return Normalize(direction)
end

-- Helper: Find closest navmesh node to a 2D position
local function getClosestNavmeshNode(pos, pathNodes)
	local closestNode = nil
	local closestDist = math.huge

	for _, node in ipairs(pathNodes) do
		local nodePos = Vector3(node.x, node.y, node.z)
		local dx = pos.x - nodePos.x
		local dy = pos.y - nodePos.y
		local dist2D = math.sqrt(dx * dx + dy * dy)

		if dist2D < closestDist then
			closestDist = dist2D
			closestNode = node
		end
	end

	return closestNode, closestDist
end

local function IsWalkable(startPos, goalPos)
	-- Clear trace tables for debugging
	TestState.hullTraces = {}
	TestState.lineTraces = {}
	local blocked = false

	local currentPos = startPos

	-- Adjust start position to ground level
	local startGroundTrace = performTraceHull(startPos + STEP_HEIGHT_Vector, startPos - MAX_FALL_DISTANCE_Vector)

	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(goalPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, goalPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		local distanceToGoal = (currentPos - goalPos):Length()
		local direction = lastDirection

		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check
		local wallTrace = performTraceHull(lastPos + STEP_HEIGHT_Vector, NextPos + STEP_HEIGHT_Vector)
		currentPos = wallTrace.endpos

		if wallTrace.fraction == 0 then
			blocked = true -- Path is blocked by a wall
		end

		-- Ground collision with segmentation
		local totalDistance = (currentPos - lastPos):Length()
		local numSegments = math.max(1, math.floor(totalDistance / MIN_STEP_SIZE))

		for seg = 1, numSegments do
			local t = seg / numSegments
			local segmentPos = lastPos + (currentPos - lastPos) * t
			local segmentTop = segmentPos + STEP_HEIGHT_Vector
			local segmentBottom = segmentPos - MAX_FALL_DISTANCE_Vector

			local groundTrace = performTraceHull(segmentTop, segmentBottom)

			if groundTrace.fraction == 1 then
				return false -- No ground beneath; path is unwalkable
			end

			if groundTrace.fraction > STEP_FRACTION or seg == numSegments then
				-- Adjust position to ground
				direction = adjustDirectionToSurface(direction, groundTrace.plane)
				currentPos = groundTrace.endpos
				blocked = false
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, goalPos)
		if blocked or currentDistance > MaxDistance then --if target is unreachable
			return false
		elseif currentDistance < 24 then --within range
			local verticalDist = math.abs(goalPos.z - currentPos.z)
			if verticalDist < 24 then --within vertical range
				return true -- Goal is within reach; path is walkable
			else --unreachable
				return false -- Goal is too far vertically; path is unwalkable
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	return false -- Max iterations reached without finding a path
end

-- Visual functions
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	local direction = end_pos - start_pos
	local min_acceptable_length = arrowhead_length + (arrowhead_width / 2)
	if direction:Length() < min_acceptable_length then
		local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
		if not (w2s_start and w2s_end) then
			return
		end
		draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		return
	end

	local normalized_direction = Normalize(direction)
	local arrow_base = end_pos - normalized_direction * arrowhead_length
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- Main test functions
local function OnCreateMove(Cmd)
	-- Check menu state
	if not G.Menu.Visuals.ISWalkableTest then
		TestState.enabled = false
		return
	end

	-- Set enabled and initialize startPos if needed
	if not TestState.enabled then
		TestState.enabled = true
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() and not TestState.startPos then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	TestState.currentPos = pLocal:GetAbsOrigin()

	-- Shift to reset position
	if input.IsButtonDown(KEY_LSHIFT) then
		TestState.startPos = TestState.currentPos
		return
	end

	-- Don't interfere with movement
	if Cmd:GetForwardMove() ~= 0 or Cmd:GetSideMove() ~= 0 then
		return
	end

	-- Only run test when F key is held
	if not input.IsButtonDown(KEY_F) then
		return
	end

	-- Only run test if we have both positions and they're far enough apart
	if TestState.startPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		local startTime, startMemory = BenchmarkStart()
		TestState.isWalkable = IsWalkable(TestState.currentPos, TestState.startPos)
		BenchmarkStop(startTime, startMemory)
	end
end

local function OnDraw()
	-- Check menu state first
	if not G.Menu.Visuals.ISWalkableTest then
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 255, 255, 255)

	-- Draw target position box
	if TestState.startPos then
		Draw3DBox(10, TestState.startPos)
	end

	-- Draw walkability test and arrow
	if TestState.startPos and TestState.currentPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		if TestState.isWalkable then
			draw.Color(0, 255, 0, 255)
		else
			draw.Color(255, 0, 0, 255)
		end
		ArrowLine(TestState.currentPos, TestState.startPos, 10, 20, false)
	end

	-- Draw benchmark info
	draw.Color(255, 255, 255, 255)
	draw.Text(20, 120, string.format("ISWalkable Test: %s", G.Menu.Visuals.ISWalkableTest and "ON" or "OFF"))
	draw.Text(20, 150, string.format("Memory usage: %.2f KB", TestState.averageMemoryUsage))
	draw.Text(20, 180, string.format("Time usage: %.2f ms", TestState.averageTimeUsage * 1000))
	draw.Text(20, 210, string.format("Result: %s", TestState.isWalkable and "WALKABLE" or "NOT WALKABLE"))
	draw.Text(20, 240, "Press SHIFT to set start | Hold F to test")

	-- Draw debug traces
	for _, trace in ipairs(TestState.lineTraces) do
		draw.Color(255, 255, 255, 255)
		local w2s_start, w2s_end = client.WorldToScreen(trace.startPos), client.WorldToScreen(trace.endPos)
		if w2s_start and w2s_end then
			draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		end
	end

	for _, trace in ipairs(TestState.hullTraces) do
		draw.Color(0, 50, 255, 255)
		ArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
	end
end

-- Toggle function
local function ToggleTest()
	TestState.enabled = not TestState.enabled
	if TestState.enabled then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
		print("ISWalkable Test Suite: ENABLED")
		client.Command('play "ui/buttonclick"', true)
	else
		print("ISWalkable Test Suite: DISABLED")
		client.Command('play "ui/buttonclick_release"', true)
	end
end

-- Public API
local ISWalkableTest = {
	Toggle = ToggleTest,
	IsEnabled = function()
		return TestState.enabled
	end,
	GetState = function()
		return TestState
	end,
}

-- Auto-register callbacks
callbacks.Register("CreateMove", "ISWalkableTest_CreateMove", OnCreateMove)
callbacks.Register("Draw", "ISWalkableTest_Draw", OnDraw)

-- Add to global for easy access
G.ISWalkableTest = ISWalkableTest

print("ISWalkable Test Suite loaded. Use G.ISWalkableTest.Toggle() to enable/disable.")

return ISWalkableTest

end)
__bundle_register("MedBot.Bot.SmartJump", function(require, _LOADED, __bundle_register, __bundle_modules)
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Log = Common.Log.new("SmartJump")

Log.Level = 0
local SJ = G.SmartJump
local SJC = G.SmartJump.Constants

-- Log:Debug now automatically respects G.Menu.Main.Debug, no wrapper needed

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function GetPlayerHitbox(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	return {
		mins,
		maxs,
	}
end

local function RotateVectorByYaw(vector, yaw)
	local rad = math.rad(yaw)
	local cos, sin = math.cos(rad), math.sin(rad)
	return Vector3(cos * vector.x - sin * vector.y, sin * vector.x + cos * vector.y, vector.z)
end

local function isSurfaceWalkable(normal)
	local vUp = Vector3(0, 0, 1)
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	return angle < 55
end

local function isPlayerOnGround(player)
	local pFlags = player:GetPropInt("m_fFlags")
	return pFlags & FL_ONGROUND == FL_ONGROUND
end

local function isPlayerDucking(player)
	return player:GetPropInt("m_fFlags") & FL_DUCKING == FL_DUCKING
end

local SmartJump = {}

-- ============================================================================
-- OBSTACLE DETECTION AND JUMP CALCULATION
-- ============================================================================

local function CheckJumpable(hitPos, moveDirection, hitbox)
	if not moveDirection then
		return false, 0
	end

	local checkPos = hitPos + moveDirection * 1
	local abovePos = checkPos + SJC.MAX_JUMP_HEIGHT

	-- Perform the trace and get detailed results
	local trace = engine.TraceHull(abovePos, checkPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	if isSurfaceWalkable(trace.plane) then
		-- FIXED: Calculate obstacle height from actual trace distance, not hardcoded 72
		local traceLength = (abovePos - checkPos):Length()
		local obstacleHeight = traceLength * (1 - trace.fraction)

		-- FIXED: Ensure obstacle height is reasonable
		if trace.fraction == 0 then
			-- Trace hit immediately, this might be a wall we're standing against
			return false, 0
		end

		if obstacleHeight <= 0 or obstacleHeight > 100 then
			-- Invalid obstacle height
			return false, 0
		end

		if obstacleHeight > 18 then
			G.SmartJump.LastObstacleHeight = hitPos.z + obstacleHeight

			-- Calculate minimum ticks needed to clear this obstacle
			-- Use quadratic formula to find time to reach obstacle height
			local jumpVel = SJC.JUMP_FORCE
			local gravity = SJC.GRAVITY
			local tickInterval = globals.TickInterval()

			local a = 0.5 * gravity
			local b = -jumpVel
			local c = obstacleHeight
			local discriminant = b * b - 4 * a * c

			local minTicksNeeded = 0
			if discriminant >= 0 then
				local t1 = (-b - math.sqrt(discriminant)) / (2 * a)
				local t2 = (-b + math.sqrt(discriminant)) / (2 * a)
				local t = math.min(t1 > 0 and t1 or math.huge, t2 > 0 and t2 or math.huge)
				if t ~= math.huge then
					minTicksNeeded = math.ceil(t / tickInterval)
				end
			else
				-- FIXED: For negative discriminant, use approximation
				-- Estimate time based on obstacle height vs max jump height
				local maxJumpHeight = 72
				local timeToMaxHeight = math.sqrt(2 * maxJumpHeight / gravity)
				local fraction = obstacleHeight / maxJumpHeight
				local estimatedTime = timeToMaxHeight * fraction
				minTicksNeeded = math.ceil(estimatedTime / tickInterval)
			end

			G.SmartJump.JumpPeekPos = trace.endpos
			return true, minTicksNeeded
		end
	end
	return false, 0
end

-- ============================================================================
-- MOVEMENT SIMULATION
-- ============================================================================

local function SimulateMovementTick(startPos, velocity, pLocal)
	local upVector = Vector3(0, 0, 1)
	local stepVector = Vector3(0, 0, 18)
	local hitbox = GetPlayerHitbox(pLocal)
	local deltaTime = globals.TickInterval()
	local moveDirection = Common.Normalize(velocity)
	local targetPos = startPos + velocity * deltaTime

	local startPostrace = engine.TraceHull(startPos + stepVector, startPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local downpstartPos = startPostrace.endpos
	local uptrace = engine.TraceHull(targetPos + stepVector, targetPos, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	local downpostarget = uptrace.endpos
	local wallTrace =
		engine.TraceHull(downpstartPos + stepVector, downpostarget + stepVector, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

	if wallTrace.fraction ~= 0 then
		targetPos = wallTrace.endpos
	end

	local Groundtrace = engine.TraceHull(targetPos, targetPos - stepVector * 2, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if Groundtrace.fraction < 1 then
		targetPos = Groundtrace.endpos
	else
		return nil, false, velocity, false, 0
	end

	Groundtrace = engine.TraceHull(targetPos, targetPos - stepVector, hitbox[1], hitbox[2], MASK_PLAYERSOLID)
	if Groundtrace.fraction < 1 then
		targetPos = Groundtrace.endpos
	else
		return nil, false, velocity, false, 0
	end

	local hitObstacle = wallTrace.fraction < 1
	local canJump = false
	local minJumpTicks = 0

	if hitObstacle then
		canJump, minJumpTicks = CheckJumpable(targetPos, moveDirection, hitbox)
		local wallNormal = wallTrace.plane
		local wallAngle = math.deg(math.acos(wallNormal:Dot(upVector)))

		-- FIXED: Apply sliding logic only for steep walls (>55 degrees)
		-- This matches the swing prediction behavior - only slide on steep walls
		if wallAngle > 55 then
			-- The wall is too steep, we'll collide
			local dot = velocity:Dot(wallNormal)
			velocity = velocity - wallNormal * dot
		end
	end

	return targetPos, hitObstacle, velocity, canJump, minJumpTicks
end
-- ============================================================================
-- SMART JUMP DETECTION
-- ============================================================================

local function isNearPayload(position)
	-- Check if position is near any payload cart
	if not G.World.payloads then
		return false
	end

	for _, payload in pairs(G.World.payloads) do
		if payload:IsValid() then
			local payloadPos = payload:GetAbsOrigin()

			-- Check distance to entity center
			local distToCenter = (position - payloadPos):Length()
			if distToCenter < 200 then
				return true
			end

			-- Also check distance to ground-level position (offset -80 like in GoalFinder)
			local groundPos = Vector3(payloadPos.x, payloadPos.y, payloadPos.z - 80)
			local distToGround = (position - groundPos):Length()
			if distToGround < 150 then
				return true
			end
		end
	end
	return false
end

local function SmartJumpDetection(cmd, pLocal)
	if not pLocal or (not isPlayerOnGround(pLocal)) then
		return false
	end

	local pLocalPos = pLocal:GetAbsOrigin()

	-- Early exit: don't jump if already near payload
	if isNearPayload(pLocalPos) then
		return false
	end

	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	local viewAngles = engine.GetViewAngles()

	if moveIntent:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()
		moveIntent = Vector3(G.BotMovementDirection:Dot(forward) * 450, (-G.BotMovementDirection:Dot(right)) * 450, 0)
	end

	local rotatedMoveIntent = RotateVectorByYaw(moveIntent, viewAngles.yaw)

	-- FIXED: Ensure we always have minimum move direction for simulation
	-- Even if move intent is very small, we need direction to detect obstacles
	local moveDir = Common.Normalize(rotatedMoveIntent)
	local moveLength = rotatedMoveIntent:Length()

	-- Always use minimum move speed for simulation (450 units/second)
	local minMoveSpeed = 450
	local simulationSpeed = math.max(moveLength, minMoveSpeed)

	-- If no movement intent at all, use forward direction
	if moveLength <= 1 then
		local forward = viewAngles:Forward()
		moveDir = forward
		simulationSpeed = minMoveSpeed
	end

	local currentVel = pLocal:EstimateAbsVelocity()
	local horizontalSpeed = currentVel:Length()

	-- Use simulation speed if we have movement intent, otherwise use current velocity
	if horizontalSpeed <= 1 then
		horizontalSpeed = simulationSpeed
	end

	local initialVelocity = moveDir * horizontalSpeed

	-- Calculate actual jump peak timing using TF2 physics
	-- Jump velocity impulse: immediately sets Z velocity to JUMP_FORCE
	-- Gravity: 800 units/second²
	-- Find time to reach peak: t = JUMP_FORCE / GRAVITY
	local jumpVel = SJC.JUMP_FORCE
	local gravity = SJC.GRAVITY
	local tickInterval = globals.TickInterval()

	-- Time to reach jump peak: t = v/g
	local timeToPeak = jumpVel / gravity -- 271/800 = 0.33875 seconds
	local jumpPeakTicks = math.ceil(timeToPeak / tickInterval) -- ~23 ticks

	local totalSimulationTicks = jumpPeakTicks

	local currentPos = pLocalPos
	local currentVelocity = initialVelocity

	G.SmartJump.SimulationPath = {
		currentPos,
	}

	for tick = 1, totalSimulationTicks do
		local newPos, hitObstacle, newVelocity, canJump, minJumpTicks =
			SimulateMovementTick(currentPos, currentVelocity, pLocal)

		if not newPos then
			break
		end

		table.insert(G.SmartJump.SimulationPath, newPos)

		if hitObstacle and canJump then
			--print(tick, minJumpTicks)

			if tick <= minJumpTicks then
				-- Check if we're trying to jump onto or near payload
				if isNearPayload(newPos) or isNearPayload(currentPos) then
					Log:Debug("SmartJump: Skipping jump - near payload cart")
					return false
				end

				G.SmartJump.PredPos = newPos
				G.SmartJump.HitObstacle = true
				Log:Debug("SmartJump: Jumping at tick %d (needed: %d)", tick, minJumpTicks)
				return true
			else
				Log:Debug("SmartJump: Obstacle detected at tick %d (need tick %d) -> Waiting", tick, minJumpTicks)
				return false
			end
		end

		currentPos = newPos
		currentVelocity = newVelocity
	end
	return false
end
-- ============================================================================
-- MAIN SMART JUMP LOGIC
-- ============================================================================

function SmartJump.Main(cmd)
	if not G.Menu.SmartJump.Enable then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.ObstacleDetected = false
		SJ.RequestEmergencyJump = false
		return
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or (not pLocal:IsAlive()) or pLocal:IsDormant() then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.ShouldJump = false
		SJ.ObstacleDetected = false
		SJ.RequestEmergencyJump = false
		return false
	end

	local onGround = isPlayerOnGround(pLocal)
	local ducking = isPlayerDucking(pLocal)
	local shouldJump = false

	if G.SmartJump.RequestEmergencyJump then
		shouldJump = true
		G.SmartJump.RequestEmergencyJump = false
		G.SmartJump.LastSmartJumpAttempt = globals.TickCount()
		SJ.jumpState = SJC.STATE_PREPARE_JUMP
		Log:Info("SmartJump: Processing emergency jump request")
	end

	local hasMovementIntent = false
	local moveDir = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveDir:Length() > 0 or G.BotIsMoving and G.BotMovementDirection and G.BotMovementDirection:Length() > 0 then
		hasMovementIntent = true
	end

	if onGround and ducking and hasMovementIntent and SJ.jumpState == SJC.STATE_IDLE then
		local obstacleDetected = SmartJumpDetection(cmd, pLocal)
		if obstacleDetected then
			SJ.jumpState = SJC.STATE_PREPARE_JUMP
			Log:Debug("SmartJump: Crouched movement with obstacle detected, initiating jump")
		else
			Log:Debug("SmartJump: Crouched movement but no obstacle detected, staying idle")
		end
	end

	if SJ.jumpState == SJC.STATE_IDLE then
		if onGround and hasMovementIntent then
			local smartJumpDetected = SmartJumpDetection(cmd, pLocal)
			if smartJumpDetected or shouldJump then
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
				Log:Debug("SmartJump: IDLE -> PREPARE_JUMP (obstacle detected)")
			end
		end
	elseif SJ.jumpState == SJC.STATE_PREPARE_JUMP then
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
		SJ.jumpState = SJC.STATE_CTAP
		Log:Debug("SmartJump: PREPARE_JUMP -> CTAP (ducking)")
	elseif SJ.jumpState == SJC.STATE_CTAP then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		cmd:SetButtons(cmd.buttons | IN_JUMP)
		SJ.jumpState = SJC.STATE_ASCENDING
		Log:Debug("SmartJump: CTAP -> ASCENDING (unduck + jump)")
	elseif SJ.jumpState == SJC.STATE_ASCENDING then
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		local velocity = pLocal:EstimateAbsVelocity()
		local currentPos = pLocal:GetAbsOrigin()

		-- Check if we should unduck (improve duck grab logic)
		local shouldUnduck = velocity.z <= 0 -- Always unduck when falling

		-- If Duck_Grab is enabled and we have obstacle height info, do improved check
		if not shouldUnduck and G.Menu.Main.Duck_Grab and G.SmartJump.LastObstacleHeight then
			local playerHeight = currentPos.z

			-- Only consider unducking if we're above the obstacle
			if playerHeight > G.SmartJump.LastObstacleHeight then
				-- IMPROVED: Trace down from player position + obstacle height + 1
				local traceStart = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight + 1)
				local traceEnd = Vector3(currentPos.x, currentPos.y, G.SmartJump.LastObstacleHeight - 10)
				local hitbox = GetPlayerHitbox(pLocal)
				local obstacleTrace = engine.TraceHull(traceStart, traceEnd, hitbox[1], hitbox[2], MASK_PLAYERSOLID)

				-- If trace hits something, obstacle is still there - safe to unduck
				if obstacleTrace.fraction < 1 then
					shouldUnduck = true
					Log:Debug(
						"SmartJump: Unducking - obstacle confirmed at height %.1f",
						G.SmartJump.LastObstacleHeight
					)
				else
					Log:Debug(
						"SmartJump: Staying ducked - no obstacle detected at height %.1f",
						G.SmartJump.LastObstacleHeight
					)
				end
			end
		end

		if shouldUnduck then
			SJ.jumpState = SJC.STATE_DESCENDING
			Log:Debug("SmartJump: ASCENDING -> DESCENDING (improved duck grab check)")
		end
	elseif SJ.jumpState == SJC.STATE_DESCENDING then
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)

		if hasMovementIntent then
			local bhopJump = SmartJumpDetection(cmd, pLocal)
			if bhopJump then
				cmd:SetButtons(cmd.buttons & ~IN_DUCK)
				cmd:SetButtons(cmd.buttons | IN_JUMP)
				SJ.jumpState = SJC.STATE_PREPARE_JUMP
				Log:Debug("SmartJump: DESCENDING -> PREPARE_JUMP (bhop with obstacle)")
			end

			if onGround then
				SJ.jumpState = SJC.STATE_IDLE
				Log:Debug("SmartJump: DESCENDING -> IDLE (landed)")
			end
		elseif onGround then
			SJ.jumpState = SJC.STATE_IDLE
			Log:Debug("SmartJump: DESCENDING -> IDLE (no movement intent)")
		end
	end

	if not SJ.stateStartTime then
		SJ.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - SJ.stateStartTime > 132 then
		SJ.jumpState = SJC.STATE_IDLE
		SJ.stateStartTime = nil
	end

	local currentState = SJ.jumpState
	if SJ.lastState ~= currentState then
		SJ.stateStartTime = globals.TickCount()
		SJ.lastState = currentState
	end

	G.SmartJump.ShouldJump = shouldJump
	return shouldJump
end

-- ============================================================================
-- VISUALIZATION AND CALLBACKS
-- ============================================================================

local function OnCreateMoveStandalone(cmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or (not pLocal:IsAlive()) then
		return
	end
	SmartJump.Main(cmd)
end

local function OnDrawSmartJump()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not G.Menu.SmartJump or not G.Menu.SmartJump.Enable then
		return
	end

	-- Check if SmartJump visuals are enabled in menu
	if not (G.Menu.Visuals and G.Menu.Visuals.showSmartJump) then
		return
	end

	local vHitbox = GetPlayerHitbox(pLocal)
	if G.SmartJump.PredPos then
		local screenPos = client.WorldToScreen(G.SmartJump.PredPos)
		if screenPos then
			draw.Color(255, 0, 0, 255)
			draw.FilledRect(screenPos[1] - 5, screenPos[2] - 5, screenPos[1] + 5, screenPos[2] + 5)
		end
	end

	if G.SmartJump.JumpPeekPos then
		local screenpeekpos = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if screenpeekpos then
			draw.Color(0, 255, 0, 255)
			draw.FilledRect(screenpeekpos[1] - 5, screenpeekpos[2] - 5, screenpeekpos[1] + 5, screenpeekpos[2] + 5)
		end

		local minPoint = vHitbox[1] + G.SmartJump.JumpPeekPos
		local maxPoint = vHitbox[2] + G.SmartJump.JumpPeekPos
		local vertices = {
			Vector3(minPoint.x, minPoint.y, minPoint.z),
			Vector3(minPoint.x, maxPoint.y, minPoint.z),
			Vector3(maxPoint.x, maxPoint.y, minPoint.z),
			Vector3(maxPoint.x, minPoint.y, minPoint.z),
			Vector3(minPoint.x, minPoint.y, maxPoint.z),
			Vector3(minPoint.x, maxPoint.y, maxPoint.z),
			Vector3(maxPoint.x, maxPoint.y, maxPoint.z),
			Vector3(maxPoint.x, minPoint.y, maxPoint.z),
		}

		for i, vertex in ipairs(vertices) do
			vertices[i] = client.WorldToScreen(vertex)
		end

		if
			vertices[1]
			and vertices[2]
			and vertices[3]
			and vertices[4]
			and vertices[5]
			and vertices[6]
			and vertices[7]
			and vertices[8]
		then
			draw.Color(0, 255, 255, 255)
			draw.Line(vertices[1][1], vertices[1][2], vertices[2][1], vertices[2][2])
			draw.Line(vertices[2][1], vertices[2][2], vertices[3][1], vertices[3][2])
			draw.Line(vertices[3][1], vertices[3][2], vertices[4][1], vertices[4][2])
			draw.Line(vertices[4][1], vertices[4][2], vertices[1][1], vertices[1][2])
			draw.Line(vertices[5][1], vertices[5][2], vertices[6][1], vertices[6][2])
			draw.Line(vertices[6][1], vertices[6][2], vertices[7][1], vertices[7][2])
			draw.Line(vertices[7][1], vertices[7][2], vertices[8][1], vertices[8][2])
			draw.Line(vertices[8][1], vertices[8][2], vertices[5][1], vertices[5][2])
			draw.Line(vertices[1][1], vertices[1][2], vertices[5][1], vertices[5][2])
			draw.Line(vertices[2][1], vertices[2][2], vertices[6][1], vertices[6][2])
			draw.Line(vertices[3][1], vertices[3][2], vertices[7][1], vertices[7][2])
			draw.Line(vertices[4][1], vertices[4][2], vertices[8][1], vertices[8][2])
		end
	end

	if G.SmartJump.SimulationPath and #G.SmartJump.SimulationPath > 1 then
		for i = 1, #G.SmartJump.SimulationPath - 1 do
			local currentPos = G.SmartJump.SimulationPath[i]
			local nextPos = G.SmartJump.SimulationPath[i + 1]
			local currentScreen = client.WorldToScreen(currentPos)
			local nextScreen = client.WorldToScreen(nextPos)
			if currentScreen and nextScreen then
				local alpha = math.floor(100 + i / #G.SmartJump.SimulationPath * 155)
				draw.Color(0, 150, 255, alpha)
				draw.Line(currentScreen[1], currentScreen[2], nextScreen[1], nextScreen[2])
			end
		end
	end

	if G.SmartJump.JumpPeekPos then
		local landingScreen = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if landingScreen then
			draw.Color(0, 255, 255, 255)
			draw.FilledRect(landingScreen[1] - 4, landingScreen[2] - 4, landingScreen[1] + 4, landingScreen[2] + 4)
		end
	end
end

-- ============================================================================
-- MODULE INITIALIZATION
-- ============================================================================

callbacks.Unregister("CreateMove", "SmartJump.Standalone")
callbacks.Register("CreateMove", "SmartJump.Standalone", OnCreateMoveStandalone)
callbacks.Unregister("Draw", "SmartJump.Visual")
callbacks.Register("Draw", "SmartJump.Visual", OnDrawSmartJump)

return SmartJump

end)
__bundle_register("MedBot.Bot.HealthLogic", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  HealthLogic.lua  ·  Bot health management
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local HealthLogic = {}

function HealthLogic.ShouldHeal(pLocal)
	if not pLocal then
		return false
	end

	local healthPercent = (pLocal:GetHealth() / pLocal:GetMaxHealth()) * 100
	local isHealing = pLocal:InCond(TFCond_Healing)
	local threshold = G.Menu.Main.SelfHealTreshold

	return healthPercent < threshold and not isHealing
end

function HealthLogic.HandleSelfHealing(pLocal)
	if not HealthLogic.ShouldHeal(pLocal) then
		return
	end

	-- Find health pack or healing source
	local players = entities.FindByClass("CTFPlayer")
	for _, player in pairs(players) do
		if
			player:GetTeamNumber() == pLocal:GetTeamNumber()
			and player:GetPropInt("m_iClass") == TF_CLASS_MEDIC
			and player ~= pLocal
		then
			G.Targets.Heal = player:GetIndex()
			return
		end
	end
end

return HealthLogic

end)
__bundle_register("MedBot.Bot.MovementDecisions", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
Movement Decision System - Composition-based bot behavior
Handles all movement decisions while ensuring walkTo is always called
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local MovementController = require("MedBot.Bot.MovementController")
local SmartJump = require("MedBot.Bot.SmartJump")
local WorkManager = require("MedBot.WorkManager")
local PathValidator = require("MedBot.Navigation.isWalkable.IsWalkable")
local NodeSkipper = require("MedBot.Bot.NodeSkipper")

local MovementDecisions = {}
local Log = Common.Log.new("MovementDecisions")

-- Log:Debug now automatically respects G.Menu.Main.Debug, no wrapper needed

-- Constants for timing and performance
local DISTANCE_CHECK_COOLDOWN = 3 -- ticks (~50ms) between distance calculations
local DEBUG_LOG_COOLDOWN = 15 -- ticks (~0.25s) between debug logs
local WALKABILITY_CHECK_COOLDOWN = 5 -- ticks (~83ms) between expensive walkability checks

-- Decision: Check if we've reached the target and advance waypoints/nodes
function MovementDecisions.checkDistanceAndAdvance(userCmd)
	local result = { shouldContinue = true }
	local LocalOrigin = G.pLocal.Origin

	-- Per-tick node skipping (runs every tick, NOT throttled)
	if NodeSkipper.Tick(LocalOrigin) then
		-- Path changed (nodes skipped), rebuild waypoints to match new path
		Navigation.BuildDoorWaypointsFromPath()
		Log:Debug("NodeSkipper modified path - waypoints rebuilt")

		-- If we skipped nodes, we might be far from the new target, or close.
		-- We should probably update the targetPos immediately for the next frame or this frame's movement execution.
		-- Current implementation of executeMovement calls getCurrentTarget(), which will get the NEW target.
		-- So we just need to ensure we don't accidentally "reach" the old target or do weird distance logic this frame.
	end

	-- Throttled distance calculation for reaching nodes
	if not WorkManager.attemptWork(DISTANCE_CHECK_COOLDOWN, "distance_check") then
		return result -- Skip this frame's distance check
	end

	-- Get current target position
	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		result.shouldContinue = false
		return result
	end

	-- In FOLLOWING state we don't advance nodes based on reach distance
	if G.currentState == G.States.FOLLOWING then
		return result
	end

	local horizontalDist = Common.Distance2D(LocalOrigin, targetPos)
	local verticalDist = math.abs(LocalOrigin.z - targetPos.z)

	-- Check if we've reached the target
	local reachedTarget = MovementDecisions.hasReachedTarget(LocalOrigin, targetPos, horizontalDist, verticalDist)

	if reachedTarget then
		Log:Debug("Reached target - advancing waypoint/node")

		-- Advance waypoint or node
		if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
			Navigation.AdvanceWaypoint()
			-- If no more waypoints, we're done
			if not Navigation.GetCurrentWaypoint() then
				Navigation.ClearPath()
				Log:Info("Reached end of waypoint path")
				result.shouldContinue = false
				G.currentState = G.States.IDLE
				G.lastPathfindingTick = 0
			end
		else
			-- Fallback to node-based advancement
			MovementDecisions.advanceNode()
		end
	end

	return result
end

-- Helper: Get current target position
function MovementDecisions.getCurrentTarget()
	if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
		local currentWaypoint = Navigation.GetCurrentWaypoint()
		if currentWaypoint then
			return currentWaypoint.pos
		end
	end

	-- Fallback to path node
	if G.Navigation.path and #G.Navigation.path > 0 then
		local currentNode = G.Navigation.path[1]
		return currentNode and currentNode.pos
	end

	return nil
end

-- Helper: Check if we've reached the target
function MovementDecisions.hasReachedTarget(origin, targetPos, horizontalDist, verticalDist)
	return (horizontalDist < G.Misc.NodeTouchDistance) and (verticalDist <= G.Misc.NodeTouchHeight)
end

-- Reset distance tracking (call when path changes)
function MovementDecisions.resetDistanceTracking()
	previousDistance = nil
end

-- Decision: Handle node advancement
function MovementDecisions.advanceNode()
	previousDistance = nil -- Reset tracking when advancing nodes
	Log:Debug(tostring(G.Menu.Main.Skip_Nodes), #G.Navigation.path)

	Log:Debug("Removing current node (reached target)")
	Navigation.RemoveCurrentNode()
	Navigation.ResetTickTimer()
	Navigation.ResetNodeSkipping()

	if #G.Navigation.path == 0 then
		Navigation.ClearPath()
		Log:Info("Reached end of path")
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		return false
	end

	return true -- Continue moving
end

-- Decision: Check stuck state: Simple walkability check with cooldown
function MovementDecisions.checkStuckState()
	-- Velocity/timeout checks ONLY when bot is walking autonomously
	if G.Menu.Main.EnableWalking then
		local pLocal = G.pLocal.entity
		if pLocal then
			-- Track how long we've been on the same node
			local currentNodeId = G.Navigation.path and G.Navigation.path[1] and G.Navigation.path[1].id
			if currentNodeId then
				if currentNodeId ~= G.Navigation.lastNodeId then
					G.Navigation.lastNodeId = currentNodeId
					G.Navigation.currentNodeTicks = 0
				else
					G.Navigation.currentNodeTicks = (G.Navigation.currentNodeTicks or 0) + 1
				end

				-- Stuck detection: If on same node for > 200 ticks (3 seconds), force repath
				if G.Navigation.currentNodeTicks > 200 then
					Log:Warn("STUCK: Same node for %d ticks, switching to STUCK state", G.Navigation.currentNodeTicks)
					G.currentState = G.States.STUCK
					G.Navigation.currentNodeTicks = 0
					return
				end
			end

			-- Velocity-based stuck detection
			local velocity = pLocal:EstimateAbsVelocity()
			if velocity and type(velocity.x) == "number" and type(velocity.y) == "number" then
				local speed2D = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

				-- Critical velocity threshold: < 50 = stuck
				if speed2D < 50 then
					G.Navigation.lowVelocityTicks = (G.Navigation.lowVelocityTicks or 0) + 1

					-- If velocity too low for 66 ticks (1 second), switch to STUCK state
					if G.Navigation.lowVelocityTicks > 66 then
						Log:Warn(
							"STUCK: Low velocity (%d) for %d ticks, entering STUCK state",
							speed2D,
							G.Navigation.lowVelocityTicks
						)
						G.currentState = G.States.STUCK
						G.Navigation.lowVelocityTicks = 0
					end
				else
					G.Navigation.lowVelocityTicks = 0
				end
			end
		end
	end

	-- Simple walkability check for ALL modes (with 33 tick cooldown)
	-- Only when NOT walking autonomously (walking mode has velocity checks)
	if not G.Menu.Main.EnableWalking then
		-- TEMPORARILY DISABLED to debug NodeSkipper traces (this was interfering with visualization)
		-- if WorkManager.attemptWork(33, "stuck_walkability_check") then
		-- 	local targetPos = MovementDecisions.getCurrentTarget()
		-- 	if targetPos then
		-- 		if not PathValidator.Path(G.pLocal.Origin, targetPos) then
		-- 			Log:Warn("STUCK: Path to current target not walkable, repathing")
		-- 			G.currentState = G.States.STUCK
		-- 		end
		-- 	end
		-- end
	end
end

-- Decision: Handle debug logging (throttled)
function MovementDecisions.handleDebugLogging()
	-- Throttled debug logging
	G.__lastMoveDebugTick = G.__lastMoveDebugTick or 0
	local now = globals.TickCount()

	if now - G.__lastMoveDebugTick > DEBUG_LOG_COOLDOWN then
		local targetPos = MovementDecisions.getCurrentTarget()
		if targetPos then
			local pathLen = G.Navigation.path and #G.Navigation.path or 0
			Log:Debug("MOVING: pathLen=%d", pathLen)
		end
		G.__lastMoveDebugTick = now
	end
end

-- Decision: Handle SmartJump execution
function MovementDecisions.handleSmartJump(userCmd)
	SmartJump.Main(userCmd)
end

-- Movement Execution: Always called at the end
function MovementDecisions.executeMovement(userCmd)
	local targetPos = MovementDecisions.getCurrentTarget()
	if not targetPos then
		Log:Warn("No target position available for movement")
		return
	end

	-- Always execute movement regardless of decision cooldowns
	if G.Menu.Main.EnableWalking then
		MovementController.walkTo(userCmd, G.pLocal.entity, targetPos)
	else
		userCmd:SetForwardMove(0)
		userCmd:SetSideMove(0)
	end
end

-- Main composition function: Run all decisions then always execute movement
function MovementDecisions.handleMovingState(userCmd)
	-- Early validation
	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	-- Update movement direction for SmartJump
	local targetPos = MovementDecisions.getCurrentTarget()
	if targetPos then
		local LocalOrigin = G.pLocal.Origin
		local direction = targetPos - LocalOrigin
		G.BotMovementDirection = direction:Length() > 0 and Common.Normalize(direction) or Vector3(0, 0, 0)
		G.BotIsMoving = true
		G.Navigation.currentTargetPos = targetPos
	end

	-- Handle camera rotation
	MovementController.handleCameraRotation(userCmd, targetPos)

	-- Run all decision components (these don't affect movement execution)
	MovementDecisions.handleDebugLogging()
	MovementDecisions.checkDistanceAndAdvance(userCmd)
	MovementDecisions.checkStuckState()

	-- ALWAYS execute movement at the end, regardless of decision outcomes
	MovementDecisions.executeMovement(userCmd)

	-- Handle SmartJump after walkTo
	MovementDecisions.handleSmartJump(userCmd)
end

return MovementDecisions

end)
__bundle_register("MedBot.Bot.NodeSkipper", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
Node Skipper - Per-tick node skipping with menu-controlled limits
Uses:
- G.Menu.Main.MaxSkipRange: max distance to skip (default 500)
- G.Menu.Main.MaxNodesToSkip: max nodes per tick (default 3)
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local isNavigable = require("MedBot.Navigation.isWalkable.isNavigable")
local Node = require("MedBot.Navigation.Node")
local WorkManager = require("MedBot.WorkManager")

local Log = Common.Log.new("NodeSkipper")

local NodeSkipper = {}

function NodeSkipper.Reset() end

function NodeSkipper.Tick(playerPos)
	assert(playerPos, "Tick: playerPos missing")

	if not G.Menu.Navigation.Skip_Nodes then
		return false
	end

	-- Check stuck cooldown (prevent skipping when stuck)
	if not WorkManager.attemptWork(1, "node_skipping") then
		return false
	end

	local path = G.Navigation.path
	if not path or #path < 2 then
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	-- SMART SKIP: Check if player already passed the current target (path[1])
	-- We compare distance to next target (path[2])
	if currentNode and currentNode.pos and nextNode and nextNode.pos then
		-- Get current area for walkability check
		local currentArea = Node.GetAreaAtPosition(playerPos)
		if not currentArea then
			return false
		end

		local distPlayerToNext = Common.Distance3D(playerPos, nextNode.pos)
		local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)

		if distPlayerToNext < distCurrentToNext then
			-- Player is closer to path[2] than path[1] is to path[2] - we passed path[1]
			-- BUT: Only skip if we can actually walk to nextNode from current position
			local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
			local success, canSkip = pcall(isNavigable.CanSkip, playerPos, nextNode.pos, currentArea, false, allowJump)

			if success and canSkip then
				local missedNode = table.remove(path, 1)

				-- Add to history
				G.Navigation.pathHistory = G.Navigation.pathHistory or {}
				table.insert(G.Navigation.pathHistory, 1, missedNode)
				while #G.Navigation.pathHistory > 32 do
					table.remove(G.Navigation.pathHistory)
				end

				-- Track when we last skipped
				G.Navigation.lastSkipTick = globals.TickCount()

				Log:Info(
					"MISSED waypoint %s (player closer to next), skipping to %s",
					tostring(missedNode.id),
					tostring(nextNode.id)
				)
				G.Navigation.currentNodeIndex = 1
				return true
			else
				Log:Debug(
					"SMART SKIP blocked: Cannot walk to next node %s from current position",
					tostring(nextNode.id)
				)
				return false
			end
		end
	end

	-- FORWARD SKIP: Single check per tick (path[3] only)
	-- If we can walk directly to path[3], skip path[1] and path[2] and bail.
	if #path < 3 then
		return false
	end

	local maxSkipRange = G.Menu.Main.MaxSkipRange or 500
	local skipTarget = path[3]
	if not (skipTarget and skipTarget.pos) then
		return false
	end

	local distToTarget = Common.Distance3D(playerPos, skipTarget.pos)
	if distToTarget > maxSkipRange then
		return false
	end

	local currentArea = Node.GetAreaAtPosition(playerPos)
	if not currentArea then
		return false
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canSkip = pcall(isNavigable.CanSkip, playerPos, skipTarget.pos, currentArea, false, allowJump)
	if not (success and canSkip) then
		return false
	end

	G.Navigation.pathHistory = G.Navigation.pathHistory or {}

	local skipped1 = table.remove(path, 1)
	if skipped1 then
		table.insert(G.Navigation.pathHistory, 1, skipped1)
	end
	local skipped2 = table.remove(path, 1)
	if skipped2 then
		table.insert(G.Navigation.pathHistory, 1, skipped2)
	end

	while #G.Navigation.pathHistory > 32 do
		table.remove(G.Navigation.pathHistory)
	end

	G.Navigation.lastSkipTick = globals.TickCount()

	Log:Info("FORWARD SKIP: bypassed 2 nodes (direct path to %s, range %.0f)", tostring(skipTarget.id), maxSkipRange)
	G.Navigation.currentNodeIndex = 1
	return true
end

return NodeSkipper

end)
__bundle_register("MedBot.WorkManager", function(require, _LOADED, __bundle_register, __bundle_modules)
local WorkManager = {}
WorkManager.works = {}
WorkManager.sortedIdentifiers = {}
WorkManager.workLimit = 1
WorkManager.executedWorks = 0

local function getCurrentTick()
	return globals.TickCount()
end

--- Adds work to the WorkManager and executes it if possible
--- @param func function The function to be executed
--- @param args table The arguments to pass to the function
--- @param delay number The delay (in ticks) before the function should be executed
--- @param identifier string A unique identifier for the work
function WorkManager.addWork(func, args, delay, identifier)
	local currentTime = getCurrentTick()
	args = args or {}

	local work = WorkManager.works[identifier]
	
	-- Check if the work already exists
	if work then
		-- Update existing work details (function, delay, args)
		work.func = func
		work.delay = delay or 1
		work.args = args
		work.wasExecuted = false
	else
		-- Add new work
		WorkManager.works[identifier] = {
			func = func,
			delay = delay,
			args = args,
			lastExecuted = currentTime,
			wasExecuted = false,
			result = nil,
		}
		-- Insert identifier and sort works based on their delay, in descending order
		table.insert(WorkManager.sortedIdentifiers, identifier)
		table.sort(WorkManager.sortedIdentifiers, function(a, b)
			return WorkManager.works[a].delay > WorkManager.works[b].delay
		end)
	end

	-- Attempt to execute the work immediately if within the work limit
	work = WorkManager.works[identifier]
	if WorkManager.executedWorks < WorkManager.workLimit then
		if not work.wasExecuted and currentTime - work.lastExecuted >= work.delay then
			-- Execute the work
			work.result = { func(table.unpack(args)) }
			work.wasExecuted = true
			work.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1
			return table.unpack(work.result)
		end
	end

	-- Return cached result if the work cannot be executed immediately
	return table.unpack(work.result or {})
end

--- Attempts to execute work if conditions are met
--- @param delay number The delay (in ticks) before the function should be executed again
--- @param identifier string A unique identifier for the work
--- @return boolean Whether the work was executed
function WorkManager.attemptWork(delay, identifier)
	local currentTime = getCurrentTick()

	-- Check if the work already exists and was executed recently
	if WorkManager.works[identifier] and currentTime - WorkManager.works[identifier].lastExecuted < delay then
		return false
	end

	-- If the work does not exist or the delay has passed, create/update the work entry
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = delay,
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime
	end

	return true
end
--- @param delay number The delay (in ticks) to set for future calls
--- @param identifier string A unique identifier for the work
--- @return boolean Always returns true to indicate work was allowed
function WorkManager.forceWork(delay, identifier)
	local currentTime = getCurrentTick()

	-- Always allow execution by updating the lastExecuted time
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = delay,
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime - delay -- Set to past to allow immediate execution
	end

	return true
end

--- Resets the cooldown for a work, allowing immediate execution on next attempt
--- @param identifier string A unique identifier for the work
--- @return boolean Always returns true to indicate reset was successful
function WorkManager.resetCooldown(identifier)
	local currentTime = getCurrentTick()

	-- Reset the cooldown by setting lastExecuted to the past
	-- This allows attemptWork to immediately allow execution on next call
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime - 1000, -- Set far in past to guarantee immediate execution
			delay = 1, -- Default delay if not set
		}
	else
		WorkManager.works[identifier].lastExecuted = currentTime - 1000 -- Set far in past to guarantee immediate execution
	end

	return true
end

--- Sets the cooldown delay for a work identifier
--- @param identifier string A unique identifier for the work
--- @param newDelay number The new delay in ticks to set
--- @return boolean Always returns true to indicate the cooldown was set
function WorkManager.setWorkCooldown(identifier, newDelay)
	local currentTime = getCurrentTick()

	-- Create or update work entry with new delay
	if not WorkManager.works[identifier] then
		WorkManager.works[identifier] = {
			lastExecuted = currentTime,
			delay = newDelay,
		}
	else
		WorkManager.works[identifier].delay = newDelay
	end

	return true
end

--- Processes the works based on their priority
function WorkManager.processWorks()
	local currentTime = getCurrentTick()
	WorkManager.executedWorks = 0

	for _, identifier in ipairs(WorkManager.sortedIdentifiers) do
		local work = WorkManager.works[identifier]
		if not work.wasExecuted and currentTime - work.lastExecuted >= work.delay then
			-- Execute the work
			work.result = { work.func(table.unpack(work.args)) }
			work.wasExecuted = true
			work.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1

			-- Stop if the work limit is reached
			if WorkManager.executedWorks >= WorkManager.workLimit then
				break
			end
		end
	end
end

--- Clears work by identifier
--- @param identifier string The identifier of the work to clear
function WorkManager.clearWork(identifier)
	if WorkManager.works[identifier] then
		WorkManager.works[identifier] = nil
		-- Remove from sorted identifiers list
		for i = #WorkManager.sortedIdentifiers, 1, -1 do
			if WorkManager.sortedIdentifiers[i] == identifier then
				table.remove(WorkManager.sortedIdentifiers, i)
				break
			end
		end
		return true
	end
	return false
end

return WorkManager

end)
__bundle_register("MedBot.Bot.MovementController", function(require, _LOADED, __bundle_register, __bundle_modules)
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

end)
__bundle_register("MedBot.Navigation", function(require, _LOADED, __bundle_register, __bundle_modules)
---@alias ConnectionObj { node: integer, cost: number, left: Vector3|nil, middle: Vector3|nil, right: Vector3|nil }
---@alias ConnectionDir { count: integer, connections: ConnectionObj[] }
---@alias Node { pos: Vector3, id: integer, c: { [1]: ConnectionDir, [2]: ConnectionDir, [3]: ConnectionDir, [4]: ConnectionDir } }
---@class Pathfinding
---@field pathFound boolean
---@field pathFailed boolean

--[[
PERFORMANCE OPTIMIZATION STRATEGY:
- Heavy validation (accessibility checks) happens at setup time via pruneInvalidConnections()
- Pathfinding uses Node.GetAdjacentNodesSimple() for speed (no expensive trace checks)
- Invalid connections are removed during setup, so pathfinding can trust remaining connections
- This moves computational load to beginning rather than during gameplay
]]

local Navigation = {}

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local AStar = require("MedBot.Algorithms.A-Star")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local NodeSkipper = require("MedBot.Bot.NodeSkipper")
local isNavigable = require("MedBot.Navigation.isWalkable.isNavigable")
local Lib = Common.Lib
local Log = Lib.Utils.Logger.new("MedBot")
Log.Level = 0

-- Constants
local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local DROP_HEIGHT = 144 -- Define your constants outside the function
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local TICK_RATE = 66
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable

-- Add a connection between two nodes
function Navigation.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		Log:Warn("AddConnection: One or both nodes are nil")
		return
	end
	Node.AddConnection(nodeA, nodeB)
	Node.AddConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		Log:Warn("RemoveConnection: One or both nodes are nil")
		return
	end
	Node.RemoveConnection(nodeA, nodeB)
	Node.RemoveConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		Log:Warn("AddCostToConnection: One or both nodes are nil")
		return
	end

	-- Use Node module's implementation to avoid duplication
	Node.AddCostToConnection(nodeA, nodeB, cost)
end

-- ========================================================================
-- SETUP & INITIALIZATION
-- ========================================================================

function Navigation.Setup()
	if engine.GetMapName() then
		Node.Setup()
		Navigation.ClearPath()
	end
end

-- ========================================================================
-- NODE QUERIES
-- ========================================================================

-- Get a node by ID
---@param nodeId integer
---@return table|nil
function Navigation.GetNode(nodeId)
	if not nodeId then
		Log:Warn("GetNode: nodeId is nil")
		return nil
	end

	return Node.GetNodeByID(nodeId)
end

-- Get adjacent nodes for a given node ID (areas only, no doors)
---@param nodeId integer
---@return integer[]
function Navigation.GetAdjacentNodes(nodeId)
	if not nodeId then
		Log:Warn("GetAdjacentNodes: nodeId is nil")
		return {}
	end

	local node = Node.GetNodeByID(nodeId)
	if not node then
		Log:Warn("GetAdjacentNodes: node %d not found", nodeId)
		return {}
	end

	-- Get adjacent nodes with the nodes table
	local neighbors = Node.GetAdjacentNodesSimple(node, G.Navigation.nodes)

	-- Extract node IDs
	local adjacentIds = {}
	for _, neighbor in ipairs(neighbors) do
		if neighbor.node and neighbor.node.id then
			table.insert(adjacentIds, neighbor.node.id)
		end
	end

	return adjacentIds
end

-- ========================================================================
-- PATH QUERIES
-- ========================================================================

-- Get the current path
---@return Node[]|nil
function Navigation.GetCurrentPath()
	return G.Navigation.path
end

-- ========================================================================
-- PATH MANAGEMENT
-- ========================================================================

-- Clear the current path
function Navigation.ClearPath()
	G.Navigation.path = {}
	G.Navigation.currentNodeIndex = 1
	-- Also clear door/center/goal waypoints to avoid stale movement/visuals
	G.Navigation.waypoints = {}
	G.Navigation.currentWaypointIndex = 1
	-- Clear path traversal history used by stuck analysis
	G.Navigation.pathHistory = {}
	-- Reset node skipping state
	NodeSkipper.Reset()
end

-- Set the current path
---@param path Node[]
function Navigation.SetCurrentPath(path)
	if not path then
		Log:Error("Failed to set path, it's nil")
		return
	end
	G.Navigation.path = path
	-- Use weak values to avoid strong retention of node objects (nodes table holds strong refs)
	pcall(setmetatable, G.Navigation.path, { __mode = "v" })
	G.Navigation.currentNodeIndex = 1 -- Start from the first node (start) and work towards goal
	-- Build door-aware waypoint list for precise movement and visuals
	--ProfilerBegin and ProfilerEnd are not available here, so rely on caller's profiling
	Navigation.BuildDoorWaypointsFromPath()
	-- Reset traversal history on new path
	G.Navigation.pathHistory = {}
	-- Reset node skipping state for new path
	local NodeSkipper = require("MedBot.Bot.NodeSkipper")
	NodeSkipper.Reset()
end

-- Remove the current node from the path (we've reached it)
function Navigation.RemoveCurrentNode()
	G.Navigation.currentNodeTicks = 0
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Remove the first node (current node we just reached)
		local reached = table.remove(G.Navigation.path, 1)
		-- Track reached nodes from last to first
		if reached then
			G.Navigation.pathHistory = G.Navigation.pathHistory or {}
			table.insert(G.Navigation.pathHistory, 1, reached)
			-- Bound history size
			if #G.Navigation.pathHistory > 32 then
				table.remove(G.Navigation.pathHistory)
			end
		end
		-- currentNodeIndex stays at 1 since we always target the first node in the remaining path
		G.Navigation.currentNodeIndex = 1
		-- Rebuild door waypoints to reflect new leading edge
		Navigation.BuildDoorWaypointsFromPath()
	end
end

-- Function to reset the current node ticks
function Navigation.ResetTickTimer()
	G.Navigation.currentNodeTicks = 0
end

function Navigation.ResetNodeSkipping()
	NodeSkipper.Reset()
end

-- ========================================================================
-- NODE VALIDATION & CHECKS
-- ========================================================================

-- Check if next node is walkable from current position
function Navigation.CheckNextNodeWalkable(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		Log:Debug(
			"CheckNextNodeWalkable: Invalid node data - currentNode=%s, nextNode=%s",
			tostring(currentNode and currentNode.id),
			tostring(nextNode and nextNode.id)
		)
		return false
	end

	-- Use isNavigable instead of IsWalkable
	local currentArea = Node.GetAreaAtPosition(currentPos)
	if not currentArea then
		Log:Debug("CheckNextNodeWalkable: Could not find current area")
		return false
	end

	local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
	local success, canWalk = pcall(isNavigable.CanSkip, currentPos, nextNode.pos, currentArea, false, allowJump)

	if success and canWalk then
		Log:Debug("Next node %d is walkable from current position", nextNode.id)
		return true
	else
		Log:Debug("Next node %d is not walkable from current position", nextNode.id)
		return false
	end
end

-- Check if next node is closer than current node
function Navigation.CheckNextNodeCloser(currentPos, currentNode, nextNode)
	if not currentNode or not nextNode or not currentNode.pos or not nextNode.pos then
		Log:Debug(
			"CheckNextNodeCloser: Invalid node data - currentNode=%s, nextNode=%s",
			tostring(currentNode and currentNode.id),
			tostring(nextNode and nextNode.id)
		)
		return false
	end

	local distanceToCurrent = Common.Distance2D(currentPos, currentNode.pos)
	local distanceToNext = Common.Distance2D(currentPos, nextNode.pos)

	if distanceToNext < distanceToCurrent then
		Log:Debug("Next node %d is closer (%.2f < %.2f)", nextNode.id, distanceToNext, distanceToCurrent)
		return true
	else
		Log:Debug(
			"Current node %d is closer or equal (%.2f >= %.2f)",
			currentNode.id,
			distanceToCurrent,
			distanceToNext
		)
		return false
	end
end

-- ========================================================================
-- WAYPOINT BUILDING
-- ========================================================================

-- Build waypoints from mixed area/door path
function Navigation.BuildDoorWaypointsFromPath()
	-- reuse existing table to avoid churn
	if not G.Navigation.waypoints then
		G.Navigation.waypoints = {}
	else
		for i = #G.Navigation.waypoints, 1, -1 do
			G.Navigation.waypoints[i] = nil
		end
	end
	G.Navigation.currentWaypointIndex = 1
	local path = G.Navigation.path
	if not path or #path == 0 then
		return
	end

	for i = 1, #path - 1 do
		local currentNode = path[i]
		local nextNode = path[i + 1]

		if currentNode and nextNode and currentNode.pos and nextNode.pos then
			-- Handle different node type transitions
			if currentNode.isDoor and nextNode.isDoor then
				-- Door to Door: move directly to next door position
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = currentNode.id,
					toId = nextNode.id,
					pos = nextNode.pos,
				})
			elseif not currentNode.isDoor and nextNode.isDoor then
				-- Area to Door: move to door position
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = currentNode.id,
					toId = nextNode.id,
					pos = nextNode.pos,
				})
			elseif currentNode.isDoor and not nextNode.isDoor then
				-- Door to Area: first move to door position, then to area center
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = currentNode.id,
					toId = nextNode.id,
					pos = currentNode.pos, -- Move to current door position first
				})
				table.insert(G.Navigation.waypoints, {
					pos = nextNode.pos,
					kind = "center",
					areaId = nextNode.id,
				})
			else
				-- Area to Area: move to next area center
				table.insert(G.Navigation.waypoints, {
					pos = nextNode.pos,
					kind = "center",
					areaId = nextNode.id,
				})
			end
		end
	end

	-- Append final precise goal position if available
	local goalPos = G.Navigation.goalPos
	if goalPos then
		table.insert(G.Navigation.waypoints, { pos = goalPos, kind = "goal" })
	end
end

function Navigation.GetCurrentWaypoint()
	local wpList = G.Navigation.waypoints
	local idx = G.Navigation.currentWaypointIndex or 1
	if wpList and idx and wpList[idx] then
		return wpList[idx]
	end
	return nil
end

function Navigation.AdvanceWaypoint()
	local wpList = G.Navigation.waypoints
	local idx = G.Navigation.currentWaypointIndex or 1
	if not (wpList and wpList[idx]) then
		return
	end
	local current = wpList[idx]

	-- FIXED: Reset timer when reaching ANY waypoint on path, not just center
	-- This ensures node skipping timer resets when reaching any point on the path
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Reset the node timer when we reach any waypoint
		Navigation.ResetTickTimer()
		-- Reset node skipping cooldowns when reaching waypoints
		-- SCRAPPED: Don't reset cooldowns on waypoint reach - let agent-based system run on its own schedule
		-- local NodeSkipper = require("MedBot.Bot.NodeSkipper")
		-- NodeSkipper.ResetWalkabilityCooldown()
		-- If we reached a center of the next area, advance the area path too
		-- if current.kind == "center" then
		-- 	-- path[1] is previous area; popping it moves us into the new area
		-- 	Navigation.RemoveCurrentNode()
		-- end
	end

	G.Navigation.currentWaypointIndex = idx + 1
end

function Navigation.SkipWaypoints(count)
	local wpList = G.Navigation.waypoints
	if not wpList then
		return
	end
	local idx = (G.Navigation.currentWaypointIndex or 1) + (count or 1)
	if idx < 1 then
		idx = 1
	end
	if idx > #wpList + 1 then
		idx = #wpList + 1
	end

	-- FIXED: Reset timer when skipping ANY waypoints on path
	-- This ensures node skipping timer resets when skipping any points on the path
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Reset the node timer when we skip waypoints
		Navigation.ResetTickTimer()
		-- If we skip over a center, reflect area progression
		local current = G.Navigation.waypoints[G.Navigation.currentWaypointIndex or 1]
		if current and current.kind ~= "center" then
			for j = (G.Navigation.currentWaypointIndex or 1), math.min(idx - 1, #wpList) do
				if wpList[j].kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
					Navigation.RemoveCurrentNode()
				end
			end
		end
	end

	G.Navigation.currentWaypointIndex = idx
end

-- Function to convert degrees to radians
local function degreesToRadians(degrees)
	return degrees * math.pi / 180
end

-- Checks for an obstruction between two points using a hull trace.
local function isPathClear(startPos, endPos)
	local traceResult = engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, MASK_PLAYERSOLID_BRUSHONLY)
	return traceResult
end

-- Checks if the ground is stable at a given position.
local function isGroundStable(position)
	local groundTraceResult = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START,
		position + GROUND_TRACE_OFFSET_END,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	return groundTraceResult.fraction < 1
end

-- Function to get the ground normal at a given position
local function getGroundNormal(position)
	local groundTraceResult = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START,
		position + GROUND_TRACE_OFFSET_END,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	return groundTraceResult.plane
end

-- Precomputed up vector and max slope angle in radians
local MAX_SLOPE_ANGLE_RAD = degreesToRadians(MAX_SLOPE_ANGLE)

-- Function to get forward speed by class
function Navigation.GetMaxSpeed(entity)
	return entity:GetPropFloat("m_flMaxspeed")
end

-- Function to compute the move direction
local function ComputeMove(pCmd, a, b)
	local diff = b - a
	if diff:Length() == 0 then
		return Vector3(0, 0, 0)
	end

	local x = diff.x
	local y = diff.y
	local vSilent = Vector3(x, y, 0)

	local ang = vSilent:Angles()
	local cYaw = pCmd:GetViewAngles().yaw
	local yaw = math.rad(ang.y - cYaw)
	local move = Vector3(math.cos(yaw), -math.sin(yaw), 0)

	local maxSpeed = Navigation.GetMaxSpeed(G.pLocal.entity) + 1
	return move * maxSpeed
end

-- Function to implement fast stop
local function FastStop(pCmd, pLocal)
	local velocity = pLocal:GetVelocity()
	velocity.z = 0
	local speed = velocity:Length2D()

	if speed < 1 then
		pCmd:SetForwardMove(0)
		pCmd:SetSideMove(0)
		return
	end

	local accel = 5.5
	local maxSpeed = Navigation.GetMaxSpeed(G.pLocal.entity)
	local playerSurfaceFriction = 1.0
	local max_accelspeed = accel * (1 / TICK_RATE) * maxSpeed * playerSurfaceFriction

	local wishspeed
	if speed - max_accelspeed <= -1 then
		wishspeed = max_accelspeed / (speed / (accel * (1 / TICK_RATE)))
	else
		wishspeed = max_accelspeed
	end

	local ndir = (velocity * -1):Angles()
	ndir.y = pCmd:GetViewAngles().y - ndir.y
	ndir = ndir:ToVector()

	pCmd:SetForwardMove(ndir.x * wishspeed)
	pCmd:SetSideMove(ndir.y * wishspeed)
end

---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetClosestNode(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetClosestNode")
		return nil
	end
	local n = Node.GetClosestNode(pos)
	if not n then
		return nil
	end
	return n
end

-- Get area at position using multi-point distance check (more precise than GetClosestNode)
---@param pos Vector3|{ x:number, y:number, z:number }
---@return Node|nil
function Navigation.GetAreaAtPosition(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetAreaAtPosition")
		return nil
	end
	local n = Node.GetAreaAtPosition(pos)
	if not n then
		return nil
	end
	return n
end

-- Main pathfinding function - FIXED TO USE DUAL A* SYSTEM
---@param startNode Node
---@param goalNode Node
function Navigation.FindPath(startNode, goalNode)
	if not startNode or not startNode.pos then
		Log:Error("Navigation.FindPath: invalid start node")
		return Navigation
	end
	if not goalNode or not goalNode.pos then
		Log:Error("Navigation.FindPath: invalid goal node")
		return Navigation
	end

	local horizontalDistance = math.abs(goalNode.pos.x - startNode.pos.x) + math.abs(goalNode.pos.y - startNode.pos.y)
	local verticalDistance = math.abs(goalNode.pos.z - startNode.pos.z)

	-- Try A* pathfinding as primary algorithm (more reliable than D*)
	local success, path = pcall(AStar.NormalPath, startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodesSimple)

	if not success then
		Log:Error("A* pathfinding crashed: %s", tostring(path))
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false

		-- Add circuit breaker penalty for this failed connection
		if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
			G.CircuitBreaker.addConnectionFailure(startNode, goalNode)
		end
		return Navigation
	end

	G.Navigation.path = path

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Error("Failed to find path from %d to %d!", startNode.id, goalNode.id)
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false

		-- Add circuit breaker penalty for this failed connection
		if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
			G.CircuitBreaker.addConnectionFailure(startNode, goalNode)
		end
	else
		Log:Info("Path found from %d to %d with %d nodes", startNode.id, goalNode.id, #G.Navigation.path)
		Navigation.pathFound = true
		Navigation.pathFailed = false
		pcall(setmetatable, G.Navigation.path, { __mode = "v" })
		-- Reset node skipping agents for new path
		G.Navigation.skipAgents = nil
		-- Refresh waypoints to reflect current door usage
		Navigation.BuildDoorWaypointsFromPath()
		-- Apply PathOptimizer for menu-controlled optimization
		-- REMOVED: All path optimization now handled by NodeSkipper.CheckContinuousSkip
		-- Reset traversed-node history for new path
		G.Navigation.pathHistory = {}
	end

	return Navigation
end

return Navigation

end)
__bundle_register("MedBot.Algorithms.A-Star", function(require, _LOADED, __bundle_register, __bundle_modules)
-- A* Pathfinding Algorithm Implementation
-- Uses a priority queue (heap) for efficient node exploration
-- Prefers paths through door nodes when distances are similar

local Heap = require("MedBot.Algorithms.Heap")
local Common = require("MedBot.Core.Common")
local Log = Common.Log.new("AStar")

-- Memory Pooling System for GC Optimization
local tablePool = {}
local poolSize = 0
local maxPoolSize = 1000

local function getPooledTable()
	local t = table.remove(tablePool)
	if t then
		poolSize = poolSize - 1
		return t
	end
	return {}
end

local function releaseTable(t)
	if not t then
		return
	end

	-- Clear the table
	for k in pairs(t) do
		t[k] = nil
	end

	-- Add to pool if not full
	if poolSize < maxPoolSize then
		table.insert(tablePool, t)
		poolSize = poolSize + 1
	end
end

-- Batch release for efficiency
local function releaseTables(...)
	for i = 1, select("#", ...) do
		releaseTable(select(i, ...))
	end
end

-- Type definitions for A* pathfinding

---@class Vector3
local function heuristicCost(nodeA, nodeB)
	-- Euclidean distance heuristic
	local dx = nodeA.pos.x - nodeB.pos.x
	local dy = nodeA.pos.y - nodeB.pos.y
	local dz = nodeA.pos.z - nodeB.pos.z
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	return dist
end

----------------------------------------------------------------
-- Path Reconstruction (O(n) instead of O(n²))
----------------------------------------------------------------
---@param cameFrom table<Node, {node:Node}>
---@param startNode Node
---@param goalNode Node
---@return Node[]|nil
local function reconstructPath(cameFrom, startNode, goalNode)
	local path = {}
	local current = goalNode

	-- Build reversed path (sequential memory writes)
	while current and current ~= startNode do
		path[#path + 1] = current
		local cf = cameFrom[current]
		if cf and cf.node then
			current = cf.node
		else
			Log:Error("A* reconstructPath failed: missing cameFrom for node " .. (current.id or "unknown"))
			return nil
		end
	end

	if not current or current ~= startNode then
		return nil
	end

	path[#path + 1] = startNode

	-- Reverse in place (O(n) total)
	local i, j = 1, #path
	while i < j do
		path[i], path[j] = path[j], path[i]
		i = i + 1
		j = j - 1
	end

	return path
end

----------------------------------------------------------------
-- Path Smoothing: Remove unnecessary waypoints
----------------------------------------------------------------
local function smoothPath(rawPath)
	if not rawPath or #rawPath < 3 then
		return rawPath
	end

	local smoothed = { rawPath[1] } -- Always keep start
	local i = 2

	while i <= #rawPath do
		local curr = rawPath[i]
		local lastKept = smoothed[#smoothed]

		-- Look ahead to see if we can skip waypoints
		local canSkip = true
		for j = i + 1, #rawPath do
			local future = rawPath[j]

			-- Check if the direct path is significantly shorter
			local directDist = (lastKept.pos - future.pos):Length()
			local waypointDist = 0

			-- Calculate total distance through waypoints
			for k = i, j - 1 do
				waypointDist = waypointDist + (rawPath[k].pos - rawPath[k + 1].pos):Length()
			end

			-- If direct path is significantly shorter, we can skip waypoints
			if directDist < waypointDist * 0.8 then
				-- Check for obstacles (simplified)
				local hasObstacle = false
				for k = i, j - 1 do
					if rawPath[k].isDoor then
						hasObstacle = true
						break
					end
				end

				if not hasObstacle then
					i = j - 1 -- Skip to this future waypoint
					canSkip = false
					break
				end
			end
		end

		if canSkip then
			-- Add current waypoint to smoothed path
			table.insert(smoothed, curr)
		end
		i = i + 1
	end

	-- Always keep the goal
	if #smoothed > 0 and smoothed[#smoothed] ~= rawPath[#rawPath] then
		table.insert(smoothed, rawPath[#rawPath])
	end

	Log:Debug("Path smoothed: " .. #rawPath .. " -> " .. #smoothed .. " waypoints")
	return smoothed
end

local function reconstructAndSmoothPath(cameFrom, startNode, goalNode)
	local rawPath = reconstructPath(cameFrom, startNode, goalNode)
	if not rawPath then
		return nil
	end
	return smoothPath(rawPath)
end

-- A* Module Table
local AStar = {}

---Find the shortest path between two nodes using A* algorithm
---@param startNode Node Starting node
---@param goalNode Node Target node
---@param nodes table<integer, Node> Lookup table of all nodes by ID
---@param adjacentFun fun(node: Node, nodes: table): NeighborDataArray Function to get adjacent nodes
---@return Node[]|nil path Array of nodes representing the path, or nil if no path exists
function AStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	if not (startNode and goalNode and startNode.id and goalNode.id) then
		return nil
	end

	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)

	local openSetLookup = getPooledTable()
	local closedSet = getPooledTable()
	local gScore = getPooledTable()
	local fScore = getPooledTable()
	local cameFrom = getPooledTable()

	gScore[startNode] = 0
	fScore[startNode] = heuristicCost(startNode, goalNode)

	openSet:push({ node = startNode, fScore = fScore[startNode] })
	openSetLookup[startNode] = true

	while not openSet:empty() do
		local currentEntry = openSet:pop()
		local current = currentEntry.node
		openSetLookup[current] = nil

		if closedSet[current] then
			goto continue
		end

		if current == goalNode then
			local path = reconstructAndSmoothPath(cameFrom, startNode, current)
			releaseTables(openSetLookup, closedSet, gScore, fScore, cameFrom)
			return path
		end

		closedSet[current] = true

		-- Direct call, no pcall overhead
		local neighbors = adjacentFun(current, nodes)
		for i = 1, #neighbors do
			local neighborData = neighbors[i]
			local nextNode = neighborData.node
			if closedSet[nextNode] then
				goto continueNeighbor
			end

			local connectionCost = neighborData.cost or (current.pos - nextNode.pos):Length()

			local tentativeG = gScore[current] + connectionCost
			if not gScore[nextNode] or tentativeG < gScore[nextNode] then
				cameFrom[nextNode] = { node = current }
				gScore[nextNode] = tentativeG
				fScore[nextNode] = tentativeG + heuristicCost(nextNode, goalNode)

				if not openSetLookup[nextNode] then
					openSet:push({ node = nextNode, fScore = fScore[nextNode] })
					openSetLookup[nextNode] = true
				else
					-- Duplicate push instead of decrease-key hack
					openSet:push({ node = nextNode, fScore = fScore[nextNode] })
				end
			end

			::continueNeighbor::
		end

		::continue::
	end

	releaseTables(openSetLookup, closedSet, gScore, fScore, cameFrom)
	return nil
end

return AStar

end)
__bundle_register("MedBot.Algorithms.Heap", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Enhanced Heap implementation in Lua.
    Modifications made for robustness and preventing memory leaks.
    Credits: github.com/GlorifiedPig/Luafinding
]]

local Heap = {}
Heap.__index = Heap

-- Constructor for the heap.
-- @param compare? Function for comparison, defining the heap property. Defaults to a min-heap.
function Heap.new(compare)
	return setmetatable({
		_data = {},
		_size = 0,
		Compare = compare or function(a, b)
			return a < b
		end,
	}, Heap)
end

-- Helper function to maintain the heap property while inserting an element.
local function sortUp(heap, index)
	while index > 1 do
		local parentIndex = math.floor(index / 2)
		if heap.Compare(heap._data[index], heap._data[parentIndex]) then
			heap._data[index], heap._data[parentIndex] = heap._data[parentIndex], heap._data[index]
			index = parentIndex
		else
			break
		end
	end
end

-- Helper function to maintain the heap property after removing the root element.
local function sortDown(heap, index)
	while true do
		local leftIndex, rightIndex = 2 * index, 2 * index + 1
		local smallest = index

		if leftIndex <= heap._size and heap.Compare(heap._data[leftIndex], heap._data[smallest]) then
			smallest = leftIndex
		end
		if rightIndex <= heap._size and heap.Compare(heap._data[rightIndex], heap._data[smallest]) then
			smallest = rightIndex
		end

		if smallest ~= index then
			heap._data[index], heap._data[smallest] = heap._data[smallest], heap._data[index]
			index = smallest
		else
			break
		end
	end
end

-- Checks if the heap is empty.
function Heap:empty()
	return self._size == 0
end

-- Clears the heap, allowing Lua's garbage collector to reclaim memory.
function Heap:clear()
	for i = 1, self._size do
		self._data[i] = nil
	end
	self._size = 0
end

-- Adds an item to the heap.
-- @param item The item to be added.
function Heap:push(item)
	self._size = self._size + 1
	self._data[self._size] = item
	sortUp(self, self._size)
end

-- Returns the root element of the heap without removing it.
function Heap:peek()
	if self._size == 0 then
		return nil
	end
	return self._data[1]
end

-- Removes and returns the root element of the heap.
function Heap:pop()
	if self._size == 0 then
		return nil
	end
	local root = self._data[1]
	self._data[1] = self._data[self._size]
	self._data[self._size] = nil -- Clear the reference to the removed item
	self._size = self._size - 1
	if self._size > 0 then
		sortDown(self, 1)
	end
	return root
end

return Heap

end)
__bundle_register("MedBot.Bot.CircuitBreaker", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
Circuit Breaker - Prevents infinite loops on problematic connections
Tracks connection failures and temporarily blocks connections that fail repeatedly
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
-- local Node = require("MedBot.Navigation.Node")  -- Temporarily disabled for bundle compatibility

local CircuitBreaker = {}
local Log = Common.Log.new("CircuitBreaker")

-- Circuit breaker state
local state = {
	failures = {}, -- [connectionKey] = { count, lastFailTime, isBlocked }
	maxFailures = 2, -- Max failures before blocking connection temporarily
	blockDuration = 300, -- Ticks to block connection (5 seconds)
	cleanupInterval = 1800, -- Clean up old entries every 30 seconds
	lastCleanup = 0,
}

-- Add a connection failure to the circuit breaker
function CircuitBreaker.addFailure(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	local connectionKey = nodeA.id .. "->" .. nodeB.id
	local currentTick = globals.TickCount()

	-- Initialize or update failure count
	if not state.failures[connectionKey] then
		state.failures[connectionKey] = { count = 0, lastFailTime = 0, isBlocked = false }
	end

	local failure = state.failures[connectionKey]
	failure.count = failure.count + 1
	failure.lastFailTime = currentTick

	-- Each failure adds MORE penalty (makes path progressively more expensive)
	local additionalPenalty = 100 -- Add 100 units per failure
	-- Node.AddFailurePenalty(nodeA, nodeB, additionalPenalty)  -- Temporarily disabled for bundle compatibility

	Log:Debug(
		"Connection %s failure #%d - added %d penalty (total accumulating)",
		connectionKey,
		failure.count,
		additionalPenalty
	)

	-- Block connection if too many failures
	if failure.count >= state.maxFailures then
		failure.isBlocked = true
		-- Add a big penalty to ensure A* avoids this completely
		local blockingPenalty = 500
		-- Node.AddFailurePenalty(nodeA, nodeB, blockingPenalty)  -- Temporarily disabled for bundle compatibility

		Log:Warn(
			"Connection %s BLOCKED after %d failures (added final %d penalty)",
			connectionKey,
			failure.count,
			blockingPenalty
		)
		return true
	end

	return false
end

-- Check if a connection is blocked by circuit breaker
function CircuitBreaker.isBlocked(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	local connectionKey = nodeA.id .. "->" .. nodeB.id
	local failure = state.failures[connectionKey]

	if not failure or not failure.isBlocked then
		return false
	end

	local currentTick = globals.TickCount()
	-- Unblock if enough time has passed (penalties remain but connection becomes usable)
	if currentTick - failure.lastFailTime > state.blockDuration then
		failure.isBlocked = false
		failure.count = 0 -- Reset failure count (penalties stay, giving A* a chance to reconsider)

		Log:Info(
			"Connection %s UNBLOCKED after timeout (accumulated penalties remain as lesson learned)",
			connectionKey
		)
		return false
	end

	return true
end

-- Clean up old circuit breaker entries
function CircuitBreaker.cleanup()
	local currentTick = globals.TickCount()
	if currentTick - state.lastCleanup < state.cleanupInterval then
		return
	end

	state.lastCleanup = currentTick
	local cleaned = 0

	for connectionKey, failure in pairs(state.failures) do
		-- Clean up old, unblocked entries
		if not failure.isBlocked and (currentTick - failure.lastFailTime) > state.blockDuration * 2 then
			state.failures[connectionKey] = nil
			cleaned = cleaned + 1
		end
	end

	if cleaned > 0 then
		Log:Debug("Circuit breaker cleaned up %d old entries", cleaned)
	end
end

-- Get circuit breaker status for debugging
function CircuitBreaker.getStatus()
	local currentTick = globals.TickCount()
	local blockedCount = 0
	local totalFailures = 0

	for connectionKey, failure in pairs(state.failures) do
		totalFailures = totalFailures + failure.count
		if failure.isBlocked then
			blockedCount = blockedCount + 1
		end
	end

	return {
		connections = state.failures,
		blockedCount = blockedCount,
		totalFailures = totalFailures,
		settings = {
			maxFailures = state.maxFailures,
			blockDuration = state.blockDuration,
		},
	}
end

-- Clear all circuit breaker data
function CircuitBreaker.clear()
	state.failures = {}
	Log:Info("Circuit breaker cleared - all connections reset")
end

-- Manually block/unblock connections
function CircuitBreaker.manualBlock(nodeA, nodeB)
	local connectionKey = tostring(nodeA) .. "->" .. tostring(nodeB)
	state.failures[connectionKey] = {
		count = state.maxFailures,
		lastFailTime = globals.TickCount(),
		isBlocked = true,
	}
	Log:Info("Manually blocked connection %s", connectionKey)
end

function CircuitBreaker.manualUnblock(nodeA, nodeB)
	local connectionKey = tostring(nodeA) .. "->" .. tostring(nodeB)
	if state.failures[connectionKey] then
		state.failures[connectionKey].isBlocked = false
		state.failures[connectionKey].count = 0
		Log:Info("Manually unblocked connection %s", connectionKey)
	end
end

return CircuitBreaker

end)
__bundle_register("MedBot.Bot.StateHandler", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  StateHandler.lua  ·  Game state management and transitions
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local Node = require("MedBot.Navigation.Node")
local WorkManager = require("MedBot.WorkManager")
local GoalFinder = require("MedBot.Bot.GoalFinder")
local CircuitBreaker = require("MedBot.Bot.CircuitBreaker")
local isNavigable = require("MedBot.Navigation.isWalkable.isNavigable")
local SmartJump = require("MedBot.Bot.SmartJump")
local MovementDecisions = require("MedBot.Bot.MovementDecisions")

local StateHandler = {}
local Log = Common.Log.new("StateHandler")

-- Log:Debug now automatically respects G.Menu.Main.Debug, no wrapper needed

function StateHandler.handleUserInput(userCmd)
	if userCmd:GetForwardMove() ~= 0 or userCmd:GetSideMove() ~= 0 then
		G.Navigation.currentNodeTicks = 0
		G.currentState = G.States.IDLE
		G.wasManualWalking = true
		G.BotIsMoving = false
		-- Set timestamp when user last moved to prevent immediate pathfinding
		G.lastManualMovementTick = globals.TickCount()
		return true
	end
	return false
end

function StateHandler.handleIdleState()
	G.BotIsMoving = false

	-- Prevent pathfinding spam after manual movement (66 tick cooldown = 1 second)
	local currentTick = globals.TickCount()
	if G.lastManualMovementTick and (currentTick - G.lastManualMovementTick) < 66 then
		return -- Still in cooldown after manual movement
	end

	-- Ensure navigation is ready before any goal work
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, staying in IDLE state")
		return
	end

	-- Use WorkManager's simple cooldown pattern instead of complex priority system
	if not WorkManager.attemptWork(5, "goal_search") then
		return -- Still on cooldown
	end

	-- Check for immediate goals
	local goalNode, goalPos = GoalFinder.findGoal("Objective")
	if goalNode and goalPos then
		local distance = (G.pLocal.Origin - goalPos):Length()

		-- Only use direct-walk shortcut outside CTF and for short hops
		local mapName = engine.GetMapName():lower()
		local allowDirectWalk = not mapName:find("ctf_") and distance > 25 and distance <= 300
		if allowDirectWalk then
			local currentArea = Navigation.GetAreaAtPosition(G.pLocal.Origin)
			if currentArea then
				local allowJump = G.Menu.Navigation.WalkableMode == "Aggressive"
				local success, canWalk =
					pcall(isNavigable.CanSkip, G.pLocal.Origin, goalPos, currentArea, false, allowJump)
				if success and canWalk then
					Log:Info("Direct-walk (short hop), moving immediately (dist: %.1f)", distance)
					G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
					G.Navigation.goalPos = goalPos
					G.Navigation.goalNodeId = goalNode.id
					G.currentState = G.States.MOVING
					G.lastPathfindingTick = globals.TickCount()
					return
				end
			end
		end

		-- Check if goal has changed significantly from current path
		if G.Navigation.goalPos then
			local goalChanged = (G.Navigation.goalPos - goalPos):Length() > 150
			if goalChanged then
				Log:Info("Goal changed significantly, forcing immediate repath (new distance: %.1f)", distance)
				G.lastPathfindingTick = 0 -- Force repath immediately
			end
		end
	end

	-- Check if path was recently modified by node skipper (prevent immediate overwrite)
	local currentTick = globals.TickCount()
	if G.Navigation.lastSkipTick and (currentTick - G.Navigation.lastSkipTick) < 10 then
		Log:Debug("Path was recently skipped, not overwriting")
		return
	end

	-- Prevent pathfinding spam by limiting frequency
	G.lastPathfindingTick = G.lastPathfindingTick or 0
	if currentTick - G.lastPathfindingTick < 33 then
		return
	end

	-- (nodes were already checked above)

	local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
	if not startNode then
		Log:Warn("Could not find start node")
		return
	end

	if not (goalNode and goalPos) then
		-- Throttle warn to avoid log spam
		G.lastNoGoalWarnTick = G.lastNoGoalWarnTick or 0
		if currentTick - G.lastNoGoalWarnTick > 60 then
			Log:Warn("Could not find goal node")
			G.lastNoGoalWarnTick = currentTick
		end
		return
	end

	G.Navigation.goalPos = goalPos
	G.Navigation.goalNodeId = goalNode and goalNode.id or nil

	-- Check if we're on same node OR neighbor node for smooth following
	local isNeighbor = false
	if startNode.id ~= goalNode.id and startNode.c then
		-- Check if goal node is a direct neighbor (connected)
		for _, dir in pairs(startNode.c) do
			if dir.connections then
				for _, conn in ipairs(dir.connections) do
					if conn.targetId == goalNode.id then
						isNeighbor = true
						break
					end
				end
			end
			if isNeighbor then
				break
			end
		end
	end

	-- Avoid pathfinding if we're at goal node or neighboring area
	if startNode.id == goalNode.id or isNeighbor then
		if goalPos then
			-- Check distance to see if we're close enough
			local dist = (G.pLocal.Origin - goalPos):Length()
			local stopRadius = G.Menu.Navigation.StopDistance or 50
			G.Navigation.followingStopRadius = stopRadius

			if dist <= stopRadius then
				-- Within stop radius - enter FOLLOWING state and just track position
				-- DON'T set lastPathfindingTick - this isn't pathfinding, just direct movement
				G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
				G.currentState = G.States.FOLLOWING
				G.Navigation.followingDistance = dist
				Log:Debug(
					"Within stop radius (%.0f/%.0f) - entering FOLLOWING state %s",
					dist,
					stopRadius,
					isNeighbor and "(neighbor)" or "(same node)"
				)
			else
				-- Too far - move closer (still direct movement, not pathfinding)
				G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
				G.currentState = G.States.MOVING
				G.Navigation.followingStopRadius = nil
				Log:Info(
					"Moving to goal position (%.0f, %.0f, %.0f) from node %d (dist=%.0f) %s",
					goalPos.x,
					goalPos.y,
					goalPos.z,
					startNode.id,
					dist,
					isNeighbor and "[neighbor]" or ""
				)
			end
		else
			Log:Debug("No goal position available, staying in IDLE")
			G.lastPathfindingTick = currentTick
			G.Navigation.followingStopRadius = nil
		end
		return
	end

	Log:Info("Generating new path from node %d to node %d", startNode.id, goalNode.id)
	WorkManager.addWork(Navigation.FindPath, { startNode, goalNode }, 33, "Pathfinding")
	G.currentState = G.States.PATHFINDING
	G.lastPathfindingTick = currentTick
end

function StateHandler.handlePathfindingState()
	if Navigation.pathFound then
		G.currentState = G.States.MOVING
		Navigation.pathFound = false
	elseif Navigation.pathFailed then
		Log:Warn("Pathfinding failed")
		G.currentState = G.States.IDLE
		Navigation.pathFailed = false
	else
		-- If no work in progress, start pathfinding
		local pathfindingWork = WorkManager.works["Pathfinding"]
		if not pathfindingWork or pathfindingWork.wasExecuted then
			local goalPos = G.Navigation.goalPos
			local goalNodeId = G.Navigation.goalNodeId

			if goalPos and goalNodeId then
				local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
				local goalNode = G.Navigation.nodes and G.Navigation.nodes[goalNodeId]

				if startNode and goalNode and startNode.id ~= goalNode.id then
					local currentTick = globals.TickCount()
					if not G.lastRepathTick then
						G.lastRepathTick = 0
					end

					if currentTick - G.lastRepathTick > 30 then
						Log:Info("Repathing from stuck state: node %d to node %d", startNode.id, goalNode.id)
						WorkManager.addWork(Navigation.FindPath, { startNode, goalNode }, 33, "Pathfinding")
						G.lastRepathTick = currentTick
					end
				else
					Log:Debug("Cannot repath - invalid start/goal nodes, returning to IDLE")
					G.currentState = G.States.IDLE
				end
			else
				Log:Debug("No existing goal for repath, returning to IDLE")
				G.currentState = G.States.IDLE
			end
		end
	end
end

-- Simplified unstuck logic - guarantee bot never gets stuck
-- Only checks velocity/timeout when bot is walking autonomously
function StateHandler.handleStuckState(userCmd)
	local currentTick = globals.TickCount()

	-- Velocity/timeout checks ONLY when bot is walking autonomously
	if G.Menu.Main.EnableWalking then
		-- Check velocity for stuck detection
		local pLocal = G.pLocal.entity
		if pLocal then
			local velocity = pLocal:EstimateAbsVelocity()
			local speed2D = 0
			if velocity and type(velocity.x) == "number" and type(velocity.y) == "number" then
				speed2D = math.sqrt(velocity.x ^ 2 + velocity.y ^ 2)
			end

			-- MAIN TRIGGER: Velocity < 50 = STUCK
			if speed2D < 50 then
				Log:Warn("STUCK DETECTED: velocity " .. tostring(speed2D) .. " < 50 - adding penalties and repathing")

				-- Disable node skipping for 132 ticks (2 seconds) by setting work cooldown
				WorkManager.setWorkCooldown("node_skipping", 132)
				Log:Debug("Node skipping disabled for 132 ticks due to stuck")

				-- Add cost penalties to current connection (node->node, node->door, door->door)
				StateHandler.addStuckPenalties()

				-- ALWAYS repath when stuck (simplified approach)
				StateHandler.forceRepath("Velocity too low")
				return
			end
		end
	end

	-- Reset stuck detection if moving normally
	G.Navigation.unwalkableCount = 0
	G.Navigation.stuckStartTick = nil

	-- Reset node skipping cooldown to 1 tick when unstuck
	WorkManager.setWorkCooldown("node_skipping", 1)
end

-- Add cost penalties to connections when stuck
function StateHandler.addStuckPenalties()
	local path = G.Navigation.path
	if not path or #path < 2 then
		return
	end

	-- Add penalty to current connection (between any two path elements)
	local currentElement = path[1]
	local nextElement = path[2]

	if currentElement and nextElement then
		-- Handle different connection types: node->node, node->door, door->door
		local fromId = currentElement.id or currentElement.fromId
		local toId = nextElement.id or nextElement.toId or nextElement.areaId

		if fromId and toId then
			-- Find and penalize the connection
			local fromNode = G.Navigation.nodes and G.Navigation.nodes[fromId]
			local toNode = G.Navigation.nodes and G.Navigation.nodes[toId]

			if fromNode and toNode then
				local connection = Node.GetConnectionEntry(fromNode, toNode)
				if connection then
					connection.cost = (connection.cost or 1) + 50
					Log:Info(
						"Added 50 cost penalty to connection "
							.. tostring(fromId)
							.. " -> "
							.. tostring(toId)
							.. " (stuck penalty)"
					)
				end
			end
		end
	end
end

-- Force immediate repath (with cooldown to prevent spam)
function StateHandler.forceRepath(reason)
	-- Prevent repath spam with 33 tick cooldown
	if not WorkManager.attemptWork(33, "force_repath_cooldown") then
		return -- Still on cooldown, ignore repath request
	end

	Log:Warn("Force repath triggered: %s", reason)

	-- Clear stuck state
	G.Navigation.stuckStartTick = nil
	G.Navigation.unwalkableCount = 0
	Navigation.ResetTickTimer()

	-- Force immediate repath
	G.currentState = G.States.PATHFINDING
	G.lastPathfindingTick = 0

	-- Reset work manager to allow immediate repath
	WorkManager.clearWork("Pathfinding")
end

-- Handle FOLLOWING state - direct following of dynamic targets on same node
function StateHandler.handleFollowingState(userCmd)
	local currentTick = globals.TickCount()

	-- Throttle updates to every 5 ticks (~83ms) for responsive tracking
	if not G.Navigation.lastFollowUpdateTick then
		G.Navigation.lastFollowUpdateTick = 0
	end

	if currentTick - G.Navigation.lastFollowUpdateTick < 5 then
		-- Use MovementDecisions to continue moving to current target
		if G.Navigation.path and #G.Navigation.path > 0 then
			MovementDecisions.handleMovingState(userCmd)
		end
		return
	end

	G.Navigation.lastFollowUpdateTick = currentTick

	-- Re-check goal position (payload/player may have moved)
	local goalNode, goalPos = GoalFinder.findGoal("Objective")

	if not goalNode or not goalPos then
		-- Lost target - return to IDLE (clear pathfinding throttle for immediate repath)
		Log:Debug("Lost target in FOLLOWING state, returning to IDLE")
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		G.Navigation.followingStopRadius = nil
		return
	end

	-- Check if still on same node
	local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
	if not startNode or startNode.id ~= goalNode.id then
		-- No longer on same node - return to IDLE to trigger pathfinding (clear throttle)
		Log:Debug("Left target node in FOLLOWING state, returning to IDLE")
		G.currentState = G.States.IDLE
		G.lastPathfindingTick = 0
		G.Navigation.followingStopRadius = nil
		return
	end

	-- Check distance change
	local currentDist = (G.pLocal.Origin - goalPos):Length()
	local stopRadius = G.Menu.Navigation.StopDistance or 50
	local distChange = math.abs(currentDist - (G.Navigation.followingDistance or currentDist))

	-- Only update if distance changed significantly (>30 units)
	if distChange > 10 then
		G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
		G.Navigation.followingDistance = currentDist
		G.Navigation.goalPos = goalPos
		Log:Debug("Target moved %.0f units, updating position (dist=%.0f)", distChange, currentDist)

		-- If moved outside stop radius, switch to MOVING
		if currentDist > stopRadius then
			Log:Debug("Target moved outside stop radius, switching to MOVING")
			G.currentState = G.States.MOVING
			G.Navigation.followingStopRadius = nil
		end
	end

	-- Continue moving to target
	if G.Navigation.path and #G.Navigation.path > 0 then
		MovementDecisions.handleMovingState(userCmd)
	end
end

return StateHandler

end)
__bundle_register("MedBot.Bot.GoalFinder", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
Goal Finder - Finds navigation goals based on current tasks
Handles payload, CTF, health pack, and teammate following goals
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")

local GoalFinder = {}
local Log = Common.Log.new("GoalFinder")

local function findPayloadGoal()
	-- Cache payload entities for 90 ticks (1.5 seconds) to avoid expensive entity searches
	local currentTick = globals.TickCount()
	if not G.World.payloadCacheTime or (currentTick - G.World.payloadCacheTime) > 90 then
		G.World.payloads = entities.FindByClass("CObjectCartDispenser")
		G.World.payloadCacheTime = currentTick
	end

	local pLocal = G.pLocal.entity
	local myTeam = pLocal:GetTeamNumber()
	local ownCart = nil
	local enemyCart = nil

	-- First pass: find own cart and enemy cart
	for _, entity in pairs(G.World.payloads or {}) do
		if entity:IsValid() then
			local cartTeam = entity:GetTeamNumber()
			if cartTeam == myTeam then
				ownCart = entity
			else
				enemyCart = entity
			end
		end
	end

	-- If we found our own cart, use it
	if ownCart then
		local pos = ownCart:GetAbsOrigin()
		-- Offset down by 80 units to get ground-level position
		pos = Vector3(pos.x, pos.y, pos.z - 80)
		return Navigation.GetAreaAtPosition(pos), pos
	end

	-- If we're on defense (no own cart found) and enemy cart exists, defend enemy cart
	if enemyCart then
		local pos = enemyCart:GetAbsOrigin()
		-- Offset down by 80 units to get ground-level position
		pos = Vector3(pos.x, pos.y, pos.z - 80)
		Log:Info("Own cart not found, defending enemy cart at position")
		return Navigation.GetAreaAtPosition(pos), pos
	end
end

local function findFlagGoal()
	local pLocal = G.pLocal.entity
	local myItem = pLocal:GetPropInt("m_hItem")

	-- Cache flag entities for 90 ticks (1.5 seconds) to avoid expensive entity searches
	local currentTick = globals.TickCount()
	if not G.World.flagCacheTime or (currentTick - G.World.flagCacheTime) > 90 then
		G.World.flags = entities.FindByClass("CCaptureFlag")
		G.World.flagCacheTime = currentTick
	end

	-- Throttle debug logging to avoid spam (only log every 60 ticks)
	if not G.lastFlagLogTick then
		G.lastFlagLogTick = 0
	end
	local shouldLog = (currentTick - G.lastFlagLogTick) > 60

	if shouldLog then
		Log:Debug("CTF Flag Detection: myItem=%d, playerTeam=%d", myItem, pLocal:GetTeamNumber())
		G.lastFlagLogTick = currentTick
	end

	local targetFlag = nil
	local targetPos = nil

	for _, entity in pairs(G.World.flags or {}) do
		local flagTeam = entity:GetTeamNumber()
		local myTeam = flagTeam == pLocal:GetTeamNumber()
		local pos = entity:GetAbsOrigin()

		if shouldLog then
			Log:Debug("Flag found: team=%d, isMyTeam=%s, pos=%s", flagTeam, tostring(myTeam), tostring(pos))
		end

		-- If carrying enemy intel (myItem > 0), go to our team's capture point
		-- If not carrying intel (myItem <= 0), go get the enemy intel
		if (myItem > 0 and myTeam) or (myItem <= 0 and not myTeam) then
			targetFlag = entity
			targetPos = pos
			if shouldLog then
				Log:Info(
					"CTF Goal: %s (carrying=%s)",
					myItem > 0 and "Return to base" or "Get enemy intel",
					tostring(myItem > 0)
				)
			end
			break -- Take the first valid target
		end
	end

	if targetFlag and targetPos then
		return Navigation.GetAreaAtPosition(targetPos), targetPos
	end

	if shouldLog then
		Log:Debug("No suitable flag target found - available flags: %d", #G.World.flags)
	end
	return nil
end

local function findHealthGoal()
	local closestDist = math.huge
	local closestNode = nil
	local closestPos = nil
	for _, pos in pairs(G.World.healthPacks) do
		local healthNode = Navigation.GetAreaAtPosition(pos)
		if healthNode then
			local dist = (G.pLocal.Origin - pos):Length()
			if dist < closestDist then
				closestDist = dist
				closestNode = healthNode
				closestPos = pos
			end
		end
	end
	return closestNode, closestPos
end

-- Find and follow the closest teammate using FastPlayers (throttled to avoid lag)
local function findFollowGoal()
	local localWP = Common.FastPlayers.GetLocal()
	if not localWP then
		return nil
	end
	local origin = localWP:GetRawEntity():GetAbsOrigin()
	local closestDist = math.huge
	local closestNode = nil
	local targetPos = nil
	local foundTarget = false

	-- Cache teammate search for 30 ticks (0.5 seconds) to reduce expensive player iteration
	local currentTick = globals.TickCount()
	if not G.World.teammatesCacheTime or (currentTick - G.World.teammatesCacheTime) > 30 then
		G.World.cachedTeammates = Common.FastPlayers.GetTeammates(true)
		G.World.teammatesCacheTime = currentTick
	end

	for _, wp in ipairs(G.World.cachedTeammates or {}) do
		local ent = wp:GetRawEntity()
		if ent and ent:IsValid() and ent:IsAlive() then
			foundTarget = true
			local pos = ent:GetAbsOrigin()
			local dist = (pos - origin):Length()
			if dist < closestDist then
				closestDist = dist
				-- Update our memory of where we last saw this target
				G.Navigation.lastKnownTargetPosition = pos
				closestNode = Navigation.GetAreaAtPosition(pos)
				targetPos = pos
			end
		end
	end

	-- If no alive teammates found, but we have a last known position, use that
	if not foundTarget and G.Navigation.lastKnownTargetPosition then
		Log:Info("No alive teammates found, moving to last known position")
		closestNode = Navigation.GetAreaAtPosition(G.Navigation.lastKnownTargetPosition)
		targetPos = G.Navigation.lastKnownTargetPosition
	end

	-- If the target is very close (same node), add some distance to avoid pathfinding to self
	if closestNode and closestDist < 150 then -- 150 units is quite close
		local startNode = Navigation.GetClosestNode(origin)
		if startNode and closestNode.id == startNode.id then
			Log:Debug("Target too close (same node), expanding search radius")
			-- Look for a node near the target but not the same as our current node
			for _, node in pairs(G.Navigation.nodes or {}) do
				if node.id ~= startNode.id then
					local targetPos = G.Navigation.lastKnownTargetPosition or closestNode.pos
					local nodeToTargetDist = (node.pos - targetPos):Length()
					if nodeToTargetDist < 200 then -- Within 200 units of target
						closestNode = node
						break
					end
				end
			end
		end
	end

	return closestNode, targetPos
end

-- Main function to find goal node based on current task
function GoalFinder.findGoal(currentTask)
	-- Safety check: ensure nodes are loaded before proceeding
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, cannot find goal")
		return nil
	end

	local mapName = engine.GetMapName():lower()

	if currentTask == "Objective" then
		if mapName:find("plr_") or mapName:find("pl_") then
			return findPayloadGoal()
		elseif mapName:find("ctf_") then
			return findFlagGoal()
		else
			-- fallback to following the closest teammate
			return findFollowGoal()
		end
	elseif currentTask == "Health" then
		return findHealthGoal()
	elseif currentTask == "Follow" then
		return findFollowGoal()
	else
		Log:Debug("Unknown task: %s", currentTask)
	end

	-- Fallbacks when no goal was found by specific strategies
	-- 1) Try following a teammate as a generic goal
	local node, pos = findFollowGoal()
	if node and pos then
		return node, pos
	end

	-- 2) Roaming fallback: pick a reasonable nearby node to move towards
	if G.Navigation.nodes and next(G.Navigation.nodes) then
		local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
		if startNode then
			local bestNode = nil
			local bestDist = math.huge
			for _, candidate in pairs(G.Navigation.nodes) do
				if candidate and candidate.id ~= startNode.id and candidate.pos then
					local d = (candidate.pos - G.pLocal.Origin):Length()
					-- Prefer nodes within 300..1200 units to avoid picking ourselves or too far targets
					if d > 300 and d < 1200 and d < bestDist then
						bestDist = d
						bestNode = candidate
					end
				end
			end
			if not bestNode then
				-- If none in preferred band, just pick the closest different node
				for _, candidate in pairs(G.Navigation.nodes) do
					if candidate and candidate.id ~= startNode.id and candidate.pos then
						local d = (candidate.pos - G.pLocal.Origin):Length()
						if d < bestDist then
							bestDist = d
							bestNode = candidate
						end
					end
				end
			end
			if bestNode then
				-- Throttle info log
				local now = globals.TickCount()
				G.lastRoamLogTick = G.lastRoamLogTick or 0
				if now - G.lastRoamLogTick > 60 then
					Log:Info("Using roaming fallback to node %d (dist=%.0f)", bestNode.id, bestDist)
					G.lastRoamLogTick = now
				end
				return bestNode, bestNode.pos
			end
		end
	end

	-- Nothing found
	return nil
end

return GoalFinder

end)
__bundle_register("MedBot.Algorithms.Greedy", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
    Greedy Best-First Search Algorithm
    Fastest possible pathfinding using straight-line heuristic
    Always expands node closest to destination (no cost consideration)
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")

local Greedy = {}

-- Calculate straight-line distance heuristic (Euclidean distance)
local function heuristic(startPos, goalPos)
	local dx = startPos.x - goalPos.x
	local dy = startPos.y - goalPos.y
	local dz = startPos.z - goalPos.z
	return math.abs(dx) + math.abs(dy) + math.abs(dz)
end

-- Main greedy pathfinding function
function Greedy.FindPath(startPos, goalPos, maxIterations)
	maxIterations = maxIterations or 500

	local startNode = Navigation.GetClosestNode(startPos)
	local goalNode = Navigation.GetClosestNode(goalPos)

	if not startNode or not goalNode then
		return {}
	end

	if startNode.id == goalNode.id then
		return { startNode.id }
	end

	-- Priority queue based on distance to goal (min-heap)
	local openSet = {}
	local closedSet = {}
	local cameFrom = {}

	-- Insert start node with its heuristic value
	table.insert(openSet, {
		nodeId = startNode.id,
		priority = heuristic(startPos, goalPos),
	})

	local iterations = 0

	while #openSet > 0 and iterations < maxIterations do
		iterations = iterations + 1

		-- Get node with lowest heuristic value (closest to goal)
		local current = table.remove(openSet, 1)

		-- Skip if already visited
		if closedSet[current.nodeId] then
			goto continue
		end

		closedSet[current.nodeId] = true

		-- Goal reached
		if current.nodeId == goalNode.id then
			-- Reconstruct path
			local path = {}
			local node = goalNode.id

			while node do
				table.insert(path, 1, node)
				node = cameFrom[node]
			end

			return path
		end

		-- Get current node data
		local currentNode = Navigation.GetNode(current.nodeId)
		if not currentNode then
			goto continue
		end

		-- Explore neighbors
		local adjacent = Navigation.GetAdjacentNodes(current.nodeId)
		for _, neighborId in ipairs(adjacent) do
			if not closedSet[neighborId] then
				local neighborNode = Navigation.GetNode(neighborId)
				if neighborNode then
					-- Calculate heuristic for neighbor
					local neighborPos = Vector3(neighborNode.x, neighborNode.y, neighborNode.z)
					local hValue = heuristic(neighborPos, goalPos)

					-- Add to open set
					table.insert(openSet, {
						nodeId = neighborId,
						priority = hValue,
					})

					-- Track parent
					if not cameFrom[neighborId] then
						cameFrom[neighborId] = current.nodeId
					end
				end
			end
		end

		-- Sort open set by priority (lowest first)
		table.sort(openSet, function(a, b)
			return a.priority < b.priority
		end)

		::continue::
	end

	-- No path found within iteration limit
	return {}
end

-- Simple version with even less overhead for very fast pathfinding
function Greedy.FindPathFast(startPos, goalPos, maxNodes)
	maxNodes = maxNodes or 100

	local startNode = Navigation.GetClosestNode(startPos)
	local goalNode = Navigation.GetClosestNode(goalPos)

	if not startNode or not goalNode then
		return {}
	end

	if startNode.id == goalNode.id then
		return { startNode.id }
	end

	local path = { startNode.id }
	local currentId = startNode.id
	local visited = { [currentId] = true }

	for i = 1, maxNodes do
		if currentId == goalNode.id then
			return path
		end

		local adjacent = Navigation.GetAdjacentNodes(currentId)
		local bestNeighbor = nil
		local bestDistance = math.huge

		-- Find neighbor closest to goal
		for _, neighborId in ipairs(adjacent) do
			if not visited[neighborId] then
				local neighborNode = Navigation.GetNode(neighborId)
				if neighborNode then
					local neighborPos = Vector3(neighborNode.x, neighborNode.y, neighborNode.z)
					local distance = heuristic(neighborPos, goalPos)

					if distance < bestDistance then
						bestDistance = distance
						bestNeighbor = neighborId
					end
				end
			end
		end

		if not bestNeighbor then
			break -- Dead end
		end

		table.insert(path, bestNeighbor)
		visited[bestNeighbor] = true
		currentId = bestNeighbor
	end

	return path
end

print("Greedy Best-First Search algorithm loaded")

return Greedy

end)
return __bundle_require("__root")