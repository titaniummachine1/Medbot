--[[ Annotations ]]
---@alias NavConnection { count: integer, connections: integer[] }
---@alias NavNode { id: integer, x: number, y: number, z: number, c: { [1]: NavConnection, [2]: NavConnection, [3]: NavConnection, [4]: NavConnection } }

--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Navigation = require("MedBot.Navigation")
local WorkManager = require("MedBot.WorkManager")

require("MedBot.Visuals")
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

	local currentNode = G.Navigation.path[G.Navigation.currentNodeIndex]
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
	if WorkManager.attemptWork(132, "Unstuck_Jump") then
		if not G.pLocal.entity:InCond(TFCond_Zoomed) and G.pLocal.flags & FL_ONGROUND == 1 then
			userCmd:SetButtons(userCmd.buttons & ~IN_DUCK)
			userCmd:SetButtons(userCmd.buttons & ~IN_JUMP)
			userCmd:SetButtons(userCmd.buttons | IN_JUMP)
		end
	end

	if G.Navigation.currentNodeTicks > 264 then
		Log:Warn("Stuck for too long, repathing...")
		Navigation.ClearPath()
		G.currentState = G.States.IDLE
	else
		G.currentState = G.States.MOVING
	end
end

-- Function to find goal node based on the current task
function findGoalNode(currentTask)
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

	if currentTask == "Objective" then
		if mapName:find("plr_") or mapName:find("pl_") then
			return findPayloadGoal()
		elseif mapName:find("ctf_") then
			return findFlagGoal()
		else
			Log:Warn("Unsupported Gamemode, try CTF, PL, or PLR")
		end
	elseif currentTask == "Health" then
		return findHealthGoal()
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

		if G.Navigation.currentNodeID < 1 then
			Navigation.ClearPath()
			Log:Info("Reached end of path")
		end
	else
		if G.Menu.Main.Skip_Nodes and WorkManager.attemptWork(2, "node skip") then
			if G.Navigation.currentNodeID > 1 then
				local nextNode = G.Navigation.path[G.Navigation.currentNodeID - 1]
				local nextHorizontalDist = math.abs(LocalOrigin.x - nextNode.pos.x)
					+ math.abs(LocalOrigin.y - nextNode.pos.y)
				local nextVerticalDist = math.abs(LocalOrigin.z - nextNode.pos.z)

				if nextHorizontalDist < horizontalDist and nextVerticalDist <= G.Misc.NodeTouchHeight then
					Log:Info("Skipping to closer node %d", G.Navigation.currentNodeID - 1)
					Navigation.RemoveCurrentNode()
				end
			end
		elseif G.Menu.Main.Optymise_Path and WorkManager.attemptWork(4, "Optymise Path") then
			Navigation.OptimizePath()
		end

		G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1
		Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
	end

	if G.pLocal.flags & FL_ONGROUND == 1 or G.pLocal.entity:EstimateAbsVelocity():Length() < 50 then
		if G.Navigation.currentNodeTicks > 66 then
			if WorkManager.attemptWork(132, "Unstuck_Jump") then
				if not G.pLocal.entity:InCond(TFCond_Zoomed) and G.pLocal.flags & FL_ONGROUND == 1 then
					userCmd:SetButtons(userCmd.buttons & ~IN_DUCK)
					userCmd:SetButtons(userCmd.buttons & ~IN_JUMP)
					userCmd:SetButtons(userCmd.buttons | IN_JUMP)
				end
			end
		end

		if
			G.Navigation.currentNodeTicks > 264
			or (G.Navigation.currentNodeTicks > 22 and horizontalDist < G.Misc.NodeTouchDistance)
				and WorkManager.attemptWork(66, "pathCheck")
		then
			if not Navigation.isWalkable(LocalOrigin, G.Navigation.currentNodePos, 1) then
				Log:Warn(
					"Path to node %d is blocked, removing connection and repathing...",
					G.Navigation.currentNodeIndex
				)
				if
					G.Navigation.path[G.Navigation.currentNodeIndex]
					and G.Navigation.path[G.Navigation.currentNodeIndex + 1]
				then
					Navigation.RemoveConnection(
						G.Navigation.path[G.Navigation.currentNodeIndex],
						G.Navigation.path[G.Navigation.currentNodeIndex + 1]
					)
				elseif
					G.Navigation.path[G.Navigation.currentNodeIndex]
					and not G.Navigation.path[G.Navigation.currentNodeIndex + 1]
					and G.Navigation.currentNodeIndex > 1
				then
					Navigation.RemoveConnection(
						G.Navigation.path[G.Navigation.currentNodeIndex - 1],
						G.Navigation.path[G.Navigation.currentNodeIndex]
					)
				end
				Navigation.ClearPath()
				Navigation.ResetTickTimer()
			elseif not WorkManager.attemptWork(5, "pathCheck") then
				Log:Warn("Path to node %d is stuck but not blocked, repathing...", G.Navigation.currentNodeIndex)
				Navigation.ClearPath()
				Navigation.ResetTickTimer()
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

Commands.Register("pf", function(args)
	if args:size() ~= 2 then
		print("Usage: pf <Start> <Goal>")
		return
	end

	local start = tonumber(args:popFront())
	local goal = tonumber(args:popFront())

	if not start or not goal then
		print("Start/Goal must be numbers!")
		return
	end

	local startNode = Navigation.GetNodeByID(start)
	local goalNode = Navigation.GetNodeByID(goal)

	if not startNode or not goalNode then
		print("Start/Goal node not found!")
		return
	end

	WorkManager.addTask(Navigation.FindPath, { startNode, goalNode }, 66, "Pathfinding")
end)

Commands.Register("pf_auto", function(args)
	G.Menu.Navigation.autoPath = G.Menu.Navigation.autoPath
	print("Auto path: " .. tostring(G.Menu.Navigation.autoPath))
end)

Notify.Alert("MedBot loaded!")
Navigation.Setup()
