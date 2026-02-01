--##########################################################################
--  NavLoader.lua  ·  Navigation file loading (BACKWARD COMPATIBILITY WRAPPER)
--##########################################################################
--
--  DEPRECATED: Use SetupOrchestrator instead for new code
--  This module now delegates to SetupOrchestrator for backward compatibility
--
--##########################################################################

local Common = require("MedBot.Core.Common")
local SetupOrchestrator = require("MedBot.Navigation.Setup.SetupOrchestrator")

local Log = Common.Log.new("NavLoader")
Log.Level = 0

local NavLoader = {}

-- DEPRECATED: Use SetupOrchestrator.ExecuteFullSetup(navFilePath) instead
-- Kept for backward compatibility with existing code
function NavLoader.LoadFile(navFile)
	Log:Warn("NavLoader.LoadFile is deprecated, use SetupOrchestrator instead")
	local full = "tf/" .. navFile
	return SetupOrchestrator.ExecuteFullSetup(full)
end

-- DEPRECATED: Use SetupOrchestrator.ExecuteFullSetup() instead
-- Kept for backward compatibility with existing code
function NavLoader.LoadNavFile()
	Log:Warn("NavLoader.LoadNavFile is deprecated, use SetupOrchestrator instead")
	return SetupOrchestrator.ExecuteFullSetup()
end

-- DEPRECATED: ProcessNavData is now internal to Phase1_NavLoad
-- This stub returns empty table to prevent crashes in legacy code
function NavLoader.ProcessNavData(navData)
	Log:Error("NavLoader.ProcessNavData is deprecated and no longer functional")
	Log:Error("Use SetupOrchestrator.ExecuteFullSetup() for full setup")
	return {}
end

return NavLoader
