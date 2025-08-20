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

	-- Build forward successors and reverse predecessors with edge costs
	local successors = {}
	local predecessors = {}

	local function getSuccessors(node)
		local succ = successors[node]
		if succ then
			return succ
		end
		local list = {}
		for _, neighbor in ipairs(adjacentFun(node, nodes)) do
			list[#list + 1] = { node = neighbor.node, cost = neighbor.cost or 1 }
			if not predecessors[neighbor.node] then
				predecessors[neighbor.node] = {}
			end
			predecessors[neighbor.node][#predecessors[neighbor.node] + 1] = { node = node, cost = neighbor.cost or 1 }
		end
		successors[node] = list
		return list
	end

	local function getPredecessors(node)
		return predecessors[node] or {}
	end

	-- State: g and rhs values
	local g, rhs = {}, {}
	local km = 0 -- No incremental movement handling in this simple version

	local function calculateKey(node)
		local minGRhs = math.min(g[node] or INF, rhs[node] or INF)
		return { minGRhs + manhattan(startNode, node) + km, minGRhs }
	end

	-- Open list with custom comparator on keys
	local open = Heap.new(function(a, b)
		return isKeyLess(a.key, b.key)
	end)

	-- Track last enqueued key to detect stale entries on pop
	local enqueuedKey = {}

	local function pushNode(node)
		local key = calculateKey(node)
		enqueuedKey[node] = key
		open:push({ node = node, key = key })
	end

	local function updateVertex(u)
		if u ~= goalNode then
			local best = INF
			for _, s in ipairs(getSuccessors(u)) do
				local cand = (g[s.node] or INF) + (s.cost or 1)
				if cand < best then
					best = cand
				end
			end
			rhs[u] = best
		end

		if (g[u] or INF) ~= (rhs[u] or INF) then
			pushNode(u)
		end
	end

	-- Initialize
	g[goalNode] = INF
	rhs[goalNode] = 0
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
		while isKeyGreater(topKey(), calculateKey(startNode)) or (rhs[startNode] or INF) ~= (g[startNode] or INF) do
			if open:empty() then
				break
			end
			local uRec = open:pop()
			if not uRec or not uRec.node or not uRec.key then
				break
			end
			local u = uRec.node
			
			-- Check if entry is stale before declaring local variables
			local isStale = uRec.key[1] ~= (enqueuedKey[u] and enqueuedKey[u][1])
				or uRec.key[2] ~= (enqueuedKey[u] and enqueuedKey[u][2])
			
			if not isStale then
				local gU = g[u] or INF
				local rhsU = rhs[u] or INF
				local keyU = uRec.key
				local calcU = calculateKey(u)
				if isKeyGreater(keyU, calcU) then
					pushNode(u)
				elseif gU > rhsU then
					g[u] = rhsU
					for _, p in ipairs(getPredecessors(u)) do
						updateVertex(p.node)
					end
				else
					g[u] = INF
					updateVertex(u)
					for _, p in ipairs(getPredecessors(u)) do
						updateVertex(p.node)
					end
				end
			end
			
			iterGuard = iterGuard + 1
			if iterGuard > 500000 then -- safety guard against infinite loops
				break
			end
		end
	end

	-- Build all successors on-demand during search
	computeShortestPath()

	-- Extract path from start to goal using greedy next-step rule
	if (g[startNode] or INF) == INF then
		return nil
	end

	local path = { startNode }
	local current = startNode
	local hopGuard = 0

	while current ~= goalNode do
		local bestNeighbor = nil
		local bestScore = INF
		for _, s in ipairs(getSuccessors(current)) do
			local score = (g[s.node] or INF) + (s.cost or 1)
			if score < bestScore then
				bestScore = score
				bestNeighbor = s.node
			end
		end
		if not bestNeighbor or bestScore == INF then
			return nil
		end
		path[#path + 1] = bestNeighbor
		current = bestNeighbor

		hopGuard = hopGuard + 1
		if hopGuard > 10000 then
			break
		end
	end

	return path
end

return DStar
