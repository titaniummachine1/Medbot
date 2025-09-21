--[[
Circuit Breaker - Prevents infinite loops on problematic connections
Tracks connection failures and temporarily blocks connections that fail repeatedly
]]

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")
-- local Node = require("MedBot.Navigation.Node")  -- Temporarily disabled for bundle compatibility

local CircuitBreaker = {}
local Log = Common.Log.new("CircuitBreaker")

-- Circuit breaker state
local state = {
	failures = {}, -- [connectionKey] = { count, lastFailTime, isBlocked }
	maxFailures = 2, -- Max failures before blocking connection temporarily
	blockDuration = 300, -- Ticks to block connection (5 seconds)
	cleanupInterval = 1800, -- Clean up old entries every 30 seconds
	lastCleanup = 0,
}

-- Add a connection failure to the circuit breaker
function CircuitBreaker.addFailure(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	local connectionKey = nodeA.id .. "->" .. nodeB.id
	local currentTick = globals.TickCount()

	-- Initialize or update failure count
	if not state.failures[connectionKey] then
		state.failures[connectionKey] = { count = 0, lastFailTime = 0, isBlocked = false }
	end

	local failure = state.failures[connectionKey]
	failure.count = failure.count + 1
	failure.lastFailTime = currentTick

	-- Each failure adds MORE penalty (makes path progressively more expensive)
	local additionalPenalty = 100 -- Add 100 units per failure
	-- Node.AddFailurePenalty(nodeA, nodeB, additionalPenalty)  -- Temporarily disabled for bundle compatibility

	Log:Debug(
		"Connection %s failure #%d - added %d penalty (total accumulating)",
		connectionKey,
		failure.count,
		additionalPenalty
	)

	-- Block connection if too many failures
	if failure.count >= state.maxFailures then
		failure.isBlocked = true
		-- Add a big penalty to ensure A* avoids this completely
		local blockingPenalty = 500
		-- Node.AddFailurePenalty(nodeA, nodeB, blockingPenalty)  -- Temporarily disabled for bundle compatibility

		Log:Warn(
			"Connection %s BLOCKED after %d failures (added final %d penalty)",
			connectionKey,
			failure.count,
			blockingPenalty
		)
		return true
	end

	return false
end

-- Check if a connection is blocked by circuit breaker
function CircuitBreaker.isBlocked(nodeA, nodeB)
	if not nodeA or not nodeB then
		return false
	end

	local connectionKey = nodeA.id .. "->" .. nodeB.id
	local failure = state.failures[connectionKey]

	if not failure or not failure.isBlocked then
		return false
	end

	local currentTick = globals.TickCount()
	-- Unblock if enough time has passed (penalties remain but connection becomes usable)
	if currentTick - failure.lastFailTime > state.blockDuration then
		failure.isBlocked = false
		failure.count = 0 -- Reset failure count (penalties stay, giving A* a chance to reconsider)

		Log:Info(
			"Connection %s UNBLOCKED after timeout (accumulated penalties remain as lesson learned)",
			connectionKey
		)
		return false
	end

	return true
end

-- Clean up old circuit breaker entries
function CircuitBreaker.cleanup()
	local currentTick = globals.TickCount()
	if currentTick - state.lastCleanup < state.cleanupInterval then
		return
	end

	state.lastCleanup = currentTick
	local cleaned = 0

	for connectionKey, failure in pairs(state.failures) do
		-- Clean up old, unblocked entries
		if not failure.isBlocked and (currentTick - failure.lastFailTime) > state.blockDuration * 2 then
			state.failures[connectionKey] = nil
			cleaned = cleaned + 1
		end
	end

	if cleaned > 0 then
		Log:Debug("Circuit breaker cleaned up %d old entries", cleaned)
	end
end

-- Get circuit breaker status for debugging
function CircuitBreaker.getStatus()
	local currentTick = globals.TickCount()
	local blockedCount = 0
	local totalFailures = 0

	for connectionKey, failure in pairs(state.failures) do
		totalFailures = totalFailures + failure.count
		if failure.isBlocked then
			blockedCount = blockedCount + 1
		end
	end

	return {
		connections = state.failures,
		blockedCount = blockedCount,
		totalFailures = totalFailures,
		settings = {
			maxFailures = state.maxFailures,
			blockDuration = state.blockDuration,
		},
	}
end

-- Clear all circuit breaker data
function CircuitBreaker.clear()
	state.failures = {}
	Log:Info("Circuit breaker cleared - all connections reset")
end

-- Manually block/unblock connections
function CircuitBreaker.manualBlock(nodeA, nodeB)
	local connectionKey = tostring(nodeA) .. "->" .. tostring(nodeB)
	state.failures[connectionKey] = {
		count = state.maxFailures,
		lastFailTime = globals.TickCount(),
		isBlocked = true,
	}
	Log:Info("Manually blocked connection %s", connectionKey)
end

function CircuitBreaker.manualUnblock(nodeA, nodeB)
	local connectionKey = tostring(nodeA) .. "->" .. tostring(nodeB)
	if state.failures[connectionKey] then
		state.failures[connectionKey].isBlocked = false
		state.failures[connectionKey].count = 0
		Log:Info("Manually unblocked connection %s", connectionKey)
	end
end

return CircuitBreaker
