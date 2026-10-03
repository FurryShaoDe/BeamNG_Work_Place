-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Ghost Racer Enhanced module by flintt, 2026.

-- Register Ghost Racer for the extension manager's post-mod loading pass.
-- Do not directly load the extension here: modScript runs during mounting, and
-- setExtensionUnloadMode is the supported registration path for this phase.

if type(setExtensionUnloadMode) == "function" then
  setExtensionUnloadMode("ghostlapping", "manual")
end
