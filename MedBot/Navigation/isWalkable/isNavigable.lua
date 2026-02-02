--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]
local Navigable = {}
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local FORWARD_STEP = 100 -- Max distance per forward trace

-- Debug
local DEBUG_TRACES = true
local hullTraces = {}
local currentTickLogged = -1

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		currentTickLogged = currentTick
	end
	local result = engine.TraceHull(startPos, endPos, minHull, maxHull, mask, filter)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end

local TraceHull = DEBUG_TRACES and traceHullWrapper or engine.TraceHull

local function shouldHitEntity(entity)
	local pLocal = G.pLocal and G.pLocal.entity
	return entity ~= pLocal
end

-- Get which node contains this position using spatial query
local function getNodeAtPosition(pos)
	return Node.GetAreaAtPosition(pos)
end

-- Direction constants
local DIR_NORTH = 1
local DIR_SOUTH = 2
local DIR_EAST = 4
local DIR_WEST = 8

-- Find where ray exits node bounds
local function findNodeExit(startPos, dir, node)
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY
	local exitDir

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
			exitDir = DIR_EAST
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
			exitDir = DIR_WEST
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
			exitDir = DIR_NORTH
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
			exitDir = DIR_SOUTH
		end
	end

	if tMin == math.huge then
		return nil
	end

	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- MAIN FUNCTION - Trace to borders
function Navigable.CanSkip(startPos, goalPos, startNode, respectPortals)
	assert(startNode, "CanSkip: startNode required")

	if respectPortals == nil then
		respectPortals = true -- Default: respect doors/portals
	end

	if DEBUG_TRACES then
		print(
			string.format(
				"[IsNavigable] START: From (%.1f, %.1f) to (%.1f, %.1f), respectPortals=%s",
				startPos.x,
				startPos.y,
				goalPos.x,
				goalPos.y,
				tostring(respectPortals)
			)
		)
	end

	local currentPos = startPos
	local currentNode = startNode
	local iteration = 0
	local MAX_ITERATIONS = 20

	while iteration < MAX_ITERATIONS do
		iteration = iteration + 1

		-- Direction to goal from current position
		local toGoal = goalPos - currentPos
		local distToGoal = toGoal:Length()

		if distToGoal < 50 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] SUCCESS: Within 50 units of goal"))
			end
			return true
		end

		local dir = toGoal / distToGoal

		if DEBUG_TRACES then
			print(
				string.format(
					"[IsNavigable] Iter %d: node=%d, pos=(%.1f,%.1f), distToGoal=%.1f",
					iteration,
					currentNode.id,
					currentPos.x,
					currentPos.y,
					distToGoal
				)
			)
		end

		-- Check if goal is in current node
		local goalNode = getNodeAtPosition(goalPos)
		if goalNode and goalNode.id == currentNode.id then
			-- Final trace to goal
			local finalTrace = TraceHull(
				currentPos + STEP_HEIGHT_Vector,
				goalPos + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)
			if finalTrace.fraction > 0.99 then
				if DEBUG_TRACES then
					print("[IsNavigable] SUCCESS: Direct trace to goal in same node")
				end
				return true
			else
				if DEBUG_TRACES then
					print(
						string.format("[IsNavigable] FAIL: Blocked at %.2f in same node as goal", finalTrace.fraction)
					)
				end
				return false
			end
		end

		-- Find where we exit current node
		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, dir, currentNode)
		if not exitPoint then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			return false
		end

		-- Trace to exit point
		local exitTrace = TraceHull(
			currentPos + STEP_HEIGHT_Vector,
			exitPoint + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)

		if exitTrace.fraction < 0.99 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: Hit obstacle at %.2f before border", exitTrace.fraction))
			end
			return false
		end

		-- Get neighbor directly from connection data
		local neighborNode = nil

		if currentNode.c and currentNode.c[exitDir] then
			local dirData = currentNode.c[exitDir]
			if dirData.connections and #dirData.connections > 0 then
				-- Get first connection (typically only one in each direction)
				local conn = dirData.connections[1]
				local neighborId = type(conn) == "table" and conn.node or conn

				-- Look up the actual node
				local nodes = G.Navigation and G.Navigation.nodes
				if nodes then
					neighborNode = nodes[neighborId]
				end

				if DEBUG_TRACES and neighborNode then
					print(
						string.format(
							"[IsNavigable] Found neighbor node %d via exitDir %d connection",
							neighborId,
							exitDir
						)
					)
				end
			end
		end

		if not neighborNode then
			if DEBUG_TRACES then
				print(
					string.format(
						"[IsNavigable] FAIL: No neighbor connection in exitDir %d from node %d",
						exitDir,
						currentNode.id
					)
				)
			end
			return false
		end

		-- Portal checking if enabled
		if respectPortals then
			-- Check for door on EITHER side of the boundary
			local foundPortal = false

			-- Calculate opposite direction for entry check
			local entryDir
			if exitDir == DIR_NORTH then
				entryDir = DIR_SOUTH
			elseif exitDir == DIR_SOUTH then
				entryDir = DIR_NORTH
			elseif exitDir == DIR_EAST then
				entryDir = DIR_WEST
			elseif exitDir == DIR_WEST then
				entryDir = DIR_EAST
			end

			-- Check exit connection on current node
			if currentNode.c and currentNode.c[exitDir] then
				local dirData = currentNode.c[exitDir]
				if DEBUG_TRACES then
					print(
						string.format(
							"[DEBUG] EXIT side: node=%d dir=%d hasConns=%s hasDoor=%s",
							currentNode.id,
							exitDir,
							tostring(dirData.connections ~= nil),
							tostring(dirData.door ~= nil)
						)
					)
				end

				if dirData.connections then
					-- Check if connection to neighbor exists
					for _, conn in ipairs(dirData.connections) do
						local targetId = type(conn) == "table" and conn.node or conn
						if targetId == neighborNode.id then
							-- Connection exists - check if there's a door
							if dirData.door then
								local door = dirData.door
								if DEBUG_TRACES then
									print(
										string.format(
											"[DEBUG] EXIT door bounds: (%.1f,%.1f)-(%.1f,%.1f)",
											door.minX,
											door.minY,
											door.maxX,
											door.maxY
										)
									)
								end
								-- Must be within door bounds
								if
									exitPoint.x >= door.minX
									and exitPoint.x <= door.maxX
									and exitPoint.y >= door.minY
									and exitPoint.y <= door.maxY
								then
									foundPortal = true
									if DEBUG_TRACES then
										print(
											string.format(
												"[IsNavigable] Portal found at EXIT with door in dir %d",
												exitDir
											)
										)
									end
									break
								end
							else
								-- No door = open connection, allow it
								foundPortal = true
								if DEBUG_TRACES then
									print(
										string.format(
											"[IsNavigable] Open connection at EXIT (no door) in dir %d",
											exitDir
										)
									)
								end
								break
							end
						end
					end
				end
			end

			-- If no exit connection, check entry connection on neighbor node
			if not foundPortal and neighborNode.c and neighborNode.c[entryDir] then
				local dirData = neighborNode.c[entryDir]
				if DEBUG_TRACES then
					print(
						string.format(
							"[DEBUG] ENTRY side: node=%d dir=%d hasConns=%s hasDoor=%s",
							neighborNode.id,
							entryDir,
							tostring(dirData.connections ~= nil),
							tostring(dirData.door ~= nil)
						)
					)
				end

				if dirData.connections then
					-- Check if connection to current node exists
					if DEBUG_TRACES then
						print(string.format("[DEBUG] ENTRY has %d connections", #dirData.connections))
					end
					for _, conn in ipairs(dirData.connections) do
						local targetId = type(conn) == "table" and conn.node or conn
						if DEBUG_TRACES then
							print(
								string.format(
									"[DEBUG] ENTRY conn target=%s, looking for=%d",
									tostring(targetId),
									currentNode.id
								)
							)
						end
						if targetId == currentNode.id then
							-- Connection exists - check if there's a door
							if dirData.door then
								local door = dirData.door
								if DEBUG_TRACES then
									print(
										string.format(
											"[DEBUG] ENTRY door bounds: (%.1f,%.1f)-(%.1f,%.1f)",
											door.minX,
											door.minY,
											door.maxX,
											door.maxY
										)
									)
								end
								-- Must be within door bounds
								if
									exitPoint.x >= door.minX
									and exitPoint.x <= door.maxX
									and exitPoint.y >= door.minY
									and exitPoint.y <= door.maxY
								then
									foundPortal = true
									if DEBUG_TRACES then
										print(
											string.format(
												"[IsNavigable] Portal found at ENTRY with door in dir %d",
												entryDir
											)
										)
									end
									break
								end
							else
								-- No door = open connection, allow it
								foundPortal = true
								if DEBUG_TRACES then
									print(
										string.format(
											"[IsNavigable] Open connection at ENTRY (no door) in dir %d",
											entryDir
										)
									)
								end
								break
							end
						end
					end
				end
			end

			if not foundPortal then
				if DEBUG_TRACES then
					print(
						string.format(
							"[IsNavigable] FAIL: No portal at boundary (%.1f, %.1f) exit_dir=%d entry_dir=%d",
							exitPoint.x,
							exitPoint.y,
							exitDir,
							entryDir
						)
					)
				end
				return false
			end
		end

		-- Entry point is exitPoint clamped to neighbor bounds
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))
		local entryPos = Vector3(entryX, entryY, exitPoint.z)

		-- Ground snap at entry
		local groundTrace = TraceHull(
			entryPos + STEP_HEIGHT_Vector,
			entryPos - Vector3(0, 0, 100),
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID,
			shouldHitEntity
		)

		if groundTrace.fraction == 1 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: No ground at entry to node %d", neighborNode.id))
			end
			return false
		end

		if DEBUG_TRACES then
			print(string.format("[IsNavigable] Crossed to node %d", neighborNode.id))
		end

		currentPos = groundTrace.endpos
		currentNode = neighborNode
	end

	if DEBUG_TRACES then
		print(string.format("[IsNavigable] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
	end
	return false
end

-- Debug
function Navigable.DrawDebugTraces()
	if not DEBUG_TRACES then
		return
	end
	for _, trace in ipairs(hullTraces) do
		if trace.startPos and trace.endPos then
			draw.Color(0, 50, 255, 255)
			Common.DrawArrowLine(trace.startPos, trace.endPos - Vector3(0, 0, 0.5), 10, 20, false)
		end
	end
end

function Navigable.SetDebug(enabled)
	DEBUG_TRACES = enabled
end

return Navigable
