-- menudemo1.lua
local TimMenu = require("TimMenu")

-- Script state
local cbState1 = false
local sliderVal1 = 25
local options1 = { "Option A", "Option B", "Option C" }
local selectedIndex1 = 1
local dropdownIndex1 = 1
local comboState1 = { false, false, false }
-- Keybind demo state
local bindKey1 = 0
-- Color picker demo state
local pickerColor1 = { 255, 0, 0, 255 }

-- TabControl demo state
local tabOptions1 = { "Tab 1", "Tab 2", "Tab 3" }
local selectedTab1 = 1

-- Showcase Tab State
local showcaseTabNames = { "Showcase Alpha", "Showcase Beta", "Showcase Gamma" }
local showcaseSelectedTab = 1
local showcaseCbX = false
local showcaseSliderP = 50
local showcaseKeyK = 0
local showcaseDropdownOptions = { "Opt D-One", "Opt D-Two", "Opt D-Three" }
local showcaseDropdownD = 1
local showcaseComboOptions = { "Item C-X", "Item C-Y", "Item C-Z" }
local showcaseComboC = { false, false, false }
local showcaseSelectorOptions = { "Sel Foo", "Sel Bar", "Sel Baz Qux" }
local showcaseSelectorS = 1
local showcaseTextT = "Edit this showcase text!"
local showcaseButtonClicks = 0

local function OnDraw_Menudemo1()
	if TimMenu.Begin("Demo Window 1") then
		-- NEW Showcase Header TabControl
		showcaseSelectedTab, _ = TimMenu.TabControl("ShowcaseHeaderTabs", showcaseTabNames, showcaseSelectedTab, true)

		if showcaseSelectedTab == 1 then
			TimMenu.Text("Widgets in Showcase Alpha:")
			TimMenu.NextLine()
			showcaseCbX = TimMenu.Checkbox("Alpha Checkbox", showcaseCbX)
			TimMenu.SameLine()
			if TimMenu.Button("Alpha Button") then
				showcaseButtonClicks = showcaseButtonClicks + 1
			end
			TimMenu.NextLine()
			showcaseSliderP, _ = TimMenu.Slider("Alpha Slider", showcaseSliderP, 0, 200, 5)
			TimMenu.Text("Button Clicks: " .. showcaseButtonClicks)
			TimMenu.Separator()
		elseif showcaseSelectedTab == 2 then
			TimMenu.Text("Demonstrating more widgets in Beta:")
			TimMenu.NextLine()
			showcaseKeyK, _ = TimMenu.Keybind("Beta Keybind", showcaseKeyK)
			showcaseDropdownD, _ = TimMenu.Dropdown("Beta Dropdown", showcaseDropdownD, showcaseDropdownOptions)
			showcaseComboC, _ = TimMenu.Combo("Beta Combo", showcaseComboC, showcaseComboOptions)
			TimMenu.Separator()
		elseif showcaseSelectedTab == 3 then
			TimMenu.Text("Input and Selection in Gamma:")
			TimMenu.NextLine()
			showcaseSelectorS, _ = TimMenu.Selector("Gamma Selector", showcaseSelectorS, showcaseSelectorOptions)
			local newTextGamma
			newTextGamma, _ = TimMenu.TextInput("Gamma Text Input", showcaseTextT)
			if newTextGamma ~= showcaseTextT then
				showcaseTextT = newTextGamma
			end
			TimMenu.Button("Gamma Action Button")
			TimMenu.Separator()
		end
		TimMenu.NextLine() -- Ensure content below header tabs starts on a new line.

		-- Color Picker demonstration
		pickerColor1, changedColor1 = TimMenu.ColorPicker("Pick Color", pickerColor1)
		if changedColor1 then
			print("[Menudemo1] Picked color: ", pickerColor1[1], pickerColor1[2], pickerColor1[3])
		end
		TimMenu.NextLine()

		-- First row: Demonstrate multiple widgets and alignment
		TimMenu.BeginSector("Multi-Widget Area")
		TimMenu.Text("Content in A")
		TimMenu.NextLine()
		cbState1 = TimMenu.Checkbox("Checkbox in A", cbState1)
		TimMenu.NextLine()
		TimMenu.Text("More text...")
		TimMenu.EndSector()

		TimMenu.BeginSector("Single Button")
		if TimMenu.Button("Button in B") then
			print("[Menudemo1] Button B clicked!XD")
		end
		TimMenu.EndSector()
		TimMenu.NextLine() -- End of the first row of sectors

		-- Nested Sector Example
		TimMenu.BeginSector("Nesting Container")
		TimMenu.Text("Inside Outer Container")
		TimMenu.NextLine()
		TimMenu.BeginSector("Nested Slider Area")
		sliderVal1, changed1 = TimMenu.Slider("Slider in Nested Area", sliderVal1, 0, 100, 5)
		if changed1 then
			print("[Menudemo1] Slider value -> " .. sliderVal1)
		end
		if TimMenu.Button("Button in B") then
			print("[Menudemo1] Button B clicked!XD")
		end
		if TimMenu.Button("Button in B") then
			print("[Menudemo1] Button B clicked!XD")
		end
		TimMenu.NextLine()
		if TimMenu.Button("Button in B") then
			print("[Menudemo1] Button B clicked!XD")
		end

		TimMenu.EndSector()
		TimMenu.NextLine()
		TimMenu.Text("Also inside Container")
		TimMenu.EndSector()
		TimMenu.NextLine() -- End of Nesting Container block

		-- Separator line (outside sectors)
		TimMenu.Separator()
		TimMenu.NextLine()

		-- Selector example using the dedicated widget (outside sectors)
		selectedIndex1, changed1 = TimMenu.Selector(nil, selectedIndex1, options1)
		if changed1 then
			print("[Menudemo1] Selector changed to index: ", selectedIndex1)
		end

		TimMenu.NextLine()
		-- Dropdown example using the dedicated widget
		dropdownIndex1, changed1 = TimMenu.Dropdown("Dropdown in Demo1", dropdownIndex1, options1)
		if changed1 then
			print("[Menudemo1] Dropdown selected: " .. options1[dropdownIndex1])
		end
		TimMenu.NextLine()

		comboState1, changed1 = TimMenu.Combo("Combo in Demo1", comboState1, options1)
		if changed1 then
			print("[Menudemo1] Combo selections:")
		end
		TimMenu.NextLine()

		TimMenu.Spacing(20) -- Add extra vertical space (custom amount)
		TimMenu.Text("Another line after custom spacing.")

		-- Tab control example
		selectedTab1, changed1 = TimMenu.TabControl("demo1_tabs", tabOptions1, selectedTab1)
		if changed1 then
			print("[Menudemo1] Tab changed to: " .. tabOptions1[selectedTab1])
		end
		-- Keybind widget
		bindKey1, changed1 = TimMenu.Keybind("Demo1 Bind", bindKey1)
		if changed1 then
			print("[Menudemo1] New bind key code: " .. tostring(bindKey1))
		end
		TimMenu.NextLine()

		-- Show full-size palette demo
		TimMenu.NextLine()
		TimMenu.Text("Palette Preview (256x256):")
		TimMenu.NextLine()
		local win = TimMenu.GetCurrentWindow()
		local Image = require("TimMenu.Widgets.Image")
		local Globals = require("TimMenu.Globals")
		Image(win, Globals.Images.ColorPicker.Interactive, 256, 256)
	end
end

-- Correct callback registration for menudemo1
callbacks.Unregister("Draw", "Menudemo1_Draw")
callbacks.Register("Draw", "Menudemo1_Draw", OnDraw_Menudemo1)
