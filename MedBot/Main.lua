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
require("MedBot.Bot.SmartJump")
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

	-- Execute SmartJump after walkTo to use same cmd with bot's movement intent
	local SmartJump = require("MedBot.Bot.SmartJump")
	SmartJump.Main(userCmd)

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
