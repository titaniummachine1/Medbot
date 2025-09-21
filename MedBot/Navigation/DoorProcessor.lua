--[[
Door Processor - Extensible Pipeline for Door Operations
Provides hooks for custom door processing, validation, and behavior.
Easy to extend with new processors without modifying core door logic.
]]

local DoorProcessor = {}

local Common = require("MedBot.Core.Common")
local Log = Common.Log.new("DoorProcessor")

-- ============================================================================
-- BASE PROCESSOR CLASS
-- ============================================================================

---Base processor class for creating custom door processors
---@class DoorProcessor
local BaseProcessor = {}
BaseProcessor.__index = BaseProcessor

---Create a new processor
---@param name string Processor name
---@return table New processor instance
function BaseProcessor.New(name)
	local self = setmetatable({}, BaseProcessor)
	self.name = name or "UnnamedProcessor"
	return self
end

---Called after door generation (for validation/modification)
---@param door table Door data
function BaseProcessor:postGenerate(door)
	-- Override in subclasses
end

---Called during door processing (for behavior/logic)
---@param door table Door data
function BaseProcessor:process(door)
	-- Override in subclasses
end

-- ============================================================================
-- BUILT-IN PROCESSORS
-- ============================================================================

---Door validator - checks door data integrity
local DoorValidator = BaseProcessor.New("DoorValidator")

function DoorValidator:postGenerate(door)
	if not door.left or not door.middle or not door.right then
		Log:Warn("Door missing edge points: %s", door.id)
	end

	if not door.owner then
		Log:Warn("Door missing owner: %s", door.id)
	end
end

---Door height analyzer - analyzes door height relationships
local DoorHeightAnalyzer = BaseProcessor.New("DoorHeightAnalyzer")

function DoorHeightAnalyzer:postGenerate(door)
	if door.zMin and door.zMax then
		local height = door.zMax - door.zMin
		door.height = height

		-- Categorize door type by height
		if height < 50 then
			door.type = "crouch"
		elseif height < 100 then
			door.type = "walk"
		else
			door.type = "jump"
		end
	end
end

---Door accessibility checker - determines if door is traversable
local DoorAccessibilityChecker = BaseProcessor.New("DoorAccessibilityChecker")

function DoorAccessibilityChecker:postGenerate(door)
	-- Basic accessibility check based on height and width
	local width = door.right.x - door.left.x
	door.isAccessible = door.height and door.height > 30 and width > 10
end

-- ============================================================================
-- PROCESSOR MANAGEMENT
-- ============================================================================

---Get all built-in processors
---@return table Array of built-in processors
function DoorProcessor.GetBuiltInProcessors()
	return {
		DoorValidator,
		DoorHeightAnalyzer,
		DoorAccessibilityChecker,
	}
end

---Create a custom processor for specific door behaviors
---@param name string Processor name
---@param postGenerateFunc function|nil Function called after door generation
---@param processFunc function|nil Function called during door processing
---@return table Custom processor
function DoorProcessor.CreateCustomProcessor(name, postGenerateFunc, processFunc)
	local processor = BaseProcessor.New(name)

	if postGenerateFunc then
		processor.postGenerate = postGenerateFunc
	end

	if processFunc then
		processor.process = processFunc
	end

	return processor
end

---Example: Create a processor that logs door information
function DoorProcessor.CreateLoggingProcessor()
	return DoorProcessor.CreateCustomProcessor("DoorLogger", function(door) -- postGenerate
		Log:Info(
			"Generated door %s: type=%s, height=%.1f, accessible=%s",
			door.id,
			door.type or "unknown",
			door.height or 0,
			door.isAccessible and "yes" or "no"
		)
	end, function(door) -- process
		-- Could log door usage here
	end)
end

---Example: Create a processor for special door types
function DoorProcessor.CreateSpecialDoorProcessor()
	return DoorProcessor.CreateCustomProcessor("SpecialDoorHandler", function(door) -- postGenerate
		if door.type == "jump" then
			door.requiresJump = true
			door.jumpHeight = door.height
		end
	end, function(door) -- process
		if door.requiresJump then
			-- Custom jump logic here
			Log:Debug("Processing jump door %s", door.id)
		end
	end)
end

DoorProcessor.BaseProcessor = BaseProcessor

return DoorProcessor
