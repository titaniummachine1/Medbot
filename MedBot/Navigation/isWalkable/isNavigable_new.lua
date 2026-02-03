function Navigable.CanSkip(startPos, goalPos, startNode, respectDoors)
	Profiler.Begin("CanSkip")

	assert(startNode, "CanSkip: startNode required")
	local nodes = G.Navigation and G.Navigation.nodes
	assert(nodes, "CanSkip: G.Navigation.nodes is nil")

	-- PHASE 1: Verify path is traversable through nodes (no traces)
	local currentPos = startPos
	local currentNode = startNode
	local pathPoints = {} -- Store points for trace phase

	-- Get initial ground info
	local startZ, startNormal = getGroundZFromQuad(startPos, startNode)
	if startZ then
		currentPos = Vector3(startPos.x, startPos.y, startZ)
	end

	local lastHeight = currentPos.z
	local highestHeight = currentPos.z
	local lastWasClimbing = false

	for iteration = 1, MAX_ITERATIONS do
		Profiler.Begin("VerifyIteration")

		-- Check if goal is in current node
		local goalInCurrentNode = goalPos.x >= currentNode._minX
			and goalPos.x <= currentNode._maxX
			and goalPos.y >= currentNode._minY
			and goalPos.y <= currentNode._maxY

		if goalInCurrentNode then
			-- Reached destination node
			table.insert(pathPoints, {
				type = "goal",
				pos = goalPos,
				node = currentNode
			})
			Profiler.End("VerifyIteration")
			break
		end

		-- Find exit and next node (same logic as before)
		local toGoal = goalPos - currentPos
		local horizDir = Vector3(toGoal.x, toGoal.y, 0)
		horizDir = Common.Normalize(horizDir)

		local _, groundNormal = getGroundZFromQuad(currentPos, currentNode)
		local dir = horizDir
		if groundNormal then
			dir = adjustDirectionToSurface(horizDir, groundNormal)
		end

		local exitPoint, exitDist, exitDir = findNodeExit(currentPos, dir, currentNode)
		if not exitPoint then
			Profiler.End("VerifyIteration")
			Profiler.End("CanSkip")
			return false
		end

		-- Find neighbor
		local neighborNode = nil
		if currentNode.c and currentNode.c[exitDir] then
			-- (neighbor finding logic - abbreviated for space)
			local dirData = currentNode.c[exitDir]
			if dirData.connections then
				for _, connection in ipairs(dirData.connections) do
					local targetId = (type(connection) == "table") and (connection.node or connection.id) or connection
					local candidate = nodes[targetId]
					if candidate and candidate._minX then
						local inX = exitPoint.x >= (candidate._minX - 5.0) and exitPoint.x <= (candidate._maxX + 5.0)
						local inY = exitPoint.y >= (candidate._minY - 5.0) and exitPoint.y <= (candidate._maxY + 5.0)
						if inX and inY then
							neighborNode = candidate
							break
						end
					end
				end
			end
		end

		if not neighborNode then
			Profiler.End("VerifyIteration")
			Profiler.End("CanSkip")
			return false
		end

		-- Get entry point Z
		local entryX = math.max(neighborNode._minX + 0.5, math.min(neighborNode._maxX - 0.5, exitPoint.x))
		local entryY = math.max(neighborNode._minY + 0.5, math.min(neighborNode._maxY - 0.5, exitPoint.y))
		local groundZ, _ = getGroundZFromQuad(Vector3(entryX, entryY, 0), neighborNode)

		if not groundZ then
			Profiler.End("VerifyIteration")
			Profiler.End("CanSkip")
			return false
		end

		local entryPos = Vector3(entryX, entryY, groundZ)

		-- Check for hills/caves
		local heightDiff = groundZ - lastHeight

		if heightDiff > HILL_THRESHOLD and not lastWasClimbing then
			-- Started climbing
			table.insert(pathPoints, {
				type = "hill_start",
				pos = currentPos,
				node = currentNode
			})
			lastWasClimbing = true
		elseif heightDiff < -HILL_THRESHOLD and lastWasClimbing then
			-- Was climbing, now descending - save hill peak
			table.insert(pathPoints, {
				type = "hill_peak",
				pos = Vector3(currentPos.x, currentPos.y, highestHeight),
				node = currentNode
			})
			lastWasClimbing = false
		end

		if groundZ > highestHeight then
			highestHeight = groundZ
		end

		-- Check for cave
		if lastHeight - groundZ > HILL_THRESHOLD then
			table.insert(pathPoints, {
				type = "cave",
				pos = entryPos,
				node = neighborNode
			})
		end

		lastHeight = groundZ
		currentPos = entryPos
		currentNode = neighborNode
		Profiler.End("VerifyIteration")
	end

	-- PHASE 2: Do traces through all points
	Profiler.Begin("TracePhase")

	local lastTracePos = startPos
	if startZ then
		lastTracePos = Vector3(startPos.x, startPos.y, startZ)
	end

	-- Do initial trace from start to first point
	if #pathPoints > 0 then
		local firstPoint = pathPoints[1]
		local toTarget = firstPoint.pos - lastTracePos
		local horizDir = Vector3(toTarget.x, toTarget.y, 0)

		if horizDir:Length() > 0.001 then
			horizDir = Common.Normalize(horizDir)
			local _, startNormal = getGroundZFromQuad(lastTracePos, startNode)
			local traceDir = horizDir
			if startNormal then
				traceDir = adjustDirectionToSurface(horizDir, startNormal)
			end

			local traceDist = (firstPoint.pos - lastTracePos):Length()
			local traceTarget = lastTracePos + traceDir * traceDist

			Profiler.Begin("InitialTrace")
			local initialTrace = TraceHull(
				lastTracePos + STEP_HEIGHT_Vector,
				traceTarget + STEP_HEIGHT_Vector,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID
			)
			Profiler.End("InitialTrace")

			if initialTrace.fraction < 0.99 then
				if DEBUG_TRACES then
					print("[IsNavigable] FAIL: Entity blocking initial path")
				end
				Profiler.End("TracePhase")
				Profiler.End("CanSkip")
				return false
			end

			lastTracePos = initialTrace.endpos - STEP_HEIGHT_Vector
		end
	end

	-- Trace through all intermediate points
	for i = 1, #pathPoints - 1 do
		local point = pathPoints[i]
		local nextPoint = pathPoints[i + 1]

		local toTarget = nextPoint.pos - lastTracePos
		local horizDir = Vector3(toTarget.x, toTarget.y, 0)
		horizDir = Common.Normalize(horizDir)

		local _, normal = getGroundZFromQuad(lastTracePos, point.node)
		local traceDir = horizDir
		if normal then
			traceDir = adjustDirectionToSurface(horizDir, normal)
		end

		local traceDist = (nextPoint.pos - lastTracePos):Length()
		local traceTarget = lastTracePos + traceDir * traceDist

		Profiler.Begin("PointTrace")
		local trace = TraceHull(
			lastTracePos + STEP_HEIGHT_Vector,
			traceTarget + STEP_HEIGHT_Vector,
			PLAYER_HULL.Min,
			PLAYER_HULL.Max,
			MASK_PLAYERSOLID
		)
		Profiler.End("PointTrace")

		if trace.fraction < 0.99 then
			if DEBUG_TRACES then
				print(string.format("[IsNavigable] FAIL: Entity blocking path at point %d", i))
			end
			Profiler.End("TracePhase")
			Profiler.End("CanSkip")
			return false
		end

		lastTracePos = trace.endpos - STEP_HEIGHT_Vector
	end

	if DEBUG_TRACES then
		print(string.format("[IsNavigable] SUCCESS: Path verified and traced (%d points)", #pathPoints))
	end

	Profiler.End("TracePhase")
	Profiler.End("CanSkip")
	return true
end
