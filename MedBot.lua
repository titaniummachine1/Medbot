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
--[[ Annotations ]]
---@alias NavConnection { count: integer, connections: integer[] }
---@alias NavNode { id: integer, x: number, y: number, z: number, c: { [1]: NavConnection, [2]: NavConnection, [3]: NavConnection, [4]: NavConnection } }

--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Navigation = require("MedBot.Navigation")
local WorkManager = require("MedBot.WorkManager")
local SmartJump = require("MedBot.Modules.SmartJump")

require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")
local Lib = Common.Lib

local Notify, Commands, WPlayer = Lib.UI.Notify, Lib.Utils.Commands, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

--[[ Functions ]]
Common.AddCurrentTask("Objective")

local function HealthLogic(pLocal)
	if
		(pLocal:GetHealth() / pLocal:GetMaxHealth()) * 100 < G.Menu.Main.SelfHealTreshold
		and not pLocal:InCond(TFCond_Healing)
	then
		if not G.Current_Tasks[G.Tasks.Health] and G.Menu.Main.shouldfindhealth then
			Log:Info("Switching to health task")
			Common.AddCurrentTask("Health")
			Navigation.ClearPath()
		end
	else
		if G.Current_Tasks[G.Tasks.Health] then
			Log:Info("Health task no longer needed, switching back to objective task")
			Common.RemoveCurrentTask("Health")
			Navigation.ClearPath()
		end
	end
end

local function handleMemoryUsage()
	G.Benchmark.MemUsage = collectgarbage("count")
	if G.Benchmark.MemUsage / 1024 > 450 then
		collectgarbage()
		collectgarbage()
		collectgarbage()

		Log:Info("Trigger GC")
	end
end

-- Initialize current state
G.currentState = G.States.IDLE

-- Function to handle user input
local function handleUserInput(userCmd)
	if userCmd:GetForwardMove() ~= 0 or userCmd:GetSideMove() ~= 0 then
		G.Navigation.currentNodeTicks = 0
		G.currentState = G.States.IDLE
		return true
	end
	return false
end

-- Function to handle the IDLE state
function handleIdleState()
	local currentTask = Common.GetHighestPriorityTask()
	if not currentTask then
		return
	end

	-- Safety check: ensure nodes are available before pathfinding
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, staying in IDLE state")
		return
	end

	local startNode = Navigation.GetClosestNode(G.pLocal.Origin)
	if not startNode then
		Log:Warn("Could not find start node")
		return
	end

	local goalNode = findGoalNode(currentTask)
	if not goalNode then
		Log:Warn("Could not find goal node")
		return
	end

	-- Avoid pathfinding if we're already at the goal
	if startNode.id == goalNode.id then
		Log:Debug("Already at goal node %d, staying in IDLE", startNode.id)
		return
	end

	Log:Info("Generating new path from node %d to node %d", startNode.id, goalNode.id)
	WorkManager.addWork(Navigation.FindPath, { startNode, goalNode }, 33, "Pathfinding")
	G.currentState = G.States.PATHFINDING
end

-- Function to handle the PATHFINDING state
function handlePathfindingState()
	if Navigation.pathFound then
		G.currentState = G.States.MOVING
		Navigation.pathFound = false
	elseif Navigation.pathFailed then
		Log:Warn("Pathfinding failed")
		G.currentState = G.States.IDLE
		Navigation.pathFailed = false
	end
end

-- Function to handle the MOVING state
function handleMovingState(userCmd)
	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Warn("No path available, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	-- Always target the first node in the remaining path
	local currentNode = G.Navigation.path[1]
	if not currentNode then
		Log:Warn("Current node is nil, returning to IDLE state")
		G.currentState = G.States.IDLE
		return
	end

	moveTowardsNode(userCmd, currentNode)

	-- Check if stuck
	if G.Navigation.currentNodeTicks > 66 then
		G.currentState = G.States.STUCK
	end
end

-- Function to handle the STUCK state
function handleStuckState(userCmd)
	local currentTick = globals.TickCount()

	-- Use SmartJump for intelligent obstacle detection
	SmartJump.Main(userCmd)

	-- Apply jump if SmartJump determined it's needed
	if G.ShouldJump and not G.pLocal.entity:InCond(TFCond_Zoomed) and (G.pLocal.flags & FL_ONGROUND) ~= 0 then
		userCmd:SetButtons(userCmd.buttons | IN_JUMP)
		userCmd:SetButtons(userCmd.buttons | IN_DUCK) -- Duck jump for 72 unit height
		Log:Debug("SmartJump triggered in stuck state")
	end

	-- Enhanced emergency jump using SmartJump's intelligence
	if SmartJump.ShouldEmergencyJump(currentTick, G.Navigation.currentNodeTicks) then
		if not G.pLocal.entity:InCond(TFCond_Zoomed) and (G.pLocal.flags & FL_ONGROUND) ~= 0 then
			userCmd:SetButtons(userCmd.buttons & ~IN_DUCK)
			userCmd:SetButtons(userCmd.buttons & ~IN_JUMP)
			userCmd:SetButtons(userCmd.buttons | IN_JUMP)
			Log:Info("Emergency jump in stuck state - SmartJump conditions met")
		end
	end

	if G.Navigation.currentNodeTicks > 264 then
		Log:Warn("Stuck for too long, repathing...")
		-- Add high cost to current connection if we have one
		local path = G.Navigation.path
		if path and #path > 1 then
			local currentNode = path[1]
			local nextNode = path[2]
			if currentNode and nextNode then
				Navigation.AddCostToConnection(currentNode, nextNode, 1000)
				Log:Debug(
					"Added high cost to connection %d -> %d due to prolonged stuck state",
					currentNode.id,
					nextNode.id
				)
			end
		end
		Navigation.ClearPath()
		G.currentState = G.States.IDLE
	else
		G.currentState = G.States.MOVING
	end
end

-- Function to find goal node based on the current task
function findGoalNode(currentTask)
	-- Safety check: ensure nodes are loaded before proceeding
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available, cannot find goal")
		return nil
	end
	local pLocal = G.pLocal.entity
	local mapName = engine.GetMapName():lower()

	local function findPayloadGoal()
		G.World.payloads = entities.FindByClass("CObjectCartDispenser")
		for _, entity in pairs(G.World.payloads) do
			if entity:GetTeamNumber() == pLocal:GetTeamNumber() then
				return Navigation.GetClosestNode(entity:GetAbsOrigin())
			end
		end
	end

	local function findFlagGoal()
		local myItem = pLocal:GetPropInt("m_hItem")
		G.World.flags = entities.FindByClass("CCaptureFlag")
		for _, entity in pairs(G.World.flags) do
			local myTeam = entity:GetTeamNumber() == pLocal:GetTeamNumber()
			if (myItem > 0 and myTeam) or (myItem < 0 and not myTeam) then
				return Navigation.GetClosestNode(entity:GetAbsOrigin())
			end
		end
	end

	local function findHealthGoal()
		local closestDist = math.huge
		local closestNode = nil
		for _, pos in pairs(G.World.healthPacks) do
			local healthNode = Navigation.GetClosestNode(pos)
			if healthNode then
				local dist = (G.pLocal.Origin - pos):Length()
				if dist < closestDist then
					closestDist = dist
					closestNode = healthNode
				end
			end
		end
		return closestNode
	end

	-- Find and follow the closest teammate using FastPlayers
	local function findFollowGoal()
		local localWP = Common.FastPlayers.GetLocal()
		if not localWP then
			return nil
		end
		local origin = localWP:GetRawEntity():GetAbsOrigin()
		local closestDist = math.huge
		local closestNode = nil
		local foundTarget = false

		for _, wp in ipairs(Common.FastPlayers.GetTeammates(true)) do
			local ent = wp:GetRawEntity()
			if ent and ent:IsAlive() then
				foundTarget = true
				local pos = ent:GetAbsOrigin()
				local dist = (pos - origin):Length()
				if dist < closestDist then
					closestDist = dist
					-- Update our memory of where we last saw this target
					G.Navigation.lastKnownTargetPosition = pos
					closestNode = Navigation.GetClosestNode(pos)
				end
			end
		end

		-- If no alive teammates found, but we have a last known position, use that
		if not foundTarget and G.Navigation.lastKnownTargetPosition then
			Log:Info("No alive teammates found, moving to last known position")
			closestNode = Navigation.GetClosestNode(G.Navigation.lastKnownTargetPosition)
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

		return closestNode
	end

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
	return nil
end

-- Function to move towards the current node
function moveTowardsNode(userCmd, node)
	local pLocalWrapped = WPlayer.GetLocal()
	local angles = Lib.Utils.Math.PositionAngles(pLocalWrapped:GetEyePos(), node.pos)
	angles.x = 0

	if G.Menu.Movement.smoothLookAtPath then
		local currentAngles = userCmd.viewangles
		local deltaAngles = { x = angles.x - currentAngles.x, y = angles.y - currentAngles.y }

		deltaAngles.y = ((deltaAngles.y + 180) % 360) - 180

		angles = EulerAngles(
			currentAngles.x + deltaAngles.x * 0.05,
			currentAngles.y + deltaAngles.y * G.Menu.Main.smoothFactor,
			0
		)
	end
	engine.SetViewAngles(angles)

	local LocalOrigin = G.pLocal.Origin
	local horizontalDist = math.abs(LocalOrigin.x - node.pos.x) + math.abs(LocalOrigin.y - node.pos.y)
	local verticalDist = math.abs(LocalOrigin.z - node.pos.z)

	if (horizontalDist < G.Misc.NodeTouchDistance) and verticalDist <= G.Misc.NodeTouchHeight then
		Navigation.RemoveCurrentNode()
		Navigation.ResetTickTimer()

		-- Check if we've reached the end of the path
		if #G.Navigation.path == 0 then
			Navigation.ClearPath()
			Log:Info("Reached end of path")
			G.currentState = G.States.IDLE
		end
	else
		if G.Menu.Main.Skip_Nodes and WorkManager.attemptWork(2, "node skip") then
			local path = G.Navigation.path
			local currentIdx = G.Navigation.currentNodeIndex
			-- Check if we can skip to the next node (index 2)
			if path and #path > 1 then
				local nextNode = path[2] -- Next node in normal order
				if nextNode then
					local nextHorizontalDist = math.abs(LocalOrigin.x - nextNode.pos.x)
						+ math.abs(LocalOrigin.y - nextNode.pos.y)
					local nextVerticalDist = math.abs(LocalOrigin.z - nextNode.pos.z)
					if nextHorizontalDist < horizontalDist and nextVerticalDist <= G.Misc.NodeTouchHeight then
						Log:Info("Skipping to closer node (index 2)")
						Navigation.RemoveCurrentNode()
					end
				end
			end
		elseif G.Menu.Main.Optymise_Path and WorkManager.attemptWork(4, "Optymise Path") then
			Navigation.OptimizePath()
		end

		G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
		Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
	end

	-- Use SmartJump for intelligent obstacle detection and jumping
	SmartJump.Main(userCmd)

	-- Apply jump if SmartJump determined it's needed
	if G.ShouldJump and not G.pLocal.entity:InCond(TFCond_Zoomed) and (G.pLocal.flags & FL_ONGROUND) ~= 0 then
		userCmd:SetButtons(userCmd.buttons | IN_JUMP)
		userCmd:SetButtons(userCmd.buttons | IN_DUCK) -- Duck jump for 72 unit height
	end

	-- Enhanced emergency jump logic using SmartJump intelligence
	if G.pLocal.flags & FL_ONGROUND == 1 or G.pLocal.entity:EstimateAbsVelocity():Length() < 50 then
		local currentTick = globals.TickCount()
		-- Use SmartJump's emergency logic instead of simple timer
		if SmartJump.ShouldEmergencyJump(currentTick, G.Navigation.currentNodeTicks) then
			if not G.pLocal.entity:InCond(TFCond_Zoomed) and (G.pLocal.flags & FL_ONGROUND) ~= 0 then
				userCmd:SetButtons(userCmd.buttons & ~IN_DUCK)
				userCmd:SetButtons(userCmd.buttons & ~IN_JUMP)
				userCmd:SetButtons(userCmd.buttons | IN_JUMP)
				Log:Info("Emergency jump triggered - obstacle detected but SmartJump inactive")
			end
		end

		local path = G.Navigation.path
		local currentIdx = G.Navigation.currentNodeIndex
		if
			path
			and (
				G.Navigation.currentNodeTicks > 264
				or (G.Navigation.currentNodeTicks > 22 and horizontalDist < G.Misc.NodeTouchDistance)
					and WorkManager.attemptWork(66, "pathCheck")
			)
		then
			-- Check if path is blocked
			local currentNode = path[currentIdx] -- Current node (index 1)
			local nextNode = path[currentIdx + 1] -- Next node (index 2)

			if not Navigation.isWalkable(LocalOrigin, currentNode.pos) then
				Log:Warn("Path to current node is blocked, adding high cost to connection and repathing...")
				if currentNode and nextNode then
					-- Add high cost instead of removing connection entirely - pathfinding will avoid but keep as backup
					Navigation.AddCostToConnection(currentNode, nextNode, 1000)
				end
				Navigation.ClearPath()
				Navigation.ResetTickTimer()
				G.currentState = G.States.IDLE
			elseif not WorkManager.attemptWork(5, "pathCheck") then
				Log:Warn("Path is stuck but not blocked, repathing...")
				Navigation.ClearPath()
				Navigation.ResetTickTimer()
				G.currentState = G.States.IDLE
			end
		end
	end
end

-- Main function
---@param userCmd UserCmd
local function OnCreateMove(userCmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		G.currentState = G.States.IDLE
		Navigation.ClearPath()
		return
	end

	-- If bot is disabled via menu, do nothing
	if not G.Menu.Main.Enable then
		Navigation.ClearPath()
		return
	end

	G.pLocal.entity = pLocal
	G.pLocal.flags = pLocal:GetPropInt("m_fFlags")
	G.pLocal.Origin = pLocal:GetAbsOrigin()

	if handleUserInput(userCmd) then
		return
	end --if user is walking

	-- Rearrange the conditions for better performance
	if G.currentState == G.States.MOVING then
		handleMovingState(userCmd)
	elseif G.currentState == G.States.PATHFINDING then
		handlePathfindingState()
	elseif G.currentState == G.States.IDLE then
		handleIdleState()
	elseif G.currentState == G.States.STUCK then
		handleStuckState(userCmd)
	end

	WorkManager.processWorks()
end

---@param ctx DrawModelContext
local function OnDrawModel(ctx)
	if ctx:GetModelName():find("medkit") then
		local entity = ctx:GetEntity()
		G.World.healthPacks[entity:GetIndex()] = entity:GetAbsOrigin()
	end
end

---@param event GameEvent
local function OnGameEvent(event)
	local eventName = event:GetName()

	if eventName == "game_newmap" then
		Log:Info("New map detected, reloading nav file...")
		Navigation.Setup()
	end
end

callbacks.Unregister("CreateMove", "MedBot.CreateMove")
callbacks.Unregister("DrawModel", "MedBot.DrawModel")
callbacks.Unregister("FireGameEvent", "MedBot.FireGameEvent")

callbacks.Register("CreateMove", "MedBot.CreateMove", OnCreateMove)
callbacks.Register("DrawModel", "MedBot.DrawModel", OnDrawModel)
callbacks.Register("FireGameEvent", "MedBot.FireGameEvent", OnGameEvent)

--[[ Commands ]]

Commands.Register("pf_reload", function()
	Navigation.Setup()
end)

Notify.Alert("MedBot loaded!")
if entities.GetLocalPlayer() then
	-- Add safety check to prevent crashes when no map is loaded
	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Navigation.Setup()
	else
		Log:Info("Skipping navigation setup - no valid map loaded")
		-- Initialize empty nodes to prevent crashes
		G.Navigation.nodes = {}
	end
end

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
local G = require("MedBot.Utils.Globals")

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

			G.Menu.Main.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Main.Skip_Nodes)
			TimMenu.NextLine()

			G.Menu.Main.smoothFactor = G.Menu.Main.smoothFactor or 0.1
			G.Menu.Main.smoothFactor = TimMenu.Slider("Smooth Factor", G.Menu.Main.smoothFactor, 0.01, 0.1, 0.01)
			TimMenu.NextLine()

			G.Menu.Main.SelfHealTreshold =
				TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Navigation Section
			TimMenu.BeginSector("Navigation Settings")
			G.Menu.Main.CleanupConnections =
				TimMenu.Checkbox("Cleanup Invalid Connections", G.Menu.Main.CleanupConnections)
			TimMenu.NextLine()

			G.Menu.Main.AllowExpensiveChecks =
				TimMenu.Checkbox("Allow Expensive Walkability Checks", G.Menu.Main.AllowExpensiveChecks or false)
			TimMenu.Tooltip("Enable expensive trace-based walkability validation (rarely needed)")
			TimMenu.NextLine()

			G.Menu.Main.UseHierarchicalPathfinding =
				TimMenu.Checkbox("Use Hierarchical Pathfinding", G.Menu.Main.UseHierarchicalPathfinding or false)
			TimMenu.Tooltip("Generate fine-grained points within areas for more accurate local pathfinding")
			TimMenu.NextLine()

			TimMenu.EndSector()
		elseif G.Menu.Tab == "Visuals" then
			-- Visual Settings Section
			TimMenu.BeginSector("Visual Settings")
			G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
			TimMenu.NextLine()

			G.Menu.Visuals.renderDistance = G.Menu.Visuals.renderDistance or 800
			G.Menu.Visuals.renderDistance = TimMenu.Slider("Render Distance", G.Menu.Visuals.renderDistance, 100, 3000, 100)
			TimMenu.EndSector()

			TimMenu.NextLine()

			-- Node Display Section
			TimMenu.BeginSector("Display Options")
			-- Basic display options
			local basicOptions = {"Show Nodes", "Show Node IDs", "Show Nav Connections", "Show Areas", "Show Fine Points"}
			G.Menu.Visuals.basicDisplay = G.Menu.Visuals.basicDisplay or {true, true, true, true, false}
			G.Menu.Visuals.basicDisplay = TimMenu.Combo("Basic Display", G.Menu.Visuals.basicDisplay, basicOptions)
			TimMenu.NextLine()
			
			-- Update individual settings based on combo selection
			G.Menu.Visuals.drawNodes = G.Menu.Visuals.basicDisplay[1]
			G.Menu.Visuals.drawNodeIDs = G.Menu.Visuals.basicDisplay[2]
			G.Menu.Visuals.showConnections = G.Menu.Visuals.basicDisplay[3]
			G.Menu.Visuals.showAreas = G.Menu.Visuals.basicDisplay[4]
			G.Menu.Visuals.showFinePoints = G.Menu.Visuals.basicDisplay[5]

			-- Fine Point Connection Options (only show if fine points are enabled)
			if G.Menu.Visuals.showFinePoints then
				local connectionOptions = {"Intra-Area Connections", "Inter-Area Connections", "Edge-to-Edge Connections"}
				G.Menu.Visuals.connectionDisplay = G.Menu.Visuals.connectionDisplay or {true, true, true}
				G.Menu.Visuals.connectionDisplay = TimMenu.Combo("Fine Point Connections", G.Menu.Visuals.connectionDisplay, connectionOptions)
				TimMenu.Tooltip("Blue: intra-area, Orange: inter-area, Bright blue: edge-to-edge")
				TimMenu.NextLine()
				
				-- Update individual connection settings
				G.Menu.Visuals.showIntraConnections = G.Menu.Visuals.connectionDisplay[1]
				G.Menu.Visuals.showInterConnections = G.Menu.Visuals.connectionDisplay[2]
				G.Menu.Visuals.showEdgeConnections = G.Menu.Visuals.connectionDisplay[3]
			end
			TimMenu.EndSector()
		end
	end
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule

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
	Origin = Vector3({ 0, 0, 0 }),
	ViewAngles = EulerAngles({ 90, 0, 0 }),
	Viewheight = Vector3({ 0, 0, 75 }),
	VisPos = Vector3({ 0, 0, 75 }),
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
	NodeTouchDistance = 10,
	NodeTouchHeight = 82,
	workLimit = 1,
}

G.Navigation = {
	path = nil,
	nodes = nil,
	currentNodeIndex = 1, -- Current node we're moving towards (1 = first node in path)
	currentNodeTicks = 0,
	FirstAgentNode = 1,
	SecondAgentNode = 2,
	lastKnownTargetPosition = nil, -- Remember last position of follow target
}

-- SmartJump integration
G.ShouldJump = false -- Set by SmartJump module when jump should be performed
G.LastSmartJumpAttempt = 0 -- Track last time SmartJump was attempted
G.LastEmergencyJump = 0 -- Track last emergency jump time
G.ObstacleDetected = false -- Track if obstacle is detected but no jump attempted

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
		Enable = false,
		Skip_Nodes = false, --skips nodes if it can go directly to ones closer to target.
		Optymise_Path = false, --straighten the nodes into segments so you would go in straight line
		OptimizationLimit = 20, --how many nodes ahead to optymise
		shouldfindhealth = true, -- Path to health
		SelfHealTreshold = 45, -- Health percentage to start looking for healthPacks
		smoothFactor = 0.05,
		CleanupConnections = false, -- Cleanup invalid connections during map load (disable to prevent crashes)
		AllowExpensiveChecks = false, -- Allow expensive walkability checks (rarely needed)
		-- Hierarchical pathfinding settings (fixed 24-unit spacing)
		UseHierarchicalPathfinding = false, -- Enable fine-grained points within areas for better accuracy
	},
	Visuals = {
		renderDistance = 800,
		EnableVisuals = true,
		memoryUsage = true,
		-- Combo-based display options
		basicDisplay = {true, true, true, true, false}, -- Show Nodes, Node IDs, Nav Connections, Areas, Fine Points
		connectionDisplay = {true, true, true}, -- Intra-Area, Inter-Area, Edge-to-Edge connections
		-- Individual settings (automatically set by combo selections)
		drawNodes = true, -- Draws all nodes on the map
		drawNodeIDs = true, -- Show node IDs  [[ Used by: MedBot.Visuals ]]
		drawPath = true, -- Draws the path to the current goal
		Objective = true,
		drawCurrentNode = false, -- Draws the current node
		showHidingSpots = true, -- Show hiding spots (areas where health packs are located)  [[ Used by: MedBot.Visuals ]]
		showConnections = true, -- Show connections between nodes  [[ Used by: MedBot.Visuals ]]
		showAreas = true, -- Show area outlines  [[ Used by: MedBot.Visuals ]]
		showFinePoints = false, -- Show fine-grained points within areas
		-- Fine point connection controls
		showIntraConnections = true, -- Show connections within the same area (blue)
		showInterConnections = true, -- Show connections between different areas (orange)
		showEdgeConnections = true, -- Show edge-to-edge connections within areas (bright blue)
	},
	Movement = {
		lookatpath = false, -- Look at where we are walking
		smoothLookAtPath = true, -- Set this to true to enable smooth look at path
		Smart_Jump = true, -- jumps perfectly before obstacle to be at peek of jump height when at colision point
	},
}

return defaultconfig

end)
__bundle_register("MedBot.Utils.Config", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local G = require("MedBot.Utils.Globals")

local Common = require("MedBot.Common")
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
__bundle_register("MedBot.Common", function(require, _LOADED, __bundle_register, __bundle_modules)
---@diagnostic disable: duplicate-set-field, undefined-field
---@class Common
local Common = {}

--[[ Imports ]]
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
Common.Json = require("MedBot.Utils.Json")

-- Globals
local G = require("MedBot.Utils.Globals")

-- FastPlayers and WrappedPlayer utilities
local FastPlayers = require("MedBot.Utils.FastPlayers")
Common.FastPlayers = FastPlayers

local WrappedPlayer = require("MedBot.Utils.WrappedPlayer")
Common.WrappedPlayer = WrappedPlayer

--[[ Utility Functions ]]
--- Normalize a vector
---@param vec Vector3
---@return Vector3
function Common.Normalize(vec)
	return vec / vec:Length()
end

--- Manhattan distance on XY plane
---@param pos1 Vector3
---@param pos2 Vector3
---@return number
function Common.horizontal_manhattan_distance(pos1, pos2)
	return math.abs(pos1.x - pos2.x) + math.abs(pos1.y - pos2.y)
end

--- Add a task to current tasks if not present
---@param taskKey string
function Common.AddCurrentTask(taskKey)
	local priority = G.Tasks[taskKey]
	if priority and not G.Current_Tasks[taskKey] then
		G.Current_Tasks[taskKey] = priority
	end
end

--- Remove a task from current tasks
---@param taskKey string
function Common.RemoveCurrentTask(taskKey)
	G.Current_Tasks[taskKey] = nil
end

--- Get the highest priority task
---@return string
function Common.GetHighestPriorityTask()
	local bestKey, bestPri = nil, math.huge
	for key, pri in pairs(G.Current_Tasks) do
		if pri < bestPri then
			bestPri = pri
			bestKey = key
		end
	end
	return bestKey or "None"
end

--- Check if entity is a valid player
---@param entity Entity The entity to check
---@param checkFriend boolean? Unused; reserved for future friend filtering
---@param checkDormant boolean? Skip if true and entity is dormant
---@param skipEnt Entity? Skip this specific entity (e.g., local player)
---@return boolean
function Common.IsValidPlayer(entity, checkFriend, checkDormant, skipEnt)
	if not entity or not entity:IsValid() or not entity:IsAlive() then
		return false
	end
	if checkDormant and entity:IsDormant() then
		return false
	end
	if skipEnt and entity == skipEnt then
		return false
	end
	return true
end

-- Play UI sound on load and unload
client.Command('play "ui/buttonclickrelease"', true)
local function OnUnload()
	client.Command('play "ui/buttonclickrelease"', true)
end
callbacks.Unregister("Unload", "Common_OnUnload")
callbacks.Register("Unload", "Common_OnUnload", OnUnload)

return Common

end)
__bundle_register("MedBot.Utils.WrappedPlayer", function(require, _LOADED, __bundle_register, __bundle_modules)
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

end)
__bundle_register("MedBot.Utils.FastPlayers", function(require, _LOADED, __bundle_register, __bundle_modules)
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

end)
__bundle_register("MedBot.Visuals", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")

local Visuals = {}

local Lib = Common.Lib
local Notify = Lib.UI.Notify
local Fonts = Lib.UI.Fonts
local tahoma_bold = draw.CreateFont("Tahoma", 12, 800, FONTFLAG_OUTLINE)

--[[ Functions ]]
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	if not corners then
		corners1 = {
			Vector3(-halfSize, -halfSize, -halfSize),
			Vector3(halfSize, -halfSize, -halfSize),
			Vector3(halfSize, halfSize, -halfSize),
			Vector3(-halfSize, halfSize, -halfSize),
			Vector3(-halfSize, -halfSize, halfSize),
			Vector3(halfSize, -halfSize, halfSize),
			Vector3(halfSize, halfSize, halfSize),
			Vector3(-halfSize, halfSize, halfSize),
		}
	end

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
	for _, cornerPos in ipairs(corners1) do
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
	local normalized_direction = Common.Normalize(direction)

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

-- maximum distance to render visuals (in world units)
local RENDER_DISTANCE = 800 -- fallback default; overridden by G.Menu.Visuals.renderDistance

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

	local myPos = me:GetAbsOrigin()
	local currentY = 120
	-- Precompute screen-visible nodes within render distance
	local visibleNodes = {}
	-- use menu-configured distance if present
	local maxDist = G.Menu.Visuals.renderDistance or RENDER_DISTANCE
	for id, node in pairs(G.Navigation.nodes or {}) do
		local dist = (myPos - node.pos):Length()
		if dist <= maxDist then
			local scr = client.WorldToScreen(node.pos)
			if scr then
				visibleNodes[id] = { node = node, screen = scr }
			end
		end
	end
	G.Navigation.currentNodeIndex = G.Navigation.currentNodeIndex or 1 -- Initialize currentNodeIndex if it's nil.
	if G.Navigation.currentNodeIndex == nil then
		return
	end

	if G.Navigation.path then
		-- Visualizing agents
		local agent1Pos = G.Navigation.path[G.Navigation.FirstAgentNode]
			and G.Navigation.path[G.Navigation.FirstAgentNode].pos
		local agent2Pos = G.Navigation.path[G.Navigation.SecondAgentNode]
			and G.Navigation.path[G.Navigation.SecondAgentNode].pos

		if agent1Pos then
			local screenPos1 = client.WorldToScreen(agent1Pos)
			if screenPos1 then
				draw.Color(255, 255, 255, 255) -- White color for the first agent
				Draw3DBox(10, agent1Pos) -- Smaller size for the first agent
			end
		end
	end

	if agent2Pos then
		local screenPos2 = client.WorldToScreen(agent2Pos)
		if screenPos2 then
			draw.Color(0, 255, 0, 255) -- Green color for the second agent
			Draw3DBox(20, agent2Pos) -- Larger size for the second agent
		end
	end

	-- Show connections between nav nodes (colored by directionality)
	if G.Menu.Visuals.showConnections then
		for id, entry in pairs(visibleNodes) do
			local node = entry.node
			for dir = 1, 4 do
				local cDir = node.c[dir]
				if cDir and cDir.connections then
					for _, nid in ipairs(cDir.connections) do
						local otherEntry = visibleNodes[nid]
						if otherEntry then
							local s1, s2 = entry.screen, otherEntry.screen
							-- determine if other->id exists in its connections
							local bidir = false
							local otherNode = otherEntry.node
							for d2 = 1, 4 do
								local otherCDir = otherNode.c[d2]
								if otherCDir and otherCDir.connections then
									for _, backId in ipairs(otherCDir.connections) do
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
							if bidir then
								draw.Color(255, 255, 0, 100)
							else
								draw.Color(255, 0, 0, 70)
							end
							draw.Line(s1[1], s1[2], s2[1], s2[2])
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

	-- Draw fine-grained points within areas (hierarchical pathfinding)
	if G.Menu.Visuals.showFinePoints and G.Menu.Main.UseHierarchicalPathfinding then
		local Node = require("MedBot.Modules.Node")
		
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
									local connectionKey = string.format("%d_%d-%d_%d", 
										point.parentArea, point.id, neighbor.point.parentArea, neighbor.point.id)
									if not drawnInterConnections[connectionKey] then
										draw.Color(255, 165, 0, 180) -- Orange for inter-area connections
										draw.Line(screenPos[1], screenPos[2], neighborScreenPos[1], neighborScreenPos[2])
										drawnInterConnections[connectionKey] = true
									end
								elseif not neighbor.isInterArea then
									-- Intra-area connections with different colors based on type
									local connectionKey = string.format("%d_%d-%d_%d", 
										math.min(point.id, neighbor.point.id), point.parentArea,
										math.max(point.id, neighbor.point.id), neighbor.point.parentArea)
									if not drawnIntraConnections[connectionKey] then
										if point.isEdge and neighbor.point.isEdge and G.Menu.Visuals.showEdgeConnections then
											draw.Color(0, 150, 255, 140) -- Bright blue for edge-to-edge connections
											draw.Line(screenPos[1], screenPos[2], neighborScreenPos[1], neighborScreenPos[2])
											drawnIntraConnections[connectionKey] = true
										elseif G.Menu.Visuals.showIntraConnections then
											draw.Color(0, 100, 200, 60) -- Blue for regular intra-area connections
											draw.Line(screenPos[1], screenPos[2], neighborScreenPos[1], neighborScreenPos[2])
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
					isolatedPoints = isolatedPoints
				})
			end
		end
		
		-- Display statistics on screen
		if #finePointStats > 0 then
			draw.Color(255, 255, 255, 255)
			local statY = currentY + 40
			draw.Text(20, statY, string.format("Fine Points: %d areas with detailed grids", #finePointStats))
			statY = statY + 15
			
			-- Show first few areas with stats
			for i = 1, math.min(3, #finePointStats) do
				local stat = finePointStats[i]
				local text = string.format("  Area %d: %d points (%d edge, %d intra, %d inter, %d isolated)", 
					stat.id, stat.totalPoints, stat.edgePoints, stat.intraConnections, stat.interConnections, stat.isolatedPoints)
				draw.Text(20, statY, text)
				statY = statY + 12
			end
			
			if #finePointStats > 3 then
				draw.Text(20, statY, string.format("  ... and %d more areas", #finePointStats - 3))
			end
		end
	end

	-- Auto path informaton
	if G.Menu.Main.Enable then
		draw.Text(20, currentY, string.format("Current Node: %d", G.Navigation.currentNodeIndex))
		currentY = currentY + 20
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

	-- Draw current path
	if G.Menu.Visuals.drawPath and G.Navigation.path and #G.Navigation.path > 0 then
		draw.Color(255, 255, 255, 255)

		for i = 1, #G.Navigation.path - 1 do
			local n1 = G.Navigation.path[i]
			local n2 = G.Navigation.path[i + 1]
			local node1Pos = n1.pos
			local node2Pos = n2.pos

			local screenPos1 = client.WorldToScreen(node1Pos)
			local screenPos2 = client.WorldToScreen(node2Pos)

			if not screenPos1 or not screenPos2 then
				goto continue
			end

			if node1Pos and node2Pos then
				ArrowLine(node1Pos, node2Pos, 22, 15, false) -- Adjust the size for the perpendicular segment as needed
			end
			::continue::
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
end

--[[ Callbacks ]]
callbacks.Unregister("Draw", "MCT_Draw") -- unregister the "Draw" callback
callbacks.Register("Draw", "MCT_Draw", OnDraw) -- Register the "Draw" callback

return Visuals

end)
__bundle_register("MedBot.Modules.Node", function(require, _LOADED, __bundle_register, __bundle_modules)
--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local SourceNav = require("MedBot.Utils.SourceNav") --[[ Imported by: MedBot.Navigation ]]
local isWalkable = require("MedBot.Modules.ISWalkable") --[[ Imported by: MedBot.Modules.Node ]]
local Log = Common.Log.new("Node")
Log.Level = 0

--[[ Module Declaration ]]
local Node = {}

--[[ Local Variables ]]
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)

--[[ Helper Functions ]]
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

local function processNavData(navData)
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

local function traceHullDown(position)
	-- Trace hull from above down to find ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, TRACE_MASK)
end

local function traceLineDown(position)
	-- Line trace down to adjust corner to ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceLine(startPos, endPos, TRACE_MASK)
end

local function getGroundNormal(position)
	local trace =
		engine.TraceLine(position + GROUND_TRACE_OFFSET_START, position + GROUND_TRACE_OFFSET_END, MASK_BRUSH_ONLY)
	return trace.plane
end

local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()
	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)
	local function rotateAroundNormal(vector, angle)
		local cosT = math.cos(angle)
		local sinT = math.sin(angle)
		return Vector3(
			(cosT + (1 - cosT) * normal.x ^ 2) * vector.x
				+ ((1 - cosT) * normal.x * normal.y - normal.z * sinT) * vector.y
				+ ((1 - cosT) * normal.x * normal.z + normal.y * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.y + normal.z * sinT) * vector.x
				+ (cosT + (1 - cosT) * normal.y ^ 2) * vector.y
				+ ((1 - cosT) * normal.y * normal.z - normal.x * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.z - normal.y * sinT) * vector.x
				+ ((1 - cosT) * normal.y * normal.z + normal.x * sinT) * vector.y
				+ (cosT + (1 - cosT) * normal.z ^ 2) * vector.z
		)
	end
	local rot = rotateAroundNormal(heightVector, math.pi / 2)
	return { corner1 + rot * (height / widthLength), corner2 + rot * (height / widthLength) }
end

--- Get all corner positions of a node
---@param node table The node to get corners from
---@return Vector3[] Array of corner positions
local function getNodeCorners(node)
	local corners = {}
	if node.nw then
		table.insert(corners, node.nw)
	end
	if node.ne then
		table.insert(corners, node.ne)
	end
	if node.se then
		table.insert(corners, node.se)
	end
	if node.sw then
		table.insert(corners, node.sw)
	end
	-- Always include center position
	if node.pos then
		table.insert(corners, node.pos)
	end
	return corners
end

--- Check if two nodes are accessible using optimized three-tier fallback approach
--- Allows going down from any height, but restricts upward movement to 72 units
---@param nodeA table First node (source)
---@param nodeB table Second node (destination)
---@return boolean True if nodes are accessible to each other
local function isNodeAccessible(nodeA, nodeB)
	local heightDiff = nodeB.pos.z - nodeA.pos.z -- Positive = going up, negative = going down

	-- Always allow going downward (falling) regardless of height
	if heightDiff <= 0 then
		return true
	end

	-- For upward movement, check if it's within duck jump height (72 units)
	if heightDiff <= 72 then
		return true -- Fast path: upward movement is within jump height
	end

	-- If upward movement > 72 units, check corners for stairs/ramps
	local cornersA = getNodeCorners(nodeA)
	local cornersB = getNodeCorners(nodeB)

	for _, cornerA in pairs(cornersA) do
		for _, cornerB in pairs(cornersB) do
			local cornerHeightDiff = cornerB.z - cornerA.z
			-- Allow if any corner-to-corner connection is within jump height
			if cornerHeightDiff <= 72 then
				return true -- Medium path: corners indicate possible stairs/ramp
			end
		end
	end

	-- Third pass: Expensive walkability check (only if allowed and previous checks failed)
	if G.Menu.Main.AllowExpensiveChecks then
		return isWalkable.Path(nodeA.pos, nodeB.pos)
	end

	-- If expensive checks are disabled and previous checks failed, assume invalid
	return false
end

--- Remove invalid connections between nodes (simple version to prevent crashes)
---@param nodes table All navigation nodes
local function pruneInvalidConnections(nodes)
	local prunedCount = 0
	local totalChecked = 0

	Log:Info("Starting connection cleanup...")

	for nodeId, node in pairs(nodes) do
		if not node or not node.c then
			goto continue
		end

		-- Check all directions using pairs
		for dir, connectionDir in pairs(node.c) do
			if connectionDir and connectionDir.connections then
				local validConnections = {}

				-- Use pairs to iterate through connections
				for _, targetNodeId in pairs(connectionDir.connections) do
					totalChecked = totalChecked + 1
					local targetNode = nodes[targetNodeId]

					if targetNode then
						-- Use proper accessibility check that considers up/down movement
						if isNodeAccessible(node, targetNode) then
							table.insert(validConnections, targetNodeId)
						else
							prunedCount = prunedCount + 1
						end
					else
						-- Remove connections to non-existent nodes
						prunedCount = prunedCount + 1
					end
				end

				-- Update the connections array
				connectionDir.connections = validConnections
				connectionDir.count = #validConnections
			end
		end

		::continue::
	end

	Log:Info("Connection cleanup complete: %d/%d connections pruned", prunedCount, totalChecked)
end

--[[ Public Module Functions ]]

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
	if not G.Navigation.nodes then
		return nil
	end
	local closest, dist = nil, math.huge
	for _, node in pairs(G.Navigation.nodes) do
		local d = (node.pos - pos):Length()
		if d < dist then
			dist, closest = d, node
		end
	end
	return closest
end

--- Manually trigger connection cleanup (useful for debugging)
function Node.CleanupConnections()
	local nodes = Node.GetNodes()
	if nodes then
		pruneInvalidConnections(nodes)
	else
		Log:Warn("No nodes loaded for cleanup")
	end
end

function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified connection adding
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			table.insert(cDir.connections, nodeB.id)
			cDir.count = cDir.count + 1
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified connection removal
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, v in pairs(cDir.connections) do
				if v == nodeB.id then
					table.remove(cDir.connections, i)
					cDir.count = cDir.count - 1
					break
				end
			end
		end
	end
end

function Node.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified cost addition
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, v in pairs(cDir.connections) do
				if v == nodeB.id then
					cDir.connections[i] = { node = v, cost = cost }
					break
				end
			end
		end
	end
end

function Node.GetAdjacentNodes(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using pairs for connections
	for d, cDir in pairs(node.c) do
		if cDir and cDir.connections then
			for _, cid in pairs(cDir.connections) do
				local targetNode = nodes[cid]
				if targetNode and targetNode.pos then
					-- Use centralized accessibility check
					if isNodeAccessible(node, targetNode) then
						table.insert(adjacent, targetNode)
					end
				end
			end
		end
	end
	return adjacent
end

function Node.LoadFile(navFile)
	local full = "tf/" .. navFile
	local navData, err = tryLoadNavFile(full)
	if not navData and err == "File not found" then
		Log:Warn("Nav file not found, attempting to generate...")
		generateNavFile()
		navData, err = tryLoadNavFile(full)
		if not navData then
			Log:Error("Failed to load or parse generated nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		elseif not navData then
			Log:Error("Failed to load nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		end
	end

	local navNodes = processNavData(navData)
	Node.SetNodes(navNodes)

	-- Fix: Count nodes properly for hash table
	local nodeCount = 0
	for _ in pairs(navNodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Successfully loaded %d navigation nodes", nodeCount)

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		pruneInvalidConnections(navNodes)
	else
		Log:Info("Connection cleanup is disabled in settings")
	end

	return true
end

function Node.LoadNavFile()
	local mf = engine.GetMapName()
	if mf and mf ~= "" then
		Node.LoadFile(string.gsub(mf, ".bsp", ".nav"))
	else
		Log:Warn("No map name available for nav file loading")
		Node.SetNodes({})
	end
end

function Node.Setup()
	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Log:Info("Setting up navigation for map: %s", mapName)
		Node.LoadNavFile()

		-- Automatically generate hierarchical network after loading nav file
		local nodes = Node.GetNodes()
		if nodes and next(nodes) then
			Log:Info("Auto-generating hierarchical network...")
			Node.GenerateHierarchicalNetwork(50) -- Process up to 50 areas
		else
			Log:Warn("No nodes loaded, skipping hierarchical network generation")
		end
	else
		Log:Info("No valid map loaded, initializing empty navigation nodes")
		-- Initialize empty nodes table to prevent crashes when no map is loaded
		Node.SetNodes({})
	end
end

--[[ Hierarchical Pathfinding Support ]]

--- Calculate Z coordinate on the plane defined by the 4 corners of the nav area
---@param x number X coordinate
---@param y number Y coordinate
---@param nw Vector3 North-west corner
---@param ne Vector3 North-east corner
---@param se Vector3 South-east corner
---@param sw Vector3 South-west corner
---@return number Z coordinate on the plane
local function calculateZOnPlane(x, y, nw, ne, se, sw)
	-- Use bilinear interpolation to find Z on the plane defined by 4 corners
	local width = se.x - nw.x
	local height = se.y - nw.y

	if width == 0 or height == 0 then
		return nw.z -- Fallback to corner Z if area is degenerate
	end

	-- Normalize coordinates (0,0) to (1,1)
	local u = (x - nw.x) / width
	local v = (y - nw.y) / height

	-- Clamp to valid range
	u = math.max(0, math.min(1, u))
	v = math.max(0, math.min(1, v))

	-- Bilinear interpolation
	local z1 = nw.z * (1 - u) + ne.z * u -- North edge interpolation
	local z2 = sw.z * (1 - u) + se.z * u -- South edge interpolation
	local z = z1 * (1 - v) + z2 * v -- Final interpolation

	return z
end

--- Generate a grid of fine-grained points within a nav area using fixed 24-unit spacing
---@param area table The nav area to generate points for
---@return table[] Array of point objects with pos, neighbors, id, and isEdge flag
local function generateAreaPoints(area)
	local GRID_SPACING = 24 -- Fixed 24-unit spacing as requested

	if not area.nw or not area.ne or not area.se or not area.sw then
		-- Fallback to center point if corners are missing
		Log:Warn("Area %d missing corners, using center point", area.id or 0)
		return { { pos = area.pos, neighbors = {}, id = 1, parentArea = area.id, isEdge = true } }
	end

	local points = {}
	local nw, ne, se, sw = area.nw, area.ne, area.se, area.sw

	-- Calculate actual area bounds (min/max coordinates)
	local minX = math.min(nw.x, ne.x, se.x, sw.x)
	local maxX = math.max(nw.x, ne.x, se.x, sw.x)
	local minY = math.min(nw.y, ne.y, se.y, sw.y)
	local maxY = math.max(nw.y, ne.y, se.y, sw.y)

	-- Calculate area dimensions
	local width = maxX - minX
	local height = maxY - minY

	-- Skip if area is too small for even one grid point
	if width < GRID_SPACING or height < GRID_SPACING then
		local centerZ = calculateZOnPlane(area.pos.x, area.pos.y, nw, ne, se, sw)
		Log:Debug("Area %d too small for 24-unit grid, using center point", area.id or 0)
		return {
			{
				pos = Vector3(area.pos.x, area.pos.y, centerZ),
				neighbors = {},
				id = 1,
				parentArea = area.id,
				isEdge = true,
			},
		}
	end

	-- Calculate number of grid points that fit perfectly
	local gridPointsX = math.floor(width / GRID_SPACING) + 1
	local gridPointsY = math.floor(height / GRID_SPACING) + 1

	-- Generate ALL points covering the whole plane with 24-unit spacing
	local allPoints = {}
	for i = 0, gridPointsX - 1 do
		for j = 0, gridPointsY - 1 do
			local pointX = minX + i * GRID_SPACING
			local pointY = minY + j * GRID_SPACING
			local pointZ = calculateZOnPlane(pointX, pointY, nw, ne, se, sw)

			table.insert(allPoints, {
				pos = Vector3(pointX, pointY, pointZ),
				neighbors = {},
				id = #allPoints + 1,
				parentArea = area.id,
				isEdge = false,
				gridX = i,
				gridY = j,
			})
		end
	end

	-- FIRST PASS: Remove edge points (points on the boundary of the grid)
	for _, point in pairs(allPoints) do
		local isOnBoundary = (
			point.gridX == 0
			or point.gridX == gridPointsX - 1
			or point.gridY == 0
			or point.gridY == gridPointsY - 1
		)
		if not isOnBoundary then
			table.insert(points, point)
		end
	end

	-- SECOND PASS: Mark new boundary points as edges for later calculations
	if #points > 1 then
		-- Find the new min/max grid coordinates after removing boundary
		local minGridX, maxGridX = math.huge, -math.huge
		local minGridY, maxGridY = math.huge, -math.huge

		for _, point in pairs(points) do
			minGridX = math.min(minGridX, point.gridX)
			maxGridX = math.max(maxGridX, point.gridX)
			minGridY = math.min(minGridY, point.gridY)
			maxGridY = math.max(maxGridY, point.gridY)
		end

		-- Mark points that are now on the new boundary as edges
		for _, point in pairs(points) do
			point.isEdge = (
				point.gridX == minGridX
				or point.gridX == maxGridX
				or point.gridY == minGridY
				or point.gridY == maxGridY
			)
		end
	end

	-- Re-assign IDs after filtering
	for i, point in pairs(points) do
		point.id = i
	end

	-- If no points generated, add center point
	if #points == 0 then
		local centerZ = calculateZOnPlane(area.pos.x, area.pos.y, nw, ne, se, sw)
		table.insert(points, {
			pos = Vector3(area.pos.x, area.pos.y, centerZ),
			neighbors = {},
			id = 1,
			parentArea = area.id,
			isEdge = true, -- Mark center point as edge for small areas so they can connect
		})
		Log:Debug("Added fallback center point for area %d (marked as edge)", area.id or 0)
	end

	Log:Debug(
		"Generated %d points for area %d (removed boundary, marked %d as edges)",
		#points,
		area.id or 0,
		#points > 0
				and (function()
					local edgeCount = 0
					for _, p in pairs(points) do
						if p.isEdge then
							edgeCount = edgeCount + 1
						end
					end
					return edgeCount
				end)()
			or 0
	)
	return points
end

--- Add internal connections within an area after points are generated
---@param points table[] Array of points in the area
local function addInternalConnections(points)
	local GRID_SPACING = 24
	local connectionsAdded = 0

	-- Add connections between ALL remaining points (not just adjacent grid points)
	for _, pointA in pairs(points) do
		for _, pointB in pairs(points) do
			if pointA.id ~= pointB.id then
				local distance = (pointA.pos - pointB.pos):Length()

				-- Connect to immediate neighbors and diagonals
				if distance <= GRID_SPACING * 1.5 then -- Allow for diagonal connections
					table.insert(pointA.neighbors, { point = pointB, cost = distance, isInterArea = false })
					connectionsAdded = connectionsAdded + 1
				end
			end
		end
	end

	-- Ensure all points have at least one connection (connectivity guarantee)
	for _, point in pairs(points) do
		if #point.neighbors == 0 then
			-- Find the closest point and force a connection
			local closestPoint = nil
			local closestDistance = math.huge
			for _, otherPoint in pairs(points) do
				if otherPoint.id ~= point.id then
					local distance = (point.pos - otherPoint.pos):Length()
					if distance < closestDistance then
						closestDistance = distance
						closestPoint = otherPoint
					end
				end
			end
			if closestPoint then
				table.insert(point.neighbors, { point = closestPoint, cost = closestDistance, isInterArea = false })
				table.insert(closestPoint.neighbors, { point = point, cost = closestDistance, isInterArea = false })
				connectionsAdded = connectionsAdded + 2
				Log:Debug(
					"Force-connected isolated point %d to point %d in area %d",
					point.id,
					closestPoint.id,
					point.parentArea
				)
			end
		end
	end

	return connectionsAdded
end

--- Build hierarchical data structure for HPA* pathfinding
---@param processedAreas table Areas with their fine points and connections
local function buildHierarchicalStructure(processedAreas)
	-- Initialize hierarchical structure in globals
	if not G.Navigation.hierarchical then
		G.Navigation.hierarchical = {}
	end

	G.Navigation.hierarchical.areas = {}
	G.Navigation.hierarchical.edgePoints = {} -- Global registry of edge points for fast lookup

	local totalEdgePoints = 0
	local totalInterConnections = 0

	-- Process each area and build the hierarchical structure
	for areaId, data in pairs(processedAreas) do
		local areaInfo = {
			id = areaId,
			area = data.area,
			points = data.points,
			edgePoints = {}, -- Points on the boundary of this area
			internalPoints = {}, -- Points inside this area
			interAreaConnections = {}, -- Connections to other areas
		}

		-- Categorize points as edge or internal
		for _, point in pairs(data.points) do
			if point.isEdge then
				table.insert(areaInfo.edgePoints, point)
				-- Add to global edge point registry with area reference
				G.Navigation.hierarchical.edgePoints[point.id .. "_" .. areaId] = {
					point = point,
					areaId = areaId,
				}
				totalEdgePoints = totalEdgePoints + 1
			else
				table.insert(areaInfo.internalPoints, point)
			end

			-- Count inter-area connections
			for _, neighbor in pairs(point.neighbors) do
				if neighbor.isInterArea then
					totalInterConnections = totalInterConnections + 1
					-- Store inter-area connection info
					table.insert(areaInfo.interAreaConnections, {
						fromPoint = point,
						toPoint = neighbor.point,
						toArea = neighbor.point.parentArea,
						cost = neighbor.cost,
					})
				end
			end
		end

		G.Navigation.hierarchical.areas[areaId] = areaInfo
		Log:Debug(
			"Area %d: %d edge points, %d internal points, %d inter-area connections",
			areaId,
			#areaInfo.edgePoints,
			#areaInfo.internalPoints,
			#areaInfo.interAreaConnections
		)
	end

	Log:Info(
		"Built hierarchical structure: %d total edge points, %d inter-area connections",
		totalEdgePoints,
		totalInterConnections
	)
end

--- Connect edge points between two adjacent areas using 1-D monotone greedy matching
---@param areaA table First area
---@param areaB table Second area
---@param pointsA table[] Fine points from area A
---@param pointsB table[] Fine points from area B
---@return number Number of connections created
local function connectAdjacentAreas(areaA, areaB, pointsA, pointsB)
	local connections = 0

	-- Verify these areas are actually neighbors using the nav mesh connections
	local areNeighbors = false
	if areaA.c then
		for dir = 1, #areaA.c do
			local connDir = areaA.c[dir]
			if connDir and connDir.connections then
				for _, connectedAreaId in ipairs(connDir.connections) do
					if connectedAreaId == areaB.id then
						areNeighbors = true
						break
					end
				end
			end
			if areNeighbors then
				break
			end
		end
	end

	if not areNeighbors then
		return 0
	end

	-- Get edge points from both areas
	local edgePointsA = {}
	local edgePointsB = {}

	for _, point in ipairs(pointsA) do
		if point.isEdge then
			table.insert(edgePointsA, point)
		end
	end

	for _, point in ipairs(pointsB) do
		if point.isEdge then
			table.insert(edgePointsB, point)
		end
	end

	if #edgePointsA == 0 or #edgePointsB == 0 then
		return 0
	end

	-- Determine shared boundary orientation (horizontal vs vertical)
	-- Simple heuristic: if areas overlap more in X than Y, it's a horizontal boundary
	local minXA, maxXA = math.huge, -math.huge
	local minYA, maxYA = math.huge, -math.huge
	local minXB, maxXB = math.huge, -math.huge
	local minYB, maxYB = math.huge, -math.huge

	for _, point in ipairs(edgePointsA) do
		minXA, maxXA = math.min(minXA, point.pos.x), math.max(maxXA, point.pos.x)
		minYA, maxYA = math.min(minYA, point.pos.y), math.max(maxYA, point.pos.y)
	end
	for _, point in ipairs(edgePointsB) do
		minXB, maxXB = math.min(minXB, point.pos.x), math.max(maxXB, point.pos.x)
		minYB, maxYB = math.min(minYB, point.pos.y), math.max(maxYB, point.pos.y)
	end

	local overlapX = math.min(maxXA, maxXB) - math.max(minXA, minXB)
	local overlapY = math.min(maxYA, maxYB) - math.max(minYA, minYB)
	local isHorizontal = overlapX >= overlapY

	-- Project edge points onto 1D boundary line and sort
	local projectedA = {}
	local projectedB = {}

	for _, point in ipairs(edgePointsA) do
		local t = isHorizontal and point.pos.x or point.pos.y
		table.insert(projectedA, { point = point, t = t })
	end
	for _, point in ipairs(edgePointsB) do
		local t = isHorizontal and point.pos.x or point.pos.y
		table.insert(projectedB, { point = point, t = t })
	end

	-- Sort by position along boundary
	table.sort(projectedA, function(a, b)
		return a.t < b.t
	end)
	table.sort(projectedB, function(a, b)
		return a.t < b.t
	end)

	-- Monotone greedy matching - no crossings, optimal pairing
	local i, j = 1, 1
	while i <= #projectedA and j <= #projectedB do
		local pointA = projectedA[i].point
		local pointB = projectedB[j].point

		-- Apply height restriction (72 units max difference)
		local heightDiff = math.abs(pointA.pos.z - pointB.pos.z)
		if heightDiff <= 72 then
			local distance = (pointA.pos - pointB.pos):Length()
			table.insert(pointA.neighbors, { point = pointB, cost = distance, isInterArea = true })
			table.insert(pointB.neighbors, { point = pointA, cost = distance, isInterArea = true })
			connections = connections + 1
		end

		-- Advance the index of the list with fewer remaining elements
		if (#projectedA - i) < (#projectedB - j) then
			i = i + 1
		else
			j = j + 1
		end
	end

	Log:Info("Created %d inter-area connections between areas %d and %d", connections, areaA.id, areaB.id)
	return connections
end

--- Generate fine-grained points for a specific nav area and cache them (no parameters for spacing)
---@param areaId number The area ID to generate points for
---@return table[]|nil Array of points or nil if area not found
function Node.GenerateAreaPoints(areaId)
	local nodes = Node.GetNodes()
	if not nodes or not nodes[areaId] then
		return nil
	end

	local area = nodes[areaId]
	if not area.finePoints then
		-- Generate points with fixed 24-unit spacing
		area.finePoints = generateAreaPoints(area)

		-- Add internal connections after point generation
		local connectionsAdded = addInternalConnections(area.finePoints)

		Log:Info(
			"Generated %d fine points for area %d with %d internal connections",
			#area.finePoints,
			areaId,
			connectionsAdded
		)
	end

	return area.finePoints
end

--- Get fine-grained points for an area, generating them if needed
---@param areaId number The area ID
---@return table[]|nil Array of points or nil if area not found
function Node.GetAreaPoints(areaId)
	local nodes = Node.GetNodes()
	if not nodes or not nodes[areaId] then
		return nil
	end

	local area = nodes[areaId]
	if not area.finePoints then
		return Node.GenerateAreaPoints(areaId)
	end

	return area.finePoints
end

--- Find the closest fine point within an area to a given position
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest point or nil if not found
function Node.GetClosestAreaPoint(areaId, position)
	local points = Node.GetAreaPoints(areaId)
	if not points then
		return nil
	end

	local closest, minDist = nil, math.huge
	for _, point in pairs(points) do
		local dist = (point.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = point
		end
	end

	return closest
end

--- Clear cached fine points for all areas (useful when settings change)
function Node.ClearAreaPoints()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	local clearedCount = 0
	for _, area in pairs(nodes) do
		if area.finePoints then
			area.finePoints = nil
			clearedCount = clearedCount + 1
		end
	end

	Log:Info("Cleared fine points cache for %d areas", clearedCount)
end

--- Generate fine points for all areas and create inter-area connections with separate passes
---@param maxAreas number? Maximum number of areas to process (for performance)
function Node.GenerateHierarchicalNetwork(maxAreas)
	maxAreas = maxAreas or 50 -- Limit for performance
	local nodes = Node.GetNodes()
	if not nodes then
		Log:Warn("No nodes available for hierarchical network generation")
		return
	end

	Log:Info("=== Starting hierarchical network generation ===")
	local processedAreas = {}
	local areaCount = 0

	-- PASS 1: Generate fine points for each area with internal connections
	Log:Info("Pass 1: Generating points and internal connections...")
	for areaId, area in pairs(nodes) do
		if areaCount >= maxAreas then
			break
		end

		local points = Node.GenerateAreaPoints(areaId)
		if points and #points > 0 then
			processedAreas[areaId] = { area = area, points = points }
			areaCount = areaCount + 1
			Log:Debug("Processed area %d with %d points", areaId, #points)
		end
	end

	Log:Info("Generated fine points for %d areas", areaCount)

	-- PASS 2: Create inter-area connections between adjacent areas
	Log:Info("Pass 2: Creating inter-area connections...")
	Log:Info(
		"DEBUG: processedAreas count: %d",
		(function()
			local count = 0
			for _ in pairs(processedAreas) do
				count = count + 1
			end
			return count
		end)()
	)
	local totalConnections = 0
	local checkedPairs = 0
	local connectionPairs = {} -- Track which area pairs we've already connected

	for areaIdA, dataA in pairs(processedAreas) do
		Log:Info("DEBUG: Checking area %d for neighbors...", areaIdA)
		local hasConnections = false
		-- Check connections to adjacent areas - iterate through all 4 directions
		for dir = 1, 4 do
			local connectionDir = dataA.area.c[dir]
			if connectionDir then
				Log:Info(
					"DEBUG: Area %d dir %d has connection object with %d connections",
					areaIdA,
					dir,
					connectionDir.connections and #connectionDir.connections or 0
				)
			end
			if connectionDir and connectionDir.connections and #connectionDir.connections > 0 then
				hasConnections = true
				for _, targetAreaId in ipairs(connectionDir.connections) do
					local dataB = processedAreas[targetAreaId]
					Log:Info(
						"DEBUG: Area %d trying to connect to area %d (dataB exists: %s)",
						areaIdA,
						targetAreaId,
						tostring(dataB ~= nil)
					)
					if dataB and targetAreaId ~= areaIdA then -- Avoid self-connections
						-- Create a unique pair key to avoid duplicate processing
						local pairKey =
							string.format("%d-%d", math.min(areaIdA, targetAreaId), math.max(areaIdA, targetAreaId))

						if not connectionPairs[pairKey] then
							connectionPairs[pairKey] = true
							checkedPairs = checkedPairs + 1
							Log:Debug("Connecting area %d to area %d", areaIdA, targetAreaId)

							local connections = connectAdjacentAreas(dataA.area, dataB.area, dataA.points, dataB.points)
							totalConnections = totalConnections + connections

							if connections > 0 then
								Log:Info(
									"✓ Connected areas %d <-> %d with %d fine point connections",
									areaIdA,
									targetAreaId,
									connections
								)
							else
								Log:Warn("✗ No connections created between areas %d <-> %d", areaIdA, targetAreaId)
							end
						end
					end
				end
			end
		end
		if not hasConnections then
			Log:Info("DEBUG: Area %d has no outgoing connections", areaIdA)
		end
	end

	-- PASS 3: Build hierarchical data structure for HPA* pathfinding
	Log:Info("Pass 3: Building HPA* data structure...")
	buildHierarchicalStructure(processedAreas)

	Log:Info("=== Network generation complete ===")
	Log:Info("Checked pairs: %d", checkedPairs)
	Log:Info("Created %d inter-area fine point connections", totalConnections)

	-- Verify connections were actually created
	local verificationCount = 0
	for areaId, data in pairs(processedAreas) do
		for _, point in pairs(data.points) do
			for _, neighbor in pairs(point.neighbors) do
				if neighbor.isInterArea then
					verificationCount = verificationCount + 1
				end
			end
		end
	end
	Log:Info("Verification: Found %d inter-area connections in the data structure", verificationCount)
end

--- Get hierarchical pathfinding data (for HPA* algorithm)
---@return table|nil Hierarchical structure or nil if not available
function Node.GetHierarchicalData()
	return G.Navigation.hierarchical
end

--- Get closest edge point in an area to a given position (for HPA* pathfinding)
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest edge point or nil if not found
function Node.GetClosestEdgePoint(areaId, position)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return nil
	end

	local areaInfo = G.Navigation.hierarchical.areas[areaId]
	local closest, minDist = nil, math.huge

	for _, edgePoint in pairs(areaInfo.edgePoints) do
		local dist = (edgePoint.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = edgePoint
		end
	end

	return closest
end

--- Get all inter-area connections from a specific area (for HPA* pathfinding)
---@param areaId number The area ID
---@return table[] Array of inter-area connections
function Node.GetInterAreaConnections(areaId)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return {}
	end

	return G.Navigation.hierarchical.areas[areaId].interAreaConnections or {}
end

return Node

end)
__bundle_register("MedBot.Modules.ISWalkable", function(require, _LOADED, __bundle_register, __bundle_modules)
local isWalkable = {}
local G = require("MedBot.Utils.Globals")
local Common = require("MedBot.Common")

local Jump_Height = 72 --duck jump height
local HULL_MIN = G.pLocal.vHitbox.Min
local HULL_MAX = G.pLocal.vHitbox.Max

local STEP_HEIGHT = 18
local UP_VECTOR = Vector3(0, 0, 1)
local MAX_SLOPE_ANGLE = 55 -- Maximum angle (in degrees) that is climbable
local GRAVITY = 800 -- Gravity in units per second squared
local MIN_STEP_SIZE = 5 -- Minimum step size in units
local preferredSteps = 10 --prefered number oif steps for simulations

-- Function to convert degrees to radians
local function degreesToRadians(degrees)
	return degrees * math.pi / 180
end

-- Checks for an obstruction between two points using a hull trace.
local function performHullTrace(startPos, endPos)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, MASK_PLAYERSOLID_BRUSHONLY)
end

-- Precomputed up vector and max slope angle in radians
local MAX_SLOPE_ANGLE_RAD = degreesToRadians(MAX_SLOPE_ANGLE)

-- Function to adjust direction based on ground normal
local function adjustDirectionToGround(direction, groundNormal)
	local angleBetween = math.acos(groundNormal:Dot(UP_VECTOR))
	if angleBetween <= MAX_SLOPE_ANGLE_RAD then
		return Common.Normalize(direction:Cross(UP_VECTOR):Cross(groundNormal))
	end
	return direction -- If the slope is too steep, keep the original direction
end

-- Main function to check if the path between the current position and the node is walkable.
function isWalkable.Path(startPos, endPos)
	local direction = (endPos - startPos)
	direction = Common.Normalize(direction)
	local totalDistance = (endPos - startPos):Length()
	local stepSize = math.max(MIN_STEP_SIZE, totalDistance / preferredSteps)
	local currentPosition = startPos
	local requiredFraction = STEP_HEIGHT / Jump_Height

	while (endPos - currentPosition):Length() > stepSize do
		local nextPosition = currentPosition + direction * stepSize
		local forwardTraceResult = performHullTrace(currentPosition, nextPosition)

		if forwardTraceResult.fraction < 1 then
			local collisionPosition = forwardTraceResult.endpos
			local forwardPosition = collisionPosition + direction * 1
			local upPosition = forwardPosition + Vector3(0, 0, Jump_Height)
			local traceDownResult = performHullTrace(upPosition, forwardPosition)

			-- Determine if we can step up or jump over the obstacle
			local canMove = traceDownResult.fraction >= requiredFraction
				or (traceDownResult.fraction > 0 and G.Menu.Movement.Smart_Jump)
			currentPosition = canMove and traceDownResult.endpos or currentPosition

			-- If we couldn't step up or jump over, the path is blocked
			if not canMove or currentPosition == collisionPosition then
				return false
			end
		else
			currentPosition = nextPosition
		end

		-- Simulate falling
		local fallDistance = (stepSize / 450) * GRAVITY
		local fallPosition = currentPosition - Vector3(0, 0, fallDistance)
		local groundTraceResult = performHullTrace(currentPosition, fallPosition)
		currentPosition = groundTraceResult.endpos

		-- Adjust direction to align with the ground
		direction = adjustDirectionToGround(Common.Normalize(endPos - currentPosition), groundTraceResult.plane)
	end

	return true -- Path is walkable
end

return isWalkable

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
__bundle_register("MedBot.Modules.SmartJump", function(require, _LOADED, __bundle_register, __bundle_modules)
---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")

-- Use MedBot's globals instead of Movement.Globals
local G = require("MedBot.Utils.Globals")

local SmartJump = {}

local Math = lnxLib.Utils.Math
local Prediction = lnxLib.TF2.Prediction
local WPlayer = lnxLib.TF2.WPlayer

-- Internal variables (for debugging or auxiliary calculations)
local lastAngle = nil ---@type number
local predictedPosition = Vector3(0, 0, 0)
local jumpPeakPosition = Vector3(0, 0, 0)

-- Constants
local JUMP_FRACTION = 0.75 -- Fraction of the jump to consider for landing
local HITBOX_MIN = Vector3(-23.99, -23.99, 0)
local HITBOX_MAX = Vector3(23.99, 23.99, 62) -- always assume ducking
local MAX_JUMP_HEIGHT = Vector3(0, 0, 72) -- Maximum jump height vector
local STEP_HEIGHT = Vector3(0, 0, 18) -- Step height (simulate stepping up)
local MAX_WALKABLE_ANGLE = 45 -- Maximum angle considered walkable
local GRAVITY = 800 -- Gravity per second squared
local JUMP_FORCE = 277 -- Initial vertical boost for a duck jump

-- Rotates a vector by a yaw (in degrees)
local function RotateVectorByYaw(vector, yaw)
	local rad = math.rad(yaw)
	local cosYaw, sinYaw = math.cos(rad), math.sin(rad)
	return Vector3(cosYaw * vector.x - sinYaw * vector.y, sinYaw * vector.x + cosYaw * vector.y, vector.z)
end

-- Normalizes a vector (if nonzero)
local function Normalize(vec)
	local len = vec:Length()
	if len == 0 then
		return vec
	end
	return vec / len
end

-- Returns whether a surface is walkable (its normal's angle is below MAX_WALKABLE_ANGLE)
local function IsSurfaceWalkable(normal)
	local upVector = Vector3(0, 0, 1)
	local angle = math.deg(math.acos(normal:Dot(upVector)))
	return angle < MAX_WALKABLE_ANGLE
end

-- (Optional) Calculates a strafe angle delta.
---@param player Entity?
local function CalcStrafe(player)
	if not player then
		return 0
	end
	local velocityAngle = player:EstimateAbsVelocity():Angles()
	local delta = 0
	if lastAngle then
		delta = Math.NormalizeAngle(velocityAngle.y - lastAngle)
	end
	lastAngle = velocityAngle.y
	return delta
end

-- Computes the peak jump position and its direction based on horizontal velocity.
local function GetJumpPeak(horizontalVelocity, startPos)
	local timeToPeak = JUMP_FORCE / GRAVITY -- time to reach peak height
	local horizontalSpeed = horizontalVelocity:Length() -- horizontal speed
	local distanceTravelled = horizontalSpeed * timeToPeak
	local peakPosition = startPos + Normalize(horizontalVelocity) * distanceTravelled
	local directionToPeak = Normalize(peakPosition - startPos)
	return peakPosition, directionToPeak
end

-- Adjusts the velocity based on the movement input in cmd.
local function AdjustVelocity(cmd)
	if not G.pLocal.entity then
		return Vector3(0, 0, 0)
	end

	local moveInput = Vector3(cmd.forwardmove, -cmd.sidemove, 0)
	if moveInput:Length() == 0 then
		return G.pLocal.entity:EstimateAbsVelocity()
	end

	local viewAngles = engine.GetViewAngles()
	local rotatedMoveDir = RotateVectorByYaw(moveInput, viewAngles.yaw)
	local normalizedMoveDir = Normalize(rotatedMoveDir)

	local velocity = G.pLocal.entity:EstimateAbsVelocity()
	local intendedSpeed = math.max(10, velocity:Length())

	-- Check if on ground using MedBot's flag system
	local onGround = (G.pLocal.flags & FL_ONGROUND) ~= 0
	if onGround then
		velocity = normalizedMoveDir * intendedSpeed
	end

	return velocity
end

-- Enhanced smart jump logic with obstacle detection and timing
-- When called from MedBot's OnCreateMove it uses G.pLocal, G.pLocal.flags, etc.
-- It returns true if the conditions for a jump are met and sets G.ShouldJump accordingly.
function SmartJump.Main(cmd)
	local shouldJump = false
	local currentTick = globals.TickCount()

	if not G.pLocal.entity then
		G.ShouldJump = false
		G.ObstacleDetected = false
		return false
	end

	-- Check if smart jump is enabled in MedBot menu
	if not G.Menu.Movement.Smart_Jump then
		G.ShouldJump = false
		G.ObstacleDetected = false
		return false
	end

	-- Use MedBot's ground detection
	local onGround = (G.pLocal.flags & FL_ONGROUND) ~= 0

	if onGround then
		local adjustedVelocity = AdjustVelocity(cmd)
		local playerPosition = G.pLocal.entity:GetAbsOrigin()
		local jumpPeakPos, jumpDirection = GetJumpPeak(adjustedVelocity, playerPosition)
		jumpPeakPosition = jumpPeakPos -- update (for debugging/visuals)

		local horizontalDistanceToPeak = (jumpPeakPos - playerPosition):Length2D()
		local traceStartPos = playerPosition + STEP_HEIGHT
		local traceEndPos = traceStartPos + (jumpDirection * horizontalDistanceToPeak)

		local forwardTrace =
			engine.TraceHull(traceStartPos, traceEndPos, HITBOX_MIN, HITBOX_MAX, MASK_PLAYERSOLID_BRUSHONLY)
		predictedPosition = forwardTrace.endpos

		-- Detect obstacle presence
		local obstacleDetected = forwardTrace.fraction < 1
		G.ObstacleDetected = obstacleDetected

		if obstacleDetected then
			local downwardTrace = engine.TraceHull(
				forwardTrace.endpos,
				forwardTrace.endpos - MAX_JUMP_HEIGHT,
				HITBOX_MIN,
				HITBOX_MAX,
				MASK_PLAYERSOLID_BRUSHONLY
			)
			local groundPosition = downwardTrace.endpos
			predictedPosition = groundPosition

			local landingPosition = groundPosition + (jumpDirection * 10)
			local landingDownwardTrace = engine.TraceHull(
				landingPosition + MAX_JUMP_HEIGHT,
				landingPosition,
				HITBOX_MIN,
				HITBOX_MAX,
				MASK_PLAYERSOLID_BRUSHONLY
			)
			predictedPosition = landingDownwardTrace.endpos

			-- Check if jump would be successful
			if landingDownwardTrace.fraction > 0 and landingDownwardTrace.fraction < JUMP_FRACTION then
				if IsSurfaceWalkable(landingDownwardTrace.plane) then
					shouldJump = true
					G.LastSmartJumpAttempt = currentTick
				end
			end
		end
	elseif (cmd.buttons & IN_JUMP) == IN_JUMP then
		shouldJump = true
		G.LastSmartJumpAttempt = currentTick
	end

	G.ShouldJump = shouldJump
	return shouldJump
end

-- Check if emergency jump should be performed (fallback when SmartJump logic fails)
---@param currentTick number Current game tick
---@param stuckTicks number How long we've been stuck
---@return boolean Whether emergency jump should be performed
function SmartJump.ShouldEmergencyJump(currentTick, stuckTicks)
	-- Only emergency jump if:
	-- 1. We've been stuck for a while (>132 ticks)
	-- 2. SmartJump hasn't attempted a jump recently (>200 ticks ago)
	-- 3. We haven't done an emergency jump recently (>300 ticks ago)
	-- 4. There's an obstacle detected
	local timeSinceLastSmartJump = currentTick - G.LastSmartJumpAttempt
	local timeSinceLastEmergencyJump = currentTick - G.LastEmergencyJump

	local shouldEmergency = stuckTicks > 132
		and timeSinceLastSmartJump > 200
		and timeSinceLastEmergencyJump > 300
		and G.ObstacleDetected

	if shouldEmergency then
		G.LastEmergencyJump = currentTick
	end

	return shouldEmergency
end

-- Export functions
SmartJump.CalcStrafe = CalcStrafe
SmartJump.GetJumpPeak = GetJumpPeak -- Export for debugging/visualization

return SmartJump

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
            result = nil
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
            entry.result = {func(table.unpack(args))}
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
            delay = delay
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
            work.result = {work.func(table.unpack(work.args))}
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
__bundle_register("MedBot.Navigation", function(require, _LOADED, __bundle_register, __bundle_modules)
---@alias Connection { count: integer, connections: integer[] }
---@alias Node { x: number, y: number, z: number, id: integer, c: { [1]: Connection, [2]: Connection, [3]: Connection, [4]: Connection } }
---@class Pathfinding
---@field pathFound boolean
---@field pathFailed boolean
local Navigation = {}

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Node = require("MedBot.Modules.Node")
local AStar = require("MedBot.Utils.A-Star")
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

	local nodes = G.Navigation.nodes

	for dir = 1, 4 do
		local conDir = nodes[nodeA.id].c[dir]
		if conDir and conDir.connections then
			-- Check if connection already exists
			local exists = false
			for _, existingId in ipairs(conDir.connections) do
				if existingId == nodeB.id then
					exists = true
					break
				end
			end
			if not exists then
				print("Adding connection between " .. nodeA.id .. " and " .. nodeB.id)
				table.insert(conDir.connections, nodeB.id)
				conDir.count = conDir.count + 1
			end
		end
	end

	for dir = 1, 4 do
		local conDir = nodes[nodeB.id].c[dir]
		if conDir and conDir.connections then
			-- Check if reverse connection already exists
			local exists = false
			for _, existingId in ipairs(conDir.connections) do
				if existingId == nodeA.id then
					exists = true
					break
				end
			end
			if not exists then
				print("Adding reverse connection between " .. nodeB.id .. " and " .. nodeA.id)
				table.insert(conDir.connections, nodeA.id)
				conDir.count = conDir.count + 1
			end
		end
	end
end

-- Remove a connection between two nodes
function Navigation.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	local nodes = G.Navigation.nodes

	for dir = 1, 4 do
		local conDir = nodes[nodeA.id].c[dir]
		if conDir and conDir.connections then
			for i, con in ipairs(conDir.connections) do
				if con == nodeB.id then
					print("Removing connection between " .. nodeA.id .. " and " .. nodeB.id)
					table.remove(conDir.connections, i)
					conDir.count = conDir.count - 1
					break
				end
			end
		end
	end

	for dir = 1, 4 do
		local conDir = nodes[nodeB.id].c[dir]
		if conDir and conDir.connections then
			for i, con in ipairs(conDir.connections) do
				if con == nodeA.id then
					print("Removing reverse connection between " .. nodeB.id .. " and " .. nodeA.id)
					table.remove(conDir.connections, i)
					conDir.count = conDir.count - 1
					break
				end
			end
		end
	end
end

-- Add cost to a connection between two nodes
function Navigation.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		print("One or both nodes are nil, exiting function")
		return
	end

	-- Use Node module's implementation to avoid duplication
	local Node = require("MedBot.Modules.Node")
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
end

-- Set the current path
---@param path Node[]
function Navigation.SetCurrentPath(path)
	if not path then
		Log:Error("Failed to set path, it's nil")
		return
	end
	G.Navigation.path = path
	G.Navigation.currentNodeIndex = 1 -- Start from the first node (start) and work towards goal
end

-- Remove the current node from the path (we've reached it)
function Navigation.RemoveCurrentNode()
	G.Navigation.currentNodeTicks = 0
	if G.Navigation.path and #G.Navigation.path > 0 then
		-- Remove the first node (current node we just reached)
		table.remove(G.Navigation.path, 1)
		-- currentNodeIndex stays at 1 since we always target the first node in the remaining path
		G.Navigation.currentNodeIndex = 1
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

-- Function to adjust direction based on ground normal
local function adjustDirectionToGround(direction, groundNormal)
	local angleBetween = math.acos(groundNormal:Dot(UP_VECTOR))
	if angleBetween <= MAX_SLOPE_ANGLE_RAD then
		local newDirection = direction:Cross(UP_VECTOR):Cross(groundNormal)
		return Common.Normalize(newDirection)
	end
	return direction -- If the slope is too steep, keep the original direction
end

-- Main function to check if the path between the current position and the node is walkable.
function Navigation.isWalkable(startPos, endPos)
	local direction = Common.Normalize(endPos - startPos)
	local totalDistance = (endPos - startPos):Length()
	local stepSize = math.max(MIN_STEP_SIZE, totalDistance / preferredSteps)
	local currentPosition = startPos
	local distanceCovered = 0
	local requiredFraction = STEP_HEIGHT / Jump_Height

	while distanceCovered < totalDistance do
		stepSize = math.min(stepSize, totalDistance - distanceCovered)
		local nextPosition = currentPosition + direction * stepSize

		-- Check if the next step is clear
		local pathClearResult = isPathClear(currentPosition, nextPosition)
		if pathClearResult.fraction < 1 then
			-- We'll collide, get end position of the trace
			local collisionPosition = pathClearResult.endpos

			-- Move 1 unit forward, then up by the jump height, then trace down
			local forwardPosition = collisionPosition + direction * 1
			local upPosition = forwardPosition + Vector3(0, 0, Jump_Height)
			local traceDownResult = isPathClear(upPosition, forwardPosition)

			-- Determine if we can step up or jump over the obstacle
			local canStepUp = traceDownResult.fraction >= requiredFraction
			local canJumpOver = traceDownResult.fraction > 0 and G.Menu.Movement.Smart_Jump

			-- Update the current position based on step up or jump over
			currentPosition = (canStepUp or canJumpOver) and traceDownResult.endpos or currentPosition

			-- If we couldn't step up or jump over, the path is blocked
			if traceDownResult.fraction == 0 or currentPosition == collisionPosition then
				return false
			end
		else
			currentPosition = nextPosition
		end

		-- Check if the ground is stable
		if not isGroundStable(currentPosition) then
			-- Simulate falling
			currentPosition = currentPosition - Vector3(0, 0, (stepSize / 450) * GRAVITY)
		else
			-- Adjust direction to align with the ground
			direction = adjustDirectionToGround(direction, getGroundNormal(currentPosition))
		end

		distanceCovered = distanceCovered + stepSize
	end

	return true -- Path is walkable
end

function Navigation.OptimizePath()
	local path = G.Navigation.path
	if not path then
		return
	end

	local currentIndex = G.Navigation.FirstAgentNode
	local checkingIndex = G.Navigation.SecondAgentNode
	local currentNode = G.Navigation.currentNode -- Assuming this is correctly set somewhere in your game logic
	local optimizationLimit = G.Menu.Main.OptimizationLimit or 10 -- Default limit if not specified

	-- Only proceed if the first agent is not too far ahead of the current node
	if currentIndex - currentNode <= optimizationLimit then
		-- Check visibility between the current node and the checking node
		if checkingIndex <= #path and G.Navigation.isWalkable(path[currentIndex].pos, path[checkingIndex].pos) then
			-- If the current node can directly walk to the checking node, move to check the next node
			checkingIndex = checkingIndex + 1
		else
			-- Once we find a node that cannot be directly walked to, we place all nodes in a straight line
			-- from currentIndex to the last directly walkable node (checkingIndex - 1)
			if checkingIndex > currentIndex + 1 then
				local startX, startY = path[currentIndex].pos.x, path[currentIndex].pos.y
				local endX, endY = path[checkingIndex - 1].pos.x, path[checkingIndex - 1].pos.y
				local numSteps = checkingIndex - currentIndex - 1
				local stepX = (endX - startX) / (numSteps + 1)
				local stepY = (endY - startY) / (numSteps + 1)
				for i = 1, numSteps do
					local nodeIndex = currentIndex + i
					local node = path[nodeIndex]
					node.pos.x = startX + stepX * i
					node.pos.y = startY + stepY * i
					Navigation.FixNode(nodeIndex)
				end
			end

			-- Update the indices in the G module to start a new segment of optimization
			G.Navigation.FirstAgentNode = checkingIndex - 1
			G.Navigation.SecondAgentNode = G.Navigation.FirstAgentNode + 1

			-- Reset the indices to the beginning if we've reached or exceeded the last node
			if G.Navigation.FirstAgentNode >= #path - 1 then
				G.Navigation.FirstAgentNode = 1
				G.Navigation.SecondAgentNode = G.Navigation.FirstAgentNode + 1
			end
		end
	end
end

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
---@return Node
function Navigation.GetClosestNode(pos)
	-- Safety check: ensure nodes are available
	if not G.Navigation.nodes or not next(G.Navigation.nodes) then
		Log:Debug("No navigation nodes available for GetClosestNode")
		return nil
	end
	return Node.GetClosestNode(pos)
end

-- Main pathfinding function
---@param startNode Node
---@param goalNode Node
function Navigation.FindPath(startNode, goalNode)
	assert(startNode and startNode.pos, "Navigation.FindPath: startNode is nil or has no pos")
	assert(goalNode and goalNode.pos, "Navigation.FindPath: goalNode is nil or has no pos")

	local horizontalDistance = math.abs(goalNode.pos.x - startNode.pos.x) + math.abs(goalNode.pos.y - startNode.pos.y)
	local verticalDistance = math.abs(goalNode.pos.z - startNode.pos.z)

	if horizontalDistance <= 100 and verticalDistance <= 18 then --attempt to avoid work
		G.Navigation.path = AStar.GBFSPath(startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodes)
	elseif
		(horizontalDistance <= 700 and verticalDistance <= 18) or Navigation.isWalkable(startNode.pos, goalNode.pos)
	then --didnt work try doing less work
		G.Navigation.path = AStar.GBFSPath(startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodes)
	else --damn it then do it propertly at least
		G.Navigation.path = AStar.NormalPath(startNode, goalNode, G.Navigation.nodes, Node.GetAdjacentNodes)
	end

	if not G.Navigation.path or #G.Navigation.path == 0 then
		Log:Error("Failed to find path from %d to %d!", startNode.id, goalNode.id)
		G.Navigation.path = nil
		Navigation.pathFailed = true
		Navigation.pathFound = false
	else
		Log:Info("Path found from %d to %d with %d nodes", startNode.id, goalNode.id, #G.Navigation.path)
		Navigation.pathFound = true
		Navigation.pathFailed = false
	end

	return Navigation
end

return Navigation

end)
__bundle_register("MedBot.Utils.A-Star", function(require, _LOADED, __bundle_register, __bundle_modules)
local Heap = require("MedBot.Utils.Heap")

---@alias PathNode { id : integer, x : number, y : number, z : number }

---@class AStar
local AStar = {}

local function ManhattanDistance(nodeA, nodeB)
	return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

local function HeuristicCostEstimate(nodeA, nodeB)
	return ManhattanDistance(nodeA, nodeB)
end

-- Function to get connection cost between two nodes (returns 1 if no cost specified, or actual cost)
local function GetConnectionCost(nodeA, nodeB, nodes)
	-- Check all directions for a connection with cost
	for dir = 1, 4 do
		local cDir = nodeA.c[dir]
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				-- Handle both integer ID and table with cost
				local targetId = (type(connection) == "table") and connection.node or connection
				local cost = (type(connection) == "table") and connection.cost or 1

				if targetId == nodeB.id then
					return cost
				end
			end
		end
	end
	return 1 -- Default cost if no connection found
end

local function reconstructPath(cameFrom, current)
	local totalPath = { current }
	while cameFrom[current] do
		current = cameFrom[current]
		table.insert(totalPath, 1, current) -- Insert at beginning to get start-to-goal order
	end
	return totalPath
end

function AStar.NormalPath(start, goal, nodes, adjacentFun)
	local openSet = Heap.new(function(a, b)
		return a.fScore < b.fScore
	end)
	local closedSet = {}
	local gScore, fScore, cameFrom = {}, {}, {}
	gScore[start] = 0
	fScore[start] = HeuristicCostEstimate(start, goal)

	openSet:push({ node = start, fScore = fScore[start] })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local current = currentData.node

		if current.id == goal.id then
			return reconstructPath(cameFrom, current)
		end

		closedSet[current] = true

		for _, neighbor in ipairs(adjacentFun(current, nodes)) do
			if not closedSet[neighbor] then
				-- Use connection cost instead of just distance
				local connectionCost = GetConnectionCost(current, neighbor, nodes)
				local tentativeGScore = gScore[current] + (HeuristicCostEstimate(current, neighbor) * connectionCost)

				if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
					cameFrom[neighbor] = current
					gScore[neighbor] = tentativeGScore
					fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
					openSet:push({ node = neighbor, fScore = fScore[neighbor] })
				end
			end
		end
	end

	return nil -- Path not found if loop exits
end

function AStar.GBFSPath(start, goal, nodes, getNeighbors)
	local openSet = Heap.new(function(a, b)
		return a.heuristic < b.heuristic
	end)
	local closedSet = {}
	local cameFrom = {}

	openSet:push({ node = start, heuristic = HeuristicCostEstimate(start, goal) })

	while not openSet:empty() do
		local currentData = openSet:pop()
		local currentNode = currentData.node

		if currentNode.id == goal.id then
			return reconstructPath(cameFrom, currentNode)
		end

		closedSet[currentNode] = true

		for _, neighbor in ipairs(getNeighbors(currentNode, nodes)) do
			if not closedSet[neighbor] then
				cameFrom[neighbor] = currentNode
				openSet:push({ node = neighbor, heuristic = HeuristicCostEstimate(neighbor, goal) })
			end
		end
	end

	return nil -- Path not found if the open set is empty
end

return AStar

--[[ 2
    
local Heap = require("MedBot.Utils.Heap")

---@alias PathNode { id : integer, x : number, y : number, z : number }

---@class AStar
local AStar = {}

local function ManhattanDistance(nodeA, nodeB)
    return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

local function HeuristicCostEstimate(nodeA, nodeB)
    return ManhattanDistance(nodeA, nodeB)
end

local function AStarPath(start, goal, nodes, adjacentFun)
    local openSet = Heap.new(function(a, b) return a.fScore < b.fScore end)
    local closedSet = {}
    local gScore, fScore = {}, {}
    gScore[start] = 0
    fScore[start] = HeuristicCostEstimate(start, goal)

    openSet:push({node = start, path = {start}, fScore = fScore[start]})

    local function pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
        gScore[neighbor] = tentativeGScore
        fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
        local newPath = {table.unpack(currentPath)}
        table.insert(newPath, neighbor)
        openSet:push({node = neighbor, path = newPath, fScore = fScore[neighbor]})
    end

    while not openSet:empty() do
        local currentData = openSet:pop()
        local current = currentData.node
        local currentPath = currentData.path

        if current.id == goal.id then
            local reversedPath = {}
            for i = #currentPath, 1, -1 do
                table.insert(reversedPath, currentPath[i])
            end
            return reversedPath
        end

        closedSet[current] = true

        local adjacentNodes = adjacentFun(current, nodes)
        for _, neighbor in ipairs(adjacentNodes) do
            if not closedSet[neighbor] then
                local tentativeGScore = gScore[current] + HeuristicCostEstimate(current, neighbor)

                if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
                    neighbor.previous = current
                    pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
                end
            end
        end
    end

    return nil -- Path not found if loop exits
end

AStar.Path = AStarPath

return AStar
]]

--------------------------------------------

--[[ 1
local Heap = require("MedBot.Utils.Heap")

---@alias PathNode { id : integer, x : number, y : number, z : number }

---@class AStar
local AStar = {}

local function ManhattanDistance(nodeA, nodeB)
    return math.abs(nodeB.pos.x - nodeA.pos.x) + math.abs(nodeB.pos.y - nodeA.pos.y)
end

local function HeuristicCostEstimate(nodeA, nodeB)
    return ManhattanDistance(nodeA, nodeB)
end

local function AStarPath(start, goal, nodes, adjacentFun)
    local openSet, closedSet = Heap.new(), {}
    local gScore, fScore = {}, {}
    gScore[start] = 0
    fScore[start] = HeuristicCostEstimate(start, goal)

    openSet.Compare = function(a, b) return fScore[a.node] < fScore[b.node] end
    openSet:push({node = start, path = {start}})

    local function pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
        gScore[neighbor] = tentativeGScore
        fScore[neighbor] = tentativeGScore + HeuristicCostEstimate(neighbor, goal)
        local newPath = {table.unpack(currentPath)}
        table.insert(newPath, neighbor)
        openSet:push({node = neighbor, path = newPath})
    end

    while not openSet:empty() do
        local currentData = openSet:pop()
        local current = currentData.node
        local currentPath = currentData.path

        if current.id == goal.id then
            local reversedPath = {}
            for i = #currentPath, 1, -1 do
                table.insert(reversedPath, currentPath[i])
            end
            return reversedPath
        end

        closedSet[current] = true

        local adjacentNodes = adjacentFun(current, nodes)
        for _, neighbor in ipairs(adjacentNodes) do
            local neighborNotInClosedSet = closedSet[neighbor] and 0 or 1
            local tentativeGScore = gScore[current] + HeuristicCostEstimate(current, neighbor)

            local newGScore = (not gScore[neighbor] and 1 or 0) + (tentativeGScore < (gScore[neighbor] or math.huge) and 1 or 0)
            local condition = neighborNotInClosedSet * newGScore

            if condition > 0 then
                pushToOpenSet(current, neighbor, currentPath, tentativeGScore)
            end
        end
    end

    return nil -- Path not found if loop exits
end

AStar.Path = AStarPath

return AStar]]

end)
__bundle_register("MedBot.Utils.Heap", function(require, _LOADED, __bundle_register, __bundle_modules)
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
        Compare = compare or function(a, b) return a < b end
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

-- Removes and returns the root element of the heap.
function Heap:pop()
    if self._size == 0 then
        return nil
    end
    local root = self._data[1]
    self._data[1] = self._data[self._size]
    self._data[self._size] = nil  -- Clear the reference to the removed item
    self._size = self._size - 1
    if self._size > 0 then
        sortDown(self, 1)
    end
    return root
end

return Heap

end)
return __bundle_require("__root")