--##########################################################################
--  CircuitBreaker.lua  ·  Connection failure handling
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local CircuitBreaker = {}

local Log = Common.Log.new("CircuitBreaker")

-- Circuit breaker configuration
local config = {
	failures = {}, -- [connectionKey] = { count, lastFailTime, isBlocked }
	maxFailures = 2, -- Max failures before blocking connection temporarily
	blockDuration = 300, -- Ticks to block connection (5 seconds)
	cleanupInterval = 180, -- Clean up old entries every 3 seconds
	maxEntries = 500, -- Hard limit to prevent memory exhaustion
	lastCleanup = 0,
}

-- Expose globally for pathfinding adjacency filter
G.CircuitBreaker = config

function CircuitBreaker.AddFailure(nodeA, nodeB)
	if not nodeA or not nodeB then return false end

	local connectionKey = nodeA.id * 1000000 + nodeB.id
	local currentTick = globals.TickCount()

	if not config.failures[connectionKey] then
		config.failures[connectionKey] = { count = 0, lastFailTime = 0, isBlocked = false }
	end

	local failure = config.failures[connectionKey]
	failure.count = failure.count + 1
	failure.lastFailTime = currentTick

	local additionalPenalty = 100
	-- Note: Need to move Node.AddFailurePenalty to this module or call it externally
	
	Log:Info("Connection %d->%d failure #%d", nodeA.id, nodeB.id, failure.count)

	if failure.count >= config.maxFailures then
		failure.isBlocked = true
		Log:Warn("Connection %d->%d BLOCKED after %d failures", nodeA.id, nodeB.id, failure.count)
		return true
	end

	return false
end

function CircuitBreaker.IsBlocked(nodeA, nodeB)
	if not nodeA or not nodeB then return false end

	local connectionKey = nodeA.id * 1000000 + nodeB.id
	local currentTick = globals.TickCount()
	local failure = config.failures[connectionKey]

	if not failure then return false end

	if failure.isBlocked then
		if currentTick - failure.lastFailTime > config.blockDuration then
			failure.isBlocked = false
			failure.count = math.max(0, failure.count - 1)
			Log:Info("Connection %d->%d unblocked after timeout", nodeA.id, nodeB.id)
			return false
		end
		return true
	end

	return false
end

function CircuitBreaker.Cleanup()
	local currentTick = globals.TickCount()
	if currentTick - config.lastCleanup < config.cleanupInterval then
		return
	end

	local totalEntries = 0
	for key, failure in pairs(config.failures) do
		totalEntries = totalEntries + 1
		if totalEntries > config.maxEntries or 
		   currentTick - failure.lastFailTime > (config.blockDuration * 3) then
			config.failures[key] = nil
		end
	end

	config.lastCleanup = currentTick
end

return CircuitBreaker
