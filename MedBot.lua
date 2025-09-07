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

--[[ Bot Modules ]]
local StateHandler = require("MedBot.Bot.StateHandler")
local CircuitBreaker = require("MedBot.Bot.CircuitBreaker")
local PathOptimizer = require("MedBot.Bot.PathOptimizer")
local MovementController = require("MedBot.Bot.MovementController")
local CommandHandler = require("MedBot.Bot.CommandHandler")
local HealthLogic = require("MedBot.Bot.HealthLogic")

--[[ Additional Systems ]]
local SmartJump = require("MedBot.Movement.SmartJump")
require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")

--[[ Setup ]]
local Lib = Common.Lib
local Notify, WPlayer = Lib.UI.Notify, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

-- Initialize current state
G.currentState = G.States.IDLE

--[[ Main Bot Logic - Minimal Entry Point ]]
-- Delegates all complex logic to focused modules with single responsibilities

---@param userCmd UserCmd
-- Forward declare to allow use inside onCreateMove
local handleMovingState

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
	if not G.lastCleanupTick then
		G.lastCleanupTick = currentTick
	end
	if currentTick - G.lastCleanupTick > 300 then -- Every 5 seconds
		G.CleanupMemory()
		CircuitBreaker.cleanup()
		G.lastCleanupTick = currentTick
	end

	-- Health logic
	HealthLogic.HandleSelfHealing(pLocal)

	-- State machine delegation
	if G.currentState == G.States.IDLE then
		StateHandler.handleIdleState()
	elseif G.currentState == G.States.PATHFINDING then
		StateHandler.handlePathfindingState()
	elseif G.currentState == G.States.MOVING then
		handleMovingState(userCmd)
	elseif G.currentState == G.States.STUCK then
		StateHandler.handleStuckState(userCmd)
	end

	-- Work management
	WorkManager.processWorks()
end

-- Moving state handler using modular components
function handleMovingState(userCmd)
	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	local currentNode = G.Navigation.path[1]

	-- Throttled debug about current path/node
	G.__lastMoveDebugTick = G.__lastMoveDebugTick or 0
	local now = globals.TickCount()
	if now - G.__lastMoveDebugTick > 15 then -- ~0.25s
		local pathLen = #G.Navigation.path
		local nodeId = currentNode and currentNode.id or -1
		Log:Debug("MOVING: pathLen=%d firstNodeId=%s", pathLen, tostring(nodeId))
		G.__lastMoveDebugTick = now
	end
	if not currentNode then
		Log:Warn("Current node is nil, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	-- Store movement direction for SmartJump
	local LocalOrigin = G.pLocal.Origin
	local direction = currentNode.pos - LocalOrigin
	G.BotMovementDirection = direction:Length() > 0 and (direction / direction:Length()) or Vector3(0, 0, 0)
	G.BotIsMoving = true

	-- Try path optimization first
	if PathOptimizer.optimize(LocalOrigin, G.Navigation.path, G.Navigation.goalPos) then
		-- If optimization changed the path, use the new first node
		currentNode = G.Navigation.path[1] or currentNode
	end

	-- Handle camera rotation
	MovementController.handleCameraRotation(userCmd, currentNode.pos)

	-- Check if we've reached the current node
	local horizontalDist = math.abs(LocalOrigin.x - currentNode.pos.x) + math.abs(LocalOrigin.y - currentNode.pos.y)
	local verticalDist = math.abs(LocalOrigin.z - currentNode.pos.z)

	if (horizontalDist < G.Misc.NodeTouchDistance) and verticalDist <= G.Misc.NodeTouchHeight then
		Log:Debug(
			"Reached node id=%s horiz=%.1f vert=%.1f (touchDist=%d, touchH=%d)",
			tostring(currentNode.id),
			horizontalDist,
			verticalDist,
			G.Misc.NodeTouchDistance,
			G.Misc.NodeTouchHeight
		)
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()

		if #G.Navigation.path == 0 then
			Navigation.ClearPath()
			Log:Info("Reached end of path")
			G.currentState = G.States.IDLE
			G.lastPathfindingTick = 0
		end
		return
	end

	-- Use superior movement controller
	if now - (G.__lastWalkDebugTick or 0) > 15 then
		local distVec = currentNode.pos - LocalOrigin
		Log:Debug(
			"Walking towards node id=%s dx=%.1f dy=%.1f dz=%.1f",
			tostring(currentNode.id),
			distVec.x,
			distVec.y,
			distVec.z
		)
		G.__lastWalkDebugTick = now
	end
	MovementController.walkTo(userCmd, G.pLocal.entity, currentNode.pos)

	-- Increment stuck counter
	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1

	-- Check if stuck
	if G.Navigation.currentNodeTicks > 132 then -- 2 seconds
		G.currentState = G.States.STUCK
	end
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
	if eventName == "game_newmap" then
		Log:Info("New map detected, reloading nav file...")
		Navigation.Setup()
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

-- Register console commands
CommandHandler.register()

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

	if TimMenu.Begin("MedBot Control") then
		-- Tab control
		G.Menu.Tab = TimMenu.TabControl("MedBotTabs", { "Main", "Visuals" }, G.Menu.Tab)
		TimMenu.NextLine()

		if G.Menu.Tab == "Main" then
			-- Bot Control Section
			TimMenu.BeginSector("Bot Control")
			G.Menu.Main.Enable = TimMenu.Checkbox("Enable Bot", G.Menu.Main.Enable)
			TimMenu.NextLine()

			G.Menu.Main.SelfHealTreshold =
				TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
			TimMenu.NextLine()

			G.Menu.Main.LookingAhead = TimMenu.Checkbox("Auto Rotate Camera", G.Menu.Main.LookingAhead or false)
			TimMenu.Tooltip("Enable automatic camera rotation towards target node (disable for manual camera control)")
			TimMenu.NextLine()

			G.Menu.Main.smoothFactor = G.Menu.Main.smoothFactor or 0.1
			G.Menu.Main.smoothFactor = TimMenu.Slider("Smooth Factor", G.Menu.Main.smoothFactor, 0.01, 1, 0.01)
			TimMenu.Tooltip("Camera rotation smoothness (only when Auto Rotate Camera is enabled)")
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Movement & Pathfinding Section
			TimMenu.BeginSector("Movement & Pathfinding")
			G.Menu.Main.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Main.Skip_Nodes)
			TimMenu.Tooltip("Allow skipping nodes when direct path is walkable (handles all optimization)")
			TimMenu.NextLine()

			-- Smart Jump (works independently of MedBot enable state)
			G.Menu.SmartJump = G.Menu.SmartJump or {}
			G.Menu.SmartJump.Enable = TimMenu.Checkbox("Smart Jump", G.Menu.SmartJump.Enable ~= false)
			TimMenu.Tooltip("Enable intelligent jumping over obstacles (works even when MedBot is disabled)")
			TimMenu.NextLine()

			G.Menu.SmartJump.Debug = G.Menu.SmartJump.Debug or false
			G.Menu.SmartJump.Debug = TimMenu.Checkbox("Smart Jump Debug", G.Menu.SmartJump.Debug)
			TimMenu.Tooltip("Print Smart Jump debug logs to console")
			TimMenu.NextLine()

			-- Path optimisation mode for following nodes
			G.Menu.Main.WalkableMode = G.Menu.Main.WalkableMode or "Smooth"
			local walkableModes = { "Smooth", "Aggressive" }
			-- Get current mode as index number
			local currentModeIndex = (G.Menu.Main.WalkableMode == "Aggressive") and 2 or 1
			local previousMode = G.Menu.Main.WalkableMode

			-- TimMenu.Selector expects a number, not a table
			local selectedIndex = TimMenu.Selector("Walkable Mode", currentModeIndex, walkableModes)

			-- Update the mode based on selection
			if selectedIndex == 1 then
				G.Menu.Main.WalkableMode = "Smooth"
			elseif selectedIndex == 2 then
				G.Menu.Main.WalkableMode = "Aggressive"
			end

			-- Auto-recalculate costs if mode changed
			if G.Menu.Main.WalkableMode ~= previousMode then
				-- Node.RecalculateConnectionCosts() -- Temporarily disabled
			end
			TimMenu.Tooltip(
				"Applies to path following only. Aggressive also enables direct skipping when path is walkable"
			)
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Advanced Settings Section
			TimMenu.BeginSector("Advanced Settings")
			G.Menu.Main.CleanupConnections =
				TimMenu.Checkbox("Cleanup Invalid Connections", G.Menu.Main.CleanupConnections or false)
			TimMenu.Tooltip("Clean up navigation connections on map load (DISABLE if causing performance issues)")
			TimMenu.NextLine()

			G.Menu.Main.AllowExpensiveChecks =
				TimMenu.Checkbox("Allow Expensive Walkability Checks", G.Menu.Main.AllowExpensiveChecks or false)
			TimMenu.Tooltip("Enable expensive trace-based walkability validation (rarely needed)")
			TimMenu.NextLine()

			-- Hierarchical pathfinding removed: single-layer areas only

			-- Connection processing status display
			if G.Menu.Main.CleanupConnections then
				-- local status = Node.GetConnectionProcessingStatus() -- Temporarily disabled
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
			G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
			TimMenu.NextLine()

			-- Align naming with visuals: renderRadius is what Visuals.lua reads
			G.Menu.Visuals.renderRadius = G.Menu.Visuals.renderRadius or G.Menu.Visuals.renderDistance or 800
			G.Menu.Visuals.renderRadius = TimMenu.Slider("Render Radius", G.Menu.Visuals.renderRadius, 100, 3000, 100)
			TimMenu.NextLine()

			G.Menu.Visuals.chunkSize = G.Menu.Visuals.chunkSize or 256
			G.Menu.Visuals.chunkSize = TimMenu.Slider("Chunk Size", G.Menu.Visuals.chunkSize, 64, 512, 16)
			TimMenu.NextLine()

			G.Menu.Visuals.renderChunks = G.Menu.Visuals.renderChunks or 3
			G.Menu.Visuals.renderChunks = TimMenu.Slider("Render Chunks", G.Menu.Visuals.renderChunks, 1, 10, 1)
			-- Visuals.MaybeRebuildGrid() -- Temporarily disabled
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Node Display Section
			TimMenu.BeginSector("Display Options")
			-- Basic display options
			local basicOptions = {
				"Show Nodes",
				"Show Node IDs",
				"Show Nav Connections",
				"Show Areas",
				"Show Doors",
				"Show Corner Connections",
			}
			G.Menu.Visuals.basicDisplay = G.Menu.Visuals.basicDisplay or { true, true, true, true, true, false }
			G.Menu.Visuals.basicDisplay = TimMenu.Combo("Basic Display", G.Menu.Visuals.basicDisplay, basicOptions)
			TimMenu.NextLine()

			-- Update individual settings based on combo selection
			G.Menu.Visuals.drawNodes = G.Menu.Visuals.basicDisplay[1]
			G.Menu.Visuals.drawNodeIDs = G.Menu.Visuals.basicDisplay[2]
			G.Menu.Visuals.showConnections = G.Menu.Visuals.basicDisplay[3]
			G.Menu.Visuals.showAreas = G.Menu.Visuals.basicDisplay[4]
			G.Menu.Visuals.showDoors = G.Menu.Visuals.basicDisplay[5]
			G.Menu.Visuals.showCornerConnections = G.Menu.Visuals.basicDisplay[6]
			TimMenu.EndSector()
		end

		TimMenu.End() -- Properly close the menu
	end
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
	NodeTouchDistance = 24,
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
}

-- SmartJump integration
G.ShouldJump = false -- Set by SmartJump module when jump should be performed
G.LastSmartJumpAttempt = 0 -- Track last time SmartJump was attempted
G.LastEmergencyJump = 0 -- Track last emergency jump time
G.ObstacleDetected = false -- Track if obstacle is detected but no jump attempted
G.RequestEmergencyJump = false -- Request emergency jump from stuck detection

-- SmartJump state table
G.SmartJump = {
	SimulationPath = {},
	PredPos = nil,
	HitObstacle = false,
	JumpPeekPos = nil,
	stateStartTime = 0,
	lastState = nil,
}

-- Bot movement tracking (for SmartJump integration)
G.BotIsMoving = false -- Track if bot is actively moving
G.BotMovementDirection = Vector3(0, 0, 0) -- Bot's intended movement direction

-- Memory management and cache tracking
G.Cache = {
	lastCleanup = 0,
	cleanupInterval = 2000, -- Clean up every 2000 ticks (~30 seconds)
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
}

G.currentState = nil
G.prevState = nil -- Track previous bot state
G.wasManualWalking = false -- Track if user manually walked last tick

-- Function to clean up memory and caches
function G.CleanupMemory()
	local currentTick = globals.TickCount()
	if currentTick - G.Cache.lastCleanup < G.Cache.cleanupInterval then
		return -- Too soon to cleanup
	end

	-- Update memory usage statistics
	local memUsage = collectgarbage("count")
	G.Benchmark.MemUsage = memUsage

	-- NOTE: Fine point caches are kept to avoid expensive re-generation
	-- when garbage collection happens.

	-- Hierarchical pathfinding removed
	G.Navigation.hierarchical = nil

	-- Reset stuck timer if it's been set for too long (prevents infinite stuck states)
	if G.Navigation.stuckStartTick and (currentTick - G.Navigation.stuckStartTick) > 1000 then
		print("Reset stuck timer during cleanup (was stuck for >1000 ticks)")
		G.Navigation.stuckStartTick = nil
		G.Navigation.currentNodeTicks = 0
	end

	-- Force garbage collection if memory usage is high
	local memBefore = memUsage
	if memUsage > 1024 * 1024 then -- More than 1GB
		collectgarbage("collect")
		memUsage = collectgarbage("count")
		G.Benchmark.MemUsage = memUsage
		print(string.format("Force GC: %.2f MB -> %.2f MB", memBefore / 1024, memUsage / 1024))
	end

	G.Cache.lastCleanup = currentTick
end

return G

end)
__bundle_register("MedBot.Utils.DefaultConfig", function(require, _LOADED, __bundle_register, __bundle_modules)
local defaultconfig
defaultconfig = {
	Tab = "Main",
	Tabs = {
		Main = true,
		Settings = false,
		Visuals = false,
		Movement = false,
	},

	Main = {
		Enable = true,
		Skip_Nodes = true, --skips nodes if it can go directly to ones closer to target.
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
		LookingAhead = true, -- Enable automatic camera rotation towards target node
		WalkableMode = "Smooth", -- "Smooth" uses 18-unit steps, "Aggressive" allows 72-unit jumps
		CleanupConnections = true, -- Cleanup invalid connections during map load (disable to prevent crashes)
		AllowExpensiveChecks = true, -- Allow expensive walkability checks for proper stair/ramp connections
		-- Hierarchical pathfinding removed
	},
	Visuals = {
		renderRadius = 400, -- Manhattan radius used by visuals culling (x+y+z)
		chunkSize = 256,
		renderChunks = 3,
		EnableVisuals = true,
		memoryUsage = true,
		ignorePathRadius = true, -- When true, path lines ignore render radius and draw full route
		showAgentBoxes = false, -- Optional legacy agent 3D boxes
		-- Combo-based display options
		basicDisplay = { false, false, false, true, true, false }, -- Show Nodes, Node IDs, Nav Connections, Areas, Doors, Corner Connections
		-- Individual settings (automatically set by combo selections)
		drawNodes = false, -- Draws all nodes on the map
		drawNodeIDs = false, -- Show node IDs  [[ Used by: MedBot.Visuals ]]
		drawPath = true, -- Draws the path to the current goal
		Objective = true,
		drawCurrentNode = false, -- Draws the current node
		showHidingSpots = false, -- Show hiding spots (areas where health packs are located)  [[ Used by: MedBot.Visuals ]]
		showConnections = false, -- Show connections between nodes  [[ Used by: MedBot.Visuals ]]
		showAreas = true, -- Show area outlines  [[ Used by: MedBot.Visuals ]]
		showDoors = true,
		showCornerConnections = false, -- Show corner connections  [[ Used by: MedBot.Visuals ]]
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
Common.Log = Lib.Utils.Logger
Common.Math = Lib.Utils.Math
Common.Conversion = Lib.Utils.Conversion
Common.WPlayer = Lib.TF2.WPlayer
Common.PR = Lib.TF2.PlayerResource
Common.Helpers = Lib.TF2.Helpers

-- JSON support
local JSON = {}
function JSON.parse(str)
    -- Simple JSON parser for basic objects/arrays
    if not str or str == "" then return nil end
    
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
    if type(obj) ~= "table" then return tostring(obj) end
    
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

-- Vector helpers
function Common.Normalize(vec)
    if not vec then return Vector3(0, 0, 0) end
    local len = vec:Length()
    if len > 0 then
        return vec / len
    end
    return Vector3(0, 0, 0)
end

function Common.VectorToString(vec)
    if not vec then return "nil" end
    return string.format("(%.1f, %.1f, %.1f)", vec.x, vec.y, vec.z)
end

-- Safe division
function Common.SafeDivide(a, b, default)
    default = default or 0
    if b == 0 then return default end
    return a / b
end

-- Distance helpers (legacy compatibility - use Distance module for new code)
function Common.Distance2D(a, b)
    return (a - b):Length2D()
end

function Common.Distance3D(a, b)
    return (a - b):Length()
end

return Common

end)
__bundle_register("MedBot.Visuals", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local isWalkable = require("MedBot.Navigation.ISWalkable")
local Distance = require("MedBot.Helpers.Distance")

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)
local Log = Common.Log.new("Visuals")

-- Grid-based rendering helpers
local gridIndex = {}
local nodeCell = {}
local visBuf = {}
local visCount = 0
Visuals.lastChunkSize = nil
Visuals.lastRenderChunks = nil

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

local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	-- If invert is true, swap start_pos and end_pos
	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	-- Calculate direction from start to end
	local direction = end_pos - start_pos
	local direction_length = direction:Length()
	if direction_length == 0 then
		return
	end

	-- Normalize the direction vector
	local normalized_direction = direction / direction_length

	-- Calculate the arrow base position by moving back from end_pos in the direction of start_pos
	local arrow_base = end_pos - normalized_direction * arrowhead_length

	-- Calculate the perpendicular vector for the arrow width
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	-- Convert world positions to screen positions
	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	-- Draw the line from start to the base of the arrow (not all the way to the end)
	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])

	-- Draw the sides of the arrowhead
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp1[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])

	-- Optionally, draw the base of the arrowhead to close it
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

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

-- Convert world position to chunk cell
local function worldToCell(pos)
    local size = G.Menu.Visuals.chunkSize or 256
    if size <= 0 then
        error("chunkSize must be greater than 0")
    end
    return math.floor(pos.x / size),
        math.floor(pos.y / size),
        math.floor(pos.z / size)
end

-- Build lookup grid of node ids per cell
local function buildGrid()
    gridIndex = {}
    nodeCell = {}
    local size = G.Menu.Visuals.chunkSize or 256
    for id, node in pairs(G.Navigation.nodes or {}) do
        -- if isWalkable(nodeA.pos, nodeB.pos) then -- Temporarily disabled
        if false then
            Log:Warn("Visuals.buildGrid: skipping invalid node %s", tostring(id))
            goto continue
        end
        local cx, cy, cz = worldToCell(node.pos)
        gridIndex[cx] = gridIndex[cx] or {}
        gridIndex[cx][cy] = gridIndex[cx][cy] or {}
        gridIndex[cx][cy][cz] = gridIndex[cx][cy][cz] or {}
        table.insert(gridIndex[cx][cy][cz], id)
        nodeCell[id] = { cx, cy, cz }
        ::continue::
    end
    Visuals.lastChunkSize = size
    Visuals.lastRenderChunks = G.Menu.Visuals.renderChunks or 3
end

-- Rebuild grid if configuration changed
function Visuals.MaybeRebuildGrid()
    local size = G.Menu.Visuals.chunkSize or 256
    local chunks = G.Menu.Visuals.renderChunks or 3
    if size ~= Visuals.lastChunkSize or chunks ~= Visuals.lastRenderChunks then
        buildGrid()
    end
end

-- External access to rebuild grid
function Visuals.BuildGrid()
    buildGrid()
end

function Visuals.Initialize()
    local success, err = pcall(buildGrid)
    if not success then
        print("Error initializing visuals grid: " .. tostring(err))
        gridIndex = {}
        nodeCell = {}
        visBuf = {}
        visCount = 0
    end
end

-- Collect visible node ids around player
local function collectVisible(me)
    visCount = 0
    local px, py, pz = worldToCell(me:GetAbsOrigin())
    local r = G.Menu.Visuals.renderChunks or 3
    for dx = -r, r do
        local ax = math.abs(dx)
        for dy = -(r - ax), (r - ax) do
            local dzMax = r - ax - math.abs(dy)
            for dz = -dzMax, dzMax do
                local bx = gridIndex[px + dx]
                local by = bx and bx[py + dy]
                local bucket = by and by[pz + dz]
                if bucket then
                    for _, id in ipairs(bucket) do
                        visCount = visCount + 1
                        visBuf[visCount] = id
                    end
                end
            end
        end
    end
end


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

        local currentY = 120
	-- Draw memory usage if enabled in config
	if G.Menu.Visuals.memoryUsage then
		draw.SetFont(Fonts.Verdana) -- Ensure font is set before drawing text
		draw.Color(255, 255, 255, 200)
		-- Get current memory usage directly for real-time display
		local currentMemKB = collectgarbage("count")
		local memMB = currentMemKB / 1024
		draw.Text(10, 10, string.format("Memory Usage: %.1f MB", memMB))
		currentY = currentY + 20
	end
    -- Collect visible nodes using chunk grid and Manhattan render radius
    Visuals.MaybeRebuildGrid()
    collectVisible(me)
    local p = me:GetAbsOrigin()
    local renderRadius = (G.Menu.Visuals.renderRadius or 400)
    local function withinRadius(pos)
        -- Inline distance check for bundle compatibility
        return (pos - p):Length() <= renderRadius
    end
        local visibleNodes = {}
        for i = 1, visCount do
            -- local nodeA = Node.GetNodeByID(connection.areaID) -- Temporarily disabled
            -- local nodeB = Node.GetNodeByID(connection.targetAreaID) -- Temporarily disabled
            local nodeA, nodeB = nil, nil
            local id = visBuf[i]
            local node = G.Navigation.nodes[id]
            if node then
                -- Use withinRadius for consistent distance culling
                if withinRadius(node.pos) then
                    local scr = client.WorldToScreen(node.pos)
                    if scr then
                        visibleNodes[id] = { node = node, screen = scr }
                    end
                end
            end
        end
    G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
    if G.Navigation.currentNodeIndex == nil then
        return
    end

    if G.Menu.Visuals.showAgentBoxes and G.Navigation.path then
        -- Visualizing agents (optional)
        local agent1Pos = G.Navigation.path[G.Navigation.FirstAgentNode]
            and G.Navigation.path[G.Navigation.FirstAgentNode].pos
        local agent2Pos = G.Navigation.path[G.Navigation.SecondAgentNode]
            and G.Navigation.path[G.Navigation.SecondAgentNode].pos

        if agent1Pos then
            local screenPos1 = client.WorldToScreen(agent1Pos)
            if screenPos1 then
                draw.Color(255, 255, 255, 255)
                Draw3DBox(10, agent1Pos)
            end
        end
        if agent2Pos then
            local screenPos2 = client.WorldToScreen(agent2Pos)
            if screenPos2 then
                draw.Color(0, 255, 0, 255)
                Draw3DBox(20, agent2Pos)
            end
        end
    end

    -- Show connections between nav nodes (colored by directionality)
    if G.Menu.Visuals.showConnections then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
            if not withinRadius(node.pos) then goto continue_node end
			for dir = 1, 4 do
				local cDir = node.c[dir]
				if cDir and cDir.connections then
                    for _, conn in ipairs(cDir.connections) do
                        local nid = (type(conn) == "table") and conn.node or conn
                        local otherNode = G.Navigation.nodes and G.Navigation.nodes[nid]
                        if otherNode then
                            local pos1 = node.pos + UP_VECTOR
                            local pos2 = otherNode.pos + UP_VECTOR
                            if not (withinRadius(pos1) and withinRadius(pos2)) then goto continue_conn end
                            local s1 = client.WorldToScreen(pos1)
                            local s2 = client.WorldToScreen(pos2)
                            if s1 and s2 then
							-- determine if other->id exists in its connections
							local bidir = false
                            
							for d2 = 1, 4 do
								local otherCDir = otherNode.c[d2]
								if otherCDir and otherCDir.connections then
                                    for _, backConn in ipairs(otherCDir.connections) do
                                        local backId = (type(backConn) == "table") and backConn.node or backConn
                                        if backId == id then
											bidir = true
											break
										end
									end
									if bidir then
										break
									end
								end
							end
							-- yellow for two-way, red for one-way
                                if bidir then draw.Color(255, 255, 0, 160) else draw.Color(255, 64, 64, 160) end
                                draw.Line(s1[1], s1[2], s2[1], s2[2])
                            end
                            ::continue_conn::
                        end
					end
				end
			end
            ::continue_node::
		end
	end

    -- Draw corner connections from node-level data (if enabled) 
    if G.Menu.Visuals.showCornerConnections then
        local wallCornerCount = 0
        local allCornerCount = 0
        
        for id, entry in pairs(visibleNodes) do
            local node = entry.node
            -- Draw all corners (green for inside corners)
            if node.allCorners then
                for _, cornerPoint in ipairs(node.allCorners) do
                    allCornerCount = allCornerCount + 1
                    if withinRadius(cornerPoint) then
                        local cornerScreen = client.WorldToScreen(cornerPoint)
                        if cornerScreen then
                            draw.Color(0, 255, 0, 200) -- Green for inside corners
                            draw.FilledRect(cornerScreen[1] - 2, cornerScreen[2] - 2, 
                                          cornerScreen[1] + 2, cornerScreen[2] + 2)
                        end
                    end
                end
            end
            
            -- Draw wall corners (orange squares)
            if node.wallCorners then
                for _, cornerPoint in ipairs(node.wallCorners) do
                    wallCornerCount = wallCornerCount + 1
                    if withinRadius(cornerPoint) then
                        local cornerScreen = client.WorldToScreen(cornerPoint)
                        if cornerScreen then
                            draw.Color(255, 165, 0, 200) -- Orange for wall corners
                            draw.FilledRect(cornerScreen[1] - 3, cornerScreen[2] - 3, 
                                          cornerScreen[1] + 3, cornerScreen[2] + 3)
                        end
                    end
                end
            end
        end
        
        -- Debug output in top-left corner
        if wallCornerCount > 0 or allCornerCount > 0 then
            draw.Color(255, 255, 255, 255)
            draw.Text(10, 10, "Wall corners: " .. wallCornerCount .. " / All corners: " .. allCornerCount)
        end
    end

    -- Draw Doors (left, middle, right) if enabled
    if G.Menu.Visuals.showDoors then
        for id, entry in pairs(visibleNodes) do
            local node = entry.node
            for dir = 1, 4 do
                local cDir = node.c[dir]
                if cDir and cDir.connections then
                    for _, conn in ipairs(cDir.connections) do
                        local doorLeft = conn.left and (conn.left + UP_VECTOR)
                        local doorMid = conn.middle and (conn.middle + UP_VECTOR)
                        local doorRight = conn.right and (conn.right + UP_VECTOR)
                        if doorLeft and doorMid and doorRight then
                            local sL = client.WorldToScreen(doorLeft)
                            local sM = client.WorldToScreen(doorMid)
                            local sR = client.WorldToScreen(doorRight)
                            if sL and sM and sR then
                                -- Door line - blue for whole door
                                draw.Color(0, 180, 255, 220)
                                draw.Line(sL[1], sL[2], sR[1], sR[2])
                                -- Left and right ticks - blue
                                draw.Color(0, 180, 255, 255)
                                draw.FilledRect(sL[1] - 2, sL[2] - 2, sL[1] + 2, sL[2] + 2)
                                draw.FilledRect(sR[1] - 2, sR[2] - 2, sR[1] + 2, sR[2] + 2)
                                -- Middle marker - also blue (consistent color)
                                draw.Color(0, 180, 255, 255)
                                draw.FilledRect(sM[1] - 2, sM[2] - 2, sM[1] + 2, sM[2] + 2)
                            else
                                -- If only two points present (left/right), compute middle as midpoint
                                local sL2 = doorLeft and client.WorldToScreen(doorLeft)
                                local sR2 = doorRight and client.WorldToScreen(doorRight)
                                if sL2 and sR2 then
                                    draw.Color(0, 180, 255, 220)
                                    draw.Line(sL2[1], sL2[2], sR2[1], sR2[2])
                                    draw.Color(0, 180, 255, 255)
                                    draw.FilledRect(sL2[1] - 2, sL2[2] - 2, sL2[1] + 2, sL2[2] + 2)
                                    draw.FilledRect(sR2[1] - 2, sR2[2] - 2, sR2[1] + 2, sR2[2] + 2)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

	-- Fill and outline areas using fixed corners from Navigation
    if G.Menu.Visuals.showAreas then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
			-- Collect the four corner vectors from the node
			local worldCorners = { node.nw, node.ne, node.se, node.sw }
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

    -- Fine points removed
        if false then
                -- Track drawn inter-area connections to avoid duplicates
                local drawnInterConnections = {}
                local drawnIntraConnections = {}

		for id, entry in pairs(visibleNodes) do
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

				-- Second pass: draw points (so they appear on top of lines)
				for _, point in ipairs(points) do
					local screenPos = client.WorldToScreen(point.pos)
					if screenPos then
						-- Color-code points: yellow for edge points, blue for regular points
						if point.isEdge then
							draw.Color(255, 255, 0, 220) -- Yellow for edge points
							draw.FilledRect(screenPos[1] - 2, screenPos[2] - 2, screenPos[1] + 2, screenPos[2] + 2)
						else
							draw.Color(0, 150, 255, 180) -- Light blue for regular points
							draw.FilledRect(screenPos[1] - 1, screenPos[2] - 1, screenPos[1] + 1, screenPos[2] + 1)
						end
					end
				end
			end
		end

		-- Show fine point statistics for areas with points
		local finePointStats = {}
		for id, entry in pairs(visibleNodes) do
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

	-- Draw all nodes
    if G.Menu.Visuals.drawNodes then
		draw.Color(0, 255, 0, 255)
		for id, entry in pairs(visibleNodes) do
			local s = entry.screen
			draw.FilledRect(s[1] - 4, s[2] - 4, s[1] + 4, s[2] + 4)
			if G.Menu.Visuals.drawNodeIDs then
				draw.Text(s[1], s[2] + 10, tostring(id))
			end
		end
	end

    -- Draw only the actual-followed path using door-aware waypoints, with a live target arrow
    if G.Menu.Visuals.drawPath then
        local wps = G.Navigation.waypoints
        if wps and #wps > 0 then
            -- Draw remaining route only from current waypoint onward to avoid residue arrows
            local startIdx = G.Navigation.currentWaypointIndex or 1
            if startIdx < 1 then startIdx = 1 end
            for i = startIdx, #wps - 1 do
                local a, b = wps[i], wps[i + 1]
                local aPos = a.pos
                local bPos = b.pos
                if not aPos and a.kind == "door" and a.points and #a.points > 0 then
                    aPos = a.points[math.ceil(#a.points / 2)]
                end
                if not bPos and b.kind == "door" and b.points and #b.points > 0 then
                    bPos = b.points[math.ceil(#b.points / 2)]
                end
                local inRad = withinRadius(aPos or p) and withinRadius(bPos or p)
                if aPos and bPos and (G.Menu.Visuals.ignorePathRadius or inRad) then
                    draw.Color(255, 255, 255, 220) -- white route
                    ArrowLine(aPos, bPos, 18, 12, false)
                end
            end
            -- Current target indicator + box at the target
            local tgt = G.Navigation.currentTargetPos
            if tgt and (G.Menu.Visuals.ignorePathRadius or withinRadius(tgt)) then
                -- Arrow color logic: white normal, red if stuck & not walkable, yellow if stuck & walkable
                local arrowR, arrowG, arrowB = 255, 255, 255
                if G.currentState == G.States.STUCK then
                    local now = globals.TickCount()
                    if not G._lastStuckWalkableTick or (now - G._lastStuckWalkableTick) > 15 then
                        local me = entities.GetLocalPlayer()
                        local mePos = me and me:GetAbsOrigin()
                        local walkMode = G.Menu.Main.WalkableMode or "Smooth"
                        G._lastStuckWalkableResult = (mePos and isWalkable.Path(mePos, tgt, walkMode)) or false
                        G._lastStuckWalkableTick = now
                    end
                    if G._lastStuckWalkableResult then
                        arrowR, arrowG, arrowB = 255, 255, 0 -- yellow: stuck but walkable
                    else
                        arrowR, arrowG, arrowB = 255, 0, 0 -- red: stuck and blocked
                    end
                end
                draw.Color(arrowR, arrowG, arrowB, 255)
                local me = entities.GetLocalPlayer()
                if me then
                    local mePos = me:GetAbsOrigin()
                    ArrowLine(mePos, tgt, 22, 16, false)
                end
                -- Also place a square at the target with same color
                local s = client.WorldToScreen(tgt)
                if s then
                    draw.Color(arrowR, arrowG, arrowB, 255)
                    draw.FilledRect(s[1] - 4, s[2] - 4, s[1] + 4, s[2] + 4)
                end
            end
            -- Omit extra squares; arrows indicate route; 3D boxes already mark agents
        end
    end

	-- Draw current node
    if G.Menu.Visuals.drawCurrentNode and G.Navigation.path then
                draw.Color(255, 0, 0, 255)

		local currentNode = G.Navigation.path[G.Navigation.currentNodeIndex]
		local currentNodePos = currentNode.pos

        local screenPos = client.WorldToScreen(currentNodePos)
        if screenPos then
            Draw3DBox(20, currentNodePos)
            draw.Text(screenPos[1], screenPos[2] + 40, tostring(G.Navigation.currentNodeIndex))
        end
    end

    -- Draw SmartJump simulation visualization (like AutoPeek)
    if G.SmartJump and G.SmartJump.SimulationPath and type(G.SmartJump.SimulationPath) == "table" and #G.SmartJump.SimulationPath > 1 then
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
        
        -- Draw jump landing position if available (lines only, no boxes)
        if G.SmartJump and G.SmartJump.JumpPeekPos and G.SmartJump.PredPos then
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
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals

end)
__bundle_register("MedBot.Helpers.Distance", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Distance Calculation Helpers ]]
-- Centralized distance calculations for performance and consistency

local Distance = {}

-- Constants
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local HITBOX_WIDTH = 48

-- Fast 2D distance using engine's optimized Length2D()
function Distance.Fast2D(posA, posB)
    return (posA - posB):Length2D()
end

-- 3D distance using engine's optimized Length()
function Distance.Fast3D(posA, posB)
    return (posA - posB):Length()
end

-- Manhattan distance (for rough culling/sorting)
function Distance.Manhattan2D(posA, posB)
    return math.abs(posA.x - posB.x) + math.abs(posA.y - posB.y)
end

-- Manhattan 3D distance
function Distance.Manhattan3D(posA, posB)
    return math.abs(posA.x - posB.x) + math.abs(posA.y - posB.y) + math.abs(posA.z - posB.z)
end

-- Squared distance (avoids sqrt for comparisons)
function Distance.Squared2D(posA, posB)
    local dx = posA.x - posB.x
    local dy = posA.y - posB.y
    return dx*dx + dy*dy
end

function Distance.Squared3D(posA, posB)
    local dx = posA.x - posB.x
    local dy = posA.y - posB.y
    local dz = posA.z - posB.z
    return dx*dx + dy*dy + dz*dz
end

-- Height difference (Z-axis only)
function Distance.HeightDiff(posA, posB)
    return math.abs(posA.z - posB.z)
end

-- Point to line segment distance (2D)
function Distance.PointToSegment2D(px, py, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local wx, wy = px - ax, py - ay
    local vv = vx * vx + vy * vy
    
    if vv == 0 then
        return math.sqrt(wx * wx + wy * wy)
    end
    
    local t = math.max(0, math.min(1, (wx * vx + wy * vy) / vv))
    local cx, cy = ax + t * vx, ay + t * vy
    local dx, dy = px - cx, py - cy
    return math.sqrt(dx * dx + dy * dy)
end

-- Check if within render radius (optimized for frequent calls)
function Distance.WithinRadius(pos, centerPos, radius)
    return Distance.Fast3D(pos, centerPos) <= radius
end

-- Check if within squared radius (faster for comparisons)
function Distance.WithinRadiusSquared(pos, centerPos, radiusSquared)
    return Distance.Squared3D(pos, centerPos) <= radiusSquared
end

-- Navigation-specific distance checks
function Distance.IsWalkableHeight(posA, posB)
    local heightDiff = Distance.HeightDiff(posA, posB)
    return heightDiff <= STEP_HEIGHT
end

function Distance.IsJumpableHeight(posA, posB)
    local heightDiff = Distance.HeightDiff(posA, posB)
    return heightDiff > STEP_HEIGHT and heightDiff <= MAX_JUMP
end

-- Wall clearance check (24 units from corners)
function Distance.HasWallClearance(doorPos, cornerPos)
    return Distance.Fast3D(doorPos, cornerPos) >= 24
end

return Distance

end)
__bundle_register("MedBot.Navigation.ISWalkable", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Path Validation Module - Uses trace hulls to check if path A→B is walkable
-- This is NOT movement execution, just validation logic
local isWalkable = {}
local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")

-- Constants based on standstill dummy's robust implementation
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) } -- Player collision hull
local STEP_HEIGHT = 18 -- Maximum height the player can step up
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local MAX_FALL_DISTANCE = 250 -- Maximum distance the player can fall without taking fall damage
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE

local UP_VECTOR = Vector3(0, 0, 1)
local MAX_SURFACE_ANGLE = 45 -- Maximum angle for ground surfaces
local MAX_ITERATIONS = 37 -- Maximum number of iterations to prevent infinite loops

-- Helper function to get local player for speed calculation
local function getLocalPlayer()
	return entities.GetLocalPlayer()
end

-- Helper function to get min step size based on player speed
local function getMinStepSize()
	local pLocal = getLocalPlayer()
	if pLocal then
		local maxSpeed = pLocal:GetPropFloat("m_flMaxspeed") or 450
		return maxSpeed * globals.TickInterval()
	end
	return 7.5 -- Fallback value (450 * 1/66)
end

-- Helper function to check if we should hit an entity (ignore local player)
local function shouldHitEntity(entity)
	local pLocal = getLocalPlayer()
	return entity ~= pLocal -- Ignore self (the player being simulated)
end

-- Normalize a vector
local function Normalize(vec)
	local length = vec:Length()
	if length == 0 then
		return vec
	end
	return vec / length
end

-- Calculate horizontal Manhattan distance between two points
local function getHorizontalManhattanDistance(point1, point2)
	return math.abs(point1.x - point2.x) + math.abs(point1.y - point2.y)
end

-- Perform a hull trace to check for obstructions between two points
local function performTraceHull(startPos, endPos)
	return engine.TraceHull(startPos, endPos, PLAYER_HULL.Min, PLAYER_HULL.Max, MASK_PLAYERSOLID, shouldHitEntity)
end

-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	-- Check if the surface is within the maximum allowed angle for adjustment
	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	local dotProduct = direction:Dot(surfaceNormal)

	-- Adjust the z component of the direction in place
	direction.z = direction.z - surfaceNormal.z * dotProduct

	-- Normalize the direction after adjustment
	return Normalize(direction)
end

-- Main function to check if the path between the current position and the node is walkable.
-- Uses robust algorithm from standstill dummy to prevent walking over walls
-- Respects Walkable Mode setting: "Step" = 18-unit steps only, "Jump" = 72-unit duck jumps allowed
function isWalkable.Path(startPos, endPos, overrideMode)
	-- Get walkable mode from menu or override value
	local walkableMode = overrideMode or G.Menu.Main.WalkableMode or "Smooth"
	local maxStepHeight = walkableMode == "Aggressive" and 72 or STEP_HEIGHT -- 72 for duck jumps, 18 for steps
	local maxStepVector = Vector3(0, 0, maxStepHeight)
	local stepFraction = maxStepHeight / MAX_FALL_DISTANCE

	-- Quick height check first
	local totalHeightDiff = endPos.z - startPos.z
	if totalHeightDiff > maxStepHeight then
		return false -- Too high for current mode
	end

	local blocked = false
	local currentPos = startPos
	local MIN_STEP_SIZE = 7.5 -- Use fixed small step size for robust ground checks

	-- Adjust start position to ground level
	local startGroundTrace = performTraceHull(startPos + maxStepVector, startPos - MAX_FALL_DISTANCE_Vector)
	currentPos = startGroundTrace.endpos

	-- Initial direction towards goal, adjusted for ground normal
	local lastPos = currentPos
	local lastDirection = adjustDirectionToSurface(endPos - currentPos, startGroundTrace.plane)

	local MaxDistance = getHorizontalManhattanDistance(startPos, endPos)

	-- Main loop to iterate towards the goal
	for iteration = 1, MAX_ITERATIONS do
		-- Calculate distance to goal and update direction
		local distanceToGoal = (currentPos - endPos):Length()
		local direction = lastDirection

		-- Calculate next position
		local NextPos = lastPos + direction * distanceToGoal

		-- Forward collision check - this prevents walking through walls
		local wallTrace = performTraceHull(lastPos + maxStepVector, NextPos + maxStepVector)
		currentPos = wallTrace.endpos

		-- If we start inside a wall, it's not walkable
		if wallTrace.fraction == 0 then
			return false
		end
		-- If we immediately hit an obstacle and barely progressed, treat as blocked
		if wallTrace.fraction < 1 then
			local progressed = (currentPos - lastPos):Length()
			if progressed < (MIN_STEP_SIZE * 0.5) then
				return false
			end
		end

		-- Ground collision with segmentation - ensures we always have ground beneath us
		local totalDistance = (currentPos - lastPos):Length()
		local numSegments = math.max(1, math.floor(totalDistance / MIN_STEP_SIZE))

		for seg = 1, numSegments do
			local t = seg / numSegments
			local segmentPos = lastPos + (currentPos - lastPos) * t
			local segmentTop = segmentPos + maxStepVector
			local segmentBottom = segmentPos - MAX_FALL_DISTANCE_Vector

			local groundTrace = performTraceHull(segmentTop, segmentBottom)

			if groundTrace.fraction == 1 then
				return false -- No ground beneath; path is unwalkable
			end

			-- Check if obstacle is within acceptable height for current mode
			local obstacleHeight = (segmentBottom - groundTrace.endpos).z
			if obstacleHeight > maxStepHeight then
				return false -- Obstacle too high for current mode
			end

			-- Stronger step acceptance: require either we reached near the ground or we are at the last segment
			if groundTrace.fraction >= (stepFraction * 0.9) or seg == numSegments then
				-- Adjust position to ground
				direction = adjustDirectionToSurface(direction, groundTrace.plane)
				currentPos = groundTrace.endpos
				blocked = false
				break
			end
		end

		-- Calculate current horizontal distance to goal
		local currentDistance = getHorizontalManhattanDistance(currentPos, endPos)
		if blocked or currentDistance > MaxDistance then -- if target is unreachable
			return false
		end

		-- If we're close enough to the goal, check both horizontal and vertical proximity
		if currentDistance < 24 then
			local verticalDist = math.abs(endPos.z - currentPos.z)
			if verticalDist < maxStepHeight then
				-- Final forward micro-check to avoid clipping through thin objects near the goal
				local microEnd = endPos
				local microTrace = performTraceHull(currentPos + maxStepVector, microEnd + maxStepVector)
				if microTrace.fraction < 1 and (microTrace.endpos - currentPos):Length() < 24 then
					return false
				end
				return true
			else
				return false
			end
		end

		-- Prepare for the next iteration
		lastPos = currentPos
		lastDirection = direction
	end

	return false -- Max iterations reached without finding a path
end

return isWalkable

end)
__bundle_register("MedBot.Navigation.Node", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  Node.lua  ·  Clean Node API following black box principles
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local NavLoader = require("MedBot.Navigation.NavLoader")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")
local ConnectionBuilder = require("MedBot.Navigation.ConnectionBuilder")
local AccessibilityChecker = require("MedBot.Navigation.AccessibilityChecker")

local Log = Common.Log.new("Node")
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

-- Setup and loading
function Node.Setup()
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return
	end
	
	NavLoader.LoadNavFile()
	ConnectionBuilder.NormalizeConnections()
	-- AccessibilityChecker.PruneInvalidConnections(G.Navigation.nodes) -- DISABLED: Uses area centers not edges
	ConnectionBuilder.BuildDoorsForConnections()
	
	local WallCornerDetector = require("MedBot.Navigation.WallCornerDetector")
	WallCornerDetector.DetectWallCorners()
	
	Log:Info("Navigation setup complete")
end

function Node.ResetSetup()
	G.Navigation.navMeshUpdated = false
	Log:Info("Navigation setup state reset")
end

function Node.LoadNavFile()
	return NavLoader.LoadNavFile()
end

function Node.LoadFile(navFile)
	return NavLoader.LoadFile(navFile)
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

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then return nil end
	
	local closestNode, closestDist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		local dist = (node.pos - pos):Length()
		if dist < closestDist then
			closestNode, closestDist = node, dist
		end
	end
	return closestNode
end

-- Connection utilities
function Node.GetConnectionNodeId(connection)
	return ConnectionUtils.GetNodeId(connection)
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
	if not nodeA or not nodeB then return end
	
	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			table.insert(dir.connections, { node = nodeB.id, cost = 1 })
			dir.count = #dir.connections
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then return end
	
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

-- Pathfinding adjacency - optimized with door registry lookup
function Node.GetAdjacentNodesSimple(node, nodes)
	if not node or not node.c or not nodes then return {} end
	
	local adjacent = {}
	local count = 0
	
	for _, dir in pairs(node.c) do
		local connections = dir.connections
		if connections then
			for i = 1, #connections do
				local targetId = ConnectionUtils.GetNodeId(connections[i])
				local targetNode = nodes[targetId]
				if targetNode then
					count = count + 1
					adjacent[count] = {
						node = targetNode,
						cost = ConnectionUtils.GetCost(connections[i])
					}
				end
			end
		end
	end
	
	return adjacent
end

-- Optimized version for when only nodes are needed (no cost data)
function Node.GetAdjacentNodesOnly(node, nodes)
	if not node or not node.c or not nodes then return {} end
	
	local adjacent = {}
	local count = 0
	
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

-- Get door target point for pathfinding between two areas
function Node.GetDoorTarget(nodeA, nodeB)
	local DoorRegistry = require("MedBot.Navigation.DoorRegistry")
	return DoorRegistry.GetDoorTarget(nodeA.id, nodeB.id)
end

-- Legacy compatibility
function Node.CleanupConnections()
	local nodes = Node.GetNodes()
	if nodes then
		AccessibilityChecker.PruneInvalidConnections(nodes)
		Log:Info("Connections cleaned up")
	end
end

function Node.NormalizeConnections()
	ConnectionBuilder.NormalizeConnections()
end

function Node.BuildDoorsForConnections()
	ConnectionBuilder.BuildDoorsForConnections()
end

-- Processing status
function Node.GetConnectionProcessingStatus()
	return {
		isProcessing = false,
		currentPhase = "complete",
		processedCount = 0,
		totalCount = 0,
		phaseDescription = "Connection processing complete"
	}
end

function Node.ProcessConnectionsBackground()
	-- Simplified - no background processing needed
end

function Node.StopConnectionProcessing()
	-- No-op - no background processing
end

return Node

end)
__bundle_register("MedBot.Navigation.DoorRegistry", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  DoorRegistry.lua  ·  Centralized door lookup system
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local DoorRegistry = {}
local Log = Common.Log.new("DoorRegistry")

-- Central door storage: doorId -> {left, middle, right, needJump, owner}
local doors = {}

-- Generate unique door ID for area pair (order-independent)
local function getDoorId(areaIdA, areaIdB)
    local minId = math.min(areaIdA, areaIdB)
    local maxId = math.max(areaIdA, areaIdB)
    return minId .. "_" .. maxId
end

-- Store door geometry in central registry
function DoorRegistry.RegisterDoor(areaIdA, areaIdB, doorData)
    if not doorData then return false end
    
    local doorId = getDoorId(areaIdA, areaIdB)
    doors[doorId] = {
        left = doorData.left,
        middle = doorData.middle,
        right = doorData.right,
        needJump = doorData.needJump,
        owner = doorData.owner
    }
    return true
end

-- Get door geometry for area pair
function DoorRegistry.GetDoor(areaIdA, areaIdB)
    local doorId = getDoorId(areaIdA, areaIdB)
    return doors[doorId]
end

-- Get door middle point for pathfinding
function DoorRegistry.GetDoorTarget(areaIdA, areaIdB)
    local door = DoorRegistry.GetDoor(areaIdA, areaIdB)
    return door and door.middle or nil
end

-- Clear all doors (for map changes)
function DoorRegistry.Clear()
    doors = {}
    Log:Info("Door registry cleared")
end

-- Get door count for debugging
function DoorRegistry.GetDoorCount()
    local count = 0
    for _ in pairs(doors) do count = count + 1 end
    return count
end

return DoorRegistry

end)
__bundle_register("MedBot.Navigation.WallCornerDetector", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  WallCornerDetector.lua  ·  Detects wall corners for door clamping
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local WallCornerDetector = {}

local Log = Common.Log.new("WallCornerDetector")

-- Group neighbors by 4 directions for an area
local function groupNeighborsByDirection(area, nodes)
	local neighbors = {
		north = {},  -- dirY = -1
		south = {},  -- dirY = 1  
		east = {},   -- dirX = 1
		west = {}    -- dirX = -1
	}
	
	if not area.c then return neighbors end
	
	for dirId, dir in pairs(area.c) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = (type(connection) == "table") and connection.node or connection
				local neighbor = nodes[targetId]
				if neighbor then
					-- Determine direction from area to neighbor
					local dx = neighbor.pos.x - area.pos.x
					local dy = neighbor.pos.y - area.pos.y
					
					if math.abs(dx) >= math.abs(dy) then
						if dx > 0 then
							table.insert(neighbors.east, neighbor)
						else
							table.insert(neighbors.west, neighbor)
						end
					else
						if dy > 0 then
							table.insert(neighbors.south, neighbor)
						else
							table.insert(neighbors.north, neighbor)
						end
					end
				end
			end
		end
	end
	
	return neighbors
end

-- Get 2 corner points for a direction edge
local function getDirectionCorners(area, direction)
	if not (area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end
	
	if direction == "north" then return area.nw, area.ne end
	if direction == "south" then return area.se, area.sw end  
	if direction == "east" then return area.ne, area.se end
	if direction == "west" then return area.sw, area.nw end
	
	return nil, nil
end

-- Check if point lies on neighbor's border edge facing our area
local function pointLiesOnNeighborBorder(point, neighbor, direction)
	if not (neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw) then
		return false
	end
	
	local tolerance = 1.0 -- Small tolerance for misaligned borders
	
	if direction == "north" then
		-- Check if point lies on neighbor's south edge
		local edge1, edge2 = neighbor.se, neighbor.sw
		-- Check if point.y matches edge Y and point.x is between edge X coords
		return math.abs(point.y - edge1.y) < tolerance and 
		       point.x >= math.min(edge1.x, edge2.x) - tolerance and
		       point.x <= math.max(edge1.x, edge2.x) + tolerance
	elseif direction == "south" then
		-- Check if point lies on neighbor's north edge  
		local edge1, edge2 = neighbor.nw, neighbor.ne
		return math.abs(point.y - edge1.y) < tolerance and
		       point.x >= math.min(edge1.x, edge2.x) - tolerance and
		       point.x <= math.max(edge1.x, edge2.x) + tolerance
	elseif direction == "east" then
		-- Check if point lies on neighbor's west edge
		local edge1, edge2 = neighbor.sw, neighbor.nw  
		return math.abs(point.x - edge1.x) < tolerance and
		       point.y >= math.min(edge1.y, edge2.y) - tolerance and
		       point.y <= math.max(edge1.y, edge2.y) + tolerance
	elseif direction == "west" then
		-- Check if point lies on neighbor's east edge
		local edge1, edge2 = neighbor.ne, neighbor.se
		return math.abs(point.x - edge1.x) < tolerance and
		       point.y >= math.min(edge1.y, edge2.y) - tolerance and
		       point.y <= math.max(edge1.y, edge2.y) + tolerance
	end
	
	return false
end

-- Count how many neighbor borders a corner lies on
local function countNeighborBorders(corner, neighbors, direction)
	local count = 0
	for _, neighbor in ipairs(neighbors) do
		if pointLiesOnNeighborBorder(corner, neighbor, direction) then
			count = count + 1
		end
	end
	return count
end

function WallCornerDetector.DetectWallCorners()
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
				Log:Debug("Node %s has %d neighbors (N:%d S:%d E:%d W:%d)", 
					tostring(nodeId), totalNeighbors, #neighbors.north, #neighbors.south, #neighbors.east, #neighbors.west)
			end
			
			-- Check all 4 directions
			for direction, dirNeighbors in pairs(neighbors) do
				local corner1, corner2 = getDirectionCorners(area, direction)
				if corner1 and corner2 then
					-- Check both corners of this direction
					for _, corner in ipairs({corner1, corner2}) do
						table.insert(area.allCorners, corner)
						allCornerCount = allCornerCount + 1
						
						local borderCount = countNeighborBorders(corner, dirNeighbors, direction)
						
						-- Debug: log border counts for first few corners
						if allCornerCount <= 10 then
							Log:Debug("Corner at (%.1f,%.1f,%.1f) in direction %s has %d border contacts", 
								corner.x, corner.y, corner.z, direction, borderCount)
						end
						
						-- Corner is wall corner if it lies on <2 neighbor borders
						if borderCount < 2 then
							table.insert(area.wallCorners, corner)
							wallCornerCount = wallCornerCount + 1
						end
					end
				end
			end
		end
	end
	
	Log:Info("Processed %d nodes, detected %d wall corners out of %d total corners", 
		nodeCount, wallCornerCount, allCornerCount)
	
	-- Console output for immediate visibility
	print("WallCornerDetector: " .. wallCornerCount .. " wall corners found")
	
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

return WallCornerDetector

end)
__bundle_register("MedBot.Navigation.AccessibilityChecker", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  AccessibilityChecker.lua  ·  Node accessibility validation
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local EdgeCalculator = require("MedBot.Navigation.EdgeCalculator")
local isWalkable = require("MedBot.Navigation.ISWalkable")

local AccessibilityChecker = {}

-- Constants
local DROP_HEIGHT = 144
local MAX_JUMP = 72
local STEP_HEIGHT = 18

local function isNodeAccessible(nodeA, nodeB, allowExpensive)
	local heightDiff = nodeB.pos.z - nodeA.pos.z

	-- Always allow going downward (falling) regardless of height - no penalty
	if heightDiff <= 0 then
		return true, 1 -- No penalty for falling
	end

	-- For upward movement, check if it's within jump range
	if heightDiff <= MAX_JUMP then
		-- Small step penalty for jumping (encourages ground-level paths)
		return true, 1 + (heightDiff / MAX_JUMP) * 0.5 -- Max 1.5x penalty
	end

	-- Height difference too large for jumping
	return false, math.huge
end

function AccessibilityChecker.IsAccessible(nodeA, nodeB, allowExpensive)
	if not nodeA or not nodeB then
		return false, math.huge
	end
	
	-- Skip expensive checks unless specifically allowed
	if not allowExpensive then
		return isNodeAccessible(nodeA, nodeB, false)
	end
	
	-- Full accessibility check with walkability
	local accessible, cost = isNodeAccessible(nodeA, nodeB, true)
	if not accessible then
		return false, math.huge
	end
	
	-- Additional walkability check if needed
	if isWalkable and isWalkable.CheckWalkability then
		local walkable = isWalkable.CheckWalkability(nodeA.pos, nodeB.pos)
		if not walkable then
			return false, math.huge
		end
	end
	
	return true, cost
end

function AccessibilityChecker.PruneInvalidConnections(nodes)
	if not nodes then return end
	
	local totalPruned = 0
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					local validConnections = {}
					for i, connection in ipairs(dir.connections) do
						local targetId = (type(connection) == "table") and connection.node or connection
						local targetNode = nodes[targetId]
						
						if targetNode then
							local accessible, cost = AccessibilityChecker.IsAccessible(node, targetNode, true)
							if accessible then
								if type(connection) == "table" then
									connection.cost = cost
									table.insert(validConnections, connection)
								else
									table.insert(validConnections, { node = connection, cost = cost })
								end
							else
								totalPruned = totalPruned + 1
							end
						else
							totalPruned = totalPruned + 1
						end
					end
					dir.connections = validConnections
					dir.count = #validConnections
				end
			end
		end
	end
	
	if totalPruned > 0 then
		local Log = Common.Log.new("AccessibilityChecker")
		Log:Info("Pruned " .. totalPruned .. " invalid connections")
	end
end

return AccessibilityChecker

end)
__bundle_register("MedBot.Navigation.EdgeCalculator", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  EdgeCalculator.lua  ·  Edge and corner geometry calculations
--##########################################################################

local G = require("MedBot.Core.Globals")

local EdgeCalculator = {}

-- Constants
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY

function EdgeCalculator.TraceHullDown(position)
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, TRACE_MASK)
end

function EdgeCalculator.TraceLineDown(position)
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceLine(startPos, endPos, TRACE_MASK)
end

function EdgeCalculator.GetGroundNormal(position)
	local trace = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START, 
		position + GROUND_TRACE_OFFSET_END, 
		MASK_BRUSH_ONLY
	)
	return trace.plane
end

function EdgeCalculator.GetNodeCorners(node)
	local corners = {}
	if node.nw then table.insert(corners, node.nw) end
	if node.ne then table.insert(corners, node.ne) end
	if node.se then table.insert(corners, node.se) end
	if node.sw then table.insert(corners, node.sw) end
	if node.pos then table.insert(corners, node.pos) end
	return corners
end

function EdgeCalculator.Cross2D(ax, ay, bx, by)
	return ax * by - ay * bx
end

function EdgeCalculator.Dot2D(ax, ay, bx, by)
	return ax * bx + ay * by
end

function EdgeCalculator.Length2D(ax, ay)
	return math.sqrt(ax * ax + ay * ay)
end

function EdgeCalculator.Distance3D(p, q)
	local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function EdgeCalculator.LerpVec(a, b, t)
	return Vector3(
		a.x + (b.x - a.x) * t, 
		a.y + (b.y - a.y) * t, 
		a.z + (b.z - a.z) * t
	)
end

return EdgeCalculator

end)
__bundle_register("MedBot.Navigation.ConnectionBuilder", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  ConnectionBuilder.lua  ·  Connection and door building
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local EdgeCalculator = require("MedBot.Navigation.EdgeCalculator")
local ConnectionUtils = require("MedBot.Navigation.ConnectionUtils")

local ConnectionBuilder = {}

-- Constants
local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local CLEARANCE_OFFSET = 34

local Log = Common.Log.new("ConnectionBuilder")

function ConnectionBuilder.NormalizeConnections()
	local nodes = G.Navigation.nodes
	if not nodes then return end
	
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

local function determineDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx > 0) and 1 or -1, 0
	else
		return 0, (dy > 0) and 1 or -1
	end
end

local function getFacingEdgeCorners(area, dirX, dirY, _)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end
	
	if dirX == 1 then return area.ne, area.se end     -- East
	if dirX == -1 then return area.sw, area.nw end    -- West  
	if dirY == 1 then return area.se, area.sw end     -- South
	if dirY == -1 then return area.nw, area.ne end    -- North
	
	return nil, nil
end

-- Compute scalar overlap on an axis and return segment [a1,a2] overlapped with [b1,b2]
local function overlap1D(a1, a2, b1, b2)
    if a1 > a2 then a1, a2 = a2, a1 end
    if b1 > b2 then b1, b2 = b2, b1 end
    local left = math.max(a1, b1)
    local right = math.min(a2, b2)
    if right <= left then return nil end
    return left, right
end

local function lerp(a, b, t) return a + (b - a) * t end

local function clampDoorAwayFromWalls(overlapLeft, overlapRight, areaA, areaB)
	local Distance = require("MedBot.Helpers.Distance")
	local WALL_CLEARANCE = 24
	
	-- Check if door endpoints are too close to wall corners from both areas
	local leftClamped = overlapLeft
	local rightClamped = overlapRight
	
	-- Check wall corners from both areas involved in the connection
	for _, area in ipairs({areaA, areaB}) do
		if area.wallCorners then
			for _, wallCorner in ipairs(area.wallCorners) do
				-- Clamp left endpoint if too close to wall corner
				if Distance.Fast3D(overlapLeft, wallCorner) < WALL_CLEARANCE then
					-- Move left endpoint away from wall corner
					local direction = (overlapRight - overlapLeft):Normalized()
					leftClamped = leftClamped + direction * WALL_CLEARANCE
				end
				
				-- Clamp right endpoint if too close to wall corner  
				if Distance.Fast3D(overlapRight, wallCorner) < WALL_CLEARANCE then
					-- Move right endpoint away from wall corner
					local direction = (overlapLeft - overlapRight):Normalized()
					rightClamped = rightClamped + direction * WALL_CLEARANCE
				end
			end
		end
	end
	
	return leftClamped, rightClamped
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

-- Calculate edge overlap and door geometry
local function calculateDoorGeometry(areaA, areaB, dirX, dirY)
	local a0, a1 = getFacingEdgeCorners(areaA, dirX, dirY, areaB.pos)
	local b0, b1 = getFacingEdgeCorners(areaB, -dirX, -dirY, areaA.pos)
	if not (a0 and a1 and b0 and b1) then return nil end
	
	local owner, ownerId = calculateDoorOwner(a0, a1, b0, b1, areaA, areaB)
	
	return {
		a0 = a0, a1 = a1, b0 = b0, b1 = b1,
		owner = owner, ownerId = ownerId
	}
end

local function createDoorForAreas(areaA, areaB)
	if not (areaA and areaB and areaA.pos and areaB.pos) then return nil end
	
	local dirX, dirY = determineDirection(areaA.pos, areaB.pos)
	local geometry = calculateDoorGeometry(areaA, areaB, dirX, dirY)
	if not geometry then return nil end
	
	local owner = geometry.owner
	local a0, a1, b0, b1 = geometry.a0, geometry.a1, geometry.b0, geometry.b1

    -- Determine 1D overlap along edge axis and reconstruct points on OWNER edge
    local oL, oR, edgeConst, axis -- axis: "x" or "y" varying
    if dirX ~= 0 then
        -- East/West: vertical edge, y varies, x constant
        oL, oR = overlap1D(a0.y, a1.y, b0.y, b1.y)
        axis = "y"
        edgeConst = owner == "B" and b0.x or a0.x
    else
        -- North/South: horizontal edge, x varies, y constant
        oL, oR = overlap1D(a0.x, a1.x, b0.x, b1.x)
        axis = "x"
        edgeConst = owner == "B" and b0.y or a0.y
    end
    if not oL then return nil end

    -- Helper to get endpoint pair on chosen owner edge
    local e0, e1 = (owner == "B" and b0 or a0), (owner == "B" and b1 or a1)
    local function pointOnOwnerEdge(val)
        -- compute t along owner edge based on axis coordinate
        local denom = (axis == "x") and (e1.x - e0.x) or (e1.y - e0.y)
        local t = denom ~= 0 and ((val - ((axis == "x") and e0.x or e0.y)) / denom) or 0
        t = math.max(0, math.min(1, t))
        local x = (axis == "x") and val or edgeConst
        local y = (axis == "y") and val or edgeConst
        local z = lerp(e0.z, e1.z, t)
        return Vector3(x, y, z)
    end

    local overlapLeft = pointOnOwnerEdge(oL)
    local overlapRight = pointOnOwnerEdge(oR)
    
    -- Clamp door away from wall corners
    overlapLeft, overlapRight = clampDoorAwayFromWalls(overlapLeft, overlapRight, areaA, areaB)
    
    local middle = EdgeCalculator.LerpVec(overlapLeft, overlapRight, 0.5)

    -- Validate width on the edge axis only (2D length) - after clamping
    local clampedWidth = (overlapRight - overlapLeft):Length()
    if clampedWidth < HITBOX_WIDTH then return nil end

    return {
        left = overlapLeft,
        middle = middle,
        right = overlapRight,
        owner = geometry.ownerId,
        needJump = (areaB.pos.z - areaA.pos.z) > STEP_HEIGHT
    }
end

function ConnectionBuilder.BuildDoorsForConnections()
	local nodes = G.Navigation.nodes
	if not nodes then return end
	
	local doorsBuilt = 0
	for nodeId, node in pairs(nodes) do
		if node.c then
			for dirId, dir in pairs(node.c) do
				if dir.connections then
					for i, connection in ipairs(dir.connections) do
						local targetId = ConnectionUtils.GetNodeId(connection)
						local targetNode = nodes[targetId]
						
						if targetNode and type(connection) == "table" then
							local door = createDoorForAreas(node, targetNode)
							if door then
                                -- Populate on owner side
                                if door.owner == node.id then
                                    connection.left = door.left
                                    connection.middle = door.middle
                                    connection.right = door.right
                                    connection.needJump = door.needJump
                                    connection.owner = door.owner
                                    doorsBuilt = doorsBuilt + 1
                                end

                                -- Mirror onto reverse connection so both directions share the same geometry
                                if nodes[targetId] and nodes[targetId].c then
                                    for _, tdir in pairs(nodes[targetId].c) do
                                        if tdir.connections then
                                            for rIndex, revConn in ipairs(tdir.connections) do
                                                local backId = ConnectionUtils.GetNodeId(revConn)
                                                if backId == node.id then
                                                    if type(revConn) ~= "table" then
                                                        -- normalize inline if raw id, and write back
                                                        local norm = ConnectionUtils.NormalizeEntry(revConn)
                                                        tdir.connections[rIndex] = norm
                                                        revConn = norm
                                                    end
                                                    revConn.left = door.left
                                                    revConn.middle = door.middle
                                                    revConn.right = door.right
                                                    revConn.needJump = door.needJump
                                                    revConn.owner = door.owner
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
	
	Log:Info("Built " .. doorsBuilt .. " doors for connections")
end

function ConnectionBuilder.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then return nil end
	
	for dirId, dir in pairs(nodeA.c or {}) do
		if dir.connections then
			for _, connection in ipairs(dir.connections) do
				local targetId = ConnectionUtils.GetNodeId(connection)
				if targetId == nodeB.id then
					return connection
				end
			end
		end
	end
	return nil
end

function ConnectionBuilder.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then return nil end
	
	local connection = ConnectionBuilder.GetConnectionEntry(areaA, areaB)
	if connection and connection.middle then
		return connection.middle
	end
	
	return areaB.pos
end


return ConnectionBuilder

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
		if entry.left then entry.left = Vector3(entry.left.x, entry.left.y, entry.left.z) end
		if entry.middle then entry.middle = Vector3(entry.middle.x, entry.middle.y, entry.middle.z) end
		if entry.right then entry.right = Vector3(entry.right.x, entry.right.y, entry.right.z) end
		return entry
	else
		return { node = entry, cost = 0, left = nil, middle = nil, right = nil }
	end
end

return ConnectionUtils

end)
__bundle_register("MedBot.Navigation.NavLoader", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  NavLoader.lua  ·  Navigation file loading and parsing
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local SourceNav = require("MedBot.Utils.SourceNav")

local Log = Common.Log.new("NavLoader")
Log.Level = 0

local NavLoader = {}

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

local function generateNavFile()
	client.RemoveConVarProtection("sv_cheats")
	client.RemoveConVarProtection("nav_generate")
	client.SetConVar("sv_cheats", "1")
	client.Command("nav_generate", true)
	Log:Info("Generating nav file. Please wait...")
	local delay = 10
	local startTime = os.time()
	repeat
	until os.time() - startTime > delay
end

function NavLoader.LoadFile(navFile)
	local full = "tf/" .. navFile
	local navData, err = tryLoadNavFile(full)
	if not navData and err == "File not found" then
		Log:Warning("Nav file not found: " .. full .. ", attempting to generate it")
		generateNavFile()
		return false
	end
	if not navData then
		Log:Error("Failed to load nav file: " .. (err or "Unknown error"))
		return false
	end
	
	local navNodes = NavLoader.ProcessNavData(navData)
	G.Navigation.nodes = navNodes
	G.Navigation.navMeshUpdated = true
	Log:Info("Navigation loaded: " .. #navData.areas .. " areas")
	return true
end

function NavLoader.LoadNavFile()
	local mf = engine.GetMapName()
	if mf and mf ~= "" then
		return NavLoader.LoadFile(string.gsub(mf, ".bsp", ".nav"))
	else
		Log:Error("No map name available")
		return false
	end
end

function NavLoader.ProcessNavData(navData)
	local navNodes = {}
	for _, area in pairs(navData.areas) do
		local cX = (area.north_west.x + area.south_east.x) / 2
		local cY = (area.north_west.y + area.south_east.y) / 2
		local cZ = (area.north_west.z + area.south_east.z) / 2
		local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
		local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
		local ne = Vector3(area.south_east.x, area.north_west.y, area.north_east_z)
		local sw = Vector3(area.north_west.x, area.south_east.y, area.south_west_z)
		navNodes[area.id] =
			{ pos = Vector3(cX, cY, cZ), id = area.id, c = area.connections, nw = nw, se = se, ne = ne, sw = sw }
	end
	return navNodes
end

return NavLoader

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
__bundle_register("MedBot.Movement.SmartJump", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field
---@class SmartJump
-- Detects when the player should jump to clear obstacles
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Utils.Globals")
local Prediction = require("MedBot.Deprecated.Prediction")

local Log = Common.Log.new("SmartJump")
Log.Level = 0 -- Default log level

-- Utility wrapper to respect debug toggle
local function DebugLog(...)
	if G.Menu.SmartJump and G.Menu.SmartJump.Debug then
		Log:Debug(...)
	end
end

-- SmartJump module
local SmartJump = {}

-- Constants
local GRAVITY = 800 -- Gravity per second squared
local JUMP_FORCE = 277 -- Initial vertical boost for a duck jump
local MAX_JUMP_HEIGHT = Vector3(0, 0, 72) -- Maximum jump height vector
-- Dynamic hitbox calculation using entity bounds
local function GetPlayerHitbox(player)
	local mins = player:GetMins()
	local maxs = player:GetMaxs()
	return { mins, maxs }
end
local MAX_WALKABLE_ANGLE = 45 -- Maximum angle considered walkable

-- State Definitions (matching user's exact logic)
local STATE_IDLE = "STATE_IDLE"
local STATE_PREPARE_JUMP = "STATE_PREPARE_JUMP"
local STATE_CTAP = "STATE_CTAP"
local STATE_ASCENDING = "STATE_ASCENDING"
local STATE_DESCENDING = "STATE_DESCENDING"

-- Initialize SmartJump's own menu settings and state
if not G.Menu.SmartJump then
	G.Menu.SmartJump = {}
end
if G.Menu.SmartJump.Enable == nil then
	G.Menu.SmartJump.Enable = true -- Default to enabled
end
if G.Menu.SmartJump.Debug == nil then
	G.Menu.SmartJump.Debug = false -- Disable debug logs by default
end

-- Initialize jump state (ensure all fields exist)
if not G.SmartJump then
	G.SmartJump = {}
end
if not G.SmartJump.jumpState then
	G.SmartJump.jumpState = STATE_IDLE
end
if not G.SmartJump.SimulationPath then
	G.SmartJump.SimulationPath = {}
end
if not G.SmartJump.PredPos then
	G.SmartJump.PredPos = nil
end
if not G.SmartJump.JumpPeekPos then
	G.SmartJump.JumpPeekPos = nil
end
if not G.SmartJump.HitObstacle then
	G.SmartJump.HitObstacle = false
end
if not G.SmartJump.lastAngle then
	G.SmartJump.lastAngle = nil
end
if not G.SmartJump.stateStartTime then
	G.SmartJump.stateStartTime = 0
end
if not G.SmartJump.lastState then
	G.SmartJump.lastState = nil
end
if not G.SmartJump.lastJumpTime then
	G.SmartJump.lastJumpTime = 0
end

-- Visual debug variables initialized above

-- Function to normalize a vector
local function NormalizeVector(vector)
	local length = vector:Length()
	return length == 0 and nil or vector / length
end

-- Rotate vector by yaw angle
local function RotateVectorByYaw(vector, yaw)
	local rad = math.rad(yaw)
	local cos, sin = math.cos(rad), math.sin(rad)
	return Vector3(cos * vector.x - sin * vector.y, sin * vector.x + cos * vector.y, vector.z)
end

-- Function to check if surface is walkable
local function isSurfaceWalkable(normal)
	local vUp = Vector3(0, 0, 1)
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	return angle < MAX_WALKABLE_ANGLE
end

-- Helper function to check if the player is on the ground
local function isPlayerOnGround(player)
	local pFlags = player:GetPropInt("m_fFlags")
	return (pFlags & FL_ONGROUND) == FL_ONGROUND
end

-- Helper function to check if the player is ducking
local function isPlayerDucking(player)
	return (player:GetPropInt("m_fFlags") & FL_DUCKING) == FL_DUCKING
end

-- Calculate strafe angle (matching user's logic)
local function CalcStrafe(player)
	if not player then
		return 0
	end

	local angle = player:EstimateAbsVelocity():Angles()
	local delta = 0
	if G.SmartJump.lastAngle then
		delta = angle.y - G.SmartJump.lastAngle
		delta = Common.Math.NormalizeAngle(delta)
	end
	G.SmartJump.lastAngle = angle.y
	return delta
end

-- Function to calculate the jump peak (user's exact logic)
local function GetJumpPeak(horizontalVelocityVector, startPos)
	-- Calculate the time to reach the jump peak
	local timeToPeak = JUMP_FORCE / GRAVITY

	-- Calculate horizontal velocity length
	local horizontalVelocity = horizontalVelocityVector:Length()

	-- Calculate distance traveled horizontally during time to peak
	local distanceTravelled = horizontalVelocity * timeToPeak

	-- Calculate peak position vector
	local peakPosVector = startPos + NormalizeVector(horizontalVelocityVector) * distanceTravelled

	-- Calculate direction to peak position
	local directionToPeak = NormalizeVector(peakPosVector - startPos)

	return peakPosVector, directionToPeak
end

-- Smart velocity calculation (user's exact logic + bot movement support)
local function SmartVelocity(cmd, pLocal)
	if not pLocal then
		return Vector3(0, 0, 0)
	end

	-- Calculate the player's movement direction
	local moveDir = Vector3(cmd.forwardmove, -cmd.sidemove, 0)

	-- If the bot is moving and there's no manual input, use the bot's movement direction
	if moveDir:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		-- Convert bot's world movement direction to local movement commands
		local viewAngles = engine.GetViewAngles()
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()

		-- Project bot movement direction onto view forward/right vectors
		local forwardComponent = G.BotMovementDirection:Dot(forward)
		local rightComponent = G.BotMovementDirection:Dot(right)

		-- Create movement vector in command space (note: sidemove is negated in the original code)
		moveDir = Vector3(forwardComponent * 450, -rightComponent * 450, 0) -- 450 is typical max speed
	end

	local viewAngles = engine.GetViewAngles()
	local rotatedMoveDir = RotateVectorByYaw(moveDir, viewAngles.yaw)
	local normalizedMoveDir = NormalizeVector(rotatedMoveDir)
	local vel = pLocal:EstimateAbsVelocity()

	-- Normalize moveDir if its length isn't 0, then ensure velocity matches the intended movement direction
	if moveDir:Length() > 0 then
		local onGround = isPlayerOnGround(pLocal)
		if onGround then
			-- Calculate the intended speed based on input magnitude
			local intendedSpeed = math.max(1, vel:Length()) -- Ensure the speed is at least 1
			-- Adjust the player's velocity to match the intended direction and speed
			vel = normalizedMoveDir * intendedSpeed
		end
	else
		-- If there's no input, return zero velocity
		vel = Vector3(0, 0, 0)
	end
	return vel
end

-- Tick-by-tick movement simulation with proper velocity physics
local function SimulateMovementTick(startPos, velocity, stepHeight)
	local vUp = Vector3(0, 0, 1)
	local vStep = Vector3(0, 0, stepHeight or 18)
	local vHitbox = { Vector3(-24, -24, 0), Vector3(24, 24, 82) }
	local MASK_PLAYERSOLID = 33636363

	local dt = globals.TickInterval()
	local targetPos = startPos + velocity * dt

	-- Step 1: Move up by step height
	local stepUpPos = startPos + vStep

	-- ALWAYS check for jump opportunities first, regardless of wall collision
	local shouldJump = false
	local moveDir = NormalizeVector(velocity)
	if moveDir then
		-- Use fresh copy of current position for jump checks - don't affect simulation
		local jumpCheckPos = Vector3(startPos.x, startPos.y, startPos.z)
		local jumpCheckStepUp = jumpCheckPos + vStep

		-- Check if there's an obstacle ahead that requires jumping
		local forwardTrace =
			engine.TraceHull(jumpCheckStepUp, jumpCheckStepUp + moveDir * 32, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
		if forwardTrace.fraction < 1 then
			-- Found obstacle - move 1 unit forward from hit point, then up 72 units, then trace down
			-- This guarantees we collide with obstacle from above
			local hitPoint = forwardTrace.endpos
			local forwardFromHit = hitPoint + moveDir * 1
			local aboveObstacle = forwardFromHit + Vector3(0, 0, 72)

			-- Trace down from above obstacle to measure height
			local downTrace = engine.TraceHull(
				aboveObstacle,
				forwardFromHit - Vector3(0, 0, 18),
				vHitbox[1],
				vHitbox[2],
				MASK_PLAYERSOLID
			)

			if downTrace.fraction < 1 then
				-- Obstacle detected - simple jump check
				local obstacleHeight = 72 * (1 - downTrace.fraction)

				-- Only jump if obstacle is worth jumping over (>18 units)
				if obstacleHeight > 18 then
					-- Check if we can clear obstacle by jumping
					local jumpPos = forwardFromHit + Vector3(0, 0, 72)

					-- Check if we're clear at jump height
					local clearTrace = engine.TraceHull(jumpPos, jumpPos, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
					if clearTrace.fraction > 0 then
						-- Check if we can land after clearing obstacle
						local landTrace = engine.TraceHull(
							jumpPos,
							jumpPos - Vector3(0, 0, 72),
							vHitbox[1],
							vHitbox[2],
							MASK_PLAYERSOLID
						)

						-- If we can land and surface is walkable
						if landTrace.fraction > 0 and landTrace.fraction < 1 then
							local groundAngle = math.deg(math.acos(landTrace.plane:Dot(Vector3(0, 0, 1))))
							if groundAngle < 45 then -- Walkable surface
								shouldJump = true
							end
						end
					end
				end
			end
		end
	end

	-- Step 2: Forward collision check
	local wallTrace = engine.TraceHull(stepUpPos, targetPos + vStep, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
	local hitWall = wallTrace.fraction < 1
	local finalPos = targetPos
	local newVelocity = velocity

	if hitWall and not shouldJump then
		-- Apply wall sliding logic (matching swing prediction)
		local normal = wallTrace.plane
		local angle = math.deg(math.acos(normal:Dot(vUp)))

		-- Check the wall angle (same as swing prediction)
		if angle > 55 then
			-- Wall too steep - slide along it and lose velocity
			local dot = velocity:Dot(normal)
			newVelocity = velocity - normal * dot
			-- Move only 1 unit into obstacle by default
			finalPos = wallTrace.endpos + normal * 1
		else
			-- Wall angle <= 55 degrees - move 1 unit into obstacle
			finalPos = wallTrace.endpos + wallTrace.plane * 1
		end
	end

	-- Step 3: Ground collision (step down) - only if not jumping, matching swing prediction logic
	if not shouldJump then
		-- Don't step down if we're in-air (simplified check)
		local downStep = vStep

		local groundTrace =
			engine.TraceHull(finalPos + vStep, finalPos - downStep, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
		local onGround = false
		if groundTrace.fraction < 1 then
			-- We'll hit the ground - check ground angle (same as swing prediction)
			local normal = groundTrace.plane
			local angle = math.deg(math.acos(normal:Dot(vUp)))

			-- Check the ground angle (matching swing prediction logic)
			if angle < 45 then
				-- Walkable surface - land on it
				finalPos = groundTrace.endpos
				onGround = true
			elseif angle < 55 then
				-- Too steep to walk but not steep enough to slide - stop movement
				newVelocity = Vector3(0, 0, 0)
				onGround = true
			else
				-- Very steep surface - slide along it
				local dot = newVelocity:Dot(normal)
				newVelocity = newVelocity - normal * dot
				onGround = true
			end
		end

		-- Apply gravity if not on ground (matching swing prediction)
		if not onGround then
			local gravity = 800 -- TF2 gravity
			newVelocity.z = newVelocity.z - gravity * dt
		end
	end

	return finalPos, hitWall, newVelocity, shouldJump
end

-- Check if we can jump over obstacle at current position
local function CanJumpOverObstacle(pos, moveDir, obstacleHeight, pLocal)
	local jumpHeight = 72 -- Max jump height
	local stepHeight = 18 -- Normal step height

	-- Only jump if obstacle is higher than step height (>18 units)
	if obstacleHeight and obstacleHeight > stepHeight then
		-- Obstacle is high enough to require jumping
	else
		return false -- Can step over, no need to jump
	end

	-- Move up jump height first, then move 1 unit into wall
	local jumpPos = pos + Vector3(0, 0, jumpHeight)
	local forwardPos = jumpPos + moveDir * 1

	-- Get dynamic hitbox for local player
	local vHitbox = GetPlayerHitbox(pLocal)
	
	-- Check if we're inside wall at jump height (trace fraction 0 means inside solid)
	local wallCheckTrace = engine.TraceHull(forwardPos, forwardPos, vHitbox[1], vHitbox[2], MASK_PLAYERSOLID)
	if wallCheckTrace.fraction == 0 then
		return false -- Still inside wall at jump height, cannot clear
	end

	-- Check if we can land after clearing obstacle
	local landTrace = engine.TraceHull(
		forwardPos,
		forwardPos - Vector3(0, 0, jumpHeight + 18),
		vHitbox[1],
		vHitbox[2],
		MASK_PLAYERSOLID
	)

	-- If trace fraction is 0, we cannot jump this obstacle
	if landTrace.fraction == 0 then
		return false
	end

	if landTrace.fraction < 1 then
		local landingPos = landTrace.endpos
		local groundAngle = math.deg(math.acos(landTrace.plane:Dot(Vector3(0, 0, 1))))
		if groundAngle < 45 then -- Walkable surface
			return true, landingPos
		end
	end

	return false
end

-- Smart jump detection with improved tick-by-tick simulation
local function SmartJumpDetection(cmd, pLocal)
	-- Basic validation - fail fast
	if not pLocal then
		return false
	end
	if not isPlayerOnGround(pLocal) then
		return false
	end

	local pLocalPos = pLocal:GetAbsOrigin()
	local vHitbox = GetPlayerHitbox(pLocal)

	-- Get move intent direction from cmd
	local moveIntent = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveIntent:Length() == 0 and G.BotIsMoving and G.BotMovementDirection then
		-- Use bot movement direction if no manual input
		local viewAngles = engine.GetViewAngles()
		local forward = viewAngles:Forward()
		local right = viewAngles:Right()
		local forwardComponent = G.BotMovementDirection:Dot(forward)
		local rightComponent = G.BotMovementDirection:Dot(right)
		moveIntent = Vector3(forwardComponent * 450, -rightComponent * 450, 0)
	end

	if moveIntent:Length() == 0 then
		return false
	end

	-- Use move intent direction with current velocity magnitude
	local viewAngles = engine.GetViewAngles()
	local rotatedMoveIntent = RotateVectorByYaw(moveIntent, viewAngles.yaw)
	local moveDir = NormalizeVector(rotatedMoveIntent)
	local currentVel = pLocal:EstimateAbsVelocity()
	local horizontalSpeed = currentVel:Length()

	if horizontalSpeed <= 1 then
		return false
	end

	-- Set initial velocity: move intent direction with current speed
	local initialVelocity = moveDir * horizontalSpeed

	local maxSimTicks = 33 -- ~0.5 seconds

	-- Initialize simulation path for visualization
	G.SmartJump.SimulationPath = { pLocalPos }

	local currentPos = pLocalPos
	local currentVelocity = initialVelocity
	local hitObstacle = false

	-- Tick-by-tick simulation until jump peak time
	for tick = 1, maxSimTicks do
		local newPos, wallHit, newVelocity, shouldJump = SimulateMovementTick(currentPos, currentVelocity, 18)

		-- Store simulation step for visualization
		table.insert(G.SmartJump.SimulationPath, newPos)

		if wallHit then
			hitObstacle = true

			if shouldJump then
				-- Calculate minimum tick needed to achieve obstacle height
				local moveDir = NormalizeVector(currentVelocity)
				if moveDir then
					-- Get actual obstacle height from the simulation tick
					local obstacleHeight = hitObstacle and 72 or 36 -- Default estimation

					-- Calculate minimum time needed to reach obstacle height
					-- Using jump physics: height = 0.5 * gravity * time^2, solve for time
					local gravity = 800 -- TF2 gravity
					local timeToReachHeight = math.sqrt(2 * obstacleHeight / gravity)
					local minJumpTick = math.ceil(timeToReachHeight / globals.TickInterval())

					-- Only jump if current tick <= minimum tick needed
					if tick <= minJumpTick - 2 then
						local jumpHeight = 72
						-- Clamp jump position to max 72 units above original position where jump was initiated
						local maxJumpZ = pLocalPos.z + jumpHeight
						local clampedJumpZ = math.min(currentPos.z + jumpHeight, maxJumpZ)
						local jumpPos = Vector3(currentPos.x, currentPos.y, clampedJumpZ)
						local forwardPos = jumpPos + moveDir * 32 -- Move forward to landing area

						-- Find landing position
						local MASK_PLAYERSOLID = 33636363
						local landTrace = engine.TraceHull(
							forwardPos,
							forwardPos - Vector3(0, 0, jumpHeight + 18),
							vHitbox[1],
							vHitbox[2],
							MASK_PLAYERSOLID
						)

						if landTrace.fraction < 1 then
							G.SmartJump.JumpPeekPos = landTrace.endpos
							-- Update simulation path to show jump arc
							table.insert(G.SmartJump.SimulationPath, jumpPos)
							table.insert(G.SmartJump.SimulationPath, landTrace.endpos)
						end

						G.SmartJump.PredPos = currentPos
						G.SmartJump.HitObstacle = true

						DebugLog(
							"SmartJump: Jump at tick %d (min needed: %d), pos=%s",
							tick,
							minJumpTick,
							tostring(currentPos)
						)
						return true
					else
						-- Set visuals but don't jump yet - too early
						G.SmartJump.PredPos = currentPos
						G.SmartJump.HitObstacle = true
						DebugLog("SmartJump: Too early to jump - tick %d > min needed %d", tick, minJumpTick)
					end
				end
			else
				-- No jump needed (obstacle <=18 units) or can't jump - continue simulation
				DebugLog("SmartJump: No jump needed at tick %d, continuing simulation", tick)
			end
		end

		currentPos = newPos
		currentVelocity = newVelocity
	end

	-- Store final simulation results
	G.SmartJump.PredPos = currentPos
	G.SmartJump.HitObstacle = hitObstacle

	DebugLog("SmartJump: Simulation complete, hitObstacle=%s, finalPos=%s", tostring(hitObstacle), tostring(currentPos))
	return false
end

-- Main SmartJump execution with state machine (user's exact logic with improvements)
function SmartJump.Main(cmd)
	local pLocal = entities.GetLocalPlayer()

	if not pLocal or not pLocal:IsAlive() then
		-- Reset state when player is invalid
		G.SmartJump.jumpState = STATE_IDLE
		G.ShouldJump = false
		G.ObstacleDetected = false
		G.RequestEmergencyJump = false
		return false
	end

	-- Check SmartJump's own enable setting
	if not G.Menu.SmartJump.Enable then
		G.SmartJump.jumpState = STATE_IDLE
		G.ShouldJump = false
		G.ObstacleDetected = false
		G.RequestEmergencyJump = false
		return false
	end

	-- Cache player state
	local onGround = isPlayerOnGround(pLocal)
	local ducking = isPlayerDucking(pLocal)
	local viewOffset = pLocal:GetPropVector("m_vecViewOffset[0]").z

	-- Initialize jump cooldown if not set
	if not G.SmartJump.lastJumpTime then
		G.SmartJump.lastJumpTime = 0
	end

	-- Add cooldown to prevent spam jumping (30 ticks = 0.5 seconds)
	local currentTick = globals.TickCount()
	local jumpCooldown = currentTick - G.SmartJump.lastJumpTime < 30

	-- Handle emergency jump request from stuck detection
	local shouldJump = false
	if G.RequestEmergencyJump and not jumpCooldown then
		shouldJump = true
		G.RequestEmergencyJump = false
		G.LastSmartJumpAttempt = globals.TickCount()
		G.SmartJump.jumpState = STATE_PREPARE_JUMP
		G.SmartJump.lastJumpTime = currentTick
		Log:Info("SmartJump: Processing emergency jump request")
	end

	-- Get bot movement intent for better detection
	local hasMovementIntent = false
	local moveDir = Vector3(cmd.forwardmove, -cmd.sidemove, 0)

	-- Check if bot is actually trying to move
	if moveDir:Length() > 0 or (G.BotIsMoving and G.BotMovementDirection and G.BotMovementDirection:Length() > 0) then
		hasMovementIntent = true
	end

	-- FIXED: Much more conservative edge case detection
	-- Only trigger if ALL conditions are met:
	-- 1. Player is on ground and actually ducking (not just low viewOffset)
	-- 2. Has movement intent (trying to walk somewhere)
	-- 3. Not in jump cooldown
	-- 4. Not already in a jump state
	-- 5. Actually detects an obstacle ahead
	if onGround and ducking and hasMovementIntent and not jumpCooldown and G.SmartJump.jumpState == STATE_IDLE then
		-- Only trigger if SmartJumpDetection actually finds an obstacle
		local obstacleDetected = SmartJumpDetection(cmd, pLocal)
		if obstacleDetected then
			G.SmartJump.jumpState = STATE_PREPARE_JUMP
			G.SmartJump.lastJumpTime = currentTick
			DebugLog("SmartJump: Crouched movement with obstacle detected, initiating jump")
		else
			-- If no obstacle detected while crouched, just stay idle
			DebugLog("SmartJump: Crouched movement but no obstacle detected, staying idle")
		end
	end

	-- State machine for CTAP and jumping (user's exact logic)
	if G.SmartJump.jumpState == STATE_IDLE then
		-- STATE_IDLE: Waiting for jump commands
		-- Only check for smart jump if we have movement intent and no cooldown
		if onGround and hasMovementIntent and not jumpCooldown then
			local smartJumpDetected = SmartJumpDetection(cmd, pLocal)

			if smartJumpDetected or shouldJump then
				G.SmartJump.jumpState = STATE_PREPARE_JUMP
				G.SmartJump.lastJumpTime = currentTick
				DebugLog("SmartJump: IDLE -> PREPARE_JUMP (obstacle detected)")
			end
		end
	elseif G.SmartJump.jumpState == STATE_PREPARE_JUMP then
		-- STATE_PREPARE_JUMP: Start crouching
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		cmd:SetButtons(cmd.buttons & ~IN_JUMP)
		G.SmartJump.jumpState = STATE_CTAP
		DebugLog("SmartJump: PREPARE_JUMP -> CTAP (ducking)")
		return true
	elseif G.SmartJump.jumpState == STATE_CTAP then
		-- STATE_CTAP: Uncrouch and jump
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)
		cmd:SetButtons(cmd.buttons | IN_JUMP)
		G.SmartJump.jumpState = STATE_ASCENDING
		DebugLog("SmartJump: CTAP -> ASCENDING (unduck + jump)")
		return true
	elseif G.SmartJump.jumpState == STATE_ASCENDING then
		-- STATE_ASCENDING: Player is moving upwards
		cmd:SetButtons(cmd.buttons | IN_DUCK)
		local velocity = pLocal:EstimateAbsVelocity()
		if velocity.z <= 0 then
			G.SmartJump.jumpState = STATE_DESCENDING
			DebugLog("SmartJump: ASCENDING -> DESCENDING (velocity.z <= 0)")
		end
		return true
	elseif G.SmartJump.jumpState == STATE_DESCENDING then
		-- STATE_DESCENDING: Player is falling down
		cmd:SetButtons(cmd.buttons & ~IN_DUCK)

		-- Use prediction for bhop detection, but only if we have movement intent
		if hasMovementIntent then
			local WLocal = Common.WPlayer.GetLocal()
			if WLocal then
				local strafeAngle = CalcStrafe(pLocal)
				local predData = Common.TF2.Prediction.Player(WLocal, 1, strafeAngle, nil)
				if predData then
					G.SmartJump.PredPos = predData.pos[1]

					if not predData.onGround[1] and not onGround then
						-- Only bhop if there's still an obstacle and not in cooldown
						if not jumpCooldown then
							local bhopJump = SmartJumpDetection(cmd, pLocal)
							if bhopJump then
								cmd:SetButtons(cmd.buttons & ~IN_DUCK)
								cmd:SetButtons(cmd.buttons | IN_JUMP)
								G.SmartJump.jumpState = STATE_PREPARE_JUMP
								G.SmartJump.lastJumpTime = currentTick
								DebugLog("SmartJump: DESCENDING -> PREPARE_JUMP (bhop with obstacle)")
								return true
							end
						end
					else
						-- Landed safely, return to idle
						G.SmartJump.jumpState = STATE_IDLE
						DebugLog("SmartJump: DESCENDING -> IDLE (landed)")
					end
				end
			else
				-- Fallback without prediction
				if onGround then
					G.SmartJump.jumpState = STATE_IDLE
					DebugLog("SmartJump: DESCENDING -> IDLE (fallback - landed)")
				end
			end
		else
			-- No movement intent, land and return to idle
			if onGround then
				G.SmartJump.jumpState = STATE_IDLE
				DebugLog("SmartJump: DESCENDING -> IDLE (no movement intent)")
			end
		end
		return true
	end

	-- Safety timeout to prevent getting stuck in any state
	if not G.SmartJump.stateStartTime then
		G.SmartJump.stateStartTime = globals.TickCount()
	elseif globals.TickCount() - G.SmartJump.stateStartTime > 132 then -- 2 seconds timeout
		Log:Warn("SmartJump: State timeout, resetting to IDLE from %s", G.SmartJump.jumpState)
		G.SmartJump.jumpState = STATE_IDLE
		G.SmartJump.stateStartTime = nil
	end

	-- Reset state timer when state changes
	local currentState = G.SmartJump.jumpState
	if G.SmartJump.lastState ~= currentState then
		G.SmartJump.stateStartTime = globals.TickCount()
		G.SmartJump.lastState = currentState
	end

	G.ShouldJump = shouldJump
	return shouldJump
end

-- Simplified version that matches Movement.lua usage pattern
function SmartJump.Execute(cmd)
	return SmartJump.Main(cmd)
end

-- Check if emergency jump should be performed
function SmartJump.ShouldEmergencyJump(currentTick, stuckTicks)
	local timeSinceLastSmartJump = currentTick - (G.LastSmartJumpAttempt or 0)
	local timeSinceLastEmergencyJump = currentTick - (G.LastEmergencyJump or 0)

	local shouldEmergency = stuckTicks > 132
		and timeSinceLastSmartJump > 200
		and timeSinceLastEmergencyJump > 300
		and G.ObstacleDetected

	if shouldEmergency then
		G.LastEmergencyJump = currentTick
		Log:Info("Emergency jump triggered - stuck for %d ticks", stuckTicks)
	end

	return shouldEmergency
end

-- Export the GetJumpPeak function for debugging/visualization
SmartJump.GetJumpPeak = GetJumpPeak

-- Standalone CreateMove callback for SmartJump (works independently of MedBot)
local function OnCreateMoveStandalone(cmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	if not G.Menu.SmartJump.Enable then
		return
	end

	-- Run SmartJump state machine
	SmartJump.Main(cmd)

	-- Note: The state machine handles all button inputs directly in SmartJump.Main()
	-- No need to apply additional jump commands here
end

-- Visual debugging (matching user's exact visual logic)
local function OnDrawSmartJump()
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not G.Menu.SmartJump.Enable then
		return
	end
	if G.SmartJump.PredPos then
		-- Draw prediction position (red square)
		local screenPos = client.WorldToScreen(G.SmartJump.PredPos)
		if screenPos then
			draw.Color(255, 0, 0, 255)
			draw.FilledRect(screenPos[1] - 5, screenPos[2] - 5, screenPos[1] + 5, screenPos[2] + 5)
		end
	end

	-- Draw jump peek position (green square)
	if G.SmartJump.JumpPeekPos then
		local screenpeekpos = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if screenpeekpos then
			draw.Color(0, 255, 0, 255)
			draw.FilledRect(screenpeekpos[1] - 5, screenpeekpos[2] - 5, screenpeekpos[1] + 5, screenpeekpos[2] + 5)
		end

		-- Draw 3D hitbox at jump peek position
		local minPoint = vHitbox[1] + G.SmartJump.JumpPeekPos
		local maxPoint = vHitbox[2] + G.SmartJump.JumpPeekPos

		local vertices = {
			Vector3(minPoint.x, minPoint.y, minPoint.z), -- Bottom-back-left
			Vector3(minPoint.x, maxPoint.y, minPoint.z), -- Bottom-front-left
			Vector3(maxPoint.x, maxPoint.y, minPoint.z), -- Bottom-front-right
			Vector3(maxPoint.x, minPoint.y, minPoint.z), -- Bottom-back-right
			Vector3(minPoint.x, minPoint.y, maxPoint.z), -- Top-back-left
			Vector3(minPoint.x, maxPoint.y, maxPoint.z), -- Top-front-left
			Vector3(maxPoint.x, maxPoint.y, maxPoint.z), -- Top-front-right
			Vector3(maxPoint.x, minPoint.y, maxPoint.z), -- Top-back-right
		}

		-- Convert 3D coordinates to 2D screen coordinates
		for i, vertex in ipairs(vertices) do
			vertices[i] = client.WorldToScreen(vertex)
		end

		-- Draw lines between vertices to visualize the box
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
			draw.Color(0, 255, 255, 255) -- Cyan color for hitbox

			-- Draw front face
			draw.Line(vertices[1][1], vertices[1][2], vertices[2][1], vertices[2][2])
			draw.Line(vertices[2][1], vertices[2][2], vertices[3][1], vertices[3][2])
			draw.Line(vertices[3][1], vertices[3][2], vertices[4][1], vertices[4][2])
			draw.Line(vertices[4][1], vertices[4][2], vertices[1][1], vertices[1][2])

			-- Draw back face
			draw.Line(vertices[5][1], vertices[5][2], vertices[6][1], vertices[6][2])
			draw.Line(vertices[6][1], vertices[6][2], vertices[7][1], vertices[7][2])
			draw.Line(vertices[7][1], vertices[7][2], vertices[8][1], vertices[8][2])
			draw.Line(vertices[8][1], vertices[8][2], vertices[5][1], vertices[5][2])

			-- Draw connecting lines
			draw.Line(vertices[1][1], vertices[1][2], vertices[5][1], vertices[5][2])
			draw.Line(vertices[2][1], vertices[2][2], vertices[6][1], vertices[6][2])
			draw.Line(vertices[3][1], vertices[3][2], vertices[7][1], vertices[7][2])
			draw.Line(vertices[4][1], vertices[4][2], vertices[8][1], vertices[8][2])
		end
	end

	-- Draw full simulation path as connected lines
	if G.SmartJump.SimulationPath and #G.SmartJump.SimulationPath > 1 then
		for i = 1, #G.SmartJump.SimulationPath - 1 do
			local currentPos = G.SmartJump.SimulationPath[i]
			local nextPos = G.SmartJump.SimulationPath[i + 1]

			local currentScreen = client.WorldToScreen(currentPos)
			local nextScreen = client.WorldToScreen(nextPos)

			if currentScreen and nextScreen then
				-- Blue gradient - darker at start, brighter at end
				local alpha = math.floor(100 + (i / #G.SmartJump.SimulationPath) * 155)
				draw.Color(0, 150, 255, alpha)
				draw.Line(currentScreen[1], currentScreen[2], nextScreen[1], nextScreen[2])
			end
		end
	end

	-- Draw jump landing position if available
	if G.SmartJump.JumpPeekPos then
		local landingScreen = client.WorldToScreen(G.SmartJump.JumpPeekPos)
		if landingScreen then
			draw.Color(0, 255, 255, 255) -- Cyan for landing
			draw.FilledRect(landingScreen[1] - 4, landingScreen[2] - 4, landingScreen[1] + 4, landingScreen[2] + 4)
		end
	end

	-- Draw current state info
	draw.Color(255, 255, 255, 255)
	draw.Text(10, 100, "SmartJump State: " .. (G.SmartJump.jumpState or "UNKNOWN"))
	if G.SmartJump.HitObstacle then
		draw.Text(10, 120, "Obstacle Detected: YES")
	else
		draw.Text(10, 120, "Obstacle Detected: NO")
	end
end

-- Register callbacks
callbacks.Unregister("CreateMove", "SmartJump.Standalone")
callbacks.Register("CreateMove", "SmartJump.Standalone", OnCreateMoveStandalone)

callbacks.Unregister("Draw", "SmartJump.Visual")
callbacks.Register("Draw", "SmartJump.Visual", OnDrawSmartJump)

return SmartJump

end)
__bundle_register("MedBot.Deprecated.Prediction", function(require, _LOADED, __bundle_register, __bundle_modules)
-- Prediction.lua
-- Utility for simulating movement and timing jumps
local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local Prediction = {}

-- Constants (must match SmartJump)
local GRAVITY = 800 -- units per second squared
local JUMP_FORCE = 277 -- initial vertical boost for duck jump
local HITBOX_MIN = Vector3(-23.99, -23.99, 0)
local HITBOX_MAX = Vector3(23.99, 23.99, 82)
local STEP_HEIGHT = 18 -- walkable step height
local SURFACE_LIMIT_ANGLE = 45 -- max walkable surface angle

local vUp = Vector3(0, 0, 1)

-- Check if a surface normal is walkable
local function isSurfaceWalkable(normal)
	local angle = math.deg(math.acos(normal:Dot(vUp)))
	return angle < SURFACE_LIMIT_ANGLE
end

-- Helper: is player grounded
local function isPlayerOnGround(p)
	local flags = p:GetPropInt("m_fFlags")
	return (flags & FL_ONGROUND) ~= 0
end

-- Simulate walking forward until hitting an obstacle too high to step
-- player: Entity, maxTicks: number of ticks to simulate (e.g. 33)
-- returns: tickIndex, obstacleHeight, surfaceNormal or nil if no obstacle
function Prediction.SimulateWalkUntilObstacle(player, maxTicks)
	local dt = globals.TickInterval()
	local pos = player:GetAbsOrigin()
	local vel = player:EstimateAbsVelocity()

	for tick = 1, maxTicks do
		if isPlayerOnGround(player) then
			-- Predict horizontal position
			local nextPos = pos + Vector3(vel.x, vel.y, 0) * dt
			-- Hull trace at step height
			local trace = engine.TraceHull(
				pos + Vector3(0, 0, STEP_HEIGHT),
				nextPos + Vector3(0, 0, STEP_HEIGHT),
				HITBOX_MIN,
				HITBOX_MAX,
				MASK_PLAYERSOLID_BRUSHONLY
			)
			if trace.fraction < 1 then
				-- Obstacle found
				local obstacleHeight = trace.endpos.z - pos.z
				return tick, obstacleHeight, trace.plane
			end
		end
		-- Advance physics
		pos = pos + vel * dt
		-- Gravity
		vel.z = vel.z - GRAVITY * dt
	end
	return nil
end

-- Simulate movement for jump peak ticks (tick-based like AutoPeek)
-- Returns: walked distance, final position, hit obstacle flag
function Prediction.SimulateMovementForJumpPeak(startPos, direction, speed)
	local peakTime = JUMP_FORCE / GRAVITY
	local peakTicks = math.ceil(peakTime / globals.TickInterval())

	local dirLen = direction:Length()
	if dirLen == 0 then
		return 0, startPos, false
	end
	local stepDir = direction / dirLen -- normalized

	local currentPos = startPos
	local walked = 0
	local stepSize = speed * globals.TickInterval() -- distance per simulated tick
	
	-- Clear and populate simulation path like AutoPeek's LineDrawList
	G.SmartJump.SimulationPath = {}
	table.insert(G.SmartJump.SimulationPath, startPos)
	if stepSize <= 0 then
		stepSize = 8 -- sensible fallback
	end

	-- Simulate for jump peak ticks (tick-based, not distance-based)
	for tick = 1, peakTicks do
		-- STEP 1: Step up 18 units to account for stairs / small ledges
		local stepUpPos = currentPos + Vector3(0, 0, STEP_HEIGHT)

		-- STEP 2: Forward trace from stepped-up position
		local forwardEnd = stepUpPos + stepDir * stepSize
		local fwdTrace = engine.TraceHull(stepUpPos, forwardEnd, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)

		if fwdTrace.fraction < 1.0 then
			-- Hit obstacle - return final position and obstacle flag
			return walked, currentPos, true
		end

		-- STEP 3: Drop down to find ground
		local dropStart = fwdTrace.endpos
		local dropEnd = dropStart - Vector3(0, 0, STEP_HEIGHT + 1)
		local dropTrace = engine.TraceHull(dropStart, dropEnd, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)
		if dropTrace.fraction >= 1.0 then
			-- No ground within step height => would fall; abort
			break
		end

		-- Update position on ground and distance walked
		currentPos = dropTrace.endpos
		walked = walked + stepSize
		
		-- Add current position to simulation path for visualization
		table.insert(G.SmartJump.SimulationPath, currentPos)
	end

	return walked, currentPos, false
end

-- Check if simulation hit obstacle and do SmartJump logic
-- Returns: canJump (bool), obstaclePos (Vector3), landingPos (Vector3) or nil
function Prediction.CheckJumpFromSimulation(finalPos, hitObstacle, moveDir)
	if not hitObstacle then
		return false, nil, nil -- No obstacle found
	end

	-- Do SmartJump logic on final position where obstacle was hit
	local jumpPeakPos = finalPos + Vector3(0, 0, 72) -- 72 units up for jump clearance

	-- Check for head clipping in roof
	local ceilingTrace = engine.TraceHull(finalPos, jumpPeakPos, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)
	if ceilingTrace.fraction == 0 then
		return false, nil, nil -- Head would clip roof
	end

	-- Move 1 unit forward from jump peak (no trace needed)
	local clearancePos = jumpPeakPos + moveDir * 1

	-- Trace down to find landing
	local downTrace = engine.TraceHull(
		clearancePos,
		clearancePos + Vector3(0, 0, -200),
		HITBOX_MIN,
		HITBOX_MAX,
		MASK_PLAYERSOLID_BRUSHONLY
	)
	if downTrace.fraction < 1.0 and isSurfaceWalkable(downTrace.plane) then
		return true, finalPos, downTrace.endpos
	end

	return false, finalPos, nil -- No valid landing
end

-- Compute time to reach a given height with initial jump force
-- returns time (s) or nil if unreachable
function Prediction.TimeToClearHeight(height)
	local V0 = JUMP_FORCE
	local disc = V0 * V0 - 2 * GRAVITY * height
	if disc <= 0 then
		return nil
	end
	return (V0 - math.sqrt(disc)) / GRAVITY
end

-- Compute minimal horizontal distance to clear an obstacle of height h at speed v
-- v: horizontal speed, height: obstacle height
-- returns distance (units) or nil if unreachable
function Prediction.MinJumpDistance(v, height)
	local t = Prediction.TimeToClearHeight(height)
	if not t then
		return nil
	end
	return v * t
end

return Prediction

end)
__bundle_register("MedBot.Utils.Globals", function(require, _LOADED, __bundle_register, __bundle_modules)
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
	NodeTouchDistance = 24,
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
}

-- SmartJump integration
G.ShouldJump = false -- Set by SmartJump module when jump should be performed
G.LastSmartJumpAttempt = 0 -- Track last time SmartJump was attempted
G.LastEmergencyJump = 0 -- Track last emergency jump time
G.ObstacleDetected = false -- Track if obstacle is detected but no jump attempted
G.RequestEmergencyJump = false -- Request emergency jump from stuck detection

-- Bot movement tracking (for SmartJump integration)
G.BotIsMoving = false -- Track if bot is actively moving
G.BotMovementDirection = Vector3(0, 0, 0) -- Bot's intended movement direction

-- Memory management and cache tracking
G.Cache = {
	lastCleanup = 0,
	cleanupInterval = 2000, -- Clean up every 2000 ticks (~30 seconds)
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
}

G.currentState = nil
G.prevState = nil -- Track previous bot state
G.wasManualWalking = false -- Track if user manually walked last tick

-- Function to clean up memory and caches
function G.CleanupMemory()
	local currentTick = globals.TickCount()
	if currentTick - G.Cache.lastCleanup < G.Cache.cleanupInterval then
		return -- Too soon to cleanup
	end

	-- Update memory usage statistics
	local memUsage = collectgarbage("count")
	G.Benchmark.MemUsage = memUsage

	-- NOTE: Fine point caches are kept to avoid expensive re-generation
	-- when garbage collection happens.

	-- Hierarchical pathfinding removed
	G.Navigation.hierarchical = nil

	-- Reset stuck timer if it's been set for too long (prevents infinite stuck states)
	if G.Navigation.stuckStartTick and (currentTick - G.Navigation.stuckStartTick) > 1000 then
		print("Reset stuck timer during cleanup (was stuck for >1000 ticks)")
		G.Navigation.stuckStartTick = nil
		G.Navigation.currentNodeTicks = 0
	end

	-- Force garbage collection if memory usage is high
	local memBefore = memUsage
	if memUsage > 1024 * 1024 then -- More than 1GB
		collectgarbage("collect")
		memUsage = collectgarbage("count")
		G.Benchmark.MemUsage = memUsage
		print(string.format("Force GC: %.2f MB -> %.2f MB", memBefore / 1024, memUsage / 1024))
	end

	G.Cache.lastCleanup = currentTick
end

return G

end)
__bundle_register("MedBot.Bot.HealthLogic", function(require, _LOADED, __bundle_register, __bundle_modules)
--##########################################################################
--  HealthLogic.lua  ·  Bot health management
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local HealthLogic = {}

function HealthLogic.ShouldHeal(pLocal)
	if not pLocal then return false end
	
	local healthPercent = (pLocal:GetHealth() / pLocal:GetMaxHealth()) * 100
	local isHealing = pLocal:InCond(TFCond_Healing)
	local threshold = G.Menu.Main.SelfHealTreshold
	
	return healthPercent < threshold and not isHealing
end

function HealthLogic.HandleSelfHealing(pLocal)
	if not HealthLogic.ShouldHeal(pLocal) then return end
	
	-- Find health pack or healing source
	local players = entities.FindByClass("CTFPlayer")
	for _, player in pairs(players) do
		if player:GetTeamNumber() == pLocal:GetTeamNumber() and 
		   player:GetPropInt("m_iClass") == TF_CLASS_MEDIC and
		   player ~= pLocal then
			G.Targets.Heal = player:GetIndex()
			return
		end
	end
end

return HealthLogic

end)
__bundle_register("MedBot.Bot.CommandHandler", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
Command Handler - Registers and handles console commands for MedBot
Provides debugging and management commands
]]

local G = require("MedBot.Core.Globals")

local CommandHandler = {}

function CommandHandler.register()
	-- All commands temporarily disabled for bundle compatibility
	-- This function will be restored after fixing dependency issues
end

return CommandHandler

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

	-- Current horizontal velocity (ignore Z)
	local vel = player:EstimateAbsVelocity() or Vector3(0, 0, 0)
	vel.z = 0

	-- Predict passive drag to next tick
	local drag = math.max(0, 1 - getGroundFriction() * tick)
	local velNext = vel * drag
	local predicted = Vector3(pos.x + velNext.x * tick, pos.y + velNext.y * tick, pos.z)

	-- Remaining displacement after coast
	local need = dest - predicted
	need.z = 0
	local dist = need:Length()
	if dist < 1.5 then
		cmd:SetForwardMove(0)
		cmd:SetSideMove(0)
		return
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

end)
__bundle_register("MedBot.Bot.PathOptimizer", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[
Path Optimizer - Prevents rubber-banding with smart windowing
Handles node skipping and direct path optimization
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local Navigation = require("MedBot.Navigation")
local ISWalkable = require("MedBot.Navigation.ISWalkable")

local Log = Common.Log.new("PathOptimizer")
local PathOptimizer = {}

-- Skip entire path if goal is directly reachable
function PathOptimizer.skipToGoalIfWalkable(origin, goalPos, path)
    local DEADZONE = 24 -- units
    if not goalPos or not origin then
        return false
    end
    local dist = (goalPos - origin):Length()
    if dist < DEADZONE then
        Navigation.ClearPath()
        G.currentState = G.States.IDLE
        G.lastPathfindingTick = 0
        return true
    end
    -- Only skip if we have a multi-node path AND goal is directly reachable
    -- Never skip on CTF maps to avoid beelining to the wrong flag area
    local mapName = engine.GetMapName():lower()
    if path and #path > 1 and not mapName:find("ctf_") then
        local walkMode = G.Menu.Main.WalkableMode or "Smooth"
        if ISWalkable.Path(origin, goalPos, walkMode) then
            Navigation.ClearPath()
            -- Set a direct path with just the goal as the node
            G.Navigation.path = { { pos = goalPos } }
            G.lastPathfindingTick = 0
            Log:Info("Cleared complex path, moving directly to goal with %s mode (distance: %.1f)", walkMode, dist)
            return true
        end
    end
    return false
end

-- Skip if next node is closer to the player than the current node
function PathOptimizer.skipIfCloser(origin, path)
    if not path or #path < 2 then
        return false
    end
    local curNode, nextNode = path[1], path[2]
    if not (curNode and nextNode and curNode.pos and nextNode.pos) then
        return false
    end
    local distCur = (curNode.pos - origin):Length()
    local distNext = (nextNode.pos - origin):Length()
    if distNext < distCur then
        Navigation.RemoveCurrentNode()
        Navigation.ResetTickTimer()
        return true
    end
    return false
end

-- Skip if we can walk directly to the node after next
function PathOptimizer.skipIfWalkable(origin, path)
    if not path or #path < 3 then
        return false
    end
    local candidate = path[3]
    local walkMode = G.Menu.Main.WalkableMode or "Smooth"
    if #path == 3 then
        walkMode = "Aggressive"
    end
    if candidate and candidate.pos and ISWalkable.Path(origin, candidate.pos, walkMode) then
        Navigation.RemoveCurrentNode()
        Navigation.ResetTickTimer()
        return true
    end
    return false
end

-- Optimize path by trying different skip strategies
function PathOptimizer.optimize(origin, path, goalPos)
    if not G.Menu.Main.Skip_Nodes or not path or #path <= 1 then
        return false
    end

    -- Try to skip directly to the goal if we have a complex path
    if goalPos and #path > 1 then
        if PathOptimizer.skipToGoalIfWalkable(origin, goalPos, path) then
            return true
        end
    end

    -- Only run the heavier skip checks every few ticks to reduce CPU
    local now = globals.TickCount()
    if not G.lastNodeSkipTick then
        G.lastNodeSkipTick = 0
    end
    if (now - G.lastNodeSkipTick) >= 3 then -- run every 3 ticks (~50 ms)
        G.lastNodeSkipTick = now
        -- Skip only when safe with door semantics
        if PathOptimizer.skipIfCloser(origin, path) then
            return true
        elseif PathOptimizer.skipIfWalkable(origin, path) then
            return true
        end
    end

    return false
end

return PathOptimizer

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
local DStar = require("MedBot.Algorithms.DStar")
--local DStar = require("MedBot.Utils.DStar")
local Lib = Common.Lib
local Log = Lib.Utils.Logger.new("MedBot")
Log.Level = 0

-- Constants
local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local DROP_HEIGHT = 144 -- Define your constants outside the function
local Jump_Height = 72 --duck jump height
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable
local GRAVITY = 800 -- Gravity in units per second squared
local MIN_STEP_SIZE = 5 -- Minimum step size in units
local preferredSteps = 10 --prefered number oif steps for simulations
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local TICK_RATE = 66

local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)

-- Add a connection between two nodes
function Navigation.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end
	Node.AddConnection(nodeA, nodeB)
	Node.AddConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end
	Node.RemoveConnection(nodeA, nodeB)
	Node.RemoveConnection(nodeB, nodeA)
	G.Navigation.navMeshUpdated = true
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	-- Use Node module's implementation to avoid duplication
	Node.AddCostToConnection(nodeA, nodeB, cost)
end

--[[
-- Perform a trace hull down from the given position to the ground
---@param position Vector3 The start position of the trace
---@param hullSize table The size of the hull
---@return Vector3 The normal of the ground at that point
local function traceHullDown(position, hullSize)
	local endPos = position - Vector3(0, 0, DROP_HEIGHT) -- Adjust the distance as needed
	local traceResult = engine.TraceHull(position, endPos, hullSize.min, hullSize.max, MASK_PLAYERSOLID_BRUSHONLY)
	return traceResult.plane -- Directly using the plane as the normal
end

-- Perform a trace line down from the given position to the ground
---@param position Vector3 The start position of the trace
---@return Vector3 The hit position
local function traceLineDown(position)
	local endPos = position - Vector3(0, 0, DROP_HEIGHT)
	local traceResult = engine.TraceLine(position, endPos, TRACE_MASK)
	return traceResult.endpos
end

-- Calculate the remaining two corners based on the adjusted corners and ground normal
---@param corner1 Vector3 The first adjusted corner
---@param corner2 Vector3 The second adjusted corner
---@param normal Vector3 The ground normal
---@param height number The height of the rectangle
---@return table The remaining two corners
local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()

	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)

	local function rotateAroundNormal(vector, angle)
		local cosTheta = math.cos(angle)
		local sinTheta = math.sin(angle)
		return Vector3(
			(cosTheta + (1 - cosTheta) * normal.x ^ 2) * vector.x
				+ ((1 - cosTheta) * normal.x * normal.y - normal.z * sinTheta) * vector.y
				+ ((1 - cosTheta) * normal.x * normal.z + normal.y * sinTheta) * vector.z,
			((1 - cosTheta) * normal.x * normal.y + normal.z * sinTheta) * vector.x
				+ (cosTheta + (1 - cosTheta) * normal.y ^ 2) * vector.y
				+ ((1 - cosTheta) * normal.y * normal.z - normal.x * sinTheta) * vector.z,
			((1 - cosTheta) * normal.x * normal.z - normal.y * sinTheta) * vector.x
				+ ((1 - cosTheta) * normal.y * normal.z + normal.x * sinTheta) * vector.y
				+ (cosTheta + (1 - cosTheta) * normal.z ^ 2) * vector.z
		)
	end

	local rotatedHeightVector = rotateAroundNormal(heightVector, math.pi / 2)

	local corner3 = corner1 + rotatedHeightVector * (height / widthLength)
	local corner4 = corner2 + rotatedHeightVector * (height / widthLength)

	return { corner3, corner4 }
end

-- Fixes a node by adjusting its height based on TraceHull and TraceLine results
-- Moves the node 18 units up and traces down to find a new valid position
---@param nodeId integer The index of the node in the Nodes table
---@return Node The fixed node
function Navigation.FixNode(nodeId)
	local nodes = G.Navigation.nodes
	local node = nodes[nodeId]
	if not node or not node.pos then
		print("Invalid node " .. tostring(nodeId) .. ", skipping FixNode")
		return nil
	end
	if node.fixed then
		return node
	end

	local upVector = Vector3(0, 0, 72)
	local downVector = Vector3(0, 0, -72)
	-- Fix center position
	local traceCenter = engine.TraceHull(node.pos + upVector, node.pos + downVector, HULL_MIN, HULL_MAX, TRACE_MASK)
	if traceCenter and traceCenter.fraction > 0 then
		node.pos = traceCenter.endpos
		node.z = traceCenter.endpos.z
	else
		node.pos = node.pos + upVector
		node.z = node.z + 72
	end
	-- Fix two known corners (nw, se) via line traces
	for _, cornerKey in ipairs({ "nw", "se" }) do
		local c = node[cornerKey]
		if c then
			local world = Vector3(c.x, c.y, c.z)
			local trace = engine.TraceLine(world + upVector, world + downVector, TRACE_MASK)
			if trace and trace.fraction < 1 then
				node[cornerKey] = trace.endpos
			else
				node[cornerKey] = world + upVector
			end
		end
	end
	-- Compute remaining corners
	local normal = getGroundNormal(node.pos)
	local height = math.abs(node.se.z - node.nw.z)
	local rem = calculateRemainingCorners(node.nw, node.se, normal, height)
	node.ne = rem[1]
	node.sw = rem[2]
	node.fixed = true
	return node
end

-- Adjust all nodes by fixing their positions and adding missing corners.
function Navigation.FixAllNodes()
	local nodes = Navigation.GetNodes()
	for id in pairs(nodes) do
		Navigation.FixNode(id)
	end
end
]]

function Navigation.Setup()
	if engine.GetMapName() then
		Node.Setup()
		Navigation.ClearPath()
	end
end

-- Get the current path
---@return Node[]|nil
function Navigation.GetCurrentPath()
	return G.Navigation.path
end

-- Clear the current path
function Navigation.ClearPath()
	G.Navigation.path = {}
	G.Navigation.currentNodeIndex = 1
	-- Also clear door/center/goal waypoints to avoid stale movement/visuals
	G.Navigation.waypoints = {}
	G.Navigation.currentWaypointIndex = 1
	-- Clear path traversal history used by stuck analysis
	G.Navigation.pathHistory = {}
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

-- Function to increment the current node ticks
function Navigation.increment_ticks()
	G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
end

-- Function to increment the current node ticks
function Navigation.ResetTickTimer()
	G.Navigation.currentNodeTicks = 0
end

-- Build flexible waypoints: choose optimal door points, skip centers when direct door-to-door is shorter
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
		local a, b = path[i], path[i + 1]
		if a and b and a.pos and b.pos then
			-- Get door entry for current edge
			local entry = Node.GetConnectionEntry(a, b)
			local doorPoint = nil
			
			if entry and (entry.left or entry.middle or entry.right) then
				-- Choose best door point based on distance to destination
				local bestPoint = nil
				local bestDistance = math.huge
				
				for _, point in ipairs({entry.left, entry.middle, entry.right}) do
					if point then
						local distance = (point - b.pos):Length()
						if distance < bestDistance then
							bestDistance = distance
							bestPoint = point
						end
					end
				end
				
				doorPoint = bestPoint
			else
				-- Fallback: use Node helper for door target
				doorPoint = Node.GetDoorTargetPoint(a, b)
			end
			
			if doorPoint then
				-- Check if we should skip area center for direct door-to-door navigation
				local shouldSkipCenter = false
				if i < #path - 1 then -- Not the last edge
					local nextArea = path[i + 2]
					if nextArea then
						local nextEntry = Node.GetConnectionEntry(b, nextArea)
						local nextDoorPoint = nil
						
						if nextEntry and (nextEntry.left or nextEntry.middle or nextEntry.right) then
							nextDoorPoint = nextEntry.middle or nextEntry.left or nextEntry.right
						else
							nextDoorPoint = Node.GetDoorTargetPoint(b, nextArea)
						end
						
						if nextDoorPoint then
							-- Compare distances: door->center->nextDoor vs door->nextDoor
							local viaCenterDist = (doorPoint - b.pos):Length() + (b.pos - nextDoorPoint):Length()
							local directDist = (doorPoint - nextDoorPoint):Length()
							
							-- Skip center if direct path is shorter by meaningful margin
							if directDist < viaCenterDist * 0.8 then
								shouldSkipCenter = true
							end
						end
					end
				end
				
				-- Add door waypoint
				table.insert(G.Navigation.waypoints, {
					kind = "door",
					fromId = a.id,
					toId = b.id,
					pos = doorPoint
				})
				
				-- Add center waypoint only if not skipping
				if not shouldSkipCenter then
					table.insert(G.Navigation.waypoints, { 
						pos = b.pos, 
						kind = "center", 
						areaId = b.id 
					})
				end
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
	-- If we reached a center of the next area, advance the area path too
	if current.kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
		-- path[1] is previous area; popping it moves us into the new area
		Navigation.RemoveCurrentNode()
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
	-- If we skip over a center, reflect area progression
	local current = G.Navigation.waypoints[G.Navigation.currentWaypointIndex or 1]
	if current and current.kind ~= "center" then
		for j = (G.Navigation.currentWaypointIndex or 1), math.min(idx - 1, #wpList) do
			if wpList[j].kind == "center" and G.Navigation.path and #G.Navigation.path > 0 then
				Navigation.RemoveCurrentNode()
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

-- Function to make the player walk to a destination smoothly and stop at the destination
function Navigation.WalkTo(pCmd, pLocal, pDestination)
	local localPos = pLocal:GetAbsOrigin()
	local distVector = pDestination - localPos
	local dist = distVector:Length()
	local currentSpeed = Navigation.GetMaxSpeed(pLocal)

	local distancePerTick = math.max(10, math.min(currentSpeed / TICK_RATE, 450)) --in case we tracvel faster then we are close to target

	if dist > distancePerTick then --if we are further away we walk normaly at max speed
		local result = ComputeMove(pCmd, localPos, pDestination)
		pCmd:SetForwardMove(result.x)
		pCmd:SetSideMove(result.y)
	else
		FastStop(pCmd, pLocal)
	end
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
		-- Try D* as fallback
		Log:Info("Trying D* fallback pathfinding...")
		success, path = pcall(DStar.NormalPath, startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodesSimple)

		if not success then
			Log:Error("D* fallback also crashed: %s", tostring(path))
			G.Navigation.path = nil
			Navigation.pathFailed = true
			Navigation.pathFound = false

			-- Add circuit breaker penalty for this failed connection
			if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
				G.CircuitBreaker.addConnectionFailure(startNode, goalNode)
			end
			return Navigation
		elseif path then
			Log:Info("D* fallback succeeded with %d nodes", #path)
		end
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
		-- Refresh waypoints to reflect current door usage
		Navigation.BuildDoorWaypointsFromPath()
		-- Reset traversed-node history for new path
		G.Navigation.pathHistory = {}
	end

	return Navigation
end

-- A* internal navigation for smooth movement within larger areas
function Navigation.GetInternalPath(startPos, endPos, maxDistance)
	maxDistance = maxDistance or 200 -- Maximum distance to consider internal navigation

	local distance = (endPos - startPos):Length()
	if distance < 50 then
		return nil -- Too close, direct movement is fine
	end

	if distance > maxDistance then
		return nil -- Too far, use regular pathfinding
	end

	-- Hierarchical pathfinding removed - using simplified system

	return nil -- No internal path available
end

-- Find the best exit point from an area towards another area
function Navigation.FindBestAreaExitPoint(currentArea, nextArea, areaInfo)
	if not areaInfo or not areaInfo.edgePoints or #areaInfo.edgePoints == 0 then
		return nil
	end

	local bestPoint = nil
	local minDistance = math.huge

	-- Find edge point closest to the next area
	for _, edgePoint in ipairs(areaInfo.edgePoints) do
		local distance = (edgePoint.pos - nextArea.pos):Length()
		if distance < minDistance then
			minDistance = distance
			bestPoint = edgePoint
		end
	end

	return bestPoint
end

-- Find the best entry point into an area from another area
function Navigation.FindBestAreaEntryPoint(currentArea, prevArea, areaInfo)
	if not areaInfo or not areaInfo.edgePoints or #areaInfo.edgePoints == 0 then
		return nil
	end

	local bestPoint = nil
	local minDistance = math.huge

	-- Find edge point closest to the previous area
	for _, edgePoint in ipairs(areaInfo.edgePoints) do
		local distance = (edgePoint.pos - prevArea.pos):Length()
		if distance < minDistance then
			minDistance = distance
			bestPoint = edgePoint
		end
	end

	return bestPoint
end

return Navigation

end)
__bundle_register("MedBot.Algorithms.DStar", function(require, _LOADED, __bundle_register, __bundle_modules)
local Heap = require("MedBot.Algorithms.Heap")

---@class DStar
local DStar = {}

local function manhattan(a, b)
	return math.abs(a.pos.x - b.pos.x) + math.abs(a.pos.y - b.pos.y)
end

local function isKeyLess(a, b)
	if a[1] < b[1] then
		return true
	elseif a[1] > b[1] then
		return false
	else
		return a[2] < b[2]
	end
end

local INF = math.huge

-- Compute the best path using a minimal D*-Lite style planner.
-- Note: This implementation builds fresh state per call (simple, readable),
-- which is acceptable for our dynamic penalties since we repath frequently.
--
-- adjacentFun must return an array of { node = neighborNode, cost = edgeCost }
function DStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	if not (startNode and goalNode and nodes and adjacentFun) then
		return nil
	end

	-- Safety check: ensure nodes have valid IDs for table keys
	if not startNode.id or not goalNode.id then
		return nil
	end

	-- Build forward successors and reverse predecessors with edge costs
	local successors = {}
	local predecessors = {}

	local function getSuccessors(node)
		-- Use node ID as key instead of node object to avoid metatable issues
		local nodeId = node.id
		if not nodeId then
			return {}
		end

		local succ = successors[nodeId]
		if succ then
			return succ
		end

		local list = {}
		local success, neighbors = pcall(adjacentFun, node, nodes)
		if not success then
			-- If adjacentFun fails, return empty list
			successors[nodeId] = list
			return list
		end

		for _, neighbor in ipairs(neighbors) do
			if neighbor and neighbor.node and neighbor.node.id then
				list[#list + 1] = { node = neighbor.node, cost = neighbor.cost or 1 }
				local neighborId = neighbor.node.id
				if not predecessors[neighborId] then
					predecessors[neighborId] = {}
				end
				predecessors[neighborId][#predecessors[neighborId] + 1] = { node = node, cost = neighbor.cost or 1 }
			end
		end
		successors[nodeId] = list
		return list
	end

	local function getPredecessors(node)
		local nodeId = node.id
		if not nodeId then
			return {}
		end
		return predecessors[nodeId] or {}
	end

	-- State: g and rhs values (use node IDs as keys)
	local g, rhs = {}, {}
	local km = 0 -- No incremental movement handling in this simple version

	local function calculateKey(node)
		local nodeId = node.id
		if not nodeId then
			return { math.huge, math.huge }
		end
		local minGRhs = math.min(g[nodeId] or INF, rhs[nodeId] or INF)
		return { minGRhs + manhattan(startNode, node) + km, minGRhs }
	end

	-- Open list with custom comparator on keys
	local open = Heap.new(function(a, b)
		return isKeyLess(a.key, b.key)
	end)

	-- Track last enqueued key to detect stale entries on pop (use node IDs)
	local enqueuedKey = {}

	local function pushNode(node)
		local nodeId = node.id
		if not nodeId then
			return
		end
		local key = calculateKey(node)
		enqueuedKey[nodeId] = key
		open:push({ node = node, key = key })
	end

	local function updateVertex(u)
		local nodeId = u.id
		if not nodeId then
			return
		end

		if u ~= goalNode then
			local best = INF
			for _, s in ipairs(getSuccessors(u)) do
				local neighborId = s.node.id
				if neighborId then
					local cand = (g[neighborId] or INF) + (s.cost or 1)
					if cand < best then
						best = cand
					end
				end
			end
			rhs[nodeId] = best
		end

		if (g[nodeId] or INF) ~= (rhs[nodeId] or INF) then
			pushNode(u)
		end
	end

	-- Initialize
	local goalId = goalNode.id
	g[goalId] = INF
	rhs[goalId] = 0
	pushNode(goalNode)

	-- Compute shortest path
	local function topKey()
		if open:empty() then
			return { INF, INF }
		end
		local peek = open:peek()
		return peek and peek.key or { INF, INF }
	end

	local function isKeyGreater(a, b)
		return isKeyLess(b, a)
	end

	local function computeShortestPath()
		local iterGuard = 0
		local maxIterations = 100000 -- Reduced from 500000 for faster failure detection

		while
			isKeyGreater(topKey(), calculateKey(startNode))
			or (rhs[startNode.id] or INF) ~= (g[startNode.id] or INF)
		do
			if open:empty() then
				break
			end

			local uRec = open:pop()
			if not uRec or not uRec.node or not uRec.key then
				break
			end

			local u = uRec.node
			local uId = u.id
			if not uId then
				break
			end

			-- Check if entry is stale before declaring local variables
			local isStale = uRec.key[1] ~= (enqueuedKey[uId] and enqueuedKey[uId][1])
				or uRec.key[2] ~= (enqueuedKey[uId] and enqueuedKey[uId][2])

			if not isStale then
				local gU = g[uId] or INF
				local rhsU = rhs[uId] or INF
				local keyU = uRec.key
				local calcU = calculateKey(u)
				if isKeyGreater(keyU, calcU) then
					pushNode(u)
				elseif gU > rhsU then
					g[uId] = rhsU
					for _, p in ipairs(getPredecessors(u)) do
						updateVertex(p.node)
					end
				else
					g[uId] = INF
					updateVertex(u)
					for _, p in ipairs(getPredecessors(u)) do
						updateVertex(p.node)
					end
				end
			end

			iterGuard = iterGuard + 1
			if iterGuard > maxIterations then -- safety guard against infinite loops
				break
			end
		end
	end

	-- Build all successors on-demand during search
	computeShortestPath()

	-- Extract path from start to goal using greedy next-step rule
	local startId = startNode.id
	if (g[startId] or INF) == INF then
		return nil
	end

	local path = { startNode }
	local current = startNode
	local hopGuard = 0
	local maxHops = 5000 -- Reduced from 10000 for faster failure detection

	while current ~= goalNode do
		local bestNeighbor = nil
		local bestScore = INF
		for _, s in ipairs(getSuccessors(current)) do
			local neighborId = s.node.id
			if neighborId then
				local score = (g[neighborId] or INF) + (s.cost or 1)
				if score < bestScore then
					bestScore = score
					bestNeighbor = s.node
				end
			end
		end
		if not bestNeighbor or bestScore == INF then
			return nil
		end
		path[#path + 1] = bestNeighbor
		current = bestNeighbor

		hopGuard = hopGuard + 1
		if hopGuard > maxHops then
			break
		end
	end

	return path
end

return DStar

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
__bundle_register("MedBot.Algorithms.A-Star", function(require, _LOADED, __bundle_register, __bundle_modules)
local Heap = require("MedBot.Algorithms.Heap")

---@class AStar
local AStar = {}

-- Simple Manhattan distance heuristic
local function manhattanDistance(nodeA, nodeB)
	return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

-- Reconstruct path from cameFrom map
local function reconstructPath(cameFrom, current)
	local path = { current }
	while cameFrom[current] do
		current = cameFrom[current]
		table.insert(path, 1, current)
	end
	return path
end

-- Clean, simple A* implementation that works with our data structure
-- adjacentFun returns: { {node = targetNode, cost = connectionCost}, ... }
function AStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	if not startNode or not goalNode or not nodes or not adjacentFun then
		return nil
	end

	-- Safety check: ensure nodes have valid IDs
	if not startNode.id or not goalNode.id then
		return nil
	end

	-- Initialize data structures
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)

	local closedSet = {} -- Track visited nodes
	local gScore = {} -- Cost from start to node
	local fScore = {} -- Total estimated cost (gScore + heuristic)
	local cameFrom = {} -- Path reconstruction

	-- Initialize start node
	gScore[startNode] = 0
	fScore[startNode] = manhattanDistance(startNode, goalNode)
	openSet:push({ node = startNode, fScore = fScore[startNode] })

	local iterations = 0
	local maxIterations = 10000 -- Safety limit

	while not openSet:empty() and iterations < maxIterations do
		iterations = iterations + 1

		-- Get node with lowest fScore
		local currentData = openSet:pop()
		local current = currentData.node

		-- Check if we reached the goal
		if current.id == goalNode.id then
			return reconstructPath(cameFrom, current)
		end

		-- Mark current node as visited
		closedSet[current] = true

		-- Get adjacent nodes with their costs
		local success, neighbors = pcall(adjacentFun, current, nodes)
		if not success then
			-- If adjacency function fails, skip this node
			goto continue
		end

		-- Process each neighbor
		for _, neighborData in ipairs(neighbors) do
			local neighbor = neighborData.node
			local connectionCost = neighborData.cost or 1

			-- Skip if already visited
			if closedSet[neighbor] then
				goto continue_neighbor
			end

			-- Calculate tentative gScore
			local tentativeGScore = gScore[current] + connectionCost

			-- Check if this path is better than previous ones
			if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
				-- This path is better, update it
				cameFrom[neighbor] = current
				gScore[neighbor] = tentativeGScore
				fScore[neighbor] = tentativeGScore + manhattanDistance(neighbor, goalNode)

				-- Add to open set
				openSet:push({ node = neighbor, fScore = fScore[neighbor] })
			end

			::continue_neighbor::
		end

		::continue::
	end

	-- No path found
	return nil
end

return AStar

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
		if
			not failure.isBlocked
			and (currentTick - failure.lastFailTime) > state.blockDuration * 2
		then
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
			blockDuration = state.blockDuration
		}
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
local WorkManager = require("MedBot.WorkManager")
local GoalFinder = require("MedBot.Bot.GoalFinder")
local CircuitBreaker = require("MedBot.Bot.CircuitBreaker")
local ISWalkable = require("MedBot.Navigation.ISWalkable")
local SmartJump = require("MedBot.Movement.SmartJump")

local StateHandler = {}
local Log = Common.Log.new("StateHandler")

function StateHandler.handleUserInput(userCmd)
	if userCmd:GetForwardMove() ~= 0 or userCmd:GetSideMove() ~= 0 then
		G.Navigation.currentNodeTicks = 0
		G.currentState = G.States.IDLE
		G.wasManualWalking = true
		G.BotIsMoving = false
		return true
	end
	return false
end

function StateHandler.handleIdleState()
	G.BotIsMoving = false
    
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
            local walkMode = G.Menu.Main.WalkableMode or "Smooth"
            walkMode = "Aggressive" -- short hops favor aggressive checks
            if ISWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
                Log:Info(
                    "Direct-walk (short hop) with %s, moving immediately (dist: %.1f)",
                    walkMode,
                    distance
                )
                G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
                G.Navigation.goalPos = goalPos
                G.Navigation.goalNodeId = goalNode.id
                G.currentState = G.States.MOVING
                G.lastPathfindingTick = globals.TickCount()
                return
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

    -- Prevent pathfinding spam by limiting frequency
    local currentTick = globals.TickCount()
	if not G.lastPathfindingTick then
		G.lastPathfindingTick = 0
	end

	-- Only allow pathfinding every 60 ticks (1 second)
	if currentTick - G.lastPathfindingTick < 60 then
		return
	end

    -- (nodes were already checked above)

	local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
	if not startNode then
		Log:Warn("Could not find start node")
		return
	end

    if not goalNode then
        goalNode, goalPos = GoalFinder.findGoal("Objective")
    end
    if not goalNode then
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

	-- Avoid pathfinding if we're already at the goal
	if startNode.id == goalNode.id then
		local walkMode = G.Menu.Main.WalkableMode or "Smooth"
		local mapName = engine.GetMapName():lower()

		-- Use aggressive mode for CTF intel objectives  
		if mapName:find("ctf_") then
			local pLocal = G.pLocal.entity
			local myItem = pLocal:GetPropInt("m_hItem")
			if myItem <= 0 then
				walkMode = "Aggressive"
				Log:Info("Using Aggressive mode for CTF intel objective")
			end
		end

		if goalPos and ISWalkable.Path(G.pLocal.Origin, goalPos, walkMode) then
			G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
			G.currentState = G.States.MOVING
			G.lastPathfindingTick = currentTick
			Log:Info("Moving directly to goal with %s mode from goal node %d", walkMode, startNode.id)
		else
			Log:Debug("Already at goal node %d, staying in IDLE", startNode.id)
			G.lastPathfindingTick = currentTick
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

function StateHandler.handleStuckState(userCmd)
	local currentTick = globals.TickCount()

	-- Initialize stuck timer if not set
	if not G.Navigation.stuckStartTick then
		G.Navigation.stuckStartTick = currentTick
	end

	local stuckDuration = currentTick - G.Navigation.stuckStartTick

	-- Circuit breaker logic - prevent infinite loops on blocked connections
	local path = G.Navigation.path
	local shouldForceRepath = false
	local connectionBlocked = false

	if path and #path > 1 then
		local currentNode, nextNode
		local closestIndex, closestDist = 1, math.huge
		local pPos = G.pLocal.Origin
		for i = 1, #path do
			local node = path[i]
			local dist = (node.pos - pPos):Length()
			if dist < closestDist then
				closestDist = dist
				closestIndex = i
			end
		end

		if closestIndex >= #path then
			closestIndex = #path - 1
		end

		if closestIndex >= 1 then
			currentNode = path[closestIndex]
			nextNode = path[closestIndex + 1]
		end

		if currentNode and nextNode and currentNode.id and nextNode.id and currentNode.id ~= nextNode.id then
			if CircuitBreaker.isBlocked(currentNode, nextNode) then
				Log:Warn(
					"Connection %d -> %d is BLOCKED by circuit breaker - forcing immediate repath",
					currentNode.id,
					nextNode.id
				)
				shouldForceRepath = true
				connectionBlocked = true
			end
		end
	end

	-- Repath after being stuck for 3 seconds OR if connection is blocked
	if stuckDuration > 198 or shouldForceRepath then
		if not connectionBlocked and path and #path > 1 then
			-- Add penalties to problematic connection
			local currentNode, nextNode
			local closestIndex, closestDist = 1, math.huge
			local pPos = G.pLocal.Origin
			for i = 1, #path do
				local node = path[i]
				local dist = (node.pos - pPos):Length()
				if dist < closestDist then
					closestDist = dist
					closestIndex = i
				end
			end

			if closestIndex >= #path then
				closestIndex = #path - 1
			end

			if closestIndex >= 1 then
				currentNode = path[closestIndex]
				nextNode = path[closestIndex + 1]
			end

			if currentNode and nextNode and currentNode.id and nextNode.id and currentNode.id ~= nextNode.id then
				if CircuitBreaker.addFailure(currentNode, nextNode) then
					Log:Error(
						"Connection %d -> %d has failed too many times - temporarily BLOCKED",
						currentNode.id,
						nextNode.id
					)
				end
			end
		end

		-- Clear stuck timer and reset navigation
		G.Navigation.stuckStartTick = nil
		Navigation.ResetTickTimer()
		G.currentState = G.States.PATHFINDING
		G.lastPathfindingTick = 0

		if connectionBlocked then
			Log:Info("Clearing current path due to blocked connection")
			Navigation.ClearPath()
		end
	else
		-- Try SmartJump for emergency unstuck after being stuck for a while
		if stuckDuration > 66 and stuckDuration < 132 then -- Between 1-2 seconds
			if SmartJump.Execute(userCmd) then
				Log:Info("Emergency SmartJump executed while stuck")
			end
		end
		
		-- Only switch back to MOVING if we've been stuck for at least 0.5 seconds
		if stuckDuration > 33 then
			G.Navigation.stuckStartTick = nil
			Navigation.ResetTickTimer()
			G.currentState = G.States.MOVING
		end
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
	for _, entity in pairs(G.World.payloads or {}) do
		if entity:IsValid() and entity:GetTeamNumber() == pLocal:GetTeamNumber() then
			local pos = entity:GetAbsOrigin()
			return Navigation.GetClosestNode(pos), pos
		end
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
		return Navigation.GetClosestNode(targetPos), targetPos
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
		local healthNode = Navigation.GetClosestNode(pos)
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
				closestNode = Navigation.GetClosestNode(pos)
				targetPos = pos
			end
		end
	end

	-- If no alive teammates found, but we have a last known position, use that
	if not foundTarget and G.Navigation.lastKnownTargetPosition then
		Log:Info("No alive teammates found, moving to last known position")
		closestNode = Navigation.GetClosestNode(G.Navigation.lastKnownTargetPosition)
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

	-- Check if the work already exists
	if WorkManager.works[identifier] then
		-- Update existing work details (function, delay, args)
		WorkManager.works[identifier].func = func
		WorkManager.works[identifier].delay = delay or 1
		WorkManager.works[identifier].args = args
		WorkManager.works[identifier].wasExecuted = false
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
	if WorkManager.executedWorks < WorkManager.workLimit then
		local entry = WorkManager.works[identifier]
		if not entry.wasExecuted and currentTime - entry.lastExecuted >= entry.delay then
			-- Execute the work
			entry.result = { func(table.unpack(args)) }
			entry.wasExecuted = true
			entry.lastExecuted = currentTime
			WorkManager.executedWorks = WorkManager.executedWorks + 1
			return table.unpack(entry.result)
		end
	end

	-- Return cached result if the work cannot be executed immediately
	local entry = WorkManager.works[identifier]
	return table.unpack(entry.result or {})
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

return WorkManager

end)
return __bundle_require("__root")