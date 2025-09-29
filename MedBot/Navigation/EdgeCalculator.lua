--##########################################################################
--  EdgeCalculator.lua  ·  Edge and corner geometry calculations
--##########################################################################

local G = require("MedBot.Core.Globals")

local EdgeCalculator = {}

function EdgeCalculator.GetNodeCorners(node)
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
	if node.pos then
		table.insert(corners, node.pos)
	end
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

function EdgeCalculator.LerpVec(a, b, t)
	return Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
end

return EdgeCalculator
