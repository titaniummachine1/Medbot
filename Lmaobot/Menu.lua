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
local G = require("Lmaobot.Utils.Globals")

-- Try loading TimMenu
---@type boolean, table
local menuLoaded, TimMenu = pcall(require, "TimMenu")
assert(menuLoaded, "TimMenu not found, please install it!")

-- Toggle state and menu helper
local menuOpen = true
local lastToggleTime = 0
local toggleCooldown = 0.1

function MenuModule.toggleMenu()
	local now = globals.RealTime()
	if now - lastToggleTime >= toggleCooldown then
		menuOpen = not menuOpen
		G.Gui.IsVisible = menuOpen
		lastToggleTime = now
	end
end

-- Draw the menu
local function OnDrawMenu()
	-- Toggle with INSERT key
	if input.IsButtonDown(KEY_INSERT) then
		MenuModule.toggleMenu()
	end

	-- Only draw when menuOpen is true
	if not menuOpen then
		return
	end

	if TimMenu.Begin("MedicBot Control", menuOpen) then
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
		G.Menu.Main.SelfHealTreshold, _ = TimMenu.Slider("Self Heal Threshold", G.Menu.Main.SelfHealTreshold, 0, 100, 1)
		TimMenu.NextLine()

		TimMenu.End()
	end
end

-- Register callbacks
callbacks.Unregister("Draw", "MedicBot.DrawMenu")
callbacks.Register("Draw", "MedicBot.DrawMenu", OnDrawMenu)

return MenuModule
