--##########################################################################
--  EdgeCalculator.lua  ·  Edge and corner geometry calculations
--##########################################################################

local G = require("MedBot.Core.Globals")

local EdgeCalculator = {}

-- Constants
local HULL_MIN, HULL_MAX = G.pLocal.vHitbox.Min, G.pLocal.vHitbox.Max
local TRACE_MASK = MASK_PLAYERSOLID
local GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5)
local GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67)
local MASK_BRUSH_ONLY = MASK_PLAYERSOLID_BRUSHONLY

function EdgeCalculator.TraceHullDown(position)
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceHull(startPos, endPos, HULL_MIN, HULL_MAX, TRACE_MASK)
end

function EdgeCalculator.TraceLineDown(position)
	local height = HULL_MAX.z
	local startPos = position + Vector3(0, 0, height)
	local endPos = position - Vector3(0, 0, height)
	return engine.TraceLine(startPos, endPos, TRACE_MASK)
end

function EdgeCalculator.GetGroundNormal(position)
	local trace = engine.TraceLine(
		position + GROUND_TRACE_OFFSET_START, 
		position + GROUND_TRACE_OFFSET_END, 
		MASK_BRUSH_ONLY
	)
	return trace.plane
end

function EdgeCalculator.GetNodeCorners(node)
	local corners = {}
	if node.nw then table.insert(corners, node.nw) end
	if node.ne then table.insert(corners, node.ne) end
	if node.se then table.insert(corners, node.se) end
	if node.sw then table.insert(corners, node.sw) end
	if node.pos then table.insert(corners, node.pos) end
	return corners
end

function EdgeCalculator.Cross2D(ax, ay, bx, by)
	return ax * by - ay * bx
end

function EdgeCalculator.Dot2D(ax, ay, bx, by)
	return ax * bx + ay * by
end

function EdgeCalculator.Length2D(ax, ay)
	return math.sqrt(ax * ax + ay * ay)
end

function EdgeCalculator.Distance3D(p, q)
	local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function EdgeCalculator.LerpVec(a, b, t)
	return Vector3(
		a.x + (b.x - a.x) * t, 
		a.y + (b.y - a.y) * t, 
		a.z + (b.z - a.z) * t
	)
end

return EdgeCalculator
