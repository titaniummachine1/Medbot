--##########################################################################
--  Node.lua  ·  MedBot Navigation / Hierarchical path-finding
--  2025-05-24  fully re-worked thin-area grid + robust inter-area linking
--##########################################################################

local Common = require("MedBot.Common")
local G = require("MedBot.Utils.Globals")
local SourceNav = require("MedBot.Utils.SourceNav")
local isWalkable = require("MedBot.Modules.ISWalkable")

-- Profiler disabled to prevent crashes
local Profiler = nil

-- Disable all profiler functions to prevent crashes
local function ProfilerBeginSystem(name) end
local function ProfilerEndSystem() end

local Log = Common.Log.new("Node") -- default Verbose in dev-build
Log.Level = 0

local Node = {}
Node.DIR = { N = 1, S = 2, E = 4, W = 8 }

--==========================================================================
--  CONSTANTS
--==========================================================================
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local GRID = 24 -- 24-unit fine grid

--==========================================================================
--  NAV-FILE LOADING (unchanged)
--==========================================================================
local function tryLoadNavFile(navFilePath)
	local file = io.open(navFilePath, "rb")
	if not file then
		return nil, "File not found"
	end
	local content = file:read("*a")
	file:close()
	local navData = SourceNav.parse(content)
	if not navData or #navData.areas == 0 then
		return nil, "Failed to parse nav file or no areas found."
	end
	return navData
end

local function generateNavFile()
	client.RemoveConVarProtection("sv_cheats")
	client.RemoveConVarProtection("nav_generate")
	client.SetConVar("sv_cheats", "1")
	client.Command("nav_generate", true)
	Log:Info("Generating nav file. Please wait...")
	local delay = 10
	local startTime = os.time()
	repeat
	until os.time() - startTime > delay
end

local function processNavData(navData)
	local navNodes = {}
	for _, area in pairs(navData.areas) do
		local cX = (area.north_west.x + area.south_east.x) / 2
		local cY = (area.north_west.y + area.south_east.y) / 2
		local cZ = (area.north_west.z + area.south_east.z) / 2
		local nw = Vector3(area.north_west.x, area.north_west.y, area.north_west.z)
		local se = Vector3(area.south_east.x, area.south_east.y, area.south_east.z)
		local ne = Vector3(area.south_east.x, area.north_west.y, area.north_east_z)
		local sw = Vector3(area.north_west.x, area.south_east.y, area.south_west_z)
		navNodes[area.id] =
			{ pos = Vector3(cX, cY, cZ), id = area.id, c = area.connections, nw = nw, se = se, ne = ne, sw = sw }
	end
	return navNodes
end

local function traceHullDown(position)
	-- Trace hull from above down to find ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, TRACE_MASK)
end

local function traceLineDown(position)
	-- Line trace down to adjust corner to ground, using hitbox height
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceLine(startPos, endPos, TRACE_MASK)
end

local function getGroundNormal(position)
	local trace =
		engine.TraceLine(position + GROUND_TRACE_OFFSET_START, position + GROUND_TRACE_OFFSET_END, MASK_BRUSH_ONLY)
	return trace.plane
end

local function calculateRemainingCorners(corner1, corner2, normal, height)
	local widthVector = corner2 - corner1
	local widthLength = widthVector:Length2D()
	local heightVector = Vector3(-widthVector.y, widthVector.x, 0)
	local function rotateAroundNormal(vector, angle)
		local cosT = math.cos(angle)
		local sinT = math.sin(angle)
		return Vector3(
			(cosT + (1 - cosT) * normal.x ^ 2) * vector.x
				+ ((1 - cosT) * normal.x * normal.y - normal.z * sinT) * vector.y
				+ ((1 - cosT) * normal.x * normal.z + normal.y * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.y + normal.z * sinT) * vector.x
				+ (cosT + (1 - cosT) * normal.y ^ 2) * vector.y
				+ ((1 - cosT) * normal.y * normal.z - normal.x * sinT) * vector.z,
			((1 - cosT) * normal.x * normal.z - normal.y * sinT) * vector.x
				+ ((1 - cosT) * normal.y * normal.z + normal.x * sinT) * vector.y
				+ (cosT + (1 - cosT) * normal.z ^ 2) * vector.z
		)
	end
	local rot = rotateAroundNormal(heightVector, math.pi / 2)
	return { corner1 + rot * (height / widthLength), corner2 + rot * (height / widthLength) }
end

--- Get all corner positions of a node
---@param node table The node to get corners from
---@return Vector3[] Array of corner positions
local function getNodeCorners(node)
	local corners = {}
	if node.nw then
		table.insert(corners, node.nw)
	end
	if node.ne then
		table.insert(corners, node.ne)
	end
	if node.se then
		table.insert(corners, node.se)
	end
	if node.sw then
		table.insert(corners, node.sw)
	end
	-- Always include center position
	if node.pos then
		table.insert(corners, node.pos)
	end
	return corners
end

--- Check if two nodes are accessible and return cost multiplier
--- Follows proper accessibility checking order as specified
---@param nodeA table First node (source)
---@param nodeB table Second node (destination)
---@param allowExpensive boolean Optional override to allow expensive checks
---@return boolean, number accessibility status and cost multiplier (1 = normal, >1 = penalty)
local function isNodeAccessible(nodeA, nodeB, allowExpensive)
	local heightDiff = nodeB.pos.z - nodeA.pos.z -- Positive = going up, negative = going down

	-- Always allow going downward (falling) regardless of height - no penalty
	if heightDiff <= 0 then
		return true, 1
	end

	-- Step 1: Check if destination is higher than 72 units
	if heightDiff > 72 then
		-- Step 2: Check if any of 4 corners of area A to any 4 corners of area B is within 72 units
		local cornersA = getNodeCorners(nodeA)
		local cornersB = getNodeCorners(nodeB)

		local foundValidCornerPath = false
		for _, cornerA in pairs(cornersA) do
			for _, cornerB in pairs(cornersB) do
				local cornerHeightDiff = cornerB.z - cornerA.z
				-- Allow if any corner-to-corner connection is within jump height
				if cornerHeightDiff <= 72 then
					foundValidCornerPath = true
					break
				end
			end
			if foundValidCornerPath then
				break
			end
		end

		if not foundValidCornerPath then
			-- Step 3: Last resort - check isWalkable if expensive checks allowed
			if allowExpensive and G.Menu.Main.AllowExpensiveChecks then
				if isWalkable.Path(nodeA.pos, nodeB.pos) then
					return true, 3 -- High cost for requiring expensive walkability check
				else
					-- Step 4: If all fails, still keep connection but with very high penalty
					return true, 10 -- Very high penalty instead of removing
				end
			else
				-- During fast processing, assume high penalty but keep connection
				return true, 5 -- High penalty for uncertain accessibility
			end
		else
			-- Corner path found - moderate penalty for complex terrain
			return true, 2
		end
	else
		-- For upward movement within 72 units, normal cost with small penalty
		if heightDiff > 18 then
			return true, 1.5 -- Small penalty for significant height gain
		else
			return true, 1 -- Normal cost for easy height gain
		end
	end
end

--==========================================================================
--  Connection utilities - Handle both integer IDs and cost objects
--==========================================================================

--- Extract node ID from connection (handles both integer and table format)
---@param connection any Connection data (integer ID or table with node/cost)
---@return integer Node ID
local function getConnectionNodeId(connection)
	if type(connection) == "table" then
		-- Support new enriched connection objects
		return connection.node or connection.neighborId
	else
		return connection
	end
end

--- Extract cost from connection (handles both integer and table format)
---@param connection any Connection data (integer ID or table with node/cost)
---@return number Cost value
local function getConnectionCost(connection)
	if type(connection) == "table" then
		return connection.cost or 1
	else
		return 1
	end
end

-- Normalize a single connection entry to the enriched table form
-- Keeps code simple and consistent across the codebase.
local function normalizeConnectionEntry(entry)
	if type(entry) == "table" then
		-- Ensure required keys exist; preserve any extra fields (flatten door points)
		entry.node = entry.node or entry.neighborId
		entry.cost = entry.cost or 1
		entry.left = entry.left or (entry.door and entry.door.left) or nil
		entry.middle = entry.middle or (entry.door and (entry.door.middle or entry.door.mid)) or nil
		entry.right = entry.right or (entry.door and entry.door.right) or nil
		entry.dir = entry.dir or (entry.door and entry.door.dir) or nil
		entry.door = nil -- flatten to keep structure simple per project philosophy
		return entry
	else
		-- Integer neighbor id -> enriched object
		return {
			node = entry,
			cost = 1,
			left = nil,
			middle = nil,
			right = nil,
			dir = nil,
		}
	end
end

--- Convert all raw integer connections to enriched objects with {node, cost, left, middle, right}
function Node.NormalizeConnections()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	-- Deterministic area order
	local ids = {}
	for id in pairs(nodes) do
		ids[#ids + 1] = id
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local area = nodes[id]
		if area and area.c then
			-- Prefer numeric 1..4 order for determinism
			for idx = 1, 4 do
				local cDir = area.c[idx]
				if cDir and cDir.connections then
					local newList = {}
					for _, entry in ipairs(cDir.connections) do
						newList[#newList + 1] = normalizeConnectionEntry(entry)
					end
					cDir.connections = newList
				end
			end
		end
	end
end

--=========================================================================
--  Door building on connections (Left, Middle, Right + needJump)
--=========================================================================

local HITBOX_WIDTH = 24
local STEP_HEIGHT = 18
local MAX_JUMP = 72
local CLEARANCE_OFFSET = 34 -- Move toward reachable side by 34 units after cutoff

local function signDirection(delta, threshold)
	if delta > threshold then
		return 1
	elseif delta < -threshold then
		return -1
	end
	return 0
end

-- Determine primary axis direction based purely on center delta.
-- Chooses the dominant axis by magnitude; sign encodes direction.
-- Examples:
--   dx=50, dy=100   -> dirX=0,  dirY= 1
--   dx=50, dy=-100  -> dirX=0,  dirY=-1
--   dx=-120,dy=40   -> dirX=-1, dirY= 0
local function determineDirection(fromPos, toPos)
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx >= 0) and 1 or -1, 0
	else
		return 0, (dy >= 0) and 1 or -1
	end
end

-- Robust cardinal direction using area bounds overlap (axis-aligned).
-- Returns dirX, dirY in {-1,0,1}. Falls back to center-based when ambiguous.
local function cardinalDirectionFromBounds(areaA, areaB)
	local function bounds(area)
		local minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
		local maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
		local minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
		local maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)
		return minX, maxX, minY, maxY
	end
	local aMinX, aMaxX, aMinY, aMaxY = bounds(areaA)
	local bMinX, bMaxX, bMinY, bMaxY = bounds(areaB)
	local eps = 2.0
	local overlapY = (aMinY <= bMaxY + eps) and (bMinY <= aMaxY + eps)
	local overlapX = (aMinX <= bMaxX + eps) and (bMinX <= aMaxX + eps)

	if overlapY and (aMaxX <= bMinX) then
		return 1, 0 -- A -> B is East
	end
	if overlapY and (bMaxX <= aMinX) then
		return -1, 0 -- A -> B is West
	end
	-- Note: Source Y axis appears inverted in-world for our use case; swap N/S signs
	if overlapX and (aMaxY <= bMinY) then
		return 0, -1 -- A -> B is South
	end
	if overlapX and (bMaxY <= aMinY) then
		return 0, 1 -- A -> B is North
	end
	-- Fallback: dominant axis with inverted Y sign
	local dx = areaB.pos.x - areaA.pos.x
	local dy = areaB.pos.y - areaA.pos.y
	if math.abs(dx) >= math.abs(dy) then
		return (dx >= 0) and 1 or -1, 0
	else
		return 0, (dy >= 0) and -1 or 1
	end
end

local function cross2D(ax, ay, bx, by)
	return ax * by - ay * bx
end

local function orderEdgeLeftRight(area, targetPos, c1, c2)
	local dir = Vector3(targetPos.x - area.pos.x, targetPos.y - area.pos.y, 0)
	local v1 = Vector3(c1.x - area.pos.x, c1.y - area.pos.y, 0)
	local v2 = Vector3(c2.x - area.pos.x, c2.y - area.pos.y, 0)
	local s1 = cross2D(dir.x, dir.y, v1.x, v1.y)
	local s2 = cross2D(dir.x, dir.y, v2.x, v2.y)
	if s1 == s2 then
		-- Fallback: keep original order
		return c1, c2
	end
	if s1 > s2 then
		return c1, c2 -- c1 is left of dir
	else
		return c2, c1
	end
end

local function getNearestEdgeCorners(area, targetPos)
	-- Return the edge whose segment is closest in XY to targetPos
	local edges = {
		{ area.nw, area.ne }, -- North
		{ area.ne, area.se }, -- East
		{ area.se, area.sw }, -- South
		{ area.sw, area.nw }, -- West
	}
	local function distPointToSeg2(p, a, b)
		local px, py = p.x, p.y
		local ax, ay = a.x, a.y
		local bx, by = b.x, b.y
		local vx, vy = bx - ax, by - ay
		local wx, wy = px - ax, py - ay
		local vv = vx * vx + vy * vy
		local t = vv > 0 and ((wx * vx + wy * vy) / vv) or 0
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
		local cx, cy = ax + t * vx, ay + t * vy
		local dx, dy = px - cx, py - cy
		return dx * dx + dy * dy
	end
	local bestA, bestB, bestD = nil, nil, math.huge
	for _, e in ipairs(edges) do
		local d = distPointToSeg2(targetPos, e[1], e[2])
		if d < bestD then
			bestD = d
			bestA, bestB = e[1], e[2]
		end
	end
	return bestA, bestB
end

local function getFacingEdgeCorners(area, dirX, dirY, otherPos)
	-- Returns leftCorner, rightCorner on the facing edge (world positions)
	if not (area and area.nw and area.ne and area.se and area.sw) then
		return nil, nil
	end
	-- Deterministic left/right per cardinal direction (axis-aligned):
	-- North: left=nw, right=ne
	-- South: left=se, right=sw
	-- East:  left=ne, right=se
	-- West:  left=sw, right=nw
	if dirX == 1 then
		return area.ne, area.se
	elseif dirX == -1 then
		return area.sw, area.nw
	elseif dirY == 1 then
		return area.nw, area.ne
	elseif dirY == -1 then
		return area.se, area.sw
	else
		-- Ambiguous: fall back to nearest edge without reordering
		local a, b = getNearestEdgeCorners(area, otherPos)
		return a, b
	end
end

local function lerpVec(a, b, t)
	return Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

local function absZDiff(a, b)
	return math.abs(a.z - b.z)
end

local function distance3D(p, q)
	local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Spec-compliant side selection:
-- Compare A_left<->B_left vs A_right<->B_right and keep the orientation with the shorter distance.
-- If distances are equal, keep as-is (stable – do nothing).
local function chooseMappingPreferShorterSide(aLeft, aRight, bLeft, bRight)
	local dLL = distance3D(aLeft, bLeft)
	local dRR = distance3D(aRight, bRight)
	if dRR < dLL then
		-- Flip B so that B_left/B_right align with the shorter side
		return bRight, bLeft
	end
	return bLeft, bRight
end

local function binarySearchCutoff(aReach, aUnreach, bReach, bUnreach)
	local low, high = 0.0, 1.0
	for _ = 1, 4 do -- ~4 iterations sufficient
		local mid = (low + high) * 0.5
		local pA = lerpVec(aReach, aUnreach, mid)
		local pB = lerpVec(bReach, bUnreach, mid)
		local diff = absZDiff(pA, pB)
		if diff >= MAX_JUMP then
			high = mid -- move toward reachable side
		else
			low = mid -- move toward unreachable side
		end
	end
	-- Back off by clearance along the edge toward reachable side
	local edgeLen = (aUnreach - aReach):Length()
	local backT = edgeLen > 0 and (CLEARANCE_OFFSET / edgeLen) or 0
	local tFinal = math.max(0, low - backT)
	local aCut = lerpVec(aReach, aUnreach, tFinal)
	local bCut = lerpVec(bReach, bUnreach, tFinal)
	return aCut, bCut
end

-- Compute overlapping projection of two facing edges along their dominant axis
local function computeOverlapParams(aLeft, aRight, bLeft, bRight)
	local dxA, dyA = aRight.x - aLeft.x, aRight.y - aLeft.y
	local useX = math.abs(dxA) >= math.abs(dyA)

	local function axisVal(p)
		return useX and p.x or p.y
	end

	local a0, a1 = axisVal(aLeft), axisVal(aRight)
	local b0, b1 = axisVal(bLeft), axisVal(bRight)
	local aMin, aMax = math.min(a0, a1), math.max(a0, a1)
	local bMin, bMax = math.min(b0, b1), math.max(b0, b1)
	local oMin, oMax = math.max(aMin, bMin), math.min(aMax, bMax)
	if oMax <= oMin then
		return nil
	end

	local function paramOn(seg0, seg1, v)
		local denom = (seg1 - seg0)
		if denom == 0 then
			return nil
		end
		return (v - seg0) / denom
	end

	local tA0 = paramOn(a0, a1, oMin)
	local tA1 = paramOn(a0, a1, oMax)
	local tB0 = paramOn(b0, b1, oMin)
	local tB1 = paramOn(b0, b1, oMax)
	if not (tA0 and tA1 and tB0 and tB1) then
		return nil
	end

	local tAL, tAR = math.min(tA0, tA1), math.max(tA0, tA1)
	local tBL, tBR = math.min(tB0, tB1), math.max(tB0, tB1)
	-- Also return axis values to allow clamping to common domain with clearance
	return {
		useX = useX,
		a0 = a0,
		a1 = a1,
		b0 = b0,
		b1 = b1,
		aMin = aMin,
		aMax = aMax,
		bMin = bMin,
		bMax = bMax,
		oMin = oMin,
		oMax = oMax,
		tAL = tAL,
		tAR = tAR,
		tBL = tBL,
		tBR = tBR,
	}
end

-- Returns tLeft, tRight (inclusive) on A-edge and minDiff across the reachable span; nil if none
local function findReachableSpan(aLeft, aRight, bLeft, bRight)
	local p = computeOverlapParams(aLeft, aRight, bLeft, bRight)
	if not p then
		return nil
	end
	-- Defensive: ensure numeric params for linters/types
	local tAL = p.tAL or 0.0
	local tAR = p.tAR or 1.0
	local tBL = p.tBL or 0.0
	local tBR = p.tBR or 1.0

	local aStart, aEnd = lerpVec(aLeft, aRight, tAL), lerpVec(aLeft, aRight, tAR)
	local bStart, bEnd = lerpVec(bLeft, bRight, tBL), lerpVec(bLeft, bRight, tBR)

	local dStart = absZDiff(aStart, bStart)
	local dEnd = absZDiff(aEnd, bEnd)
	local startReach, endReach = dStart < MAX_JUMP, dEnd < MAX_JUMP

	if (not startReach) and not endReach then
		return nil
	end

	if startReach and endReach then
		-- Clamp to common domain on the shared axis with 24u from each area's corners when possible
		local edgeLen = (aRight - aLeft):Length()
		local domainMin, domainMax = p.oMin, p.oMax
		local widthA = p.aMax - p.aMin
		local widthB = p.bMax - p.bMin
		local clearance = HITBOX_WIDTH
		if widthA > (2 * clearance) then
			domainMin = math.max(domainMin, p.aMin + clearance)
			domainMax = math.min(domainMax, p.aMax - clearance)
		end
		if widthB > (2 * clearance) then
			domainMin = math.max(domainMin, p.bMin + clearance)
			domainMax = math.min(domainMax, p.bMax - clearance)
		end
		if domainMax <= domainMin then
			domainMin, domainMax = p.oMin, p.oMax
		end

		local denomA = (p.a1 - p.a0)
		local tL = denomA ~= 0 and ((domainMin - p.a0) / denomA) or tAL
		local tR = denomA ~= 0 and ((domainMax - p.a0) / denomA) or tAR
		tL = math.max(tAL, math.max(0, math.min(1, tL)))
		tR = math.min(tAR, math.max(0, math.min(1, tR)))
		tR = math.max(tL, tR)
		local minDiff = math.min(dStart, dEnd)
		return tL, tR, minDiff
	end

	if startReach and not endReach then
		if dStart >= MAX_JUMP then
			return nil
		end
		local aCut = binarySearchCutoff(aStart, aEnd, bStart, bEnd)
		-- Map cut point back to param along A edge (project on XY)
		local vx, vy = aRight.x - aLeft.x, aRight.y - aLeft.y
		local wx, wy = aCut.x - aLeft.x, aCut.y - aLeft.y
		local denom = vx * vx + vy * vy
		local tRraw = denom > 0 and ((wx * vx + wy * vy) / denom) or tAR
		local tRnum = (type(tRraw) == "number") and tRraw or 0.0
		local tL = tAL
		local tRval = math.max(tL, math.min(tAR, tRnum))
		return tL, tRval, dStart
	elseif endReach and not startReach then
		if dEnd >= MAX_JUMP then
			return nil
		end
		local aCut = binarySearchCutoff(aEnd, aStart, bEnd, bStart)
		local vx, vy = aRight.x - aLeft.x, aRight.y - aLeft.y
		local wx, wy = aCut.x - aLeft.x, aCut.y - aLeft.y
		local denom = vx * vx + vy * vy
		local tLraw = denom > 0 and ((wx * vx + wy * vy) / denom) or tAL
		local tLnum = (type(tLraw) == "number") and tLraw or 0.0
		local tR = tAR
		local tLval = math.min(math.max(tAL, tLnum), tR)
		return tLval, tR, dEnd
	end

	return nil
end

-- STEP 1: Get basic door geometry and direction info
local function getDoorGeometry(areaA, areaB)
	local dirAX, dirAY = cardinalDirectionFromBounds(areaA, areaB)
	local dirBX, dirBY = -dirAX, -dirAY
	local aLeft, aRight = getFacingEdgeCorners(areaA, dirAX, dirAY, areaB.pos)
	local bLeft, bRight = getFacingEdgeCorners(areaB, dirBX, dirBY, areaA.pos)

	if not (aLeft and aRight and bLeft and bRight) then
		return nil
	end

	-- Detect downward one-way connections
	local aZ = (areaA.nw.z + areaA.ne.z + areaA.se.z + areaA.sw.z) * 0.25
	local bZ = (areaB.nw.z + areaB.ne.z + areaB.se.z + areaB.sw.z) * 0.25
	local isDownwardOneWay = (bZ < aZ - 0.5)

	return {
		dirAX = dirAX,
		dirAY = dirAY,
		aLeft = aLeft,
		aRight = aRight,
		bLeft = bLeft,
		bRight = bRight,
		isDownwardOneWay = isDownwardOneWay,
		edgeLength = (aRight - aLeft):Length(),
	}
end

-- Helper to check if area has connection in given direction
local function hasConnectionInDirection(area, checkDirX, checkDirY)
	if not area.c then
		return false
	end

	local foundConnections = {}
	for _, cDir in pairs(area.c) do
		if cDir and cDir.connections then
			for _, conn in ipairs(cDir.connections) do
				local neighborId = getConnectionNodeId(conn)
				local neighbor = G.Navigation.nodes and G.Navigation.nodes[neighborId]
				if neighbor then
					local nDirX, nDirY = cardinalDirectionFromBounds(area, neighbor)
					if nDirX == checkDirX and nDirY == checkDirY then
						table.insert(foundConnections, neighborId)
					end
				end
			end
		end
	end

	-- Debug logging for specific areas
	if area.id == 3843 or area.id == 3539 then
		if #foundConnections > 0 then
			Log:Info(
				"Area %d has %d connections in direction (%d,%d): %s",
				area.id,
				#foundConnections,
				checkDirX,
				checkDirY,
				table.concat(foundConnections, ",")
			)
		else
			Log:Info("Area %d has NO connections in direction (%d,%d)", area.id, checkDirX, checkDirY)
		end
	end

	return #foundConnections > 0
end

-- STEP 2: Detect wall constraints (REPLACEABLE - proper connection detection)
local function detectWallConstraints(areaA, areaB, geometry)
	-- If edge is too narrow for any clamping, skip all limits
	if geometry.edgeLength < 48 then -- Less than 2 * 24 units
		return {
			leftNeedsLimit = false,
			rightNeedsLimit = false,
			leftLimit = HITBOX_WIDTH,
			rightLimit = HITBOX_WIDTH,
		}
	end

	-- Determine which corners are near walls by checking connections
	local aLeftIsWall, aRightIsWall = false, false
	local bLeftIsWall, bRightIsWall = false, false

	-- Check perpendicular directions to the door direction
	if geometry.dirAX ~= 0 then -- Horizontal movement (E/W)
		-- For East/West doors, check North/South connections
		aLeftIsWall = not hasConnectionInDirection(areaA, 0, 1) -- No North connection = left wall
		aRightIsWall = not hasConnectionInDirection(areaA, 0, -1) -- No South connection = right wall
		bLeftIsWall = not hasConnectionInDirection(areaB, 0, 1) -- No North connection = left wall
		bRightIsWall = not hasConnectionInDirection(areaB, 0, -1) -- No South connection = right wall
	else -- Vertical movement (N/S)
		-- For North/South doors, check East/West connections
		aLeftIsWall = not hasConnectionInDirection(areaA, -1, 0) -- No West connection = left wall
		aRightIsWall = not hasConnectionInDirection(areaA, 1, 0) -- No East connection = right wall
		bLeftIsWall = not hasConnectionInDirection(areaB, -1, 0) -- No West connection = left wall
		bRightIsWall = not hasConnectionInDirection(areaB, 1, 0) -- No East connection = right wall
	end

	-- Debug logging for specific nodes
	if (areaA.id == 3843 and areaB.id == 3539) or (areaA.id == 3539 and areaB.id == 3843) then
		Log:Info(
			"Door debug - Area %d->%d: aLeft=%s, aRight=%s, bLeft=%s, bRight=%s",
			areaA.id,
			areaB.id,
			tostring(aLeftIsWall),
			tostring(aRightIsWall),
			tostring(bLeftIsWall),
			tostring(bRightIsWall)
		)

		-- Additional debug: Check what connections each area actually has
		Log:Info(
			"Area %d connections: North=%s, South=%s, West=%s, East=%s",
			areaA.id,
			tostring(hasConnectionInDirection(areaA, 0, 1)),
			tostring(hasConnectionInDirection(areaA, 0, -1)),
			tostring(hasConnectionInDirection(areaA, -1, 0)),
			tostring(hasConnectionInDirection(areaA, 1, 0))
		)
		Log:Info(
			"Area %d connections: North=%s, South=%s, West=%s, East=%s",
			areaB.id,
			tostring(hasConnectionInDirection(areaB, 0, 1)),
			tostring(hasConnectionInDirection(areaB, 0, -1)),
			tostring(hasConnectionInDirection(areaB, -1, 0)),
			tostring(hasConnectionInDirection(areaB, 1, 0))
		)
	end

	-- TEMPORARILY DISABLED: Apply limits only from wall corners
	-- local edgeLimit = 24
	-- local leftNeedsLimit = aLeftIsWall or bLeftIsWall
	-- local rightNeedsLimit = aRightIsWall or bRightIsWall

	-- -- Calculate total limits needed
	-- local totalLimit = 0
	-- if leftNeedsLimit then
	-- 	totalLimit = totalLimit + edgeLimit
	-- end
	-- if rightNeedsLimit then
	-- 	totalLimit = totalLimit + edgeLimit
	-- end

	-- -- Check if there's enough space after applying wall limits
	-- local availableWidth = geometry.edgeLength - totalLimit

	-- if availableWidth >= HITBOX_WIDTH then
	-- 	-- Enough space - apply limits only where walls exist
	-- 	return {
	-- 		leftNeedsLimit = leftNeedsLimit,
	-- 		rightNeedsLimit = rightNeedsLimit,
	-- 		leftLimit = leftNeedsLimit and edgeLimit or HITBOX_WIDTH,
	-- 		rightLimit = rightNeedsLimit and edgeLimit or HITBOX_WIDTH,
	-- 	}
	-- else
	-- 	-- Not enough space - skip limits to preserve door
	-- 	return {
	-- 		leftNeedsLimit = false,
	-- 		rightNeedsLimit = false,
	-- 		leftLimit = HITBOX_WIDTH,
	-- 		rightLimit = HITBOX_WIDTH,
	-- 	}
	-- end

	-- TEMPORARILY: No clamping - use full door width
	return {
		leftNeedsLimit = false,
		rightNeedsLimit = false,
		leftLimit = HITBOX_WIDTH,
		rightLimit = HITBOX_WIDTH,
	}
end

-- STEP 3: Calculate base door span (TEMPORARILY DISABLED - use full width)
local function calculateBaseDoorSpan(geometry)
	-- TEMPORARILY DISABLED: Use full width instead of reachable span
	-- Doors should extend to full corners of areas
	return {
		tL = 0.0, -- Start at left corner
		tR = 1.0, -- End at right corner
		overlapParams = nil,
	}

	-- [Original logic commented out]
	-- if geometry.isDownwardOneWay then
	--     [downward one-way logic...]
	-- else
	--     [reachable span logic...]
	-- end
end

-- STEP 4: Apply constraints to door span (TEMPORARILY DISABLED)
local function applyDoorConstraints(geometry, span, constraints)
	-- TEMPORARILY DISABLED: No constraints applied - use full door span
	-- Doors should match the size of smallest common side
	return span.tL, span.tR

	-- [Original constraint logic commented out]
	-- local tL, tR = span.tL, span.tR
	-- if geometry.isDownwardOneWay and span.overlapParams then
	--     [downward one-way logic...]
	-- else
	--     [normal constraint logic...]
	-- end
end

-- STEP 5: Generate final door points and metadata
local function generateDoorPoints(geometry, finalTL, finalTR)
	-- Calculate initial door points
	local aDoorLeft = lerpVec(geometry.aLeft, geometry.aRight, finalTL)
	local aDoorRight = lerpVec(geometry.aLeft, geometry.aRight, finalTR)

	-- Calculate center AFTER clamping (center moves based on door point positions)
	local mid = lerpVec(aDoorLeft, aDoorRight, 0.5)

	-- Check if jump is needed
	local leftEndDiff =
		absZDiff(lerpVec(geometry.aLeft, geometry.aRight, finalTL), lerpVec(geometry.bLeft, geometry.bRight, finalTL))
	local rightEndDiff =
		absZDiff(lerpVec(geometry.aLeft, geometry.aRight, finalTR), lerpVec(geometry.bLeft, geometry.bRight, finalTR))
	local needJump = (leftEndDiff > STEP_HEIGHT and leftEndDiff < MAX_JUMP)
		or (rightEndDiff > STEP_HEIGHT and rightEndDiff < MAX_JUMP)

	-- Get direction string
	local dirStr = (geometry.dirAX == 1 and "E")
		or (geometry.dirAX == -1 and "W")
		or (geometry.dirAY == 1 and "N")
		or (geometry.dirAY == -1 and "S")
		or "N"

	return {
		left = aDoorLeft,
		middle = mid,
		right = aDoorRight,
		needJump = needJump,
		dir = dirStr,
		oneWayDown = geometry.isDownwardOneWay,
	}
end

-- MAIN: Modular door creation function
local function createDoorForAreas(areaA, areaB)
	-- Step 1: Get basic geometry
	local geometry = getDoorGeometry(areaA, areaB)
	if not geometry then
		return nil
	end

	-- Step 2: Detect constraints (EASILY REPLACEABLE)
	local constraints = detectWallConstraints(areaA, areaB, geometry)

	-- Step 3: Calculate base door span
	local span = calculateBaseDoorSpan(geometry)
	if not span then
		return nil
	end

	-- Step 4: Apply constraints (EASILY REPLACEABLE)
	local finalTL, finalTR = applyDoorConstraints(geometry, span, constraints)

	-- Step 5: Generate final door
	return generateDoorPoints(geometry, finalTL, finalTR)
end

-- Global storage for wall corner visualization
G.WallCorners = G.WallCorners or {}

function Node.BuildDoorsForConnections()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	-- Clear previous wall corners (only if not already calculated)
	if not G.WallCornersCalculated then
		G.WallCorners = {}
		G.WallCornerScores = {}
	else
		-- Already calculated, skip this expensive process
		Log:Info("Wall corners already calculated, skipping recalculation")
		return
	end

	-- Deterministic area order
	local ids = {}
	for id in pairs(nodes) do
		ids[#ids + 1] = id
	end
	table.sort(ids)

	-- First pass: Build doors and collect ALL area corners for proximity analysis
	local areaCornerProximity = {}

	for _, id in ipairs(ids) do
		local areaA = nodes[id]
		if areaA and areaA.c then
			-- Initialize proximity scores for ALL 4 corners of this area
			if areaA.nw and areaA.ne and areaA.se and areaA.sw then
				areaCornerProximity[areaA.nw] = 0
				areaCornerProximity[areaA.ne] = 0
				areaCornerProximity[areaA.se] = 0
				areaCornerProximity[areaA.sw] = 0
			end

			-- Still build doors for pathfinding
			for dirIndex = 1, 4 do
				local cDir = areaA.c[dirIndex]
				if cDir and cDir.connections then
					local updated = {}
					for _, connection in ipairs(cDir.connections) do
						local entry = normalizeConnectionEntry(connection)
						local neighbor = nodes[entry.node]
						if neighbor and neighbor.pos then
							local door = createDoorForAreas(areaA, neighbor)
							if door then
								entry.left = door.left
								entry.middle = door.middle
								entry.right = door.right
								entry.needJump = door.needJump and true or false
								entry.dir = door.dir
								entry.oneWayDown = door.oneWayDown and true or false
								updated[#updated + 1] = entry
							else
								-- Drop unreachable connection
							end
						end
					end
					cDir.connections = updated
					cDir.count = #updated
				end
			end
		end
	end

	-- Second pass: Calculate proximity scores using door generation logic for corner pairs
	local processedAreas = 0
	local totalCornersChecked = 0

	for _, id in ipairs(ids) do
		local areaA = nodes[id]
		if areaA and areaA.c and areaA.nw and areaA.ne and areaA.se and areaA.sw then
			-- For all 4 directions, get neighbors and check corner pairs facing that direction
			for dirIndex = 1, 4 do
				local cDir = areaA.c[dirIndex]
				if cDir and cDir.connections then
					for _, connection in ipairs(cDir.connections) do
						local entry = normalizeConnectionEntry(connection)
						local neighborId = entry.node
						local neighbor = nodes[neighborId]

						if neighbor and neighbor.nw and neighbor.ne and neighbor.se and neighbor.sw then
							-- Use same logic as door generation to get the 2 corners facing this neighbor
							local geometry = getDoorGeometry(areaA, neighbor)
							if
								geometry
								and geometry.aLeft
								and geometry.aRight
								and geometry.bLeft
								and geometry.bRight
							then
								local aCorner1, aCorner2 = geometry.aLeft, geometry.aRight
								local bCorner1, bCorner2 = geometry.bLeft, geometry.bRight

								-- Helper function for line check with tolerance
								local function isPointOnLine(point, lineStart, lineEnd, tolerance)
									tolerance = tolerance or 2.0

									-- Safety check for nil values
									if not point or not lineStart or not lineEnd then
										return false
									end

									-- Check if point is within the bounding box of the line (with tolerance)
									local minX = math.min(lineStart.x, lineEnd.x) - tolerance
									local maxX = math.max(lineStart.x, lineEnd.x) + tolerance
									local minY = math.min(lineStart.y, lineEnd.y) - tolerance
									local maxY = math.max(lineStart.y, lineEnd.y) + tolerance

									if point.x < minX or point.x > maxX or point.y < minY or point.y > maxY then
										return false
									end

									-- Check if it's close to the line (horizontal or vertical)
									if math.abs(lineStart.x - lineEnd.x) < 0.1 then
										-- Vertical line
										return math.abs(point.x - lineStart.x) <= tolerance
									elseif math.abs(lineStart.y - lineEnd.y) < 0.1 then
										-- Horizontal line
										return math.abs(point.y - lineStart.y) <= tolerance
									end

									return false
								end

								-- Check if the 2 area corners facing this neighbor lie on the neighbor's line
								if isPointOnLine(aCorner1, bCorner1, bCorner2) then
									areaCornerProximity[aCorner1] = areaCornerProximity[aCorner1] + 1
									totalCornersChecked = totalCornersChecked + 1
								end
								if isPointOnLine(aCorner2, bCorner1, bCorner2) then
									areaCornerProximity[aCorner2] = areaCornerProximity[aCorner2] + 1
									totalCornersChecked = totalCornersChecked + 1
								end
							else
								-- Debug: Log when geometry is missing
								Log:Info("Missing geometry for area %d -> neighbor %d", id, neighborId)
							end
						end
					end
				end
			end
			processedAreas = processedAreas + 1
		end
	end

	Log:Info(
		"Processed %d areas, checked %d corner-neighbor pairs for proximity analysis",
		processedAreas,
		totalCornersChecked
	)

	-- Third pass: Store wall corners (proximity <= 1) for visualization
	local totalPoints = 0
	local wallPoints = 0
	local insidePoints = 0

	-- Store both wall corners and proximity scores for display
	G.WallCorners = {}
	G.WallCornerScores = {} -- Clear previous scores

	for point, proximity in pairs(areaCornerProximity) do
		totalPoints = totalPoints + 1
		-- Proper logic: 0 or 1 neighbors = wall corner, 2+ neighbors = inside
		if proximity <= 1 then
			wallPoints = wallPoints + 1
			-- Store wall corner 2 units above the area corner
			local wallCorner = point + Vector3(0, 0, 2)
			table.insert(G.WallCorners, wallCorner)
			-- Store proximity score for display
			G.WallCornerScores[wallCorner] = proximity
		else
			insidePoints = insidePoints + 1
		end

		-- Debug: Log first few proximity scores
		if totalPoints <= 10 then
			Log:Info("Corner proximity: (%0.1f, %0.1f, %0.1f) = %d", point.x, point.y, point.z, proximity)
		end
	end

	Log:Info(
		"Area corner analysis: %d total, %d wall corners (proximity <= 1), %d inside (proximity >= 2)",
		totalPoints,
		wallPoints,
		insidePoints
	)
	Log:Info("Generated %d wall corners for visualization", #G.WallCorners)

	-- Mark as calculated to prevent recalculation
	G.WallCornersCalculated = true
end

--- Public utility functions for connection handling
---@param connection any Connection data (integer ID or table with node/cost)
---@return integer Node ID
function Node.GetConnectionNodeId(connection)
	return getConnectionNodeId(connection)
end

--- Public utility function for getting connection cost
---@param connection any Connection data (integer ID or table with node/cost)
---@return number Cost value
function Node.GetConnectionCost(connection)
	return getConnectionCost(connection)
end

--- Returns the enriched connection entry (with door points) from A->B if present
---@param nodeA table
---@param nodeB table
---@return table|nil
function Node.GetConnectionEntry(nodeA, nodeB)
	if not nodeA or not nodeB then
		return nil
	end
	local nodes = Node.GetNodes()
	if not nodes then
		return nil
	end
	local areaA = nodes[nodeA.id]
	if not (areaA and areaA.c) then
		return nil
	end
	for _, cDir in pairs(areaA.c) do
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				if targetNodeId == nodeB.id then
					return normalizeConnectionEntry(connection)
				end
			end
		end
	end
	return nil
end

-- Cache for quick door target lookup with cleanup to prevent memory leaks
local DoorTargetCache = {}
local DoorTargetCacheCleanup = {
	lastCleanup = 0,
	cleanupInterval = 600, -- Clean every 10 seconds
	maxEntries = 200, -- Reasonable limit for door transitions
}

--- Get a door target point for transitioning from areaA to areaB.
--- Chooses middle for N/S, right for E, left for W. Falls back to middle when uncertain.
---@param areaA table
---@param areaB table
---@return Vector3|nil
function Node.GetDoorTargetPoint(areaA, areaB)
	if not (areaA and areaB) then
		return nil
	end
	local key = tostring(areaA.id) .. "->" .. tostring(areaB.id)
	if DoorTargetCache[key] then
		return DoorTargetCache[key]
	end

	-- Prefer precomputed door points on the connection
	local entry = Node.GetConnectionEntry(areaA, areaB)
	local doorLeft, doorMid, doorRight = nil, nil, nil
	local dirOverride = nil
	if entry then
		doorLeft, doorMid, doorRight = entry.left, entry.middle, entry.right
		dirOverride = entry.dir
	end

	-- If we lack door points, try constructing them on the fly
	if not (doorLeft and doorMid and doorRight) then
		local dirAX, dirAY = cardinalDirectionFromBounds(areaA, areaB)
		local aLeft, aRight = getFacingEdgeCorners(areaA, dirAX, dirAY, areaB.pos)
		local bLeft, bRight = getFacingEdgeCorners(areaB, -dirAX, -dirAY, areaA.pos)
		if aLeft and aRight and bLeft and bRight then
			local tL, tR = findReachableSpan(aLeft, aRight, bLeft, bRight)
			if tL and tR then
				doorLeft = lerpVec(aLeft, aRight, tL)
				doorRight = lerpVec(aLeft, aRight, tR)
				doorMid = lerpVec(doorLeft, doorRight, 0.5)
			end
		end
	end

	if not (doorLeft or doorMid or doorRight) then
		return nil
	end

	-- Choose side by cardinal direction: E=right, W=left, N/S=middle
	local dirX, dirY = cardinalDirectionFromBounds(areaA, areaB)
	if dirOverride then
		if dirOverride == "E" then
			dirX, dirY = 1, 0
		elseif dirOverride == "W" then
			dirX, dirY = -1, 0
		elseif dirOverride == "N" then
			dirX, dirY = 0, 1
		elseif dirOverride == "S" then
			dirX, dirY = 0, -1
		end
	end
	local target = nil
	if dirX == 1 then
		target = doorRight or doorMid or doorLeft
	elseif dirX == -1 then
		target = doorLeft or doorMid or doorRight
	else
		target = doorMid or doorLeft or doorRight
	end

	DoorTargetCache[key] = target

	-- Periodic cleanup to prevent unbounded growth
	local currentTick = globals.TickCount()
	if (currentTick - DoorTargetCacheCleanup.lastCleanup) > DoorTargetCacheCleanup.cleanupInterval then
		local count = 0
		for _ in pairs(DoorTargetCache) do
			count = count + 1
		end

		if count > DoorTargetCacheCleanup.maxEntries then
			-- Simple cleanup: clear half the cache when limit exceeded
			local cleared = 0
			local targetClear = math.floor(count / 2)
			for cacheKey, _ in pairs(DoorTargetCache) do
				DoorTargetCache[cacheKey] = nil
				cleared = cleared + 1
				if cleared >= targetClear then
					break
				end
			end
			Log:Debug("DoorTargetCache cleaned: %d/%d entries removed", cleared, count)
		end

		DoorTargetCacheCleanup.lastCleanup = currentTick
	end

	return target
end

--==========================================================================
--  Dynamic batch processing system with frame time monitoring
--==========================================================================

local ConnectionProcessor = {
	-- Current processing state
	isProcessing = false,
	currentPhase = 1, -- 1 = basic connections, 2 = expensive fallback, 3 = fine point expensive stitching
	processedNodes = {},
	pendingNodes = {},
	nodeQueue = {},

	-- Performance monitoring
	targetFPS = 24,
	maxFrameTime = 1.0 / 24, -- ~41.7ms for 24 FPS
	currentBatchSize = 5,
	minBatchSize = 1,
	maxBatchSize = 20,

	-- Statistics
	totalProcessed = 0,
	connectionsFound = 0,
	expensiveChecksUsed = 0,
	finePointConnectionsAdded = 0,
}

--- Calculate current FPS and adjust batch size dynamically
local function adjustBatchSize()
	local frameTime = globals.FrameTime()
	local currentFPS = 1 / frameTime

	-- If FPS is too low, reduce batch size
	if currentFPS < ConnectionProcessor.targetFPS then
		ConnectionProcessor.currentBatchSize =
			math.max(ConnectionProcessor.minBatchSize, ConnectionProcessor.currentBatchSize - 1)
	-- If FPS is good, try to increase batch size for faster processing
	elseif currentFPS > ConnectionProcessor.targetFPS * 1.5 and frameTime < ConnectionProcessor.maxFrameTime * 0.8 then
		ConnectionProcessor.currentBatchSize =
			math.min(ConnectionProcessor.maxBatchSize, ConnectionProcessor.currentBatchSize + 1)
	end

	return currentFPS
end

--- Initialize connection processing
local function initializeConnectionProcessing(nodes)
	ConnectionProcessor.isProcessing = true
	ConnectionProcessor.currentPhase = 1
	ConnectionProcessor.processedNodes = {}
	ConnectionProcessor.pendingNodes = {}
	ConnectionProcessor.nodeQueue = {}

	-- Build queue of all nodes to process
	for nodeId, node in pairs(nodes) do
		if node and node.c then
			table.insert(ConnectionProcessor.nodeQueue, { id = nodeId, node = node })
		end
	end

	ConnectionProcessor.totalProcessed = 0
	ConnectionProcessor.connectionsFound = 0
	ConnectionProcessor.expensiveChecksUsed = 0

	Log:Info(
		"Started dynamic connection processing: %d nodes queued, target FPS: %d",
		#ConnectionProcessor.nodeQueue,
		ConnectionProcessor.targetFPS
	)
end

--- Process a batch of connections for one frame
local function processBatch(nodes)
	if not ConnectionProcessor.isProcessing then
		return false
	end

	local startTime = globals.FrameTime()
	local processed = 0

	-- Phase 1: Basic connection validation (no expensive checks)
	if ConnectionProcessor.currentPhase == 1 then
		while processed < ConnectionProcessor.currentBatchSize and #ConnectionProcessor.nodeQueue > 0 do
			local nodeData = table.remove(ConnectionProcessor.nodeQueue, 1)
			local nodeId, node = nodeData.id, nodeData.node

			if node and node.c then
				-- Process all directions for this node
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						local validConnections = {}

						for _, connection in pairs(connectionDir.connections) do
							local targetNodeId = getConnectionNodeId(connection)
							local currentCost = getConnectionCost(connection)
							local targetNode = nodes[targetNodeId]

							if targetNode then
								-- Phase 1: Fast accessibility check without expensive operations
								local isAccessible, costMultiplier = isNodeAccessible(node, targetNode, false)
								local finalCost = currentCost * costMultiplier

								-- Add height-based cost for smooth walking mode
								if G.Menu.Main.WalkableMode == "Smooth" then
									local heightDiff = targetNode.pos.z - node.pos.z
									if heightDiff > 18 then -- Requires jump in smooth mode
										local heightPenalty = math.floor(heightDiff / 18) * 10 -- 10 cost per 18 units
										finalCost = finalCost + heightPenalty
									end
								end

								-- Always keep connection but adjust cost; preserve door points if any
								local base = normalizeConnectionEntry(connection)
								table.insert(validConnections, {
									node = targetNodeId,
									cost = finalCost,
									left = base.left,
									middle = base.middle,
									right = base.right,
								})

								ConnectionProcessor.connectionsFound = ConnectionProcessor.connectionsFound + 1

								-- If high penalty was applied, mark for potential expensive check
								if costMultiplier >= 5 then
									if not ConnectionProcessor.pendingNodes[nodeId] then
										ConnectionProcessor.pendingNodes[nodeId] = {}
									end
									table.insert(ConnectionProcessor.pendingNodes[nodeId], {
										dir = dir,
										targetId = targetNodeId,
										originalCost = currentCost,
										connectionIndex = #validConnections, -- Track which connection to update
									})
								end
							end
						end

						-- Update connections (always enriched objects)
						connectionDir.connections = validConnections
						connectionDir.count = #validConnections
					end
				end

				ConnectionProcessor.processedNodes[nodeId] = true
			end

			processed = processed + 1
			ConnectionProcessor.totalProcessed = ConnectionProcessor.totalProcessed + 1
		end

		-- Check if phase 1 is complete
		if #ConnectionProcessor.nodeQueue == 0 then
			local pendingCount = 0
			for _ in pairs(ConnectionProcessor.pendingNodes) do
				pendingCount = pendingCount + 1
			end
			Log:Info(
				"Phase 1 complete: %d basic connections found, %d nodes need expensive checks",
				ConnectionProcessor.connectionsFound,
				pendingCount
			)

			ConnectionProcessor.currentPhase = 2
			ConnectionProcessor.currentBatchSize = math.max(1, ConnectionProcessor.currentBatchSize / 4) -- Slower for expensive checks
		end

	-- Phase 2: Expensive fallback checks to improve high-penalty connections
	elseif ConnectionProcessor.currentPhase == 2 then
		local pendingProcessed = 0

		for nodeId, pendingConnections in pairs(ConnectionProcessor.pendingNodes) do
			if pendingProcessed >= ConnectionProcessor.currentBatchSize then
				break
			end

			local node = nodes[nodeId]
			if node and #pendingConnections > 0 then
				local connectionData = table.remove(pendingConnections, 1)
				local targetNode = nodes[connectionData.targetId]

				if targetNode then
					-- Use expensive check to get better cost assessment
					local isAccessible, costMultiplier = isNodeAccessible(node, targetNode, true)
					local dir = connectionData.dir
					local connectionDir = node.c[dir]

					if connectionDir and connectionDir.connections and connectionData.connectionIndex then
						-- Update the existing connection with better cost information
						local existingConnection = connectionDir.connections[connectionData.connectionIndex]
						if existingConnection then
							local improvedCost = connectionData.originalCost * costMultiplier

							-- Update the connection cost
							local base = normalizeConnectionEntry(existingConnection)
							connectionDir.connections[connectionData.connectionIndex] = {
								node = base.node,
								cost = improvedCost,
								left = base.left,
								middle = base.middle,
								right = base.right,
							}

							ConnectionProcessor.expensiveChecksUsed = ConnectionProcessor.expensiveChecksUsed + 1

							Log:Debug(
								"Improved connection cost from node %d to %d: %s -> %.1f",
								nodeId,
								connectionData.targetId,
								"high penalty",
								improvedCost
							)
						end
					end
				end

				pendingProcessed = pendingProcessed + 1

				-- Clean up empty pending lists
				if #pendingConnections == 0 then
					ConnectionProcessor.pendingNodes[nodeId] = nil
				end
			end
		end

		-- Check if all processing is complete
		local hasPending = false
		for _, pendingList in pairs(ConnectionProcessor.pendingNodes) do
			if #pendingList > 0 then
				hasPending = true
				break
			end
		end

		if not hasPending then
			Log:Info(
				"Phase 2 complete: %d total connections, %d expensive checks used, starting stair patching",
				ConnectionProcessor.connectionsFound,
				ConnectionProcessor.expensiveChecksUsed
			)
			ConnectionProcessor.currentPhase = 3
			ConnectionProcessor.currentBatchSize = math.max(1, ConnectionProcessor.currentBatchSize / 2) -- Moderate speed for stair patching
		end

	-- Phase 3: Stair connection patching - add missing reverse connections for stairs
	elseif ConnectionProcessor.currentPhase == 3 then
		local processed = 0
		local maxProcessPerFrame = ConnectionProcessor.currentBatchSize
		local patchedConnections = 0

		-- Build a quick lookup of all existing connections
		local existingConnections = {}
		for nodeId, node in pairs(nodes) do
			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = getConnectionNodeId(connection)
							local key = nodeId .. "->" .. targetNodeId
							existingConnections[key] = true
						end
					end
				end
			end
		end

		-- Check for missing reverse connections, especially for stairs
		for nodeId, node in pairs(nodes) do
			if processed >= maxProcessPerFrame then
				break
			end

			if node and node.c then
				for dir, connectionDir in pairs(node.c) do
					if connectionDir and connectionDir.connections then
						for _, connection in ipairs(connectionDir.connections) do
							local targetNodeId = getConnectionNodeId(connection)
							local targetNode = nodes[targetNodeId]

							if targetNode then
								-- Check if reverse connection exists
								local reverseKey = targetNodeId .. "->" .. nodeId
								if not existingConnections[reverseKey] then
									-- No reverse connection exists, check if we should add one
									local heightDiff = targetNode.pos.z - node.pos.z

									-- For stair-like connections (significant height difference)
									if math.abs(heightDiff) > 18 and math.abs(heightDiff) <= 200 then
										-- Use expensive isWalkable check for reverse direction
										if
											G.Menu.Main.AllowExpensiveChecks
											and isWalkable.Path(targetNode.pos, node.pos)
										then
											-- Add reverse connection to target node
											local addedToDirection = false
											for targetDir, targetConnectionDir in pairs(targetNode.c) do
												if
													targetConnectionDir
													and targetConnectionDir.connections
													and not addedToDirection
												then
													-- Calculate appropriate cost for reverse connection
													local reverseCost = 1
													if heightDiff > 0 then
														-- Going down - easier, lower cost
														reverseCost = 1
													else
														-- Going up - harder, higher cost
														reverseCost = math.abs(heightDiff) > 72 and 3 or 1.5
													end

													table.insert(targetConnectionDir.connections, {
														node = nodeId,
														cost = reverseCost,
														left = nil,
														middle = nil,
														right = nil,
													})
													targetConnectionDir.count = targetConnectionDir.count + 1
													patchedConnections = patchedConnections + 1
													addedToDirection = true

													-- Update our lookup to prevent duplicate patching
													existingConnections[reverseKey] = true

													Log:Debug(
														"Patched stair connection: %d -> %d (height: %.1f, cost: %.1f)",
														targetNodeId,
														nodeId,
														-heightDiff,
														reverseCost
													)
													break
												end
											end
										end
									end
								end
							end
							processed = processed + 1
						end
					end
				end
			end
		end

		-- Check if Phase 3 is complete
		if processed == 0 or patchedConnections == 0 then
			Log:Info("Stair patching complete: %d reverse connections added", patchedConnections)
			ConnectionProcessor.currentPhase = 4
			ConnectionProcessor.currentBatchSize = math.max(1, ConnectionProcessor.currentBatchSize / 2)
			ConnectionProcessor.finePointConnectionsAdded = patchedConnections
		end

	-- Phase 4: Fine point expensive stitching for missing inter-area connections
	elseif ConnectionProcessor.currentPhase == 4 then
		if G.Navigation.hierarchical and G.Navigation.hierarchical.areas then
			local processed = 0
			local maxProcessPerFrame = ConnectionProcessor.currentBatchSize

			-- Process fine point connections between adjacent areas
			for areaId, areaInfo in pairs(G.Navigation.hierarchical.areas) do
				if processed >= maxProcessPerFrame then
					break
				end

				-- Get adjacent areas for this area
				local area = areaInfo.area
				if area and area.c then
					local adjacentAreas = Node.GetAdjacentNodesOnly(area, nodes)

					-- Check each edge point against edge points in adjacent areas
					for _, edgePoint in pairs(areaInfo.edgePoints) do
						if processed >= maxProcessPerFrame then
							break
						end

						for _, adjacentArea in pairs(adjacentAreas) do
							local adjacentAreaInfo = G.Navigation.hierarchical.areas[adjacentArea.id]
							if adjacentAreaInfo then
								-- Check connections to edge points in adjacent area
								for _, adjacentEdgePoint in pairs(adjacentAreaInfo.edgePoints) do
									-- Check if connection already exists
									local connectionExists = false
									for _, neighbor in pairs(edgePoint.neighbors) do
										if
											neighbor.point
											and neighbor.point.id == adjacentEdgePoint.id
											and neighbor.point.parentArea == adjacentEdgePoint.parentArea
										then
											connectionExists = true
											break
										end
									end

									-- If no connection exists, try expensive check
									if not connectionExists then
										local distance = (edgePoint.pos - adjacentEdgePoint.pos):Length()

										-- Only check reasonable distances (not too far apart)
										if distance < 150 and distance > 5 then
											-- Use expensive walkability check
											if isWalkable.Path(edgePoint.pos, adjacentEdgePoint.pos) then
												-- Add bidirectional connection
												table.insert(edgePoint.neighbors, {
													point = adjacentEdgePoint,
													cost = distance,
													isInterArea = true,
												})
												table.insert(adjacentEdgePoint.neighbors, {
													point = edgePoint,
													cost = distance,
													isInterArea = true,
												})

												ConnectionProcessor.finePointConnectionsAdded = ConnectionProcessor.finePointConnectionsAdded
													+ 1
												ConnectionProcessor.expensiveChecksUsed = ConnectionProcessor.expensiveChecksUsed
													+ 1

												Log:Debug(
													"Added fine point connection: Area %d point %d <-> Area %d point %d (dist: %.1f)",
													areaId,
													edgePoint.id,
													adjacentArea.id,
													adjacentEdgePoint.id,
													distance
												)
											end
										end
									end
								end
							end
						end
						processed = processed + 1
					end
				end
			end

			-- Check if Phase 3 is complete (when we've processed all areas)
			if processed == 0 then
				Log:Info(
					"Fine point stitching complete: %d connections added with expensive checks",
					ConnectionProcessor.finePointConnectionsAdded
				)
				ConnectionProcessor.isProcessing = false
				return false -- Processing finished
			end
		else
			-- No hierarchical data, skip Phase 3
			Log:Info("No hierarchical data available, skipping fine point stitching")
			ConnectionProcessor.isProcessing = false
			return false
		end
	end

	-- Adjust batch size based on frame time
	adjustBatchSize()

	return true -- Continue processing
end

--- Apply proper connection cost analysis without removing connections
local function pruneInvalidConnections(nodes)
	Log:Info("Starting proper connection cost analysis (no connections removed)")

	-- Apply cost penalties to all connections using our proper accessibility logic
	local processedConnections = 0
	local penalizedConnections = 0

	for nodeId, node in pairs(nodes) do
		if node and node.c then
			for dir, connectionDir in pairs(node.c) do
				if connectionDir and connectionDir.connections then
					local updatedConnections = {}

					for _, connection in pairs(connectionDir.connections) do
						local targetNodeId = getConnectionNodeId(connection)
						local currentCost = getConnectionCost(connection)
						local targetNode = nodes[targetNodeId]

						if targetNode then
							-- Use our proper accessibility checking with expensive checks allowed
							local isAccessible, costMultiplier = isNodeAccessible(node, targetNode, true)
							local finalCost = currentCost * costMultiplier

							-- Always keep connection, just adjust cost; preserve door points if any
							local base = normalizeConnectionEntry(connection)
							table.insert(updatedConnections, {
								node = targetNodeId,
								cost = finalCost,
								left = base.left,
								middle = base.middle,
								right = base.right,
							})

							if costMultiplier > 1 then
								penalizedConnections = penalizedConnections + 1
							end
							processedConnections = processedConnections + 1
						else
							-- Only remove connections to non-existent nodes
							Log:Debug("Removing connection to non-existent node %d", targetNodeId)
						end
					end

					connectionDir.connections = updatedConnections
					connectionDir.count = #updatedConnections
				end
			end
		end
	end

	Log:Info(
		"Connection analysis complete: %d processed, %d penalized, 0 removed",
		processedConnections,
		penalizedConnections
	)

	-- Initialize background processing for fine-tuning if enabled
	if G.Menu.Main.CleanupConnections then
		initializeConnectionProcessing(nodes)
	end
end

--- Process connections in background (called from OnDraw)
function Node.ProcessConnectionsBackground()
	if ConnectionProcessor.isProcessing then
		local nodes = Node.GetNodes()
		if nodes then
			return processBatch(nodes)
		end
	end
	return false
end

--- Get connection processing status
function Node.GetConnectionProcessingStatus()
	return {
		isProcessing = ConnectionProcessor.isProcessing,
		currentPhase = ConnectionProcessor.currentPhase,
		totalNodes = #ConnectionProcessor.nodeQueue + ConnectionProcessor.totalProcessed,
		processedNodes = ConnectionProcessor.totalProcessed,
		connectionsFound = ConnectionProcessor.connectionsFound,
		expensiveChecksUsed = ConnectionProcessor.expensiveChecksUsed,
		finePointConnectionsAdded = ConnectionProcessor.finePointConnectionsAdded,
		currentBatchSize = ConnectionProcessor.currentBatchSize,
		currentFPS = ConnectionProcessor.isProcessing and (1 / globals.FrameTime()) or 0,
	}
end

--- Force stop connection processing
function Node.StopConnectionProcessing()
	ConnectionProcessor.isProcessing = false
	Log:Info("Connection processing stopped by user")
end

------------------------------------------------------------------------
--  Utility  ·  bilinear Z on the area-plane
------------------------------------------------------------------------
local function bilinearZ(x, y, nw, ne, se, sw)
	local w, h = se.x - nw.x, se.y - nw.y
	if w == 0 or h == 0 then
		return nw.z
	end
	local u, v = (x - nw.x) / w, (y - nw.y) / h
	u, v = math.max(0, math.min(1, u)), math.max(0, math.min(1, v))
	local zN = nw.z * (1 - u) + ne.z * u
	local zS = sw.z * (1 - u) + se.z * u
	return zN * (1 - v) + zS * v
end

------------------------------------------------------------------------
--  Fine-grid generation   (thin-area aware + ring & dir tags)
------------------------------------------------------------------------
local function generateAreaPoints(area)
	------------------------------------------------------------
	-- cache bounds
	------------------------------------------------------------
	area.minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	area.maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	area.minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
	area.maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)

	local areaWidth = area.maxX - area.minX
	local areaHeight = area.maxY - area.minY

	-- If area is smaller than grid size in either dimension, treat as minor node
	if areaWidth < GRID or areaHeight < GRID then
		Log:Debug("Area %d too small (%dx%d), treating as minor node", area.id, areaWidth, areaHeight)
		local minorPoint = {
			id = 1,
			gridX = 0,
			gridY = 0,
			pos = area.pos,
			neighbors = {},
			parentArea = area.id,
			ring = 0,
			isEdge = true,
			isInner = false,
			dirTags = { "N", "S", "E", "W" }, -- Minor area connects in all directions
			dirMask = Node.DIR.N | Node.DIR.S | Node.DIR.E | Node.DIR.W,
		}

		-- Create edgeSets for minor areas - single point represents all directions
		area.edgeSets = {
			N = { minorPoint },
			S = { minorPoint },
			E = { minorPoint },
			W = { minorPoint },
		}

		-- Set grid extents for minor areas
		area.gridMinX, area.gridMaxX = 0, 0
		area.gridMinY, area.gridMaxY = 0, 0

		return { minorPoint }
	end

	-- Use larger edge buffer to prevent grid points from being placed too close to walls
	local edgeBuffer = math.max(16, GRID * 0.75) -- At least 16 units or 75% of grid size
	local usableWidth = areaWidth - (2 * edgeBuffer)
	local usableHeight = areaHeight - (2 * edgeBuffer)

	-- If usable area after edge buffer is too small, treat as minor node
	if usableWidth < GRID or usableHeight < GRID then
		Log:Debug("Area %d usable space too small after edge buffer, treating as minor node", area.id)
		local minorPoint = {
			id = 1,
			gridX = 0,
			gridY = 0,
			pos = area.pos,
			neighbors = {},
			parentArea = area.id,
			ring = 0,
			isEdge = true,
			isInner = false,
			dirTags = { "N", "S", "E", "W" }, -- Minor area connects in all directions
			dirMask = Node.DIR.N | Node.DIR.S | Node.DIR.E | Node.DIR.W,
		}

		-- Create edgeSets for minor areas - single point represents all directions
		area.edgeSets = {
			N = { minorPoint },
			S = { minorPoint },
			E = { minorPoint },
			W = { minorPoint },
		}

		-- Set grid extents for minor areas
		area.gridMinX, area.gridMaxX = 0, 0
		area.gridMinY, area.gridMaxY = 0, 0

		return { minorPoint }
	end

	local gx = math.floor(usableWidth / GRID) + 1
	local gy = math.floor(usableHeight / GRID) + 1

	-- Double-check for degenerate cases
	if gx <= 0 or gy <= 0 then
		Log:Debug("Area %d grid calculation resulted in degenerate dimensions (%dx%d)", area.id, gx, gy)
		local minorPoint = {
			id = 1,
			gridX = 0,
			gridY = 0,
			pos = area.pos,
			neighbors = {},
			parentArea = area.id,
			ring = 0,
			isEdge = true,
			isInner = false,
			dirTags = { "N", "S", "E", "W" }, -- Minor area connects in all directions
			dirMask = Node.DIR.N | Node.DIR.S | Node.DIR.E | Node.DIR.W,
		}

		-- Create edgeSets for minor areas - single point represents all directions
		area.edgeSets = {
			N = { minorPoint },
			S = { minorPoint },
			E = { minorPoint },
			W = { minorPoint },
		}

		-- Set grid extents for minor areas
		area.gridMinX, area.gridMaxX = 0, 0
		area.gridMinY, area.gridMaxY = 0, 0

		return { minorPoint }
	end

	------------------------------------------------------------
	-- build raw grid
	------------------------------------------------------------
	local raw = {}
	for ix = 0, gx - 1 do
		for iy = 0, gy - 1 do
			-- Place grid points within the usable area, starting from edgeBuffer offset
			local x = area.minX + edgeBuffer + ix * GRID
			local y = area.minY + edgeBuffer + iy * GRID
			raw[#raw + 1] = {
				gridX = ix,
				gridY = iy,
				pos = Vector3(x, y, bilinearZ(x, y, area.nw, area.ne, area.se, area.sw)),
				neighbors = {},
				parentArea = area.id,
			}
		end
	end

	------------------------------------------------------------
	-- peel border IF we still have something inside afterwards
	------------------------------------------------------------
	local keepFull = (gx <= 2) or (gy <= 2)
	local points = {}
	if keepFull then
		points = raw
		Log:Debug("Area %d keeping full grid (%dx%d points) - too small to peel border", area.id, gx, gy)
	else
		for _, p in ipairs(raw) do
			if not (p.gridX == 0 or p.gridX == gx - 1 or p.gridY == 0 or p.gridY == gy - 1) then
				points[#points + 1] = p
			end
		end
		if #points == 0 then -- pathological L-shape → revert
			points, keepFull = raw, true
			Log:Debug("Area %d reverting to full grid - peeling resulted in no points", area.id)
		else
			Log:Debug("Area %d peeled border: %d -> %d points", area.id, #raw, #points)
		end
	end

	------------------------------------------------------------
	-- ring metric + edge / inner flags + directional tags
	------------------------------------------------------------
	local minGX, maxGX, minGY, maxGY = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(points) do
		minGX, maxGX = math.min(minGX, p.gridX), math.max(maxGX, p.gridX)
		minGY, maxGY = math.min(minGY, p.gridY), math.max(maxGY, p.gridY)
	end
	for i, p in ipairs(points) do
		p.id = i
		p.ring = math.min(p.gridX - minGX, maxGX - p.gridX, p.gridY - minGY, maxGY - p.gridY)
		p.isEdge = (p.ring == 0 or p.ring == 1) -- 1-st/2-nd order
		p.isInner = (p.ring >= 2)
		p.dirTags = {}
	end
	------------------------------------------------------------
	-- dirTags computed against the ring-2 rectangle
	------------------------------------------------------------
	local innerMinGX, innerMaxGX = math.huge, -math.huge
	local innerMinGY, innerMaxGY = math.huge, -math.huge
	for _, p in ipairs(points) do
		if p.isInner then
			innerMinGX, innerMaxGX = math.min(innerMinGX, p.gridX), math.max(innerMaxGX, p.gridX)
			innerMinGY, innerMaxGY = math.min(innerMinGY, p.gridY), math.max(innerMaxGY, p.gridY)
		end
	end
	for _, p in ipairs(points) do
		if innerMinGX <= innerMaxGX then
			if p.gridX < innerMinGX then
				p.dirTags[#p.dirTags + 1] = "W"
			end
			if p.gridX > innerMaxGX then
				p.dirTags[#p.dirTags + 1] = "E"
			end
			if p.gridY < innerMinGY then
				p.dirTags[#p.dirTags + 1] = "S"
			end
			if p.gridY > innerMaxGY then
				p.dirTags[#p.dirTags + 1] = "N"
			end
		end
	end

	------------------------------------------------------------
	-- NEW: build edge buckets and dirMask for fast lookups
	------------------------------------------------------------
	area.edgeSets = { N = {}, S = {}, E = {}, W = {} }
	for _, p in ipairs(points) do
		local m = 0
		if p.gridY == maxGY then
			m = m | Node.DIR.N
			area.edgeSets.N[#area.edgeSets.N + 1] = p
		end
		if p.gridY == minGY then
			m = m | Node.DIR.S
			area.edgeSets.S[#area.edgeSets.S + 1] = p
		end
		if p.gridX == maxGX then
			m = m | Node.DIR.E
			area.edgeSets.E[#area.edgeSets.E + 1] = p
		end
		if p.gridX == minGX then
			m = m | Node.DIR.W
			area.edgeSets.W[#area.edgeSets.W + 1] = p
		end
		p.dirMask = m
	end

	------------------------------------------------------------
	-- orthogonal neighbours, fallback diagonal if isolated
	------------------------------------------------------------
	local function addLink(a, b)
		local d = (a.pos - b.pos):Length()
		local cost = d

		-- Add height-based cost for smooth walking mode
		if G.Menu.Main.WalkableMode == "Smooth" then
			local heightDiff = math.abs(b.pos.z - a.pos.z)
			if heightDiff > 18 then -- Requires jump in smooth mode
				local heightPenalty = math.floor(heightDiff / 18) * 10 -- 10 cost per 18 units
				cost = cost + heightPenalty
			end
		end

		a.neighbors[#a.neighbors + 1] = { point = b, cost = cost, isInterArea = true }
		b.neighbors[#b.neighbors + 1] = { point = a, cost = cost, isInterArea = true }
	end
	local idx = {} -- quick lookup
	for _, p in ipairs(points) do
		idx[p.gridX .. "," .. p.gridY] = p
	end
	local added = 0
	for _, p in ipairs(points) do
		local n = idx[p.gridX .. "," .. (p.gridY + 1)]
		local s = idx[p.gridX .. "," .. (p.gridY - 1)]
		local e = idx[(p.gridX + 1) .. "," .. p.gridY]
		local w = idx[(p.gridX - 1) .. "," .. p.gridY]
		if n then
			addLink(p, n)
			added = added + 1
		end
		if s then
			addLink(p, s)
			added = added + 1
		end
		if e then
			addLink(p, e)
			added = added + 1
		end
		if w then
			addLink(p, w)
			added = added + 1
		end
		if #p.neighbors == 0 then -- stranded corner → diag
			local ne = idx[(p.gridX + 1) .. "," .. (p.gridY + 1)]
			local nw = idx[(p.gridX - 1) .. "," .. (p.gridY + 1)]
			local se = idx[(p.gridX + 1) .. "," .. (p.gridY - 1)]
			local sw = idx[(p.gridX - 1) .. "," .. (p.gridY - 1)]
			if ne then
				addLink(p, ne)
				added = added + 1
			end
			if nw then
				addLink(p, nw)
				added = added + 1
			end
			if se then
				addLink(p, se)
				added = added + 1
			end
			if sw then
				addLink(p, sw)
				added = added + 1
			end
		end
	end

	Log:Debug("Area %d grid %dx%d  kept %d pts  links %d", area.id, gx, gy, #points, added)

	-- Cache grid extents for edge detection (use actual grid dimensions, not area bounds)
	area.gridMinX, area.gridMaxX, area.gridMinY, area.gridMaxY = minGX, maxGX, minGY, maxGY

	return points
end

--==========================================================================
--  Area point cache helpers  (unchanged API)
--==========================================================================

--- Check if an area should be treated as a minor node (too small for grid)
---@param area table The area to check
---@return boolean True if area should be treated as minor node
function Node.IsMinorArea(area)
	if not area then
		return true
	end

	local minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	local maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
	local minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
	local maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)

	local areaWidth = maxX - minX
	local areaHeight = maxY - minY

	return areaWidth < GRID or areaHeight < GRID
end

function Node.GenerateAreaPoints(id)
	local nodes = G.Navigation.nodes
	if not (nodes and nodes[id]) then
		return
	end
	local area = nodes[id]
	if area.finePoints then
		return area.finePoints
	end
	area.finePoints = generateAreaPoints(area)

	-- Log whether this area was treated as minor
	if area.finePoints and #area.finePoints == 1 then
		Log:Debug("Area %d treated as minor node (single point)", id)
	end

	return area.finePoints
end

function Node.GetAreaPoints(id)
	return Node.GenerateAreaPoints(id)
end

--==========================================================================
--  Touching-boxes helper
--==========================================================================
local function neighbourSide(a, b, eps)
	eps = eps or 1.0
	local overlapY = (a.minY <= b.maxY + eps) and (b.minY <= a.maxY + eps)
	local overlapX = (a.minX <= b.maxX + eps) and (b.minX <= a.maxX + eps)
	if overlapY and math.abs(a.maxX - b.minX) < eps then
		return "E", "W"
	end
	if overlapY and math.abs(b.maxX - a.minX) < eps then
		return "W", "E"
	end
	if overlapX and math.abs(a.maxY - b.minY) < eps then
		return "N", "S"
	end
	if overlapX and math.abs(b.maxY - a.minY) < eps then
		return "S", "N"
	end
	return nil
end

local function edgePoints(area, side)
	-- return precomputed bucket for the side
	return area.edgeSets[side] or {}
end

local function link(a, b)
	local d = (a.pos - b.pos):Length()
	local cost = d

	-- Add height-based cost for smooth walking mode
	if G.Menu.Main.WalkableMode == "Smooth" then
		local heightDiff = math.abs(b.pos.z - a.pos.z)
		if heightDiff > 18 then -- Requires jump in smooth mode
			local heightPenalty = math.floor(heightDiff / 18) * 10 -- 10 cost per 18 units
			cost = cost + heightPenalty
		end
	end

	a.neighbors[#a.neighbors + 1] = { point = b, cost = cost, isInterArea = true }
	b.neighbors[#b.neighbors + 1] = { point = a, cost = cost, isInterArea = true }
end

local function connectPair(areaA, areaB)
	-- Simple and fast stitching: each edge node connects to its 2 closest neighbors
	local sideA, sideB = neighbourSide(areaA, areaB, 5.0)
	if not sideA then
		return 0
	end

	local edgeA, edgeB = edgePoints(areaA, sideA), edgePoints(areaB, sideB)
	if #edgeA == 0 or #edgeB == 0 then
		return 0
	end

	local connectionCount = 0
	local maxDistance = 200 -- Maximum connection distance

	-- For each edge point in area A, find up to 2 closest points in area B
	for _, pointA in ipairs(edgeA) do
		local candidates = {}

		-- Find all candidates within max distance
		for _, pointB in ipairs(edgeB) do
			local distance = (pointA.pos - pointB.pos):Length()
			if distance <= maxDistance and isNodeAccessible(pointA, pointB, true) then
				table.insert(candidates, {
					point = pointB,
					distance = distance,
				})
			end
		end

		-- Sort by distance and take the 2 closest
		table.sort(candidates, function(a, b)
			return a.distance < b.distance
		end)

		-- Connect to up to 2 closest candidates
		local connectionsForThisPoint = 0
		for i = 1, math.min(2, #candidates) do
			local candidate = candidates[i]
			link(pointA, candidate.point)
			connectionCount = connectionCount + 1
			connectionsForThisPoint = connectionsForThisPoint + 1
		end

		-- Log detailed connections for debugging
		if connectionsForThisPoint > 0 then
			Log:Debug("Point in area %d connected to %d points in area %d", areaA.id, connectionsForThisPoint, areaB.id)
		end
	end

	-- For each edge point in area B, find up to 2 closest points in area A (bidirectional)
	for _, pointB in ipairs(edgeB) do
		local candidates = {}

		-- Find all candidates within max distance
		for _, pointA in ipairs(edgeA) do
			local distance = (pointB.pos - pointA.pos):Length()
			if distance <= maxDistance and isNodeAccessible(pointB, pointA, true) then
				-- Check if this connection already exists to avoid duplicates
				local alreadyConnected = false
				for _, neighbor in ipairs(pointB.neighbors) do
					if neighbor.point == pointA then
						alreadyConnected = true
						break
					end
				end

				if not alreadyConnected then
					table.insert(candidates, {
						point = pointA,
						distance = distance,
					})
				end
			end
		end

		-- Sort by distance and take the 2 closest
		table.sort(candidates, function(a, b)
			return a.distance < b.distance
		end)

		-- Connect to up to 2 closest candidates (if not already connected)
		local connectionsForThisPoint = 0
		for i = 1, math.min(2, #candidates) do
			local candidate = candidates[i]
			link(pointB, candidate.point)
			connectionCount = connectionCount + 1
			connectionsForThisPoint = connectionsForThisPoint + 1
		end
	end

	Log:Debug("Fast stitching: %d total connections between areas %d <-> %d", connectionCount, areaA.id, areaB.id)
	return connectionCount
end

--- Build hierarchical data structure for HPA* pathfinding
---@param processedAreas table Areas with their fine points and connections
local function buildHierarchicalStructure(processedAreas)
	-- Initialize hierarchical structure in globals
	if not G.Navigation.hierarchical then
		G.Navigation.hierarchical = {}
	end

	G.Navigation.hierarchical.areas = {}
	G.Navigation.hierarchical.edgePoints = {} -- Global registry of edge points for fast lookup

	local totalEdgePoints = 0
	local totalInterConnections = 0

	-- Process each area and build the hierarchical structure
	for areaId, data in pairs(processedAreas) do
		local areaInfo = {
			id = areaId,
			area = data.area,
			points = data.points,
			edgePoints = {}, -- Points on the boundary of this area
			internalPoints = {}, -- Points inside this area
			interAreaConnections = {}, -- Connections to other areas
		}
		-- Categorize points as edge or internal
		for _, point in pairs(data.points) do
			if point.isEdge then
				table.insert(areaInfo.edgePoints, point)
				-- Add to global edge point registry with area reference
				G.Navigation.hierarchical.edgePoints[point.id .. "_" .. areaId] = {
					point = point,
					areaId = areaId,
				}
				totalEdgePoints = totalEdgePoints + 1
			else
				table.insert(areaInfo.internalPoints, point)
			end

			-- Count inter-area connections
			for _, neighbor in pairs(point.neighbors) do
				if neighbor.isInterArea then
					totalInterConnections = totalInterConnections + 1
					-- Store inter-area connection info
					table.insert(areaInfo.interAreaConnections, {
						fromPoint = point,
						toPoint = neighbor.point,
						toArea = neighbor.point.parentArea,
						cost = neighbor.cost,
					})
				end
			end
		end

		G.Navigation.hierarchical.areas[areaId] = areaInfo
		Log:Debug(
			"Area %d: %d edge points, %d internal points, %d inter-area connections",
			areaId,
			#areaInfo.edgePoints,
			#areaInfo.internalPoints,
			#areaInfo.interAreaConnections
		)
	end

	Log:Info(
		"Built hierarchical structure: %d total edge points, %d inter-area connections",
		totalEdgePoints,
		totalInterConnections
	)
end

--==========================================================================
--  Multi-tick setup system to prevent game freezing
--==========================================================================
local SetupState = {
	currentPhase = 0,
	processedAreas = {},
	maxAreasPerTick = 10, -- Increased from 5 since stitching is now much faster
	totalAreas = 0,
	currentAreaIndex = 0,
	hierarchicalData = {},
}

--- Apply height penalties to all fine point connections
local function applyHeightPenaltiesToConnections(processedAreas)
	local penalizedCount = 0
	local invalidatedCount = 0

	Log:Info("Applying height penalties to fine point connections...")

	for areaId, data in pairs(processedAreas) do
		for _, point in ipairs(data.points) do
			local validNeighbors = {}

			for _, neighbor in ipairs(point.neighbors) do
				local heightDiff = neighbor.point.pos.z - point.pos.z

				if heightDiff > 72 then
					-- Invalid connection - can't jump this high
					invalidatedCount = invalidatedCount + 1
				elseif heightDiff > 18 then
					-- Apply 100 unit penalty for steep climbs
					neighbor.cost = (neighbor.cost or 1) + 100
					table.insert(validNeighbors, neighbor)
					penalizedCount = penalizedCount + 1
				else
					-- Normal connection
					table.insert(validNeighbors, neighbor)
				end
			end

			point.neighbors = validNeighbors
		end
	end

	Log:Info("Height penalties applied: %d penalized, %d invalidated", penalizedCount, invalidatedCount)
end

--- Initialize multi-tick setup
local function initializeSetup()
	SetupState.currentPhase = 1
	SetupState.processedAreas = {}
	SetupState.currentAreaIndex = 0
	SetupState.hierarchicalData = {}

	local nodes = G.Navigation.nodes
	if nodes then
		SetupState.totalAreas = 0
		for _ in pairs(nodes) do
			SetupState.totalAreas = SetupState.totalAreas + 1
		end
	end

	Log:Info("Starting multi-tick hierarchical setup: %d areas total", SetupState.totalAreas)
end

--- Process one tick of setup work
local function processSetupTick()
	if SetupState.currentPhase == 0 then
		return false -- No setup in progress
	end

	local nodes = G.Navigation.nodes
	if not nodes then
		SetupState.currentPhase = 0
		return false
	end

	if SetupState.currentPhase == 1 then
		-- Phase 1: Generate fine points (spread across multiple ticks)
		local processed = 0
		local areaIds = {}
		for id in pairs(nodes) do
			table.insert(areaIds, id)
		end

		local startIdx = SetupState.currentAreaIndex + 1
		local endIdx = math.min(startIdx + SetupState.maxAreasPerTick - 1, #areaIds)

		for i = startIdx, endIdx do
			local areaId = areaIds[i]
			local area = nodes[areaId]

			-- Generate fine points for this area (this also sets area bounds)
			local finePoints = Node.GenerateAreaPoints(areaId)

			-- Ensure the area has its bounds properly cached for neighbourSide function
			if not area.minX then
				area.minX = math.min(area.nw.x, area.ne.x, area.se.x, area.sw.x)
				area.maxX = math.max(area.nw.x, area.ne.x, area.se.x, area.sw.x)
				area.minY = math.min(area.nw.y, area.ne.y, area.se.y, area.sw.y)
				area.maxY = math.max(area.nw.y, area.ne.y, area.se.y, area.sw.y)
			end

			SetupState.processedAreas[areaId] = {
				area = area,
				points = finePoints,
			}
			processed = processed + 1
		end

		SetupState.currentAreaIndex = endIdx

		Log:Debug("Phase 1: Processed %d areas (%d/%d)", processed, SetupState.currentAreaIndex, #areaIds)

		if SetupState.currentAreaIndex >= #areaIds then
			SetupState.currentPhase = 2
			SetupState.currentAreaIndex = 0
			Log:Info("Phase 1 complete: Fine points generated for all areas with proper bounds")
		end

		return true -- More work to do
	elseif SetupState.currentPhase == 2 then
		-- Phase 2: Connect fine points between adjacent areas (spread across ticks) - OPTIMIZED
		local processed = 0
		local totalConnections = 0
		local areaIds = {}
		for id in pairs(SetupState.processedAreas) do
			table.insert(areaIds, id)
		end

		local startIdx = SetupState.currentAreaIndex + 1
		local endIdx = math.min(startIdx + SetupState.maxAreasPerTick - 1, #areaIds)

		for i = startIdx, endIdx do
			local areaId = areaIds[i]
			local data = SetupState.processedAreas[areaId]
			local area = data.area

			-- Get adjacent areas and process connections more efficiently
			local adjacentAreas = Node.GetAdjacentNodesOnly(area, nodes)

			if #adjacentAreas > 0 then
				Log:Debug("Area %d processing %d adjacent areas", areaId, #adjacentAreas)
			end

			for _, adjacentArea in ipairs(adjacentAreas) do
				-- Only connect to areas with higher IDs to avoid duplicate processing
				if SetupState.processedAreas[adjacentArea.id] and adjacentArea.id > areaId then
					-- Ensure both areas have their edgeSets (only regenerate if truly missing)
					local needsRegenA = not area.edgeSets
					local needsRegenB = not adjacentArea.edgeSets

					if needsRegenA then
						Log:Debug("Regenerating edgeSets for area %d", areaId)
						Node.GenerateAreaPoints(areaId)
					end
					if needsRegenB then
						Log:Debug("Regenerating edgeSets for area %d", adjacentArea.id)
						Node.GenerateAreaPoints(adjacentArea.id)
					end

					-- Fast stitching with the new algorithm
					local connections = connectPair(area, adjacentArea)
					totalConnections = totalConnections + connections

					if connections > 0 then
						Log:Debug("Fast stitched %d connections: %d <-> %d", connections, areaId, adjacentArea.id)
					end
				end
			end
			processed = processed + 1
		end

		SetupState.currentAreaIndex = endIdx

		Log:Debug(
			"Phase 2 (Fast): Processed %d areas (%d/%d), created %d connections this batch",
			processed,
			SetupState.currentAreaIndex,
			#areaIds,
			totalConnections
		)

		if SetupState.currentAreaIndex >= #areaIds then
			SetupState.currentPhase = 3
			Log:Info("Phase 2 complete: Fast inter-area stitching finished")
		end

		return true -- More work to do
	elseif SetupState.currentPhase == 3 then
		-- Phase 3: Apply height penalties and build hierarchical structure
		applyHeightPenaltiesToConnections(SetupState.processedAreas)
		buildHierarchicalStructure(SetupState.processedAreas)

		SetupState.currentPhase = 0 -- Setup complete
		Log:Info("Multi-tick hierarchical setup complete!")
		G.Navigation.navMeshUpdated = true
		return false -- Setup finished
	end

	return false
end

--==========================================================================
--  Enhanced hierarchical network generation with multi-tick support
--==========================================================================
function Node.GenerateHierarchicalNetwork(maxAreas)
	-- DISABLED: Hierarchical setup is disabled to prevent crashes
	-- The simplified pathfinding system doesn't need hierarchical data
	Log:Info("Hierarchical network generation disabled - using simplified pathfinding")
	return false
end

--==========================================================================
--  PUBLIC (everything else unchanged)
--==========================================================================

function Node.SetNodes(nodes)
	G.Navigation.nodes = nodes
end

function Node.GetNodes()
	return G.Navigation.nodes
end

function Node.GetNodeByID(id)
	return G.Navigation.nodes and G.Navigation.nodes[id] or nil
end

function Node.GetClosestNode(pos)
	if not G.Navigation.nodes then
		return nil
	end
	local closestArea, minDist = nil, math.huge
	for _, area in pairs(G.Navigation.nodes) do
		local d = (area.pos - pos):Length()
		if d < minDist then
			minDist = d
			closestArea = area
		end
	end
	return closestArea
end

--- Manually trigger connection cleanup (useful for debugging)
function Node.CleanupConnections()
	local nodes = Node.GetNodes()
	if nodes then
		pruneInvalidConnections(nodes)
	else
		Log:Warn("No nodes loaded for cleanup")
	end
end

function Node.AddConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Simplified connection adding
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			table.insert(cDir.connections, { node = nodeB.id, cost = 1, left = nil, middle = nil, right = nil })
			cDir.count = cDir.count + 1
			break
		end
	end
end

function Node.RemoveConnection(nodeA, nodeB)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Updated to handle both connection formats
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, connection in pairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				if targetNodeId == nodeB.id then
					table.remove(cDir.connections, i)
					cDir.count = cDir.count - 1
					break
				end
			end
		end
	end
end

function Node.AddCostToConnection(nodeA, nodeB, cost)
	if not nodeA or not nodeB then
		return
	end
	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end
	-- Updated to handle both connection formats and preserve door fields
	for dir, cDir in pairs(nodes[nodeA.id] and nodes[nodeA.id].c or {}) do
		if cDir and cDir.connections then
			for i, connection in pairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				if targetNodeId == nodeB.id then
					local base = normalizeConnectionEntry(connection)
					base.cost = cost
					cDir.connections[i] = base
					break
				end
			end
		end
	end
end

--- Add penalty to connection when pathfinding fails (adds 100 cost each failure)
---@param nodeA table First node (source)
---@param nodeB table Second node (destination)
function Node.AddFailurePenalty(nodeA, nodeB, penalty)
	penalty = penalty or 100
	if not nodeA or not nodeB then
		return
	end

	local nodes = G.Navigation.nodes
	if not nodes then
		return
	end

	-- Resolve area IDs for both nodes (supports fine points)

	-- Prefer parentArea when present to avoid mixing fine point IDs with area IDs
	local function resolveAreaId(n)
		if not n then
			return nil
		end

		if n.parentArea then
			return n.parentArea
		end

		return n.id
	end

	-- Helper to apply penalty in one direction for area connections
	local function applyAreaPenalty(fromAreaId, toAreaId)
		if not (fromAreaId and toAreaId) then
			return false
		end
		for _, cDir in pairs(nodes[fromAreaId] and nodes[fromAreaId].c or {}) do
			if cDir and cDir.connections then
				for i, connection in pairs(cDir.connections) do
					local targetNodeId = getConnectionNodeId(connection)
					if targetNodeId == toAreaId then
						local currentCost = getConnectionCost(connection)
						local newCost = currentCost + penalty
						local base = normalizeConnectionEntry(connection)
						base.cost = newCost
						cDir.connections[i] = base
						Log:Debug(
							"Added failure penalty to connection %d -> %d: %.1f -> %.1f",
							fromAreaId,
							toAreaId,
							currentCost,
							newCost
						)
						return true
					end
				end
			end
		end
		return false
	end

	-- Helper to apply penalty for fine point neighbors
	local function applyFinePenalty(fromNode, toNode)
		if not fromNode.neighbors then
			return false
		end
		for _, neighbor in ipairs(fromNode.neighbors) do
			if
				neighbor.point
				and (
					neighbor.point == toNode
					or (neighbor.point.id == toNode.id and neighbor.point.parentArea == toNode.parentArea)
				)
			then
				local currentCost = neighbor.cost or 1
				local newCost = currentCost + penalty
				neighbor.cost = newCost
				Log:Debug(
					"Added fine failure penalty to point %d (area %s) -> %d (area %s): %.1f -> %.1f",
					fromNode.id or -1,
					fromNode.parentArea or "?",
					toNode.id or -1,
					toNode.parentArea or "?",
					currentCost,
					newCost
				)
				return true
			end
		end
		return false
	end

	local function applyPenalty(fromNode, toNode)
		-- First try area-level penalty
		local fromArea = resolveAreaId(fromNode)
		local toArea = resolveAreaId(toNode)
		local appliedArea = applyAreaPenalty(fromArea, toArea)

		-- Then fine-point penalty if applicable
		local appliedFine = applyFinePenalty(fromNode, toNode)

		-- Debug if no connection was updated
		if not appliedArea and not appliedFine then
			Log:Warn(
				"Skipping penalty for invalid connection: %s->%s",
				tostring(fromArea or fromNode.id),
				tostring(toArea or toNode.id)
			)
		end
	end

	-- Apply penalty both directions to discourage repeated failure
	applyPenalty(nodeA, nodeB)
	applyPenalty(nodeB, nodeA)
end

--- Get adjacent nodes with accessibility checks (expensive, for pathfinding)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of accessible adjacent nodes
--- NOTE: This function is EXPENSIVE due to accessibility checks.
--- Use GetAdjacentNodesSimple for pathfinding after setup validation is complete.
function Node.GetAdjacentNodes(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for _, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode and targetNode.pos then
					-- Use centralized accessibility check (EXPENSIVE)
					if isNodeAccessible(node, targetNode, true) then
						table.insert(adjacent, targetNode)
					end
				end
			end
		end
	end
	return adjacent
end

--- Get adjacent nodes without accessibility checks (fast, for finding connections)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of connected adjacent nodes with costs
--- NOTE: This function is FAST and should be used for pathfinding.
--- Assumes connections are already validated during setup time.
--- Returns: { {node = targetNode, cost = connectionCost}, ... }
function Node.GetAdjacentNodesSimple(node, nodes)
	local adjacent = {}
	if not node or not node.c or not nodes then
		return adjacent
	end

	-- Check all directions using ipairs for connections
	for _, cDir in ipairs(node.c) do
		if cDir and cDir.connections then
			for _, connection in ipairs(cDir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local connectionCost = getConnectionCost(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode and targetNode.pos then
					-- Return node WITH cost for direct use in pathfinding
					table.insert(adjacent, {
						node = targetNode,
						cost = connectionCost,
					})
				end
			end
		end
	end
	return adjacent
end

--- Get adjacent nodes as simple array (for backward compatibility with non-pathfinding uses)
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of adjacent node objects only
function Node.GetAdjacentNodesOnly(node, nodes)
	local adjacent = {}
	local adjacentWithCost = Node.GetAdjacentNodesSimple(node, nodes)

	for _, neighborData in ipairs(adjacentWithCost) do
		table.insert(adjacent, neighborData.node)
	end

	return adjacent
end

--- Fast, zero logic - just returns whatever the nav-file says
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of adjacent node objects (raw connections)
function Node.GetAdjacentNodesRaw(node, nodes)
	local out = {}
	if not node or not node.c then
		return out
	end

	for _, dir in pairs(node.c) do
		if dir and dir.connections then
			for _, connection in pairs(dir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode then
					out[#out + 1] = targetNode
				end
			end
		end
	end
	return out
end

--- Slow but safe - uses isNodeAccessible / walkable checks
---@param node table First node (source)
---@param nodes table All navigation nodes
---@return table[] Array of accessible adjacent node objects
function Node.GetAdjacentNodesClean(node, nodes)
	local out = {}
	if not node or not node.c then
		return out
	end

	for _, dir in pairs(node.c) do
		if dir and dir.connections then
			for _, connection in pairs(dir.connections) do
				local targetNodeId = getConnectionNodeId(connection)
				local targetNode = nodes[targetNodeId]
				if targetNode and isNodeAccessible(node, targetNode, true) then
					out[#out + 1] = targetNode
				end
			end
		end
	end
	return out
end

function Node.LoadFile(navFile)
	local full = "tf/" .. navFile
	local navData, err = tryLoadNavFile(full)
	if not navData and err == "File not found" then
		Log:Warn("Nav file not found, attempting to generate...")
		generateNavFile()
		navData, err = tryLoadNavFile(full)
		if not navData then
			Log:Error("Failed to load or parse generated nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		elseif not navData then
			Log:Error("Failed to load nav file: %s", err or "unknown")
			-- Initialize empty nodes table to prevent crashes
			Node.SetNodes({})
			return false
		end
	end

	local navNodes = processNavData(navData)
	if not navNodes or not next(navNodes) then
		Log:Error("No navigation nodes found in nav file")
		return false
	end

	Node.SetNodes(navNodes)

	-- Safe setup with error handling
	local success, setupErr = pcall(function()
		-- Ensure all connections use enriched structure { node, cost, left, middle, right }
		Node.NormalizeConnections()
		-- Build doors and prune unreachable connections
		Node.BuildDoorsForConnections()
	end)

	if not success then
		Log:Error("Setup failed: %s", setupErr or "Unknown error")
		return false
	end

	-- Fix: Count nodes properly for hash table
	local nodeCount = 0
	for _ in pairs(navNodes) do
		nodeCount = nodeCount + 1
	end
	Log:Info("Successfully loaded %d navigation nodes", nodeCount)

	-- Cleanup invalid connections after loading (if enabled)
	if G.Menu.Main.CleanupConnections then
		pruneInvalidConnections(navNodes)
	else
		Log:Info("Connection cleanup is disabled in settings")
	end

	return true
end

function Node.LoadNavFile()
	local mf = engine.GetMapName()
	if mf and mf ~= "" then
		Node.LoadFile(string.gsub(mf, ".bsp", ".nav"))
	else
		Log:Warn("No map name available for nav file loading")
		Node.SetNodes({})
	end
end

function Node.Setup()
	-- Prevent multiple setup calls
	if G.Navigation.navMeshUpdated then
		Log:Debug("Navigation already set up, skipping")
		return
	end

	local mapName = engine.GetMapName()
	if mapName and mapName ~= "" and mapName ~= "menu" then
		Log:Info("Setting up navigation for map: %s", mapName)
		Node.LoadNavFile()
		-- Simplified setup - no hierarchical network to prevent crashes
		-- Pathfinding uses only main areas and enriched connections
		G.Navigation.navMeshUpdated = true
	else
		Log:Info("No valid map loaded, initializing empty navigation nodes")
		-- Initialize empty nodes table to prevent crashes when no map is loaded
		Node.SetNodes({})
	end
end

-- Reset setup state (useful for debugging or map changes)
function Node.ResetSetup()
	G.Navigation.navMeshUpdated = false
	Log:Info("Navigation setup state reset")
end

--- Find the closest fine point within an area to a given position
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest point or nil if not found
function Node.GetClosestAreaPoint(areaId, position)
	local points = Node.GetAreaPoints(areaId)
	if not points then
		return nil
	end

	local closest, minDist = nil, math.huge
	for _, point in pairs(points) do
		local dist = (point.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = point
		end
	end

	return closest
end

--- Clear cached fine points for all areas (useful when settings change)
function Node.ClearAreaPoints()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	local clearedCount = 0
	for _, area in pairs(nodes) do
		if area.finePoints then
			area.finePoints = nil
			clearedCount = clearedCount + 1
		end
	end

	Log:Info("Cleared fine points cache for %d areas", clearedCount)
end

--- Get hierarchical pathfinding data (for HPA* algorithm)
---@return table|nil Hierarchical structure or nil if not available
function Node.GetHierarchicalData()
	return G.Navigation.hierarchical
end

--- Get closest edge point in an area to a given position (for HPA* pathfinding)
---@param areaId number The area ID
---@param position Vector3 The target position
---@return table|nil The closest edge point or nil if not found
function Node.GetClosestEdgePoint(areaId, position)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return nil
	end

	local areaInfo = G.Navigation.hierarchical.areas[areaId]
	local closest, minDist = nil, math.huge

	for _, edgePoint in pairs(areaInfo.edgePoints) do
		local dist = (edgePoint.pos - position):Length()
		if dist < minDist then
			minDist = dist
			closest = edgePoint
		end
	end

	return closest
end

--- Get all inter-area connections from a specific area (for HPA* pathfinding)
---@param areaId number The area ID
---@return table[] Array of inter-area connections
function Node.GetInterAreaConnections(areaId)
	if not G.Navigation.hierarchical or not G.Navigation.hierarchical.areas[areaId] then
		return {}
	end

	return G.Navigation.hierarchical.areas[areaId].interAreaConnections or {}
end

-- Register OnDraw callback for background connection processing
local function OnDrawConnectionProcessing()
	ProfilerBeginSystem("node_connection_draw")

	Node.ProcessConnectionsBackground()

	ProfilerEndSystem()
end

callbacks.Unregister("Draw", "Node.ConnectionProcessing")
callbacks.Register("Draw", "Node.ConnectionProcessing", OnDrawConnectionProcessing)

--- Recalculate all connection costs based on current walking mode
function Node.RecalculateConnectionCosts()
	local nodes = Node.GetNodes()
	if not nodes then
		return
	end

	local recalculatedCount = 0
	local smoothMode = G.Menu.Main.WalkableMode == "Smooth"

	Log:Info("Recalculating connection costs for %s walking mode", G.Menu.Main.WalkableMode)

	-- Recalculate regular node connections
	for nodeId, node in pairs(nodes) do
		if node and node.c then
			for dir, connectionDir in pairs(node.c) do
				if connectionDir and connectionDir.connections then
					for i, connection in ipairs(connectionDir.connections) do
						local targetNodeId = getConnectionNodeId(connection)
						local targetNode = nodes[targetNodeId]

						if targetNode and type(connection) == "table" then
							local baseCost = connection.cost or 1
							local heightDiff = targetNode.pos.z - node.pos.z

							-- Reset to base cost first
							local newCost = baseCost

							-- Add height penalty for smooth mode
							if smoothMode and heightDiff > 18 then
								local heightPenalty = math.floor(heightDiff / 18) * 10
								newCost = newCost + heightPenalty
							end

							connection.cost = newCost
							recalculatedCount = recalculatedCount + 1
						end
					end
				end
			end
		end
	end

	-- Recalculate inter-area fine point connections
	if G.Navigation.hierarchical and G.Navigation.hierarchical.areas then
		for areaId, areaInfo in pairs(G.Navigation.hierarchical.areas) do
			if areaInfo.points then
				for _, point in ipairs(areaInfo.points) do
					if point.neighbors then
						for _, neighbor in ipairs(point.neighbors) do
							if neighbor.point and neighbor.cost then
								local baseDist = (point.pos - neighbor.point.pos):Length()
								local heightDiff = math.abs(neighbor.point.pos.z - point.pos.z)

								-- Reset to base distance
								local newCost = baseDist

								-- Add height penalty for smooth mode
								if smoothMode and heightDiff > 18 then
									local heightPenalty = math.floor(heightDiff / 18) * 10
									newCost = newCost + heightPenalty
								end

								neighbor.cost = newCost
								recalculatedCount = recalculatedCount + 1
							end
						end
					end
				end
			end
		end
	end

	Log:Info("Recalculated %d connection costs for %s mode", recalculatedCount, G.Menu.Main.WalkableMode)
end

return Node
