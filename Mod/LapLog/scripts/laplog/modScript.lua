-- LapLog mod script.
--
-- Register the extension for the extension manager post-mod loading pass. Calling
-- extensions.loadExtension from here is wrong: modScript runs while the mod is
-- still being mounted, and setExtensionUnloadMode is the supported registration
-- path for this phase. Choosing "manual" hands teardown to the extension own
-- onModDeactivated hook, which is what strips the app out of the player saved UI
-- layouts when the mod is disabled.
--
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

if type(setExtensionUnloadMode) == "function" then
  setExtensionUnloadMode("laplog", "manual")
end