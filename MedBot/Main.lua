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

	if G.Menu.Main.LookingAhead then
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
		-- Simple node skipping logic - check if we can walk directly to next node
		if G.Menu.Main.Skip_Nodes and WorkManager.attemptWork(2, "node skip") then
			local path = G.Navigation.path
			if path and #path > 1 then
				local nextNode = path[2] -- Next node after current
				if nextNode then
					-- Choose walkability check based on aggressive skipping setting
					local canSkip = false
					if G.Menu.Main.AggressivePathSkipping then
						-- Aggressive mode: allow jumping (use full walkability)
						canSkip = Navigation.isWalkable(LocalOrigin, nextNode.pos)
					else
						-- Conservative mode: only allow stepping (18-unit height limit)
						canSkip = Navigation.isStepOnlyWalkable(LocalOrigin, nextNode.pos)
					end

					if canSkip then
						Log:Info(
							"Node skip: Can walk directly to next node (aggressive: %s)",
							tostring(G.Menu.Main.AggressivePathSkipping)
						)
						Navigation.RemoveCurrentNode()
					end
				end
			end
		end

		-- Advanced features only if looking ahead is not disabled
		if not G.Menu.Main.DisableLookingAhead then
			-- A* internal navigation for smoother movement within large areas
			if G.Menu.Main.UseHierarchicalPathfinding and WorkManager.attemptWork(8, "internal nav") then
				local path = G.Navigation.path
				if path and #path > 1 then
					local currentNode = path[1]
					local targetNode = path[math.min(3, #path)] -- Look 2-3 nodes ahead

					if currentNode and targetNode then
						local internalPath = Navigation.GetInternalPath(LocalOrigin, targetNode.pos, 200)
						if internalPath and #internalPath > 2 then
							-- Replace current movement target with internal path
							Log:Debug("Using A* internal navigation with %d waypoints", #internalPath)
							-- For now, just move to the second point in the internal path for smoother movement
							local internalTarget = internalPath[2]
							if internalTarget then
								Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, internalTarget.pos)
							else
								Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
							end
						else
							Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
						end
					else
						Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
					end
				else
					Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
				end
			elseif G.Menu.Main.Optymise_Path and WorkManager.attemptWork(4, "Optymise Path") then
				Navigation.OptimizePath()
				Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
			else
				Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
			end
		else
			-- Simple movement when looking ahead is disabled
			Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)
		end

		G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1

		-- Continuous path optimization - check every tick if we can skip to next node
		if G.Menu.Main.ContinuousOptimization then
			Navigation.OptimizePathStep(LocalOrigin)
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

Commands.Register("pf_hierarchical", function(args)
	if args[1] == "network" then
		local Node = require("MedBot.Modules.Node")
		Node.GenerateHierarchicalNetwork()
		Notify.Simple(
			"Started hierarchical network generation",
			"Will process across multiple ticks to prevent freezing",
			5
		)
	elseif args[1] == "status" then
		-- Check setup progress by accessing the SetupState (we need to expose this)
		local G = require("MedBot.Utils.Globals")
		if G.Navigation.hierarchical then
			print("Hierarchical network ready and available")
		else
			print("Hierarchical network not yet available - check if setup is in progress")
		end
	elseif args[1] == "info" then
		local areaId = tonumber(args[2])
		if areaId then
			local Node = require("MedBot.Modules.Node")
			local points = Node.GetAreaPoints(areaId)
			if points then
				print(string.format("Area %d: %d fine points", areaId, #points))
				local edgeCount = 0
				for _, point in ipairs(points) do
					if point.isEdge then
						edgeCount = edgeCount + 1
					end
				end
				print(string.format("  - %d edge points, %d internal points", edgeCount, #points - edgeCount))
			else
				print("Area not found or no points generated")
			end
		else
			print("Usage: pf_hierarchical info <areaId>")
		end
	else
		print("Usage: pf_hierarchical network | status | info <areaId>")
		print("  network - Start multi-tick hierarchical network generation")
		print("  status  - Check if hierarchical network is ready")
		print("  info    - Show detailed info for specific area")
	end
end)

Commands.Register("pf_test_hierarchical", function()
	local hierarchical = G.Navigation.hierarchical
	if hierarchical then
		print(
			string.format("Hierarchical data available for %d areas", hierarchical.areas and #hierarchical.areas or 0)
		)
		local totalEdgePoints = 0
		local totalConnections = 0
		for areaId, areaInfo in pairs(hierarchical.areas or {}) do
			totalEdgePoints = totalEdgePoints + #areaInfo.edgePoints
			totalConnections = totalConnections + #areaInfo.interAreaConnections
		end
		print(string.format("Total: %d edge points, %d inter-area connections", totalEdgePoints, totalConnections))
	else
		print("No hierarchical data available. Run 'pf_hierarchical network' first.")
	end
end)

Commands.Register("pf_connections", function(args)
	local Node = require("MedBot.Modules.Node")

	if args[1] == "status" then
		local status = Node.GetConnectionProcessingStatus()
		if status.isProcessing then
			local phaseNames = {
				[1] = "Basic validation",
				[2] = "Expensive fallback",
				[3] = "Fine point stitching",
			}
			print(string.format("Connection Processing Active:"))
			print(string.format("  Phase: %d (%s)", status.currentPhase, phaseNames[status.currentPhase] or "Unknown"))
			print(string.format("  Progress: %d/%d nodes processed", status.processedNodes, status.totalNodes))
			print(string.format("  Connections found: %d", status.connectionsFound))
			print(string.format("  Expensive checks used: %d", status.expensiveChecksUsed))
			print(string.format("  Fine point connections added: %d", status.finePointConnectionsAdded))
			print(string.format("  Current FPS: %.1f (batch size: %d)", status.currentFPS, status.currentBatchSize))
		else
			print("Connection processing is not active")
		end
	elseif args[1] == "stop" then
		Node.StopConnectionProcessing()
		print("Stopped connection processing")
	elseif args[1] == "start" then
		local nodes = Node.GetNodes()
		if nodes and next(nodes) then
			-- Trigger connection processing by calling the internal function
			-- This is a bit of a hack but allows manual restart
			print("Starting connection processing...")
			Node.CleanupConnections()
		else
			print("No nodes loaded")
		end
	else
		print("Usage: pf_connections status | stop | start")
		print("  status - Show current processing status")
		print("  stop   - Stop background processing")
		print("  start  - Start/restart connection processing")
	end
end)

Commands.Register("pf_optimize", function(args)
	if args[1] == "test" then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			local origin = pLocal:GetAbsOrigin()
			local optimized = Navigation.OptimizePathStep(origin)
			if optimized then
				print("Path optimization successful - skipped to next node")
			else
				print("Path optimization failed - no skip performed")
			end
		else
			print("Player not available for testing")
		end
	elseif args[1] == "info" then
		print(
			string.format("Continuous Optimization: %s", G.Menu.Main.ContinuousOptimization and "Enabled" or "Disabled")
		)
		print(
			string.format(
				"Aggressive Path Skipping: %s",
				G.Menu.Main.AggressivePathSkipping and "Enabled (full walkability)" or "Disabled (18-unit steps only)"
			)
		)

		local path = G.Navigation.path
		if path and #path > 0 then
			print(string.format("Current path: %d nodes remaining", #path))
		else
			print("No active path")
		end
	else
		print("Usage: pf_optimize test | info")
		print("  test - Test path optimization with current position")
		print("  info - Show optimization settings and path status")
	end
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
