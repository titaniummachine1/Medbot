--[[
    Simple Ray-Marching Path Validator
    Like IsWalkable but uses navmesh awareness to minimize traces
]]

local vectordivide = vector.Divide
local vectorLength = vector.Length

local Navigable = {}
local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")
local Common = require("MedBot.Core.Common")

-- Constants
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT = 18
local JUMP_HEIGHT = 72
local STEP_HEIGHT_Vector = Vector3(0, 0, STEP_HEIGHT)
local JUMP_HEIGHT_Vector = Vector3(0, 0, JUMP_HEIGHT)
local FORWARD_STEP = 100 -- Max distance per forward trace
local HILL_THRESHOLD = 4 -- 0.5x step height for significant elevation changes

local MaxSpeed = 450
local MAX_FALL_DISTANCE = 250
local MAX_FALL_DISTANCE_Vector = Vector3(0, 0, MAX_FALL_DISTANCE)
local STEP_FRACTION = STEP_HEIGHT / MAX_FALL_DISTANCE
local UP_VECTOR = Vector3(0, 0, 1)
local MIN_STEP_SIZE = MaxSpeed * globals.TickInterval()
local MAX_SURFACE_ANGLE = 55
local MAX_ITERATIONS = 37
local TOLERANCE = 10.0

-- Debug
local DEBUG_MODE = true -- Set to true for debugging (enables traces)
local hullTraces = {}
local currentTickLogged = -1

local engineTraceHull = engine.TraceHull

local function traceHullWrapper(startPos, endPos, minHull, maxHull, mask, filter)
	local currentTick = globals.TickCount()
	if currentTick > currentTickLogged then
		hullTraces = {}
		currentTickLogged = currentTick
	end
	local result = engineTraceHull(startPos, endPos, minHull, maxHull, mask)
	table.insert(hullTraces, { startPos = startPos, endPos = result.endpos })
	return result
end


local TraceHull = DEBUG_MODE and traceHullWrapper or engineTraceHull

-- Helper: Get surface angle from normal-- curently unused
local function getSurfaceAngle(surfaceNormal)
	if not surfaceNormal then
		return 0
	end
	return math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))
end


-- Adjust the direction vector to align with the surface normal
local function adjustDirectionToSurface(direction, surfaceNormal)
	direction = Common.Normalize(direction)
	local angle = math.deg(math.acos(surfaceNormal:Dot(UP_VECTOR)))

	if angle > MAX_SURFACE_ANGLE then
		return direction
	end

	-- Project horizontal direction onto sloped surface
	-- 1. Get right vector perpendicular to horizontal direction
	local right = direction:Cross(UP_VECTOR)
	if right:Length() < 0.0001 then
		-- Direction is straight up/down, return as-is
		return direction
	end
	right = Common.Normalize(right)

	-- 2. Get forward direction on surface (perpendicular to both right and surface normal)
	local forward = right:Cross(surfaceNormal)
	forward = Common.Normalize(forward)

	-- 3. Ensure forward points in same general direction as input
	if forward:Dot(direction) < 0 then
		forward = forward * -1
	end

	return forward
end

-- Find where ray exits node bounds
-- Returns: exitPoint, exitDist, exitDir (1=N, 2=E, 3=S, 4=W)
local function findNodeExit(startPos, dir, node)
	local minX, maxX = node._minX, node._maxX
	local minY, maxY = node._minY, node._maxY

	local tMin = math.huge
	local exitX, exitY
	local exitDir = nil

	-- Check X boundaries
	if dir.x > 0 then
		local t = (maxX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = maxX
			exitY = startPos.y + dir.y * t
			exitDir = 2 -- East
		end
	elseif dir.x < 0 then
		local t = (minX - startPos.x) / dir.x
		if t > 0 and t < tMin then
			tMin = t
			exitX = minX
			exitY = startPos.y + dir.y * t
			exitDir = 4 -- West
		end
	end

	-- Check Y boundaries
	if dir.y > 0 then
		local t = (maxY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = maxY
			exitDir = 3 -- South
		end
	elseif dir.y < 0 then
		local t = (minY - startPos.y) / dir.y
		if t > 0 and t < tMin then
			tMin = t
			exitX = startPos.x + dir.x * t
			exitY = minY
			exitDir = 1 -- North
		end
	end

	if tMin == math.huge then
		return nil, nil, nil
	end
	return Vector3(exitX, exitY, startPos.z), tMin, exitDir
end

-- Calculate ground Z position from node quad geometry (no engine call)
local function getGroundZFromQuad(pos, node)
	if not (node.nw and node.ne and node.sw and node.se) then
		return nil, nil
	end

	local nw, ne, sw, se = node.nw, node.ne, node.sw, node.se

	-- Determine which triangle contains the point
	-- Split quad into: Triangle1(nw,ne,se) and Triangle2(nw,se,sw)
	local dx = pos.x - nw.x
	local dy = pos.y - nw.y
	local dx_ne = ne.x - nw.x
	local dy_se = se.y - nw.y

	local inTriangle1 = (dx / dx_ne + dy / dy_se) <= 1.0

	local v0, v1, v2
	if inTriangle1 then
		-- Triangle: nw, ne, se
		v0, v1, v2 = nw, ne, se
	else
		-- Triangle: nw, se, sw
		v0, v1, v2 = nw, se, sw
	end

	-- Barycentric interpolation for Z
	local denom = (v1.y - v2.y) * (v0.x - v2.x) + (v2.x - v1.x) * (v0.y - v2.y)
	if math.abs(denom) < 0.0001 then
		return v0.z, UP_VECTOR -- Degenerate triangle, use first vertex
	end

	local w0 = ((v1.y - v2.y) * (pos.x - v2.x) + (v2.x - v1.x) * (pos.y - v2.y)) / denom
	local w1 = ((v2.y - v0.y) * (pos.x - v2.x) + (v0.x - v2.x) * (pos.y - v2.y)) / denom
	local w2 = 1.0 - w0 - w1

	local z = w0 * v0.z + w1 * v1.z + w2 * v2.z

	-- Calculate normal from cross product
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local normal = edge1:Cross(edge2)
	normal = Common.Normalize(normal)
	if not normal then
		normal = UP_VECTOR
	end

	return z, normal
end

-- Helper: Check if horizontal point is within node bounds (with tolerance)
local function isPointInNodeBounds(point, node, tolerance)
	tolerance = tolerance or 0
	local inX = point.x >= (node._minX - tolerance) and point.x <= (node._maxX + tolerance)
	local inY = point.y >= (node._minY - tolerance) and point.y <= (node._maxY + tolerance)
	return inX and inY
end

-- Helper: Check if exit point is valid for neighbor connection
-- Tolerance only on opposite axis to shared edge
-- Z check: down up to 450, up to jump/step height based on allowJump
local function isValidNeighborConnection(currentNode, candidateNode, exitPoint, exitDir, allowJump)
	local EDGE_TOLERANCE = 16.0 -- Increased for edge alignment
	local maxUp = allowJump and JUMP_HEIGHT or STEP_HEIGHT

	-- Get ground Z at exit point for both nodes
	local currentZ = getGroundZFromQuad(exitPoint, currentNode)
	local candidateZ = getGroundZFromQuad(exitPoint, candidateNode)

	if not currentZ or not candidateZ then
		if DEBUG_MODE then
			print(string.format("[IsNavigable]   FAIL: No ground Z - currentZ=%s, candidateZ=%s", tostring(currentZ),
				tostring(candidateZ)))
		end
		return false
	end

	-- Check Z height difference
	local zDiff = candidateZ - currentZ
	if zDiff > maxUp or zDiff < -MAX_FALL_DISTANCE then
		if DEBUG_MODE then
			print(string.format("[IsNavigable]   FAIL: Z diff %.1f outside range [%.1f, %.1f]", zDiff, -
			MAX_FALL_DISTANCE, maxUp))
		end
		return false
	end

	-- Check bounds based on exit direction (tolerance only on opposite axis)
	if exitDir == 2 or exitDir == 4 then -- East/West - shared X edge
		-- X must be at the edge (with tolerance), Y can have tolerance
		local atXEdge = (exitPoint.x >= candidateNode._minX - EDGE_TOLERANCE and exitPoint.x <= candidateNode._maxX + EDGE_TOLERANCE)
		local inY = exitPoint.y >= (candidateNode._minY - TOLERANCE) and exitPoint.y <= (candidateNode._maxY + TOLERANCE)
		if DEBUG_MODE then
			print(string.format(
				"[IsNavigable]   E/W check: exit=(%.1f,%.1f), node bounds=[%.1f,%.1f,%.1f,%.1f], atXEdge=%s, inY=%s",
				exitPoint.x, exitPoint.y, candidateNode._minX, candidateNode._maxX, candidateNode._minY,
				candidateNode._maxY,
				tostring(atXEdge), tostring(inY)))
		end
		return atXEdge and inY
	else -- North/South - shared Y edge
		-- Y must be at the edge (with tolerance), X can have tolerance
		local atYEdge = (exitPoint.y >= candidateNode._minY - EDGE_TOLERANCE and exitPoint.y <= candidateNode._maxY + EDGE_TOLERANCE)
		local inX = exitPoint.x >= (candidateNode._minX - TOLERANCE) and exitPoint.x <= (candidateNode._maxX + TOLERANCE)
		if DEBUG_MODE then
			print(string.format(
				"[IsNavigable]   N/S check: exit=(%.1f,%.1f), node bounds=[%.1f,%.1f,%.1f,%.1f], atYEdge=%s, inX=%s",
				exitPoint.x, exitPoint.y, candidateNode._minX, candidateNode._maxX, candidateNode._minY,
				candidateNode._maxY,
				tostring(atYEdge), tostring(inX)))
		end
		return atYEdge and inX
	end
end

-- Helper: Find neighbor node through connections/doors from exit point
local function findNeighborAtExit(currentNode, exitPoint, exitDir, nodes, respectDoors, allowJump)
	local dirData = currentNode.c[exitDir]
	if not dirData or not dirData.connections then
		return nil
	end

	local connCount = #dirData.connections
	-- TOLERANCE removed - using Z-based height checks in isValidNeighborConnection

	-- Determine search direction based on exit position
	local searchForward = true
	if exitDir == 2 or exitDir == 4 then -- East/West (X axis)
		local midX = (currentNode._minX + currentNode._maxX) * 0.5
		searchForward = exitPoint.x < midX
	else -- North/South (Y axis)
		local midY = (currentNode._minY + currentNode._maxY) * 0.5
		searchForward = exitPoint.y < midY
	end

	local start, finish, step = 1, connCount, 1
	if not searchForward then
		start, finish, step = connCount, 1, -1
	end

	for i = start, finish, step do
		local connection = dirData.connections[i]
		local targetId = (type(connection) == "table") and (connection.node or connection.id) or connection
		local candidate = nodes[targetId]

		if not candidate then
			goto continue
		end

		-- Area node with bounds
		if candidate._minX and candidate._maxX and candidate._minY and candidate._maxY then
			local checkNode = candidate

			-- If respecting doors, find door between currentNode and candidate
			if respectDoors then
				for _, conn in ipairs(dirData.connections) do
					local tid = (type(conn) == "table") and (conn.node or conn.id) or conn
					local door = nodes[tid]
					if door and not door._minX and door.c then
						-- Check if door connects to candidate
						for _, ddir in pairs(door.c) do
							if ddir.connections then
								for _, dconn in ipairs(ddir.connections) do
									local did = (type(dconn) == "table") and (dconn.node or dconn.id) or dconn
									if did == candidate.id then
										checkNode = door
										break
									end
								end
							end
							if checkNode == door then
								break
							end
						end
						if checkNode == door then
							break
						end
					end
				end
			end

			local inBounds = isValidNeighborConnection(currentNode, checkNode, exitPoint, exitDir, allowJump)
			if DEBUG_MODE then
				print(
					string.format(
						"[IsNavigable]   Check area=%d via %s, bounds=[%.1f,%.1f,%.1f,%.1f], exit=(%.1f,%.1f), inBounds=%s",
						candidate.id,
						(checkNode == candidate and "area" or "door"),
						checkNode._minX,
						checkNode._maxX,
						checkNode._minY,
						checkNode._maxY,
						exitPoint.x,
						exitPoint.y,
						tostring(inBounds)
					)
				)
			end

			if inBounds then
				return candidate
			end

			-- Door node - traverse through to find area on other side
		elseif candidate.c then
			if DEBUG_MODE then
				print(string.format("[IsNavigable]   Conn %d: Door %s, traversing...", i, tostring(targetId)))
			end
			for doorDir, doorDirData in pairs(candidate.c) do
				if doorDirData.connections then
					for _, doorConn in ipairs(doorDirData.connections) do
						local areaId = (type(doorConn) == "table") and (doorConn.node or doorConn.id) or doorConn
						local areaNode = nodes[areaId]

						if DEBUG_MODE then
							print(
								string.format(
									"[IsNavigable]     Door dir %s -> area %s (exists=%s, hasBounds=%s)",
									tostring(doorDir),
									tostring(areaId),
									tostring(areaNode ~= nil),
									tostring(areaNode and areaNode._minX ~= nil)
								)
							)
						end

						if areaId ~= currentNode.id and areaNode and areaNode._minX then
							local inBounds = isValidNeighborConnection(currentNode, areaNode, exitPoint, exitDir,
								allowJump)
							if DEBUG_MODE then
								print(
									string.format(
										"[IsNavigable]       Check area %s inBounds=%s, bounds=[%.1f,%.1f,%.1f,%.1f]",
										tostring(areaId),
										tostring(inBounds),
										areaNode._minX,
										areaNode._maxX,
										areaNode._minY,
										areaNode._maxY
									)
								)
							end
							if inBounds then
								return areaNode
							end
						end
					end
				end
			end
		end

		::continue::
	end

	return nil
end

-- Helper: Trace through waypoints (Phase 2)
-- allowJump: if true, will attempt jump (72 units) when hitting obstacles
local function traceWaypoints(waypoints, allowJump)
	local ANGLE_CHANGE_THRESHOLD = 15 -- degrees
	local traceStart = waypoints[1]
	local traceCount = 0

	for i = 2, #waypoints do
		local currentWp = waypoints[i]
		local prevWp = waypoints[i - 1]

		-- Calculate angle change between consecutive normals
		local angleChange = 0
		if prevWp.normal and currentWp.normal then
			local dotProduct = prevWp.normal:Dot(currentWp.normal)
			dotProduct = math.max(-1, math.min(1, dotProduct))
			angleChange = math.deg(math.acos(dotProduct))
		end

		-- Check if this is last waypoint or angle changed significantly
		local isLastWaypoint = (i == #waypoints)
		local zDiff = math.abs(currentWp.pos.z - prevWp.pos.z)
		local shouldTrace = isLastWaypoint or angleChange > ANGLE_CHANGE_THRESHOLD or zDiff > 8

		if shouldTrace then
			-- Calculate horizontal direction from trace start to current
			local toTarget = currentWp.pos - traceStart.pos
			local horizDir = Vector3(toTarget.x, toTarget.y, 0)
			horizDir = Common.Normalize(horizDir)

			-- Adjust direction using trace start's surface normal
			local traceDir = horizDir
			if traceStart.normal then
				traceDir = adjustDirectionToSurface(horizDir, traceStart.normal)
				if DEBUG_MODE then
					print(string.format(
						"[IsNavigable] Trace using start normal (%.2f, %.2f, %.2f) -> dir (%.2f, %.2f, %.2f)",
						traceStart.normal.x, traceStart.normal.y, traceStart.normal.z,
						traceDir.x, traceDir.y, traceDir.z))
				end
			else
				if DEBUG_MODE then
					print(string.format("[IsNavigable] Trace using flat direction (no start normal)"))
				end
			end
			-- Calculate trace endpoint
			local traceDist = (currentWp.pos - traceStart.pos):Length()
			local traceEnd = traceStart.pos + traceDir * traceDist

			-- Check if going significantly downward - if so, don't add upward step offset to end
			local zDiff = currentWp.pos.z - traceStart.pos.z
			local isGoingDown = zDiff < -8

			local stepHeightVec = Vector3(0, 0, STEP_HEIGHT)
			local jumpHeightVec = Vector3(0, 0, JUMP_HEIGHT)
			local traceSuccess = false

			-- Store the base Z for this segment to prevent height accumulation
			local baseZ = traceStart.pos.z
			local currentTracePos = traceStart.pos
			local currentTraceNormal = traceStart.normal

			-- Try step height first, then jump height if needed
			local stepHeights = { STEP_HEIGHT, JUMP_HEIGHT }
			local currentStepIndex = 1
			local maxRetries = 3
			local retryCount = 0
			local hitNode = nil
			local lastTracePos = nil -- Track last position to detect no progress

			while currentStepIndex <= #stepHeights and retryCount < maxRetries do
				local stepH = stepHeights[currentStepIndex]
				local stepVec = Vector3(0, 0, stepH)
				local useJump = (stepH == JUMP_HEIGHT)

				-- Skip jump attempt if not allowed
				if useJump and not allowJump then
					break
				end

				-- Calculate trace endpoint based on current position
				local toTarget = traceEnd - currentTracePos
				local remainingDist = toTarget:Length()
				if remainingDist < 0.001 then
					traceSuccess = true
					break
				end

				local traceDir = Common.Normalize(toTarget)
				local currentTraceEnd = currentTracePos + traceDir * remainingDist

				-- Forward trace with current step height
				-- When going down, don't add step offset to end (follow slope naturally)
				local traceStartPos = currentTracePos + stepVec
				local traceEndPos = isGoingDown and currentTraceEnd or (currentTraceEnd + stepVec)
				local trace = TraceHull(
					traceStartPos,
					traceEndPos,
					PLAYER_HULL.Min,
					PLAYER_HULL.Max,
					MASK_SHOT_HULL
				)

				traceCount = traceCount + 1

				if trace.fraction >= 0.99 then
					-- Clear path - reached destination
					traceSuccess = true
					break
				end

				-- Hit something - find what node/area the hit is in
				local hitPos = trace.endpos
				local nodes = G.Navigation and G.Navigation.nodes

				if nodes then
					hitNode = Node.GetAreaAtPosition(hitPos)
				end

				if not hitNode then
					-- No valid node at hit position - try next step height
					if DEBUG_MODE then
						print(string.format("[IsNavigable] Hit at (%.1f, %.1f, %.1f) not on navmesh, trying next...",
							hitPos.x, hitPos.y, hitPos.z))
					end
					currentStepIndex = currentStepIndex + 1
					retryCount = retryCount + 1
					goto continue_retry
				end

				-- Adjust to ground on the hit node's navmesh
				local groundZ, groundNormal = getGroundZFromQuad(hitPos, hitNode)

				if not groundZ then
					-- No ground on this node - try next step height
					if DEBUG_MODE then
						print(string.format("[IsNavigable] No ground on node %d at hit, trying next...", hitNode.id))
					end
					currentStepIndex = currentStepIndex + 1
					retryCount = retryCount + 1
					goto continue_retry
				end

				-- Check if surface angle is too steep for this step height
				if groundNormal then
					local surfaceAngle = math.deg(math.acos(groundNormal:Dot(UP_VECTOR)))
					if surfaceAngle > MAX_SURFACE_ANGLE then
						if DEBUG_MODE then
							print(string.format("[IsNavigable] Surface too steep (%.1f° > %.1f°), trying next step height...",
								surfaceAngle, MAX_SURFACE_ANGLE))
						end
						currentStepIndex = currentStepIndex + 1
						retryCount = retryCount + 1
						goto continue_retry
					end
				end

				-- Clamp Z to prevent climbing too high
				local maxAllowedZ = baseZ + stepH
				if groundZ > maxAllowedZ then
					if DEBUG_MODE then
						print(string.format("[IsNavigable] Ground too high (%.1f > %.1f), clamping", groundZ, maxAllowedZ))
					end
					groundZ = maxAllowedZ
				end

				local groundPos = Vector3(hitPos.x, hitPos.y, groundZ)

				if DEBUG_MODE then
					print(string.format("[IsNavigable] Hit on node %d, adjusted to (%.1f, %.1f, %.1f)", hitNode.id,
						groundPos.x, groundPos.y, groundPos.z))
				end

				-- Check if we're making progress (XY must change)
				local dx = groundPos.x - currentTracePos.x
				local dy = groundPos.y - currentTracePos.y
				local horizDist = math.sqrt(dx * dx + dy * dy)
				if horizDist < 0.5 then
					-- No progress - try next step height
					if DEBUG_MODE then
						print(string.format("[IsNavigable] No progress made (horiz=%.2f), trying next step height...",
							horizDist))
					end
					currentStepIndex = currentStepIndex + 1
					retryCount = retryCount + 1
					goto continue_retry
				end

				-- If using jump, check if we changed nodes
				if useJump then
					local nodeAtGround = Node.GetAreaAtPosition(groundPos)
					if nodeAtGround and nodeAtGround.id == hitNode.id then
						-- Same node - jump didn't get us past the obstacle
						if DEBUG_MODE then
							print(string.format("[IsNavigable] Jump failed: still on node %d, giving up", hitNode.id))
						end
						return false
					else
						-- Different node - jump succeeded
						if DEBUG_MODE then
							print(string.format("[IsNavigable] Jump success: moved to node %d from node %d",
								nodeAtGround and nodeAtGround.id or -1, hitNode.id))
						end
					end
				end

				-- Update position and continue with same step height (retry)
				currentTracePos = groundPos
				currentTraceNormal = groundNormal
				retryCount = retryCount + 1

				::continue_retry::
			end

			if not traceSuccess then
				if DEBUG_MODE then
					print(
						string.format(
							"[IsNavigable] FAIL: Entity blocking segment (trace %d, angle=%.1f°)",
							traceCount,
							angleChange
						)
					)
				end
				return false
			end

			-- Start next trace segment from current waypoint
			traceStart = currentWp
		end
	end

	if DEBUG_MODE then
		print(
			string.format(
				"[IsNavigable] SUCCESS: Path clear with %d traces (from %d waypoints)",
				traceCount,
				#waypoints
			)
		)
	end

	return true
end

-- MAIN FUNCTION - Two phases: 1) verify path through nodes, 2) trace with surface pitch
-- allowJump: if true, will use jump height (72) when step height (18) fails
function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors, allowJump)
	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	-- ============ PHASE 1: Verify path through nodes ============
	local currentPos = startPos
	local currentNode = startNode
	local waypoints = {} -- Waypoints for Phase 2

	-- Get starting ground Z
	local startZ, startNormal = getGroundZFromQuad(startPos, startNode)
	if startZ then
		currentPos = Vector3(startPos.x, startPos.y, startZ)
	end

	-- Add start waypoint
	table.insert(waypoints, {
		pos = currentPos,
		node = startNode,
		normal = startNormal,
	})

	-- Traverse to destination (no traces - just verify path exists)
	for iteration = 1, MAX_ITERATIONS do
		-- Check if goal reached
		if isPointInNodeBounds(goalPos, currentNode) then
			table.insert(waypoints, { pos = goalPos, node = currentNode, normal = nil })
			return traceWaypoints(waypoints, allowJump)
		end

		-- Find where we exit current node toward goal
		local toGoal = goalPos - currentPos
		-- Horizontal direction to destination (only X/Y matters for heading)
		local horizDir = Vector3(toGoal.x, toGoal.y, 0)
		horizDir = Common.Normalize(horizDir)

		-- Get ground normal at current position
		local groundZ, groundNormal = getGroundZFromQuad(currentPos, currentNode)

		-- Adjust direction to follow surface - only Z changes based on slope
		local dir = horizDir
		if groundNormal then
			dir = adjustDirectionToSurface(horizDir, groundNormal)
		end

		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, dir, currentNode)

		if not exitPoint or not exitDir then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: No exit found from node %d", currentNode.id))
			end
			return false
		end

		if DEBUG_MODE then
			local dirNames = { [1] = "N", [2] = "E", [3] = "S", [4] = "W" }
			print(
				string.format(
					"[IsNavigable] Exit via %s at (%.1f, %.1f)",
					dirNames[exitDir] or "?",
					exitPoint.x,
					exitPoint.y
				)
			)
		end

		-- Find neighbor
		local neighborNode = findNeighborAtExit(currentNode, exitPoint, exitDir, nodes, respectDoors, allowJump)

		if not neighborNode then
			if DEBUG_MODE then
				print(
					string.format(
						"[IsNavigable] FAIL: No neighbor found at exit (%.1f, %.1f)",
						exitPoint.x,
						exitPoint.y
					)
				)
			end
			return false
		end

		-- Calculate entry point clamped to neighbor bounds
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))

		local entryZ, entryNormal = getGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)

		if not entryZ then
			if DEBUG_MODE then
				print(string.format("[IsNavigable] FAIL: No ground geometry at entry to node %d", neighborNode.id))
			end
			return false
		end

		local entryPos = Vector3(entryX, entryY, entryZ)

		-- Add intermediate waypoint if Z changes significantly (for slopes/hills)
		local zDiff = math.abs(entryZ - currentPos.z)
		if zDiff > 8 then
			-- Create intermediate waypoint at exit point with interpolated Z
			local exitZ = getGroundZFromQuad(exitPoint, currentNode)
			if exitZ then
				local exitPos = Vector3(exitPoint.x, exitPoint.y, exitZ)
				local _, exitNormal = getGroundZFromQuad(exitPoint, currentNode)
				table.insert(waypoints, { pos = exitPos, node = currentNode, normal = exitNormal })
				if DEBUG_MODE then
					print(string.format("[IsNavigable] Added slope waypoint at exit (Z=%.1f)", exitZ))
				end
			end
		end

		table.insert(waypoints, { pos = entryPos, node = neighborNode, normal = entryNormal })

		if DEBUG_MODE then
			print(string.format("[IsNavigable] Crossed to node %d (Z=%.1f)", neighborNode.id, entryZ))
		end

		currentPos = entryPos
		currentNode = neighborNode
	end

	if DEBUG_MODE then
		print(string.format("[IsNavigable] FAIL: Max iterations (%d) exceeded", MAX_ITERATIONS))
	end
	return false
end

-- Debug
function Navigable.DrawDebugTraces()
	if not DEBUG_MODE then
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
	DEBUG_MODE = enabled
end

return Navigable
