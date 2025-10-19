--[[
Node Skipper - Simple forward-progress node skipping
Logic:
1. Respect Skip_Nodes toggle
2. Only skip when the player is closer to the next node than the current node is
3. Returns fixed skip count (1) to advance steadily without funneling
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
local PathValidator = require("MedBot.Navigation.PathValidator")

local NodeSkipper = {}

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Initialize/reset state when needed
function NodeSkipper.Reset()
	G.Navigation.nextNodeCloser = false
end

-- SINGLE SOURCE OF TRUTH for node skipping
-- Checks if we should skip current node and executes the skip
-- RETURNS: true if skipped, false otherwise
function NodeSkipper.TrySkipNode(currentPos, removeNodeCallback)
	-- Respect Skip_Nodes menu setting
	if not G.Menu.Navigation.Skip_Nodes then
		print("NodeSkipper: Skip_Nodes is disabled")
		return false
	end
	
	print("NodeSkipper: Skip_Nodes is ENABLED, checking conditions...")

	local path = G.Navigation.path
	if not path then
		print("NodeSkipper: ABORT - No path exists")
		return false
	end
	
	if #path < 2 then
		print(string.format("NodeSkipper: ABORT - Path too short (length=%d)", #path))
		return false
	end

	local currentNode = path[1]
	local nextNode = path[2]

	if not currentNode or not nextNode then
		print("NodeSkipper: ABORT - Missing nodes")
		return false
	end
	
	if not currentNode.pos or not nextNode.pos then
		print("NodeSkipper: ABORT - Missing node positions")
		return false
	end
	
	print(string.format("NodeSkipper: Path valid, checking distances (path length=%d)", #path))
	print(string.format("NodeSkipper: Current node ID=%s, Next node ID=%s", tostring(currentNode.id or "nil"), tostring(nextNode.id or "nil")))

	local distPlayerToNext = Common.Distance3D(currentPos, nextNode.pos)
	local distCurrentToNext = Common.Distance3D(currentNode.pos, nextNode.pos)
	
	print(string.format("NodeSkipper: Player pos=(%.0f,%.0f,%.0f)", currentPos.x, currentPos.y, currentPos.z))
	print(string.format("NodeSkipper: Current node pos=(%.0f,%.0f,%.0f)", currentNode.pos.x, currentNode.pos.y, currentNode.pos.z))
	print(string.format("NodeSkipper: Next node pos=(%.0f,%.0f,%.0f)", nextNode.pos.x, nextNode.pos.y, nextNode.pos.z))

	-- User spec: Only skip if player is closer to next node than current node is to next node
	if distPlayerToNext >= distCurrentToNext then
		print(string.format("NodeSkipper: ABORT - Not closer (player=%.0f >= current=%.0f)", distPlayerToNext, distCurrentToNext))
		return false -- Don't skip if we're not moving forward
	end
	
	print(string.format("NodeSkipper: Distance check PASSED (player=%.0f < current=%.0f)", distPlayerToNext, distCurrentToNext))

	-- Validate player can walk DIRECTLY to next node (if yes, we don't need current node!)
	print(string.format("NodeSkipper: === CALLING PathValidator ==="))
	print(string.format("NodeSkipper: FROM PLAYER(%.0f,%.0f,%.0f) TO NEXT_NODE(%.0f,%.0f,%.0f)", 
		currentPos.x, currentPos.y, currentPos.z, 
		nextNode.pos.x, nextNode.pos.y, nextNode.pos.z))
	
	local isWalkable = PathValidator.Path(currentPos, nextNode.pos)
	
	print(string.format("NodeSkipper: === PathValidator RETURNED %s ===", tostring(isWalkable)))
	
	-- Debug logging (respects G.Menu.Main.Debug)
	local Log = require("MedBot.Core.Common").Log.new("NodeSkipper")
	Log:Debug("Skip check: playerDist=%.0f currentDist=%.0f walkable=%s", distPlayerToNext, distCurrentToNext, tostring(isWalkable))
	
	if not isWalkable then
		Log:Debug("Skip blocked: path not walkable (wall detected)")
		return false -- Don't skip if path has walls/obstacles
	end

	-- Execute the skip
	if removeNodeCallback then
		Log:Debug("Skipping node - path is clear")
		removeNodeCallback()
		return true
	end

	return false
end

return NodeSkipper
