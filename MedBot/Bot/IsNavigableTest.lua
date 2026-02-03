--[[
    IsNavigable Test Suite
    Test module for node-based navigation skipping
    Author: titaniummachine1 (github.com/titaniummachine1)
]]

local G = require("MedBot.Core.Globals")
local Node = require("MedBot.Navigation.Node")

-- Test state variables
local TestState = {
	enabled = false,
	startPos = nil,
	currentPos = nil,
	isNavigable = false,
	showVisuals = true,

	-- Benchmark data
	benchmarkRecords = {},
	MAX_RECORDS = 66,
	averageMemoryUsage = 0,
	averageTimeUsage = 0,

	-- Visual data
	hullTraces = {},
	lineTraces = {},
}

-- Load Navigable module
local Navigable = require("MedBot.Navigation.isWalkable.isNavigable")

-- Constants
local Fonts = { Verdana = draw.CreateFont("Verdana", 14, 510) }

-- Benchmark functions
local function BenchmarkStart()
	local startMemory = collectgarbage("count")
	local startTime = os.clock()
	return startTime, startMemory
end

local function BenchmarkStop(startTime, startMemory)
	local stopTime = os.clock()
	local stopMemory = collectgarbage("count")

	local elapsedTime = math.max(stopTime - startTime, 0)
	local memoryDelta = math.abs(stopMemory - startMemory)

	table.insert(TestState.benchmarkRecords, 1, { time = elapsedTime, memory = memoryDelta })
	if #TestState.benchmarkRecords > TestState.MAX_RECORDS then
		table.remove(TestState.benchmarkRecords)
	end

	local totalTime, totalMemory = 0, 0
	for _, record in ipairs(TestState.benchmarkRecords) do
		totalTime = totalTime + record.time
		totalMemory = totalMemory + record.memory
	end

	TestState.averageTimeUsage = totalTime / #TestState.benchmarkRecords
	TestState.averageMemoryUsage = totalMemory / #TestState.benchmarkRecords
end

-- Normalize vector
local function Normalize(vec)
	return vec / vec:Length()
end

-- Arrow line drawing function
local function ArrowLine(start_pos, end_pos, arrowhead_length, arrowhead_width, invert)
	if not (start_pos and end_pos) then
		return
	end

	if invert then
		start_pos, end_pos = end_pos, start_pos
	end

	local direction = end_pos - start_pos
	local min_acceptable_length = arrowhead_length + (arrowhead_width / 2)
	if direction:Length() < min_acceptable_length then
		local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
		if not (w2s_start and w2s_end) then
			return
		end
		draw.Line(w2s_start[1], w2s_start[2], w2s_end[1], w2s_end[2])
		return
	end

	local normalized_direction = Normalize(direction)
	local arrow_base = end_pos - normalized_direction * arrowhead_length
	local perpendicular = Vector3(-normalized_direction.y, normalized_direction.x, 0) * (arrowhead_width / 2)

	local w2s_start, w2s_end = client.WorldToScreen(start_pos), client.WorldToScreen(end_pos)
	local w2s_arrow_base = client.WorldToScreen(arrow_base)
	local w2s_perp1 = client.WorldToScreen(arrow_base + perpendicular)
	local w2s_perp2 = client.WorldToScreen(arrow_base - perpendicular)

	if not (w2s_start and w2s_end and w2s_arrow_base and w2s_perp1 and w2s_perp2) then
		return
	end

	draw.Line(w2s_start[1], w2s_start[2], w2s_arrow_base[1], w2s_arrow_base[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp1[1], w2s_perp2[2])
	draw.Line(w2s_end[1], w2s_end[2], w2s_perp2[1], w2s_perp2[2])
	draw.Line(w2s_perp1[1], w2s_perp1[2], w2s_perp2[1], w2s_perp2[2])
end

-- Draw 3D box at position
local function Draw3DBox(size, pos)
	local halfSize = size / 2
	local corners = {
		Vector3(-halfSize, -halfSize, -halfSize),
		Vector3(halfSize, -halfSize, -halfSize),
		Vector3(halfSize, halfSize, -halfSize),
		Vector3(-halfSize, halfSize, -halfSize),
		Vector3(-halfSize, -halfSize, halfSize),
		Vector3(halfSize, -halfSize, halfSize),
		Vector3(halfSize, halfSize, halfSize),
		Vector3(-halfSize, halfSize, halfSize),
	}

	local linesToDraw = {
		{ 1, 2 },
		{ 2, 3 },
		{ 3, 4 },
		{ 4, 1 },
		{ 5, 6 },
		{ 6, 7 },
		{ 7, 8 },
		{ 8, 5 },
		{ 1, 5 },
		{ 2, 6 },
		{ 3, 7 },
		{ 4, 8 },
	}

	local screenPositions = {}
	for _, cornerPos in ipairs(corners) do
		local worldPos = pos + cornerPos
		local screenPos = client.WorldToScreen(worldPos)
		if screenPos then
			table.insert(screenPositions, { x = screenPos[1], y = screenPos[2] })
		end
	end

	for _, line in ipairs(linesToDraw) do
		local p1, p2 = screenPositions[line[1]], screenPositions[line[2]]
		if p1 and p2 then
			draw.Line(p1.x, p1.y, p2.x, p2.y)
		end
	end
end

-- CreateMove callback
local function OnCreateMove(Cmd)
	-- Check menu state first
	if not G.Menu.Visuals.IsNavigableTest then
		return
	end

	-- Set enabled and initialize startPos if needed
	if not TestState.enabled then
		TestState.enabled = true
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() and not TestState.startPos then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal or not pLocal:IsAlive() then
		return
	end

	TestState.currentPos = pLocal:GetAbsOrigin()

	-- Shift to reset position
	if input.IsButtonDown(KEY_LSHIFT) then
		TestState.startPos = TestState.currentPos
		return
	end

	-- Don't interfere with movement
	if Cmd:GetForwardMove() ~= 0 or Cmd:GetSideMove() ~= 0 then
		return
	end

	-- Only run test when F key is held
	if not input.IsButtonDown(KEY_F) then
		return
	end

	-- Only run test if we have both positions and they're far enough apart
	if TestState.startPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		-- Get current node for start position
		local startNode = Node.GetAreaAtPosition(TestState.currentPos)

		if startNode then
			local startTime, startMemory = BenchmarkStart()
			TestState.isNavigable = Navigable.CanSkip(TestState.currentPos, TestState.startPos, startNode)
			BenchmarkStop(startTime, startMemory)
		else
			TestState.isNavigable = false
		end
	end
end

-- Draw callback
local function OnDraw()
	-- Check menu state first
	if not G.Menu.Visuals.IsNavigableTest then
		return
	end

	if engine.Con_IsVisible() or engine.IsGameUIVisible() then
		return
	end

	draw.SetFont(Fonts.Verdana)
	draw.Color(255, 255, 255, 255)

	-- Draw target position box
	if TestState.startPos then
		Draw3DBox(10, TestState.startPos)
	end

	-- Draw navigability test and arrow
	if TestState.startPos and TestState.currentPos and (TestState.currentPos - TestState.startPos):Length() > 10 then
		if TestState.isNavigable then
			draw.Color(0, 255, 0, 255)
		else
			draw.Color(255, 0, 0, 255)
		end
		ArrowLine(TestState.currentPos, TestState.startPos, 10, 20, false)
	end

	-- Draw benchmark info
	draw.Color(255, 255, 255, 255)
	draw.Text(20, 120, string.format("IsNavigable Test: %s", G.Menu.Visuals.IsNavigableTest and "ON" or "OFF"))
	draw.Text(20, 150, string.format("Memory usage: %.2f KB", TestState.averageMemoryUsage))
	draw.Text(20, 180, string.format("Time usage: %.2f ms", TestState.averageTimeUsage * 1000))
	draw.Text(20, 210, string.format("Result: %s", TestState.isNavigable and "NAVIGABLE" or "NOT NAVIGABLE"))
	draw.Text(20, 240, "Press SHIFT to set start | Hold F to test")

	-- Draw debug traces from Navigable module
	Navigable.DrawDebugTraces()
end

-- Toggle function
local function ToggleTest()
	TestState.enabled = not TestState.enabled
	if TestState.enabled then
		local pLocal = entities.GetLocalPlayer()
		if pLocal and pLocal:IsAlive() then
			TestState.startPos = pLocal:GetAbsOrigin()
		end
		print("IsNavigable Test Suite: ENABLED")
		client.Command('play "ui/buttonclick"', true)
	else
		print("IsNavigable Test Suite: DISABLED")
		client.Command('play "ui/buttonclick_release"', true)
	end
end

-- Public API
local IsNavigableTest = {
	Toggle = ToggleTest,
	IsEnabled = function()
		return TestState.enabled
	end,
	GetState = function()
		return TestState
	end,
}

-- Auto-register callbacks
callbacks.Register("CreateMove", "IsNavigableTest_CreateMove", OnCreateMove)
callbacks.Register("Draw", "IsNavigableTest_Draw", OnDraw)

-- Add to global for easy access
G.IsNavigableTest = IsNavigableTest

print("IsNavigable Test Suite loaded. Use G.IsNavigableTest.Toggle() to enable/disable.")

return IsNavigableTest
