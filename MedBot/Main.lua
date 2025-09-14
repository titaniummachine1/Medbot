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
local SmartJump = require("MedBot.Bot.SmartJump")
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

	-- Use waypoints for precise movement, fallback to path nodes
	local targetPos
	local targetId

	if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
		local currentWaypoint = Navigation.GetCurrentWaypoint()
		if currentWaypoint then
			targetPos = currentWaypoint.pos
			targetId = currentWaypoint.kind == "door" and currentWaypoint.toId
				or currentWaypoint.kind == "center" and currentWaypoint.areaId
				or currentWaypoint.id
		end
	end

	-- Fallback to path node if no waypoint available
	if not targetPos then
		local currentNode = G.Navigation.path[1]
		targetPos = currentNode.pos
		targetId = currentNode.id
	end

	-- Throttled debug about current target
	G.__lastMoveDebugTick = G.__lastMoveDebugTick or 0
	local now = globals.TickCount()
	if now - G.__lastMoveDebugTick > 15 then -- ~0.25s
		local pathLen = #G.Navigation.path
		Log:Debug("MOVING: pathLen=%d targetId=%s", pathLen, tostring(targetId))
		G.__lastMoveDebugTick = now
	end

	if not targetPos then
		Log:Warn("No target position available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	-- Store movement direction for SmartJump
	local LocalOrigin = G.pLocal.Origin
	local direction = targetPos - LocalOrigin
	G.BotMovementDirection = direction:Length() > 0 and (direction / direction:Length()) or Vector3(0, 0, 0)
	G.BotIsMoving = true

	-- Update current target position for visualization
	G.Navigation.currentTargetPos = targetPos

	-- Handle camera rotation
	MovementController.handleCameraRotation(userCmd, targetPos)

	-- Check if we've reached the current target
	local horizontalDist = math.abs(LocalOrigin.x - targetPos.x) + math.abs(LocalOrigin.y - targetPos.y)
	local verticalDist = math.abs(LocalOrigin.z - targetPos.z)

	if (horizontalDist < G.Misc.NodeTouchDistance) and verticalDist <= G.Misc.NodeTouchHeight then
		Log:Debug(
			"Reached target id=%s horiz=%.1f vert=%.1f (touchDist=%d, touchH=%d)",
			tostring(targetId),
			horizontalDist,
			verticalDist,
			G.Misc.NodeTouchDistance,
			G.Misc.NodeTouchHeight
		)

		-- Advance to next waypoint or node
		if G.Navigation.waypoints and #G.Navigation.waypoints > 0 then
			Navigation.AdvanceWaypoint()
			-- If no more waypoints, we're done
			if not Navigation.GetCurrentWaypoint() then
				Navigation.ClearPath()
				Log:Info("Reached end of waypoint path")
				G.currentState = G.States.IDLE
				G.lastPathfindingTick = 0
			end
		else
			-- Fallback to node-based advancement
			Log:Debug("Main.lua node advancement - Skip_Nodes = %s, path length = %d", tostring(G.Menu.Main.Skip_Nodes), #G.Navigation.path)
			if G.Menu.Main.Skip_Nodes then
				-- Only skip nodes if Skip Nodes is enabled
				Log:Debug("Main.lua: Removing current node (Skip Nodes enabled)")
				Navigation.RemoveCurrentNode()
				Navigation.ResetTickTimer()

				if #G.Navigation.path == 0 then
					Navigation.ClearPath()
					Log:Info("Reached end of path")
					G.currentState = G.States.IDLE
					G.lastPathfindingTick = 0
				end
			else
				-- Skip Nodes disabled - don't remove nodes, just clear path when reaching final node
				Log:Debug("Main.lua: Skip Nodes disabled - not removing node")
				if #G.Navigation.path <= 1 then
					Navigation.ClearPath()
					Log:Info("Reached final node (Skip Nodes disabled)")
					G.currentState = G.States.IDLE
					G.lastPathfindingTick = 0
				end
			end
		end
		return
	end

	-- Use superior movement controller
	if now - (G.__lastWalkDebugTick or 0) > 15 then
		local distVec = targetPos - LocalOrigin
		Log:Debug(
			"Walking towards target id=%s dx=%.1f dy=%.1f dz=%.1f (Walking: %s)",
			tostring(targetId),
			distVec.x,
			distVec.y,
			distVec.z,
			G.Menu.Main.EnableWalking and "ON" or "OFF"
		)
		G.__lastWalkDebugTick = now
	end

	-- Only move if walking is enabled
	if G.Menu.Main.EnableWalking then
		MovementController.walkTo(userCmd, G.pLocal.entity, targetPos)
	else
		-- Reset movement if walking is disabled
		userCmd:SetForwardMove(0)
		userCmd:SetSideMove(0)
	end

	-- Execute SmartJump after walkTo to use same cmd with bot's movement intent
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
