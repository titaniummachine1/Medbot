--[[debug commands
    client.SetConVar("cl_vWeapon_sway_interp",              0)             -- Set cl_vWeapon_sway_interp to 0
    client.SetConVar("cl_jiggle_bone_framerate_cutoff", 0)             -- Set cl_jiggle_bone_framerate_cutoff to 0
    client.SetConVar("cl_bobcycle",                     10000)         -- Set cl_bobcycle to 10000
    client.SetConVar("sv_cheats", 1)                                    -- debug fast setup
    client.SetConVar("mp_disable_respawn_times", 1)
    client.SetConVar("mp_respawnwavetime", -1)
    client.SetConVar("mp_teams_unbalance_limit", 1000)

    -- debug command: ent_fire !picker Addoutput "health 99999" --superbot
]]
local MenuModule = {}

-- Import globals
local G = require("MedBot.Utils.Globals")

-- Try loading TimMenu
---@type boolean, table
local menuLoaded, TimMenu = pcall(require, "TimMenu")
assert(menuLoaded, "TimMenu not found, please install it!")

-- Draw the menu
local function OnDrawMenu()
	-- Only draw when the Lmaobox menu is open
	if not gui.IsMenuOpen() then
		return
	end

	if TimMenu.Begin("MedBot Control") then
		-- Tab control
		G.Menu.Tab, _ = TimMenu.TabControl("MedBotTabs", { "Main", "Visuals" }, G.Menu.Tab)
		TimMenu.NextLine()

		if G.Menu.Tab == "Main" then
			-- Enable bot
			G.Menu.Main.Enable = TimMenu.Checkbox("Enable Bot", G.Menu.Main.Enable)
			TimMenu.NextLine()

			-- Skip nodes optimization
			G.Menu.Main.Skip_Nodes = TimMenu.Checkbox("Skip Nodes", G.Menu.Main.Skip_Nodes)
			TimMenu.NextLine()

			-- Smooth look factor for path following
			G.Menu.Main.smoothFactor, _ = TimMenu.Slider("Smooth Factor", G.Menu.Main.smoothFactor, 0.01, 0.1, 0.01)
			TimMenu.NextLine()

			-- Self-heal threshold
			G.Menu.Main.SelfHealTreshold, _ =
				TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
			TimMenu.NextLine()
		elseif G.Menu.Tab == "Visuals" then
			-- Visuals settings
			G.Menu.Visuals.EnableVisuals = TimMenu.Checkbox("Enable Visuals", G.Menu.Visuals.EnableVisuals)
			TimMenu.NextLine()
			G.Menu.Visuals.drawNodes = TimMenu.Checkbox("Show Nodes", G.Menu.Visuals.drawNodes)
			TimMenu.NextLine()
			G.Menu.Visuals.drawNodeIDs = TimMenu.Checkbox("Show Node IDs", G.Menu.Visuals.drawNodeIDs)
			TimMenu.NextLine()
			G.Menu.Visuals.showConnections = TimMenu.Checkbox("Show Connections", G.Menu.Visuals.showConnections)
			TimMenu.NextLine()
			G.Menu.Visuals.showAreas = TimMenu.Checkbox("Show Areas", G.Menu.Visuals.showAreas)
			TimMenu.NextLine()
			-- Maximum render distance for visuals
			G.Menu.Visuals.renderDistance, _ =
				TimMenu.Slider("Render Distance", G.Menu.Visuals.renderDistance, 100, 3000, 100)
			TimMenu.NextLine()
		end
	end
end

-- Register callbacks
callbacks.Unregister("Draw", "MedBot.DrawMenu")
callbacks.Register("Draw", "MedBot.DrawMenu", OnDrawMenu)

return MenuModule
