local Heap = require("MedBot.Utils.Heap")

---@class DStar
local DStar = {}

local function manhattan(a, b)
	return math.abs(a.pos.x - b.pos.x) + math.abs(a.pos.y - b.pos.y)
end

local function isKeyLess(a, b)
	if a[1] < b[1] then
		return true
	elseif a[1] > b[1] then
		return false
	else
		return a[2] < b[2]
	end
end

local INF = math.huge

-- Compute the best path using a minimal D*-Lite style planner.
-- Note: This implementation builds fresh state per call (simple, readable),
-- which is acceptable for our dynamic penalties since we repath frequently.
--
-- adjacentFun must return an array of { node = neighborNode, cost = edgeCost }
function DStar.NormalPath(startNode, goalNode, nodes, adjacentFun)
	if not (startNode and goalNode and nodes and adjacentFun) then
		return nil
	end

	-- Safety check: ensure nodes have valid IDs for table keys
	if not startNode.id or not goalNode.id then
		return nil
	end

	-- Build forward successors and reverse predecessors with edge costs
	local successors = {}
	local predecessors = {}

	local function getSuccessors(node)
		-- Use node ID as key instead of node object to avoid metatable issues
		local nodeId = node.id
		if not nodeId then
			return {}
		end

		local succ = successors[nodeId]
		if succ then
			return succ
		end

		local list = {}
		local success, neighbors = pcall(adjacentFun, node, nodes)
		if not success then
			-- If adjacentFun fails, return empty list
			successors[nodeId] = list
			return list
		end

		for _, neighbor in ipairs(neighbors) do
			if neighbor and neighbor.node and neighbor.node.id then
				list[#list + 1] = { node = neighbor.node, cost = neighbor.cost or 1 }
				local neighborId = neighbor.node.id
				if not predecessors[neighborId] then
					predecessors[neighborId] = {}
				end
				predecessors[neighborId][#predecessors[neighborId] + 1] = { node = node, cost = neighbor.cost or 1 }
			end
		end
		successors[nodeId] = list
		return list
	end

	local function getPredecessors(node)
		local nodeId = node.id
		if not nodeId then
			return {}
		end
		return predecessors[nodeId] or {}
	end

	-- State: g and rhs values (use node IDs as keys)
	local g, rhs = {}, {}
	local km = 0 -- No incremental movement handling in this simple version

	local function calculateKey(node)
		local nodeId = node.id
		if not nodeId then
			return { math.huge, math.huge }
		end
		local minGRhs = math.min(g[nodeId] or INF, rhs[nodeId] or INF)
		return { minGRhs + manhattan(startNode, node) + km, minGRhs }
	end

	-- Open list with custom comparator on keys
	local open = Heap.new(function(a, b)
		return isKeyLess(a.key, b.key)
	end)

	-- Track last enqueued key to detect stale entries on pop (use node IDs)
	local enqueuedKey = {}

	local function pushNode(node)
		local nodeId = node.id
		if not nodeId then
			return
		end
		local key = calculateKey(node)
		enqueuedKey[nodeId] = key
		open:push({ node = node, key = key })
	end

	local function updateVertex(u)
		local nodeId = u.id
		if not nodeId then
			return
		end

		if u ~= goalNode then
			local best = INF
			for _, s in ipairs(getSuccessors(u)) do
				local neighborId = s.node.id
				if neighborId then
					local cand = (g[neighborId] or INF) + (s.cost or 1)
					if cand < best then
						best = cand
					end
				end
			end
			rhs[nodeId] = best
		end

		if (g[nodeId] or INF) ~= (rhs[nodeId] or INF) then
			pushNode(u)
		end
	end

	-- Initialize
	local goalId = goalNode.id
	g[goalId] = INF
	rhs[goalId] = 0
	pushNode(goalNode)

	-- Compute shortest path
	local function topKey()
		if open:empty() then
			return { INF, INF }
		end
		local peek = open:peek()
		return peek and peek.key or { INF, INF }
	end

	local function isKeyGreater(a, b)
		return isKeyLess(b, a)
	end

	local function computeShortestPath()
		local iterGuard = 0
		local maxIterations = 100000 -- Reduced from 500000 for faster failure detection

		while
			isKeyGreater(topKey(), calculateKey(startNode))
			or (rhs[startNode.id] or INF) ~= (g[startNode.id] or INF)
		do
			if open:empty() then
				break
			end

			local uRec = open:pop()
			if not uRec or not uRec.node or not uRec.key then
				break
			end

			local u = uRec.node
			local uId = u.id
			if not uId then
				break
			end

			-- Check if entry is stale before declaring local variables
			local isStale = uRec.key[1] ~= (enqueuedKey[uId] and enqueuedKey[uId][1])
				or uRec.key[2] ~= (enqueuedKey[uId] and enqueuedKey[uId][2])

			if not isStale then
				local gU = g[uId] or INF
				local rhsU = rhs[uId] or INF
				local keyU = uRec.key
				local calcU = calculateKey(u)
				if isKeyGreater(keyU, calcU) then
					pushNode(u)
				elseif gU > rhsU then
					g[uId] = rhsU
					for _, p in ipairs(getPredecessors(u)) do
						updateVertex(p.node)
					end
				else
					g[uId] = INF
					updateVertex(u)
					for _, p in ipairs(getPredecessors(u)) do
						updateVertex(p.node)
					end
				end
			end

			iterGuard = iterGuard + 1
			if iterGuard > maxIterations then -- safety guard against infinite loops
				break
			end
		end
	end

	-- Build all successors on-demand during search
	computeShortestPath()

	-- Extract path from start to goal using greedy next-step rule
	local startId = startNode.id
	if (g[startId] or INF) == INF then
		return nil
	end

	local path = { startNode }
	local current = startNode
	local hopGuard = 0
	local maxHops = 5000 -- Reduced from 10000 for faster failure detection

	while current ~= goalNode do
		local bestNeighbor = nil
		local bestScore = INF
		for _, s in ipairs(getSuccessors(current)) do
			local neighborId = s.node.id
			if neighborId then
				local score = (g[neighborId] or INF) + (s.cost or 1)
				if score < bestScore then
					bestScore = score
					bestNeighbor = s.node
				end
			end
		end
		if not bestNeighbor or bestScore == INF then
			return nil
		end
		path[#path + 1] = bestNeighbor
		current = bestNeighbor

		hopGuard = hopGuard + 1
		if hopGuard > maxHops then
			break
		end
	end

	return path
end

return DStar
