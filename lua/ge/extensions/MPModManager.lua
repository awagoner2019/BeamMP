-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPModManager API.
--- Author of this documentation is Titch
--- @module MPModManager


local M = {}

local serverMods = {} -- multiplayerModName1, multiplayerModName2
local serverModDisplayNames = {}
local whitelist = {"multiplayerbeammp", "beammp", "translations"} -- these mods won't be activated or deactivated
local hasMods = false
local deactivateMod = core_modmanager.deactivateMod

--TODO: build handler for repo mod downloads

function queueExtensionToLoad(extension)  -- temporary workaround for mods still using that function
	guihooks.trigger("toastrMsg", {type="error", title="queueExtensionToLoad", msg="This function is deprecated, please use setExtensionUnloadMode() instead."})
	log('E','queueExtensionToLoad', 'This function is deprecated, please use setExtensionUnloadMode() instead.')
	setExtensionUnloadMode(extension, 'manual')
end

--- Check if a mod is allowed according to the servers mods
-- @param modName string The mod in question to check
-- @return boolean
-- @usage MPModManager.isModAllowed('...')
local function isModAllowed(modName)
	for _,v in pairs(serverMods) do -- checking for server mods
		if string.lower(v) == string.lower(modName) then --[[ log('M', 'isModAllowed', modName .. ' is allowed.') ]] return true end
	end
	--log('W', 'isModAllowed', modName .. ' is not allowed.')
	return false
end

--- Check if a mod is whitelisted according to BeamMP core set E.g. itself, BeamMP.
-- @param modName string The mod in question to check
-- @return boolean
-- @usage MPModManager.isModWhitelisted('...')
local function isModWhitelisted(modName)
	for _,v in pairs(whitelist) do
		if string.lower(v) == string.lower(modName) then --[[log('M', 'isModWhitelisted', modName .. ' is whitelisted.')]] return true end
	end
	return false
end

--- Check if a mod is allowed (Calls isModAllowed and isModWhitelist)
-- If it is now allowed we disable it, if it is in the multiplayer folder we also delete it as this is maintained by BeamMP
-- @param mod table The mod in question to check
-- @usage MPModManager.isModAllowed('...')
local function checkMod(mod) --TODO: might have a flaw with repo mods as their name is the repo ID and not the zip name
	--log('M', 'checkMod', 'Checking mod.modname: '..mod.modname)
	local modname = mod.modname
	local modAllowed = isModAllowed(modname)
	local modWhitelisted = isModWhitelisted(modname)

	if modWhitelisted then return end -- don't do anything with whitelisted mods

	if not modAllowed and mod.active then
		log('W', 'checkMod', "This mod should not be running: "..modname)
		deactivateMod(modname)
		if mod.dirname == '/mods/multiplayer/' then
			core_modmanager.deleteMod(modname)
		end
	elseif modAllowed and not mod.active then
		log('W', 'checkMod', 'Inactive Mod but Should be Active: '..modname)
		core_modmanager.activateMod(modname)--'/mods/'..string.lower(v)..'.zip')
	elseif modAllowed and mod.active then
		log('M', 'checkMod', modname..' is already active. Not doing anything.')
	else
		--log('M', 'checkMod', modname..' is none of the above.')
	end
end

--- BeamNG function from extensions/core/modmanager.lua
-- @param path string The raw mod file path
-- @return string modname The cleaned modname from the mod file path
local function getModNameFromPath(path) 
	local modname = string.lower(path)
	modname = modname:gsub('/mods/', '')
	modname = modname:gsub('repo/', '')
	modname = modname:gsub('unpacked/', '')
	modname = modname:gsub('/', '')
	modname = modname:gsub('.zip$', '')
	return modname
end

--- The mods json object which the game manages.
-- @return table mods The mods according to the game managed db
local function getModList()
	local modsDB = jsonReadFile("mods/db.json")
	return modsDB.mods
end

local waitForFilesChanged = false

-- Batch loading: while the launcher syncs the server mods, the game's auto-mount is held off so
-- each zip isn't mounted (and every file-change listener fired) one at a time. Once the sync is
-- done the mod manager's initDB mounts all of them in one pass, like it does on game startup.
local batchLoading = false -- auto-mount is held off by us
local batchMountPending = false -- waiting for initDB to finish
local batchMountTimer = 0
local batchMountTimeout = 60 -- seconds before falling back to one-by-one loading
local loadGeneration = 0 -- bumped on every join/leave so stale jobs don't act on a newer session

local function canBatchLoad()
	if core_modmanager == nil or core_modmanager.disableAutoMount == nil or core_modmanager.enableAutoMount == nil or core_modmanager.getModDB == nil then
		return false
	end
	-- initDB returns early without mounting anything while mods are disabled after a game update
	if settings.getValue('disableModsAfterUpdate') then
		return false
	end
	return true
end

local function isLoadCurrent(generation)
	return generation == loadGeneration and (MPCoreNetwork.isMPSession() or MPCoreNetwork.isGoingMPSession())
end

-- Server mods that arrived while auto-mount was held aren't in the mod DB yet, so
-- cleanUpSessionMods can't see them. Remove them before auto-mount would mount them.
local function removeHeldSessionMods()
	local count = 0
	for _, path in ipairs(FS:findFiles("/mods/multiplayer", "*.zip", -1, false, false)) do
		local modname = getModNameFromPath(path)
		if modname ~= "multiplayerbeammp" and not core_modmanager.getModDB(modname) then
			if FS:remove(path) == 0 then
				count = count + 1
			else
				log('E', 'removeHeldSessionMods', 'Unable to delete ' .. path)
			end
		end
	end
	log('M', 'removeHeldSessionMods', count .. ' unloaded session mods removed')
end

local releaseDelay = 2 -- seconds to let a mod the launcher is still placing land before cleaning up
local releaseTimer = nil

local function releaseAutoMount()
	releaseTimer = nil
	if batchLoading then
		batchLoading = false
		removeHeldSessionMods()
		log('M', 'releaseAutoMount', 'Restoring mod auto-mount')
		core_modmanager.enableAutoMount()
	end
end

--- Release auto-mount shortly after a leave, once the launcher has stopped placing files
local function scheduleReleaseAutoMount()
	if batchLoading and not releaseTimer then
		releaseTimer = 0
	end
end

--- Check the game mod list against BeamMP's expected
local function checkAllMods() --add counters?
	log('M', 'checkAllMods', 'Checking all mods...')
	for modname, mod in pairs(getModList()) do
		checkMod(mod)
	end
end

--- Load the Servers mods one at a time (original behaviour, used as fallback)
local function loadServerModsOneByOne()
	local modsDir = FS:findFiles("/mods/multiplayer", "*.zip", -1, false, false)
	local generation = loadGeneration

    core_jobsystem.create(function(job)
		local amount = #modsDir
        local batchSize = 5
		local core_modmanager_workOffChangedMod = core_modmanager.workOffChangedMod
        for i = 1, amount, batchSize do
            if not isLoadCurrent(generation) then return end
            for j = i, math.min(i + batchSize - 1, amount) do
                core_modmanager_workOffChangedMod(modsDir[j], 'added')
            end
            job.sleep(0)
        end
        if not isLoadCurrent(generation) then return end
        checkAllMods()
        MPCoreNetwork.requestMap()
    end)
end

--- Load the Servers mods, these are put in by the BeamMP Launcher
local function loadServerMods()
	log('W', 'loadServerMods', 'loadServerMods')
	if batchLoading then
		batchLoading = false
		batchMountPending = true
		batchMountTimer = 0
		log('M', 'loadServerMods', 'Mounting all server mods in one batch')
		core_modmanager.enableAutoMount() -- runs initDB, which mounts every new mod in one pass
		return
	end
	loadServerModsOneByOne()
end

--- Returns the mod DB entries of all server mods, or nil if any of them isn't mounted and active
local function getMountedServerMods()
	local result = {}
	for _, modname in ipairs(serverMods) do
		local mod = core_modmanager.getModDB(modname)
		if not mod or not mod.active or not mod.fullpath or not FS:isMounted(mod.fullpath) then
			log('W', 'getMountedServerMods', 'Server mod not mounted after batch: ' .. tostring(modname))
			return nil
		end
		table.insert(result, mod)
	end
	return result
end

--- A BeamNG event that is called when the mod manager finished (re)mounting all mods
local function onModManagerModsMounted()
	if not batchMountPending then return end
	batchMountPending = false
	local mounted = getMountedServerMods()
	if not mounted then
		log('W', 'onModManagerModsMounted', 'Batch mount incomplete, loading server mods one by one')
		loadServerModsOneByOne()
		return
	end
	log('M', 'onModManagerModsMounted', 'Batch mount done')
	-- initDB doesn't fire this per mod like activateMod does, so listeners still get it
	for _, mod in ipairs(mounted) do
		extensions.hook('onModActivated', deepcopy(mod))
	end
	checkAllMods()
	MPCoreNetwork.requestMap()
end

--- Verify that the servers mods have been loaded by the game.
-- Currently not properly functioning / missing functionality
local function verifyMods() --TODO: improve and actually implement this
	local verifyTable = {}
	for _,v in pairs(serverMods) do
		verifyTable[v] = false
	end
	for _,v in pairs(getModList()) do
		for _,n in pairs(serverMods) do
			if v.modname == n then verifyTable[n] = true end
		end
	end
end

--- Cleanup the mods from the ended session ready for another.
local function cleanUpSessionMods()
	log('M', "cleanUpSessionMods", "Deleting all multiplayer mods")
	local count = 0
	for modname, mod in pairs(getModList()) do
		if mod.dirname == "/mods/multiplayer/" and modname ~= "multiplayerbeammp" then
			hasMods = true
			count = count + 1
			core_modmanager.deleteMod(modname)
		end
	end
	log('M', "cleanUpSessionMods", count.." Mods cleaned up")
	log('M', "cleanUpSessionMods", "Unloading extensions...")
	--dump(getModList())
	-- TODO: Need to find an alternative for this...
	--unloadGameModules()
end

--- Set the servers mods as a string in Lua for loading and checking
-- Called from MPCoreNetwork
-- @param modsString string The mod string from the server
-- @usage MPModManager.setServerMods('...')
local function setServerMods(modsString) 
	if modsString == "" then
		log('M', 'setServerMods', 'Received no mods.')
		serverMods = {}
		serverModDisplayNames = {}
		guihooks.trigger("onBeamMPServerModsChanged", serverModDisplayNames)
		return
	end
	log('W', 'setMods', modsString)
	local mods = {}
	if (modsString) then -- takes: mod1.zip;mod2.zip;mod3.zip, returns a table of mod1,mod2,mod3
		for mod in string.gmatch(modsString, "([^;]+)") do
			local modFileName = mod:gsub("%.zip;*$","")
			table.insert(mods, modFileName)
		end
	end
	log('M', 'setServerMods', 'Server Mods set to: ' .. dumps(mods))
	serverModDisplayNames = {}
	for key, modName in ipairs(mods) do -- mods in a directory deeper than /mods/ have "<directory name> + modname" as their mod name
		serverModDisplayNames[key] = modName
		mods[key] = string.lower('multiplayer'..modName)
	end
	serverMods = mods
	guihooks.trigger("onBeamMPServerModsChanged", serverModDisplayNames)
	loadGeneration = loadGeneration + 1
	if releaseTimer then
		releaseTimer = nil -- joining again before the delayed release: keep holding auto-mount
		log('M', 'setServerMods', 'Keeping mod auto-mount held for the new session')
	end
	if canBatchLoad() and not batchLoading and not batchMountPending then
		batchLoading = true
		core_modmanager.disableAutoMount()
		log('M', 'setServerMods', 'Holding mod auto-mount until all server mods are synced')
	end
end

local function getServerMods()
	local result = {}
	for index, modName in ipairs(serverModDisplayNames) do
		result[index] = modName
	end
	return result
end

--- A BeamNG event that is called when a mod is loaded by the games mod manager
-- @param mod table The loaded mod information
local function onModActivated(mod)
	log('M', 'onModActivated', mod.modname)
	if MPCoreNetwork.isMPSession() then
		checkMod(mod)
	end
end


local original_registerCoreModule

--- This prevents mods from registering extensions as core modules, which don't get unloaded without a lua reload
local function extensionLoader()
	original_registerCoreModule = registerCoreModule
	registerCoreModule = function(modulePath)
		--log('M', 'extensionLoader', modulePath)
		local debug = debug.getinfo(2)
		--dump(debug)
		debug = string.lower(debug.source)
		if string.match(debug, "beammp") then
			--log('W', 'extensionLoader', "Source is BeamMP! ".. debug)
		original_registerCoreModule(modulePath)
		elseif string.match(debug, "modscript") then
			log('W', 'extensionLoader', "Modscript attempting to register a core module! Falling back to setExtensionUnloadMode(arg, \"auto\") " .. debug)
			extensionName = extensions.luaPathToExtName(modulePath)
			setExtensionUnloadMode(extensionName, "auto")
		else
			log('W', 'extensionLoader', "Source is not BeamMP or a modscript, running original function! " .. debug)
			original_registerCoreModule(modulePath)
		end
	end
end

local original_Unsubscribe

M.repositoryReplacer = function() --TODO: if this function is called onExtensionLoaded core_repository is not loaded yet at that time
	if not core_repository and not core_repository.modUnsubscribe then log('W', 'repositoryReplacer', 'core_repository not loaded yet') return end
	original_Unsubscribe = core_repository.modUnsubscribe
	core_repository.modUnsubscribe = function(mod_id)
		if MPCoreNetwork and MPCoreNetwork.isMPSession() then
			log('W', 'replaceStuff', 'mod_id: ' .. mod_id)
			for k,modName in pairs(serverMods) do
				if modName == mod_id then
					log('W', 'repositoryReplacer', 'You cannot remove session mods! Quit the multiplayer session to remove mods.')
					return
				else
					original_Unsubscribe(mod_id)
				end
			end
		else
			original_Unsubscribe(mod_id)
		end
	end
end

--- Triggered by BeamNG when the lua mod is loaded by the modmanager system.
-- We use this to apply BeamMP defaults, cleanup the mods ahead of mp use and ensure our modloader is used
local function onExtensionLoaded()
	if VersionCheck then
		VersionCheck.onInit = function()
			local modLocation = FS:findOverrides("lua/ge/extensions/VersionCheck.lua")[1]
			local message = "."
			if modLocation ~= nil then
				message = ", the mod is located at: " .. modLocation
			end
			core_jobsystem.create(function(job)
				job.sleep(8)
				guihooks.trigger("toastrMsg", {type="error", title="BeamMP has detected an incompatible mod", msg="Possibly broken lua code has been found and disabled" .. message, config={closeButton=true, timeOut=0, extendedTimeOut=0}}) 
			end)
			print("Possibly malicous lua code has been found and disabled" .. message)
		end
	end

	log('I', 'onExtensionLoaded','Amount of files in content/vehicles/: ' .. tostring(#FS:directoryList("/content/vehicles/")))
	log('I', 'onExtensionLoaded','Amount of files in content/levels/: ' .. tostring(#FS:directoryList("/content/levels/")))
	log('I', 'onExtensionLoaded','Amount of files in content/: ' .. tostring(#FS:directoryList("/content/")))
	extensions.printExtensions()

	cleanUpSessionMods()
	--extensionLoader()
	--M.replaceStuff()
end

--- Triggered by BeamNG when the lua mod is unloaded by the modmanager system.
-- We use this to restore core module defintions
local function onExtensionUnloaded() -- restore functions back to their default values
	--registerCoreModule = original_registerCoreModule and original_registerCoreModule
	if core_repository then core_repository.modUnsubscribe = original_Unsubscribe and original_Unsubscribe end
	releaseAutoMount() -- don't leave the game's mod auto-mount off if we're unloaded mid-sync
end

--- This is used to ensure the cleanup of the mods from the mod manager is done at the end of the session.
local function onServerLeave()
	if MPCoreNetwork.isMPSession() or MPCoreNetwork.isGoingMPSession() then
		log('W', 'onServerLeave', 'MPModManager')
		serverMods = {}
		serverModDisplayNames = {}
		guihooks.trigger("onBeamMPServerModsChanged", serverModDisplayNames)
		cleanUpSessionMods() -- removes any leftover session mods
	end
	loadGeneration = loadGeneration + 1
	batchMountPending = false
	scheduleReleaseAutoMount()
end

local requestLuaReload = false

--- Reload lua but with a 0.5 second delay to allow other states to refresh
local function reloadLuaReloadWithDelay()
	if hasMods then -- don't reload if server doesn't contain mods
		requestLuaReload = true
	end
end
local reloadTimer = 0

--- onUpdate is a game eventloop function. It is called each frame by the game engine.
-- @param dt float
local function onUpdate(dt)
	if batchLoading and not releaseTimer and not MPCoreNetwork.isMPSession() and not MPCoreNetwork.isGoingMPSession() then
		log('W', 'onUpdate', 'Session ended during mod sync, restoring mod auto-mount')
		scheduleReleaseAutoMount()
	end
	if releaseTimer then
		releaseTimer = releaseTimer + dt
		if releaseTimer >= releaseDelay then
			releaseAutoMount()
		end
	end
	if batchMountPending then
		batchMountTimer = batchMountTimer + dt
		if batchMountTimer >= batchMountTimeout then
			batchMountPending = false
			log('W', 'onUpdate', 'Batch mount did not finish, loading server mods one by one')
			loadServerModsOneByOne()
		end
	end
	if requestLuaReload then
		reloadTimer = reloadTimer + dt
		if reloadTimer >= 0.5 then Lua:requestReload() end
	end
end

M.reloadLuaReloadWithDelay = reloadLuaReloadWithDelay
M.cleanUpSessionMods = cleanUpSessionMods
M.isModWhitelisted = isModWhitelisted
M.loadServerMods = loadServerMods
M.setServerMods = setServerMods
M.getServerMods = getServerMods
M.checkAllMods = checkAllMods
M.isModAllowed = isModAllowed
M.getModList = getModList
M.verifyMods = verifyMods
--events
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onModActivated = onModActivated
M.onModManagerModsMounted = onModManagerModsMounted
M.onBeamMPServerLeave = onServerLeave
M.onExit = cleanUpSessionMods
M.onUpdate = onUpdate
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
