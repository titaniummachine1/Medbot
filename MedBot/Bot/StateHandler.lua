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
local ISWalkable = require("MedBot.Navigation.ISWalkable")
local SmartJump = require("MedBot.Bot.SmartJump")

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
				Log:Info("Direct-walk (short hop) with %s, moving immediately (dist: %.1f)", walkMode, distance)
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

	-- Check velocity and path walkability for unstuck
	local pLocal = G.pLocal.entity
	if pLocal then
		local velocity = pLocal:EstimateAbsVelocity()
		local speed2D = velocity and math.sqrt(velocity.x^2 + velocity.y^2) or 0

		-- If velocity drops below 50, check if path is walkable
		if speed2D < 50 then
			local path = G.Navigation.path
			if path and #path >= 1 then
				local currentNode = path[1]
				if currentNode and currentNode.pos then
					local walkMode = G.Menu.Main.WalkableMode or "Smooth"
					local origin = G.pLocal.Origin

					-- Check if we can walk to current target
					if not ISWalkable.Path(origin, currentNode.pos, walkMode) then
						Log:Warn("Velocity < 50 (%.1f) and path to current node is unwalkable - adding 100 cost penalty", speed2D)

						-- Find the connection and add 100 cost
						if #path >= 2 then
							local prevNode = #path >= 2 and path[#path - 1] or nil
							local currNode = path[#path - 1]
							local nextNode = path[#path]

							if prevNode and currNode and nextNode then
								-- Add cost to the connection we're trying to traverse
								local connection = Node.GetConnectionEntry(currNode, nextNode)
								if connection then
									connection.cost = (connection.cost or 1) + 100
									Log:Info("Added 100 cost penalty to connection %d -> %d (new cost: %d)",
										currNode.id, nextNode.id, connection.cost)
								end
							end
						end

						-- Force immediate repath
						G.currentState = G.States.PATHFINDING
						G.lastPathfindingTick = 0
						G.Navigation.stuckStartTick = nil
						return
					end
				end
			end
		end
	end

	-- Rest of the existing stuck logic for circuit breaker...
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
			if SmartJump.Main(userCmd) then
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
