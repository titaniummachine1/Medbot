-- Movement Execution Module - Physics-accurate walking, unstuck logic, and movement state handling
-- This handles the actual movement execution, not pathfinding or validation
local MovementCore = {}

local G = require("MedBot.Core.Globals")
local Common = require("MedBot.Core.Common")
local isWalkable = require("MedBot.Navigation.ISWalkable")
local Node = require("MedBot.Navigation.Node")
local Navigation = require("MedBot.Navigation")

local Log = Common.Log.new("MovementCore")

-- Constants for physics-accurate movement
local MAX_SPEED = 450 -- Maximum speed the player can move
local TWO_PI = 2 * math.pi
local DEG_TO_RAD = math.pi / 180

-- Ground-physics helpers (synced with server convars)
local DEFAULT_GROUND_FRICTION = 4 -- fallback for sv_friction
local DEFAULT_SV_ACCELERATE = 10 -- fallback for sv_accelerate

local function GetGroundFriction()
	local ok, val = pcall(client.GetConVar, "sv_friction")
	if ok and val and val > 0 then
		return val
	end
	return DEFAULT_GROUND_FRICTION
end

local function GetGroundMaxDeltaV(player, tick)
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
local function ComputeMove(userCmd, a, b)
	local dx, dy = b.x - a.x, b.y - a.y

	local targetYaw = (math.atan(dy, dx) + TWO_PI) % TWO_PI
	local _, currentYaw = userCmd:GetViewAngles()
	currentYaw = currentYaw * DEG_TO_RAD

	local yawDiff = (targetYaw - currentYaw + math.pi) % TWO_PI - math.pi

	return Vector3(math.cos(yawDiff) * MAX_SPEED, math.sin(-yawDiff) * MAX_SPEED, 0)
end

-- Predictive/no-overshoot WalkTo (superior implementation from standstill dummy)
function MovementCore.WalkTo(cmd, player, dest)
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
	local drag = math.max(0, 1 - GetGroundFriction() * tick)
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
	local aMax = GetGroundMaxDeltaV(player, tick)
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
	local moveVec = ComputeMove(cmd, pos, dirEnd)
	local fwd = (moveVec.x / MAX_SPEED) * wishSpeed
	local side = (moveVec.y / MAX_SPEED) * wishSpeed

	-- Set the movement commands
	cmd:SetForwardMove(fwd)
	cmd:SetSideMove(side)
end

-- Function to get the target position from a node, handling door positions if available
local function getNodePosition(node)
	if not node or not node.pos then
		return nil
	end

	-- Check if this is a door node with specific positions
	if node.doorPositions then
		-- Use middle position if available, otherwise fall back to node position
		return node.doorPositions.middle or node.pos
	end

	return node.pos
end

-- Simple function to get the next point in the path, following A*'s order
local function getNextPathPoint()
	local path = G.Navigation.path or {}
	if #path == 0 then
		return nil, nil
	end

	-- Initialize or get current path index
	G.Navigation.currentIndex = G.Navigation.currentIndex or 1
	local currentIdx = G.Navigation.currentIndex

	-- If we've reached the end of the path, stay at the last node
	if currentIdx > #path then
		currentIdx = #path
		G.Navigation.currentIndex = currentIdx
	end

	local currentNode = path[currentIdx]
	if not currentNode then
		return nil, nil
	end

	local nodePos = getNodePosition(currentNode)

	-- If we're close to the current node, advance to the next one
	if nodePos then
		local LocalOrigin = G.pLocal and G.pLocal.Origin or Vector3(0, 0, 0)
		local distance = (nodePos - LocalOrigin):Length2D()

		-- If we're close enough to the current node, move to the next one
		if distance < 32 and currentIdx < #path then -- 32 unit threshold
			currentIdx = currentIdx + 1
			G.Navigation.currentIndex = currentIdx
			currentNode = path[currentIdx]
			if currentNode then
				nodePos = getNodePosition(currentNode)
			else
				nodePos = nil
			end
		end
	end

	return currentNode, nodePos
end

-- Function to move along the path
function MovementCore.moveTowardsNode(userCmd, currentNode)
	-- Reset path index if we don't have a valid current node
	if not currentNode or not currentNode.pos then
		G.Navigation.currentIndex = nil
		return
	end

	-- Initialize path index if needed
	if G.Navigation.currentIndex == nil then
		G.Navigation.currentIndex = 1
	end

	-- Get the next point to move towards
	local targetNode, targetPos = getNextPathPoint()
	if not targetNode or not targetPos then
		return
	end

	-- Store the intended movement direction for SmartJump to use
	local LocalOrigin = G.pLocal.Origin
	local direction = targetPos - LocalOrigin
	local distance = direction:Length2D()

	-- Only update direction if we have a valid distance
	if distance > 0 then
		G.BotMovementDirection = direction / distance
		G.BotIsMoving = true

		-- Move directly towards the target point
		MovementCore.WalkTo(userCmd, G.pLocal.entity, targetPos)

		-- Check if we've reached the end of the path
		local nav = G.Navigation
		if nav.currentIndex and nav.path and nav.currentIndex >= #nav.path then
			-- Wait until we're close to the final node before clearing the path
			local LocalOrigin = G.pLocal and G.pLocal.Origin or Vector3(0, 0, 0)
			local finalNode = nav.path[#nav.path]
			local finalPos = finalNode and getNodePosition(finalNode)

			if finalPos and (finalPos - LocalOrigin):Length2D() < 32 then
				nav.path = {}
				nav.currentIndex = nil
			end
		end
	else
		G.BotIsMoving = false
	end

	-- Update movement tick counter
	G.Navigation.currentNodeTicks = (G.Navigation.currentNodeTicks or 0) + 1
end

-- Function to handle the MOVING state
function MovementCore.handleMovingState(userCmd)
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

	MovementCore.moveTowardsNode(userCmd, currentNode)

	-- Only detect stuck; actual penalties applied in STUCK state every ~1s
	if G.Navigation.currentNodeTicks > 66 then
		-- Remember last node before stuck to target penalty precisely
		local hist = G.Navigation.pathHistory or {}
		G.Navigation.lastPreStuckNodeId = (hist[1] and hist[1].id) or nil
		G.Navigation.currentStuckTargetNodeId = currentNode and currentNode.id or nil

		G.currentState = G.States.STUCK
		return
	end
end

-- Function to handle the STUCK state
function MovementCore.handleStuckState(userCmd)
	local currentTick = globals.TickCount()
	if not G.Navigation._lastStuckEval then
		G.Navigation._lastStuckEval = 0
	end

	-- Evaluate roughly every second (~66 ticks)
	if (currentTick - G.Navigation._lastStuckEval) < 66 then
		return
	end
	G.Navigation._lastStuckEval = currentTick

	local path = G.Navigation.path
	if path and #path > 1 then
		local fromNode = path[1]
		local toNode = path[2]
		if fromNode and toNode and fromNode.id and toNode.id and fromNode.id ~= toNode.id then
			local walkMode = G.Menu.Main.WalkableMode or "Smooth"
			local blocked = not isWalkable.Path(G.pLocal.Origin, toNode.pos, walkMode)

			-- Also treat zero-velocity / no-progress as stuck
			local origin = G.pLocal.Origin
			local ent = G.pLocal and G.pLocal.entity or nil
			local vel = ent and ent.EstimateAbsVelocity and ent:EstimateAbsVelocity() or Vector3(0, 0, 0)
			if vel then
				vel.z = 0
			end
			local speed = vel and vel.Length and vel:Length() or 0
			local distNow = (toNode.pos - origin):Length()
			local lastDist = G.Navigation._lastStuckEvalDist or distNow
			local progress = lastDist - distNow
			G.Navigation._lastStuckEvalDist = distNow
			-- Thresholds: very low speed and negligible progress since last evaluation (~1s)
			local stall = (speed < 10) and (progress < 8)

			if blocked or stall then
				-- Penalize the exact current edge (door) from fromNode -> toNode
				if fromNode and toNode and fromNode.id ~= toNode.id then
					Node.AddFailurePenalty(fromNode, toNode, 100)
					Log:Debug("STUCK: current edge penalty applied %d -> %d (+100)", fromNode.id, toNode.id)
					-- Record a circuit-breaker failure for this edge
					if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
						G.CircuitBreaker.addConnectionFailure(fromNode, toNode)
						Log:Debug("STUCK: recorded connection failure %d -> %d", fromNode.id, toNode.id)
					end
				end

				-- Build up to two prior edges: prev2->prev1, prev1->fromNode
				local edges = {}
				local hist = G.Navigation.pathHistory or {}
				-- Edge 1: prev2 -> prev1
				if hist[2] and hist[1] then
					edges[#edges + 1] = { a = hist[2], b = hist[1] }
				end
				-- Edge 2: prev1 -> fromNode
				if hist[1] then
					edges[#edges + 1] = { a = hist[1], b = fromNode }
				end

				-- Additionally, penalize remembered last->current edge for precise targeting
				local nodesTbl = G.Navigation.nodes
				if nodesTbl and G.Navigation.lastPreStuckNodeId then
					local lastNode = nodesTbl[G.Navigation.lastPreStuckNodeId]
					if lastNode and fromNode then
						edges[#edges + 1] = { a = lastNode, b = fromNode, remembered = true }
					end
				end

				for _, e in ipairs(edges) do
					if e.a and e.b and e.a.id and e.b.id and e.a.id ~= e.b.id then
						Node.AddFailurePenalty(e.a, e.b, 100)
						if e.remembered then
							Log:Debug("STUCK: remembered edge penalty applied %d -> %d (+100)", e.a.id, e.b.id)
						end
						-- Record circuit-breaker failure for prior/remembered edges as well
						if G.CircuitBreaker and G.CircuitBreaker.addConnectionFailure then
							G.CircuitBreaker.addConnectionFailure(e.a, e.b)
						end
					end
				end

				if blocked then
					Log:Info(
						"STUCK: destination unwalkable (%s). Penalised prior edges near %d -> %d and repathing",
						walkMode,
						fromNode.id,
						toNode.id
					)
				else
					Log:Info(
						"STUCK: no progress (speed=%.1f, progress=%.1f). Penalised prior edges near %d -> %d and repathing",
						speed,
						progress,
						fromNode.id,
						toNode.id
					)
				end

				-- Clear traversal history and remembered IDs for the new attempt
				G.Navigation.pathHistory = {}
				G.Navigation.lastPreStuckNodeId = nil
				G.Navigation.currentStuckTargetNodeId = nil

				-- Trigger repath and continue
				Navigation.ResetTickTimer()
				G.currentState = G.States.PATHFINDING
				G.lastPathfindingTick = 0
				return
			else
				-- Not blocked anymore: resume moving
				Navigation.ResetTickTimer()
				G.currentState = G.States.MOVING
				return
			end
		end
	end

	-- Fallback: if no path or invalid, return to PATHFINDING
	Navigation.ResetTickTimer()
	G.currentState = G.States.PATHFINDING
	G.lastPathfindingTick = 0
end

return MovementCore
