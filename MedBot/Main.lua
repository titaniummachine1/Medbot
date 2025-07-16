--[[ Annotations ]]
---@alias NavConnection { count: integer, connections: integer[] }
---@alias NavNode { id: integer, x: number, y: number, z: number, c: { [1]: NavConnection, [2]: NavConnection, [3]: NavConnection, [4]: NavConnection } }

--[[ Imports ]]
local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local Navigation = require("MedBot.Navigation")
local WorkManager = require("MedBot.WorkManager")
local Node = require("MedBot.Modules.Node")
local SmartJump = require("MedBot.Modules.SmartJump")
local isWalkable = require("MedBot.Modules.ISWalkable")

require("MedBot.Visuals")
require("MedBot.Utils.Config")
require("MedBot.Menu")
local Lib = Common.Lib

local Notify, Commands, WPlayer = Lib.UI.Notify, Lib.Utils.Commands, Lib.TF2.WPlayer
local Log = Common.Log.new("MedBot")
Log.Level = 0

--[[ Path Optimiser ]]
-- ############################################################
--  Path optimiser - prevents rubber-banding with smart windowing
-- ############################################################
-- Minimal Optimiser: only skip if next node is closer to the player than the current node
local Optimiser = {}

function Optimiser.skipIfCloser(origin, path)
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

function Optimiser.skipIfWalkable(origin, path, goalPos)
        if not path or #path < 2 then
                return false
        end
        local nextNode = path[2]
        local mode = G.Menu.Main.WalkableMode or "Smooth"
        if #path == 2 or (goalPos and isWalkable.Path(origin, goalPos, "Aggressive")) then
                mode = "Aggressive"
        end
        if nextNode and isWalkable.Path(origin, nextNode.pos, mode) then
                Navigation.RemoveCurrentNode()
                Navigation.ResetTickTimer()
                return true
        end
        return false
end

function Optimiser.skipToGoalIfWalkable(origin, goalPos, path)
	local DEADZONE = 24 -- units, tweak as needed
	if not goalPos or not origin then
		return false
	end
	local dist = (goalPos - origin):Length()
	if dist < DEADZONE then
		Navigation.ClearPath()
		G.currentState = G.States.IDLE
		return true
	end
        -- Use aggressive checks when trying to move directly to the goal
        if path and #path > 1 and isWalkable.Path(origin, goalPos, "Aggressive") then
		Navigation.ClearPath()
		-- Optionally, set a direct path with just the goal as the node
		G.Navigation.path = { { pos = goalPos } }
		return true
	end
	return false
end

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
                G.wasManualWalking = true
                return true
        end
        return false
end

-- Function to handle the IDLE state
function handleIdleState()
	G.BotIsMoving = false -- Clear movement state when idle
	local currentTask = Common.GetHighestPriorityTask()
	if not currentTask then
		return
	end

	-- PERFORMANCE FIX: Prevent pathfinding spam by limiting frequency
	local currentTick = globals.TickCount()
	if not G.lastPathfindingTick then
		G.lastPathfindingTick = 0
	end

	-- Only allow pathfinding every 60 ticks (1 second) to prevent spam
	if currentTick - G.lastPathfindingTick < 60 then
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

       local goalNode, goalPos = findGoalNode(currentTask)
       if not goalNode then
               Log:Warn("Could not find goal node")
               return
       end

       G.Navigation.goalPos = goalPos
       G.Navigation.goalNodeId = goalNode and goalNode.id or nil

	-- Avoid pathfinding if we're already at the goal
       if startNode.id == goalNode.id then
               -- Try direct movement or internal path before giving up
               if goalPos and isWalkable.Path(G.pLocal.Origin, goalPos, "Aggressive") then
			G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
			G.currentState = G.States.MOVING
			G.lastPathfindingTick = currentTick
		else
			local internal = Navigation.GetInternalPath(G.pLocal.Origin, goalPos)
			if internal then
				G.Navigation.path = internal
				G.currentState = G.States.MOVING
				G.lastPathfindingTick = currentTick
			else
				Log:Debug("Already at goal node %d, staying in IDLE", startNode.id)
				G.lastPathfindingTick = currentTick
			end
		end
		return
	end

	Log:Info("Generating new path from node %d to node %d", startNode.id, goalNode.id)
	WorkManager.addWork(Navigation.FindPath, { startNode, goalNode }, 33, "Pathfinding")
	G.currentState = G.States.PATHFINDING
	G.lastPathfindingTick = currentTick
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

	-- Store the intended movement direction for SmartJump to use
	local LocalOrigin = G.pLocal.Origin
	local direction = currentNode.pos - LocalOrigin
	G.BotMovementDirection = direction:Length() > 0 and (direction / direction:Length()) or Vector3(0, 0, 0)
	G.BotIsMoving = true

	moveTowardsNode(userCmd, currentNode)

	-- Check if stuck
	if G.Navigation.currentNodeTicks > 66 then
		G.currentState = G.States.STUCK
	end
end

-- Function to handle the STUCK state
function handleStuckState(userCmd)
	local currentTick = globals.TickCount()

	-- SmartJump runs independently, just request emergency jump when needed
	-- Request emergency jump through SmartJump system (don't apply directly)
	if SmartJump.ShouldEmergencyJump(currentTick, G.Navigation.currentNodeTicks) then
		-- Set flag for SmartJump to handle emergency jump
		G.RequestEmergencyJump = true
		Log:Info("Emergency jump requested - SmartJump will handle it")
	end

        if G.Navigation.currentNodeTicks > 264 then
                Log:Warn("Stuck for too long, repathing...")
                local path = G.Navigation.path
                if path and #path > 1 then
                        local currentNode = path[1]
                        local nextNode = path[2]
                        if currentNode and nextNode then
                                local penalty = 10
                                if not isWalkable.Path(G.pLocal.Origin, nextNode.pos) then
                                        if isWalkable.Path(G.pLocal.Origin, nextNode.pos, "Aggressive") then
                                                penalty = 50
                                        else
                                                penalty = 100
                                        end
                                end
                                Node.AddFailurePenalty(currentNode, nextNode, penalty)
                                Log:Debug(
                                        "Added failure penalty to connection %d -> %d due to prolonged stuck state",
                                        currentNode.id,
                                        nextNode.id
                                )
                        end
                end
                Navigation.ResetTickTimer()
                G.currentState = G.States.PATHFINDING
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
				local pos = entity:GetAbsOrigin()
				return Navigation.GetClosestNode(pos), pos
			end
		end
	end

	local function findFlagGoal()
		local myItem = pLocal:GetPropInt("m_hItem")
		G.World.flags = entities.FindByClass("CCaptureFlag")
		for _, entity in pairs(G.World.flags) do
			local myTeam = entity:GetTeamNumber() == pLocal:GetTeamNumber()
			if (myItem > 0 and myTeam) or (myItem < 0 and not myTeam) then
				local pos = entity:GetAbsOrigin()
				return Navigation.GetClosestNode(pos), pos
			end
		end
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

	-- Find and follow the closest teammate using FastPlayers
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

-- Function to move towards the current node (simplified for better FPS)
function moveTowardsNode(userCmd, node)
	local LocalOrigin = G.pLocal.Origin
	local goalPos = nil
	-- Find the goal position from the last node in the path if available
	if G.Navigation.path and #G.Navigation.path > 0 then
		goalPos = G.Navigation.path[#G.Navigation.path].pos
	end
	-- Try to skip directly to the goal if possible
	if G.Menu.Main.Skip_Nodes and goalPos then
		if Optimiser.skipToGoalIfWalkable(LocalOrigin, goalPos, G.Navigation.path) then
			return -- Stop for this tick if we skipped to goal
		end
	end

	-- Only rotate camera if LookingAhead is enabled
	if G.Menu.Main.LookingAhead then
		local pLocalWrapped = WPlayer.GetLocal()
		local angles = Lib.Utils.Math.PositionAngles(pLocalWrapped:GetEyePos(), node.pos)
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

	local horizontalDist = math.abs(LocalOrigin.x - node.pos.x) + math.abs(LocalOrigin.y - node.pos.y)
	local verticalDist = math.abs(LocalOrigin.z - node.pos.z)

	-- Check if we've reached the current node
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
		------------------------------------------------------------
		--  Hybrid Skip - Robust walkability check for node skipping
		------------------------------------------------------------
		-- Only skip one node per tick, first if closer, then if walkable
               if G.Menu.Main.Skip_Nodes and #G.Navigation.path > 1 then
                        local skipped = false
                        if Optimiser.skipIfCloser(LocalOrigin, G.Navigation.path) then
                                skipped = true
                        elseif Optimiser.skipIfWalkable(LocalOrigin, G.Navigation.path, goalPos) then
                                skipped = true
                        end
                        if skipped then
                                node = G.Navigation.path[1]
                                if not node then
                                        return
                                end
                        end
                end

		-- Store current button state before WalkTo (SmartJump may have set jump/duck buttons)
		local originalButtons = userCmd.buttons

		-- Simple movement without complex optimizations
		Lib.TF2.Helpers.WalkTo(userCmd, G.pLocal.entity, node.pos)

		-- Preserve SmartJump button inputs (jump and duck commands)
		-- WalkTo might clear these, so we need to restore them
		local smartJumpButtons = originalButtons & (IN_JUMP | IN_DUCK)
		if smartJumpButtons ~= 0 then
			userCmd:SetButtons(userCmd.buttons | smartJumpButtons)
		end

		G.Navigation.currentNodeTicks = G.Navigation.currentNodeTicks + 1

		-- Expensive walkability verification - only when stuck for a while
                if G.Navigation.currentNodeTicks > 66 then
                        if not isWalkable.Path(LocalOrigin, node.pos) then
                                Log:Warn("Path to current node blocked after being stuck, repathing...")
                                local path = G.Navigation.path
                                if path and #path > 1 then
                                        local currentNode = path[1]
                                        local nextNode = path[2]
                                        if currentNode and nextNode then
                                                local penalty = isWalkable.Path(LocalOrigin, node.pos, "Aggressive") and 50 or 100
                                                Node.AddFailurePenalty(currentNode, nextNode, penalty)
                                        end
                                end
                                Navigation.ResetTickTimer()
                                G.currentState = G.States.PATHFINDING
                                return
                        end
                end

		-- Fast re-sync when blast displacement < 1200 uu (optional recovery system)
		local path = G.Navigation.path
		local origin = G.pLocal.Origin
		local MAX_SNAP = 1200 * 1200 -- sqDist

		if path and #path > 0 and G.Navigation.currentNodeTicks > 30 then -- Only after being stuck for a bit
			-- Scan *once* from front to back for the first node we can still walk to
			for i = 1, math.min(#path, 30) do
				local pathNode = path[i]
				if pathNode and pathNode.pos and (pathNode.pos - origin):LengthSqr() < MAX_SNAP then
					-- Only do expensive walkability check for potential recovery targets
					if isWalkable.Path(origin, pathNode.pos) then
						-- Drop everything before i
						for j = 1, i - 1 do
							Navigation.RemoveCurrentNode()
						end
						Log:Debug("Re-synced to path node %d after displacement", i)
						break
					end
				end
			end
		end

		-- Simple stuck detection and repathing
                if G.Navigation.currentNodeTicks > 264 then
                        Log:Warn("Stuck for too long, repathing...")
                        local path = G.Navigation.path
                        if path and #path > 1 then
                                local currentNode = path[1]
                                local nextNode = path[2]
                                if currentNode and nextNode then
                                        local penalty = 10
                                        if not isWalkable.Path(LocalOrigin, nextNode.pos) then
                                                if isWalkable.Path(LocalOrigin, nextNode.pos, "Aggressive") then
                                                        penalty = 50
                                                else
                                                        penalty = 100
                                                end
                                        end
                                        Node.AddFailurePenalty(currentNode, nextNode, penalty)
                                        Log:Debug(
                                                "Added failure penalty to connection %d -> %d due to prolonged stuck",
                                                currentNode.id,
                                                nextNode.id
                                        )
                                end
                        end
                        Navigation.ResetTickTimer()
                        G.currentState = G.States.PATHFINDING
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

       if not G.prevState then
               G.prevState = G.currentState
       end

	-- If bot is disabled via menu, do nothing
	if not G.Menu.Main.Enable then
		Navigation.ClearPath()
		G.BotIsMoving = false -- Clear bot movement state when disabled
		return
	end

	G.pLocal.entity = pLocal
	G.pLocal.flags = pLocal:GetPropInt("m_fFlags")
	G.pLocal.Origin = pLocal:GetAbsOrigin()

	-- PERFORMANCE FIX: Only run memory cleanup every 300 ticks (5 seconds) to prevent frame drops
	local currentTick = globals.TickCount()
	if not G.lastCleanupTick then
		G.lastCleanupTick = currentTick
	end

	if currentTick - G.lastCleanupTick > 300 then -- Every 5 seconds
		G.CleanupMemory()
		G.lastCleanupTick = currentTick
	end

       if handleUserInput(userCmd) then
               G.BotIsMoving = false -- Clear bot movement state when user takes control
               return
       end --if user is walking

       if G.wasManualWalking then
               if userCmd:GetForwardMove() == 0 and userCmd:GetSideMove() == 0 then
                       G.wasManualWalking = false
                       G.lastPathfindingTick = 0 -- force repath soon
               end
       end

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

       -- Repath when state changes
       if G.prevState ~= G.currentState then
               if WorkManager.attemptWork(33, "StateChangeRepath") then
                       G.lastPathfindingTick = 0
               end
               G.prevState = G.currentState
       end

       -- Repath if goal node changed
       if G.Navigation.goalPos and G.Navigation.goalNodeId then
               if WorkManager.attemptWork(33, "GoalCheck") then
                       local newNode = Navigation.GetClosestNode(G.Navigation.goalPos)
                       if newNode and newNode.id ~= G.Navigation.goalNodeId then
                               G.lastPathfindingTick = 0
                               G.Navigation.goalNodeId = newNode.id
                       end
               end
       end

       -- Repath after navmesh updates
       if G.Navigation.navMeshUpdated then
               G.Navigation.navMeshUpdated = false
               G.lastPathfindingTick = 0
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

-- Ensure SmartJump callback runs BEFORE MedBot's callback by using a name that comes after alphabetically
callbacks.Unregister("CreateMove", "ZMedBot.CreateMove") -- Z prefix ensures it runs after SmartJump
callbacks.Unregister("DrawModel", "MedBot.DrawModel")
callbacks.Unregister("FireGameEvent", "MedBot.FireGameEvent")

callbacks.Register("CreateMove", "ZMedBot.CreateMove", OnCreateMove) -- Z prefix ensures it runs after SmartJump
callbacks.Register("DrawModel", "MedBot.DrawModel", OnDrawModel)
callbacks.Register("FireGameEvent", "MedBot.FireGameEvent", OnGameEvent)

--[[ Commands ]]

Commands.Register("pf_reload", function()
	Navigation.Setup()
end)

Commands.Register("pf_hierarchical", function(args)
	if args[1] == "network" then
		Node.GenerateHierarchicalNetwork()
		Notify.Simple(
			"Started hierarchical network generation",
			"Will process across multiple ticks to prevent freezing",
			5
		)
	elseif args[1] == "status" then
		-- Check setup progress by accessing the SetupState
		if G.Navigation.hierarchical then
			print("Hierarchical network ready and available")
		else
			print("Hierarchical network not yet available - check if setup is in progress")
		end
	elseif args[1] == "info" then
		local areaId = tonumber(args[2])
		if areaId then
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
	if args[1] == "status" then
		local status = Node.GetConnectionProcessingStatus()
		if status.isProcessing then
			local phaseNames = {
				[1] = "Basic validation",
				[2] = "Expensive fallback",
				[3] = "Stair patching",
				[4] = "Fine point stitching",
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
			local path = G.Navigation.path
			if path and #path > 1 then
				local nextNode = path[2]
				if nextNode and Navigation.isWalkable(origin, nextNode.pos) then
					print("Path optimization successful - can skip to next node")
				else
					print("Path optimization failed - cannot skip current node")
				end
			else
				print("No path or insufficient nodes to test")
			end
		else
			print("Player not available for testing")
		end
	elseif args[1] == "info" then
		print(string.format("Skip Nodes: %s", G.Menu.Main.Skip_Nodes and "Enabled" or "Disabled"))
		print(string.format("Walking Mode: %s", G.Menu.Main.WalkableMode or "Smooth"))

		local path = G.Navigation.path
		if path and #path > 0 then
			print(string.format("Current path: %d nodes remaining", #path))
		else
			print("No active path")
		end
	else
		print("Usage: pf_optimize test | info")
		print("  test - Test if current node can be skipped")
		print("  info - Show node skipping settings and path status")
	end
end)

Commands.Register("pf_stairs", function(args)
	local nodes = Node.GetNodes()

	if not nodes or not next(nodes) then
		print("No navigation nodes loaded")
		return
	end

	if args[1] == "check" then
		-- Check for one-directional connections
		local oneWayConnections = 0
		local totalConnections = 0
		local existingConnections = {}

		-- Build connection lookup
		for nodeId, node in pairs(nodes) do
			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = Node.GetConnectionNodeId(connection)
							local key = nodeId .. "->" .. targetNodeId
							existingConnections[key] = true
							totalConnections = totalConnections + 1
						end
					end
				end
			end
		end

		-- Check for missing reverse connections
		for nodeId, node in pairs(nodes) do
			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = Node.GetConnectionNodeId(connection)
							local targetNode = nodes[targetNodeId]

							if targetNode then
								local reverseKey = targetNodeId .. "->" .. nodeId
								if not existingConnections[reverseKey] then
									local heightDiff = targetNode.pos.z - node.pos.z
									if math.abs(heightDiff) > 18 and math.abs(heightDiff) <= 200 then
										oneWayConnections = oneWayConnections + 1
									end
								end
							end
						end
					end
				end
			end
		end

		print(string.format("Connection Analysis:"))
		print(string.format("  Total connections: %d", totalConnections))
		print(string.format("  One-way stair connections: %d", oneWayConnections))
		print(string.format("  Potential patches: %d", oneWayConnections))
	else
		print("Usage: pf_stairs check")
		print("  check - Analyze one-directional stair connections")
	end
end)

Commands.Register("pf_costs", function(args)
	if args[1] == "recalc" then
		Node.RecalculateConnectionCosts()
		print("Connection costs recalculated for current walking mode")
	elseif args[1] == "info" then
		print(string.format("Walking Mode: %s", G.Menu.Main.WalkableMode or "Smooth"))
		if G.Menu.Main.WalkableMode == "Smooth" then
			print("  - Uses 18-unit steps + height penalties")
			print("  - Adds 10 cost per 18 units of height")
		else
			print("  - Allows 72-unit jumps without penalties")
		end

		local nodes = Node.GetNodes()
		if nodes then
			local totalConnections = 0
			local costlyConnections = 0
			for _, node in pairs(nodes) do
				if node and node.c then
					for _, connectionDir in pairs(node.c) do
						if connectionDir and connectionDir.connections then
							for _, connection in ipairs(connectionDir.connections) do
								totalConnections = totalConnections + 1
								local cost = Node.GetConnectionCost(connection)
								if cost > 1 then
									costlyConnections = costlyConnections + 1
								end
							end
						end
					end
				end
			end
			print(string.format("Connections: %d total, %d with extra costs", totalConnections, costlyConnections))
		end
	else
		print("Usage: pf_costs recalc | info")
		print("  recalc - Recalculate all connection costs for current walking mode")
		print("  info   - Show walking mode and connection cost statistics")
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

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		Log:Info("Connection cleanup enabled - this may cause temporary frame drops")
		-- Note: pruneInvalidConnections function is handled automatically during node setup
	else
		Log:Info("Connection cleanup is disabled in settings (recommended for performance)")
	end
end
