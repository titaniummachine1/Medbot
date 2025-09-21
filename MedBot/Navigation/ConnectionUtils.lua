--##########################################################################
--  ConnectionUtils.lua  ·  Connection data handling utilities
--##########################################################################

local ConnectionUtils = {}

-- Extract node ID from connection (handles both integer and table format)
function ConnectionUtils.GetNodeId(connection)
	if type(connection) == "table" then
		return connection.node or connection.neighborId
	else
		return connection
	end
end

-- Extract cost from connection (handles both integer and table format)
function ConnectionUtils.GetCost(connection)
	if type(connection) == "table" then
		return connection.cost or 0
	else
		return 0
	end
end

-- Normalize a single connection entry to the enriched table form
function ConnectionUtils.NormalizeEntry(entry)
	if type(entry) == "table" then
		entry.node = entry.node or entry.neighborId
		entry.cost = entry.cost or 0
		if entry.left then
			entry.left = Vector3(entry.left.x, entry.left.y, entry.left.z)
		end
		if entry.middle then
			entry.middle = Vector3(entry.middle.x, entry.middle.y, entry.middle.z)
		end
		if entry.right then
			entry.right = Vector3(entry.right.x, entry.right.y, entry.right.z)
		end
		return entry
	else
		return { node = entry, cost = 0, left = nil, middle = nil, right = nil }
	end
end

return ConnectionUtils
