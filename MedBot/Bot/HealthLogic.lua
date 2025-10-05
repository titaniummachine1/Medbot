--##########################################################################
--  HealthLogic.lua  ·  Bot health management
--##########################################################################

local Common = require("MedBot.Core.Common")
local G = require("MedBot.Core.Globals")

local HealthLogic = {}

function HealthLogic.ShouldHeal(pLocal)
	if not pLocal then
		return false
	end

	local healthPercent = (pLocal:GetHealth() / pLocal:GetMaxHealth()) * 100
	local isHealing = pLocal:InCond(TFCond_Healing)
	local threshold = G.Menu.Main.SelfHealTreshold

	return healthPercent < threshold and not isHealing
end

function HealthLogic.HandleSelfHealing(pLocal)
	if not HealthLogic.ShouldHeal(pLocal) then
		return
	end

	-- Find health pack or healing source
	local players = entities.FindByClass("CTFPlayer")
	for _, player in pairs(players) do
		if
			player:GetTeamNumber() == pLocal:GetTeamNumber()
			and player:GetPropInt("m_iClass") == TF_CLASS_MEDIC
			and player ~= pLocal
		then
			G.Targets.Heal = player:GetIndex()
			return
		end
	end
end

return HealthLogic
