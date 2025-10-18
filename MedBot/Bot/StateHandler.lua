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
local PathValidator = require("MedBot.Navigation.PathValidator")
local SmartJump = require("MedBot.Bot.SmartJump")

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
			if PathValidator.Path(G.pLocal.Origin, goalPos) then
				Log:Info("Direct-walk (short hop), moving immediately (dist: %.1f)", distance)
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

	-- Only allow pathfinding every 90 ticks (~1.5 seconds) to prevent spam
	if currentTick - G.lastPathfindingTick < 90 then
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
		if goalPos and PathValidator.Path(G.pLocal.Origin, goalPos) then
			G.Navigation.path = { { pos = goalPos, id = goalNode.id } }
			G.currentState = G.States.MOVING
			G.lastPathfindingTick = currentTick
			Log:Info("Moving directly to goal from goal node %d", startNode.id)
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
	local WorkManager = require("MedBot.WorkManager")

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

return StateHandler
