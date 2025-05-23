-- menudemo2.lua
local TimMenu = require("TimMenu")

-- Script state
local cbState2 = true
local sliderVal2 = 75
local balanceVal2 = 0
local selectedOption2 = 1
local options2 = { "Option A", "Option B", "Option C", "Option D" }
local tabs = { "Main", "Audio", "Options", "Debug" }
local currentTab = tabs[1]
local dropdownIndex2 = 1
local comboState2 = { false, false, false, false }
-- Keybind demo state
local bindKey2 = 0
-- Color picker demo state
local pickerColor2 = { 0, 255, 0, 255 }

local function OnDraw_Menudemo2()
	if TimMenu.Begin("Demo Window 2 - Advanced") then
		-- Use simplified TabControl (returns selected label)
		local newTabLabel, changedTab = TimMenu.TabControl("DemoTabs", tabs, currentTab)

		if changedTab then
			currentTab = newTabLabel
		end

		if currentTab == "Main" then
			TimMenu.Text("Welcome to the Main Tab")
			TimMenu.NextLine()
			cbState2 = TimMenu.Checkbox("Enable Feature", cbState2)
			TimMenu.NextLine()
			if TimMenu.Button("Run Action") then
				print("[Menudemo2] Action executed")
			end
			-- Color Picker in Main tab
			pickerColor2, changedColor2 = TimMenu.ColorPicker("Main Color", pickerColor2)
			if changedColor2 then
				print("[Menudemo2] New color: ", pickerColor2[1], pickerColor2[2], pickerColor2[3])
			end
			TimMenu.NextLine()

			TimMenu.NextLine()
			-- Keybind widget
			bindKey2, changed2 = TimMenu.Keybind("Demo2 Bind", bindKey2)
			if changed2 then
				print("[Menudemo2] New bind key code: " .. tostring(bindKey2))
			end
		elseif currentTab == "Audio" then
			sliderVal2, changed2 = TimMenu.Slider("Volume", sliderVal2, 0, 100, 5)
			if changed2 then
				print("[Menudemo2] Volume -> " .. sliderVal2)
			end
			TimMenu.NextLine()
			balanceVal2, changed3 = TimMenu.Slider("Balance", balanceVal2, -50, 50, 1)
			if changed3 then
				print("[Menudemo2] Balance -> " .. balanceVal2)
			end
		elseif currentTab == "Options" then
			TimMenu.Text("Select Option:")
			TimMenu.NextLine()

			-- Selector example using the dedicated widget
			selectedOption2, changedOption = TimMenu.Selector(nil, selectedOption2, options2)
			if changedOption then
				print("[Menudemo2] Selector selected: " .. options2[selectedOption2])
			end
			TimMenu.NextLine()

			-- Dropdown example using the dedicated widget
			dropdownIndex2, changedOption = TimMenu.Dropdown("Dropdown in Demo2", dropdownIndex2, options2)
			if changedOption then
				print("[Menudemo2] Dropdown selected: " .. options2[dropdownIndex2])
			end
			TimMenu.NextLine()

			-- Multi-selection Combo example
			comboState2, changedOption = TimMenu.Combo("Combo in Demo2", comboState2, options2)
			if changedOption then
				print("[Menudemo2] Combo selections:")
				for i, sel in ipairs(comboState2) do
					if sel then
						print(" - " .. options2[i])
					end
				end
			end
			TimMenu.NextLine()
		elseif currentTab == "Debug" then
			TimMenu.ShowDebug()
		end
	end
end

-- Register draw callback
callbacks.Unregister("Draw", "Menudemo22_Draw")
callbacks.Register("Draw", "Menudemo22_Draw", OnDraw_Menudemo2)
