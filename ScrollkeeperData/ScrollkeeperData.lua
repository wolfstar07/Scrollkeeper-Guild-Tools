-- ScrollkeeperData
-- Centralized event cache using LibHistoire

-- Local references
local Scrollkeeper = Scrollkeeper
local SF = Scrollkeeper.Framework

if type(SF) ~= "table" then
  d(SF.func._L("ScrollkeeperData", "ERROR_FRAMEWORK_MISSING"))
  return
end

-- Initialize module
Scrollkeeper.Data = Scrollkeeper.Data or { Name = "ScrollkeeperData" }
local _addon = Scrollkeeper.Data

-- Ensure Data table exists on framework - FORCE it to exist
SF.Data = Scrollkeeper.Data
local D = Scrollkeeper.Data

-- Immediately verify the table exists
if type(SF.Data) ~= "table" then
  d(SF.func._L("ScrollkeeperData", "ERROR_DATA_NOT_TABLE"))
  return
end

-- Event cache: [guildName][category][eventId] = eventData
local eventCache = {}
local processors = {}
local histoireReady = false
local loaded = {}  -- [guildName .. "_" .. categoryKey] = true once caught up
local cacheGeneration = 0  -- bumped whenever eventCache changes; invalidates the sorted/deposit caches
local sortedCache = {}     -- [guildName .. "|" .. category] = { gen = n, events = {...} }
local depositIndex = {}    -- [guildName] = { gen = n, byName = { [name] = { event, ... } } }

-- Expose eventCache so other modules can access it
D.eventCache = eventCache

-- Settings defaults
local defaults = {
  manualDonations = {},
}

-- Get settings using unified system (ACCOUNT-WIDE for manual donations)
local function getSettings()
  if type(SF) ~= "table" or type(SF.getModuleSettings) ~= "function" then
    local safe = {}
    for k, v in pairs(defaults) do safe[k] = v end
    return safe
  end

  -- Use module name WITHOUT account suffix for account-wide storage
  local accountKey = _addon.Name  -- NOT _addon.Name .. "_" .. accountName

  local ok, settings = pcall(SF.getModuleSettings, accountKey, defaults)
  if not ok or type(settings) ~= "table" then
    local safe = {}
    for k, v in pairs(defaults) do safe[k] = v end
    return safe
  end

  settings.manualDonations = settings.manualDonations or {}
  return settings
end

-- Also expose through D for consistency
local function getManualDonations()
  local settings = getSettings()
  return settings.manualDonations or {}
end

-- Category constants
local CATEGORIES = {
  [GUILD_HISTORY_EVENT_CATEGORY_ROSTER]         = "roster",
  [GUILD_HISTORY_EVENT_CATEGORY_BANKED_CURRENCY] = "bankedGold",
  [GUILD_HISTORY_EVENT_CATEGORY_BANKED_ITEM]     = "bankedItems",
  [GUILD_HISTORY_EVENT_CATEGORY_TRADER]          = "sales",
}

-- Get events for a guild/category (newest first).
-- Sorted arrays are cached per guild/category and rebuilt only when the cache has changed.
-- The returned array is shared with the cache: callers must treat it as read-only.
D.getEvents = function(guildName, category, maxEvents)
  maxEvents = maxEvents or 10000

  if not eventCache[guildName] or not category then return {} end

  local key = guildName .. "|" .. category
  local entry = sortedCache[key]
  if not entry or entry.gen ~= cacheGeneration then
    local events = {}

    if category == "all" then
      for _, catCache in pairs(eventCache[guildName]) do
        for _, event in pairs(catCache) do
          events[#events + 1] = event
        end
      end
    else
      local catCache = eventCache[guildName][category]
      if catCache then
        for _, event in pairs(catCache) do
          events[#events + 1] = event
        end
      end
    end

    table.sort(events, function(a, b) return a.timestamp > b.timestamp end)

    entry = { gen = cacheGeneration, events = events }
    sortedCache[key] = entry
  end

  local events = entry.events
  if #events > maxEvents then
    local limited = {}
    for i = 1, maxEvents do
      limited[i] = events[i]
    end
    return limited
  end

  return events
end

-- Timestamp of the oldest cached event for a guild/category (nil when there are none)
D.getOldestTimestamp = function(guildName, category)
  local events = D.getEvents(guildName, category, math.huge)
  local oldest = events[#events]
  return oldest and oldest.timestamp or nil
end

-- Deposits made by one member (bankedGold), from an index rebuilt only when the cache has changed.
-- Names are matched without a leading "@". The returned array is read-only.
D.getMemberDeposits = function(guildName, displayName)
  if not guildName or not displayName then return {} end

  local entry = depositIndex[guildName]
  if not entry or entry.gen ~= cacheGeneration then
    local byName = {}
    local goldCache = eventCache[guildName] and eventCache[guildName].bankedGold
    if goldCache then
      for _, event in pairs(goldCache) do
        if event.eventType == GUILD_HISTORY_BANKED_CURRENCY_EVENT_DEPOSITED then
          local name = event.info.displayName or event.info.actingDisplayName
          if name then
            if string.sub(name, 1, 1) == "@" then name = string.sub(name, 2) end
            local list = byName[name]
            if not list then
              list = {}
              byName[name] = list
            end
            list[#list + 1] = event
          end
        end
      end
    end
    entry = { gen = cacheGeneration, byName = byName }
    depositIndex[guildName] = entry
  end

  local name = displayName
  if string.sub(name, 1, 1) == "@" then name = string.sub(name, 2) end
  return entry.byName[name] or {}
end

-- Get cache status
D.getCacheStatus = function()
  local status = {}
  for guildName, categories in pairs(eventCache) do
    status[guildName] = {}
    for category, events in pairs(categories) do
      local count = 0
      for _ in pairs(events) do count = count + 1 end
      status[guildName][category] = count
    end
  end
  return status
end

-- Clear cache
D.clear = function()
  ZO_ClearTable(eventCache)
  cacheGeneration = cacheGeneration + 1
  sortedCache = {}
  depositIndex = {}
  for _, processor in pairs(processors) do
    if processor:IsRunning() then
      processor:Stop()
    end
  end
  processors = {}
  loaded = {}
end

-- Check if LibHistoire is ready
D.isReady = function()
  return histoireReady
end

-- True once this guild/category processor has caught up with LibHistoire's cached events
D.isLoaded = function(guildName, categoryKey)
  return loaded[guildName .. "_" .. categoryKey] == true
end

-- True when every started processor for this guild has caught up (false if none started)
D.isGuildLoaded = function(guildName)
  local any = false
  for _, categoryKey in pairs(CATEGORIES) do
    local key = guildName .. "_" .. categoryKey
    if processors[key] then
      any = true
      if not loaded[key] then return false end
    end
  end
  return any
end

-- True while a processor for this guild/category has been started but has not caught up yet
D.isLoading = function(guildName, categoryKey)
  local key = guildName .. "_" .. categoryKey
  return processors[key] ~= nil and not loaded[key]
end

-- Get member donation info (ENHANCED to include manual donations)
D.getMemberDonationInfo = function(guildName, displayName)
  local totalDonated = 0
  local lastDonationTime = nil
  local firstDonationTime = nil
  local hasManualEntries = false
  
  -- Check automated donations from cache
  for _, event in ipairs(D.getMemberDeposits(guildName, displayName)) do
    totalDonated = totalDonated + (event.info.amount or 0)
    if event.info._manualEntry then hasManualEntries = true end
    if not lastDonationTime or event.timestamp > lastDonationTime then lastDonationTime = event.timestamp end
    if not firstDonationTime or event.timestamp < firstDonationTime then firstDonationTime = event.timestamp end
  end
  
  if totalDonated == 0 then
    return nil
  end
  
  return {
    totalDonated = totalDonated,
    lastDonationTime = lastDonationTime,
    firstDonationTime = firstDonationTime,
    hasManualEntries = hasManualEntries
  }
end

-- Get the manual donation entries (logged events) for a member
D.getManualDonations = function(guildName, displayName)
  local result = {}
  local entries = getManualDonations()[guildName]
  if not entries then return result end

  for _, entry in ipairs(entries) do
    if entry.info and entry.info.displayName == displayName then
      result[#result + 1] = entry
    end
  end
  return result
end

-- Clear manual donations for a member (saved variables and runtime cache)
D.clearManualDonations = function(guildName, displayName)
  local entries = getManualDonations()[guildName]
  if not entries then return false end

  local removed = false
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if entry.info and entry.info.displayName == displayName then
      if eventCache[guildName] and eventCache[guildName].bankedGold then
        eventCache[guildName].bankedGold[entry.eventId] = nil
      end
      table.remove(entries, i)
      removed = true
    end
  end

  if removed then cacheGeneration = cacheGeneration + 1 end
  return removed
end

-- Manual donation logging with persistence
function D.logManualDonation(guildName, displayName, amount, donationType, notes)
  if not guildName or not displayName or not amount then 
    return false 
  end
  
  local timestamp = GetTimeStamp()
  local amountNum = tonumber(amount) or 0
  
  if amountNum <= 0 then
    return false
  end
  
  -- Generate a unique event ID
  local eventId = "manual_" .. timestamp .. "_" .. math.random(1000, 9999)
  
  -- Create event matching EXACT LibHistoire structure
  local manualEvent = {
    eventId = eventId,
    eventType = GUILD_HISTORY_BANKED_CURRENCY_EVENT_DEPOSITED,
    timestamp = timestamp,
    category = "bankedGold",
    guildName = guildName,
    info = {
      displayName = displayName,
      actingDisplayName = displayName,
      amount = amountNum,
      currencyType = CURT_MONEY,
      -- Store metadata without affecting the main fields
      _manualEntry = true,
      _notes = tostring(notes or ""),
      _loggedBy = GetDisplayName(),
    }
  }
  
  -- Get settings for persistence
  local settings = getSettings()
  if not settings then
    return false
  end
  
  -- Store in saved variables for persistence
  settings.manualDonations[guildName] = settings.manualDonations[guildName] or {}
  table.insert(settings.manualDonations[guildName], manualEvent)
  
  -- Add to eventCache so it appears immediately
  eventCache[guildName] = eventCache[guildName] or {}
  eventCache[guildName].bankedGold = eventCache[guildName].bankedGold or {}
  
  -- Store using event ID as key (same structure as LibHistoire events)
  eventCache[guildName].bankedGold[eventId] = manualEvent
  cacheGeneration = cacheGeneration + 1
  
  d(string.format(SF.func._L("ScrollkeeperData", "LOG_MANUAL_DONATION"), 
    amountNum, displayName, guildName))
  
  return true
end

-- Add a debug function to check cache contents
function D.debugCache(guildName)
  if not guildName then
    d(SF.func._L("ScrollkeeperData", "DEBUG_NO_GUILD"))
    return
  end
  
  if not eventCache[guildName] then
    d(string.format(SF.func._L("ScrollkeeperData", "DEBUG_NO_CACHE_FOR_GUILD"), guildName))
    d(SF.func._L("ScrollkeeperData", "DEBUG_AVAILABLE_GUILDS"))
    for name, _ in pairs(eventCache) do
      d(string.format(SF.func._L("ScrollkeeperData", "DEBUG_GUILD_LIST_ITEM"), name))
    end
    return
  end
  
  local guild = eventCache[guildName]
  d(string.format(SF.func._L("ScrollkeeperData", "DEBUG_CACHE_FOR_GUILD"), guildName))
  
  if guild.bankedGold then
    local count = 0
    for _ in pairs(guild.bankedGold) do count = count + 1 end
    d(string.format(SF.func._L("ScrollkeeperData", "DEBUG_BANKED_GOLD_COUNT"), count))
    
    -- Show last 5 deposits
    local deposits = {}
    for eventId, event in pairs(guild.bankedGold) do
      if event.eventType == GUILD_HISTORY_BANKED_CURRENCY_EVENT_DEPOSITED then
        local name = event.info.displayName or event.info.actingDisplayName or "unknown"
        local amount = event.info.amount or 0
        local date = os.date("%Y-%m-%d", event.timestamp)
        local isManual = event.info._manualEntry and " (manual)" or ""
        table.insert(deposits, {
          time = event.timestamp,
          text = string.format("%s: %d gold on %s%s", name, amount, date, isManual)
        })
      end
    end
    
    -- Sort by timestamp, newest first
    table.sort(deposits, function(a, b) return a.time > b.time end)
    
    if #deposits > 0 then
      d(SF.func._L("ScrollkeeperData", "DEBUG_RECENT_DEPOSITS"))
      for i = 1, math.min(5, #deposits) do
        d("    " .. deposits[i].text)
      end
    else
      d(SF.func._L("ScrollkeeperData", "DEBUG_NO_DEPOSITS"))
    end
  else
    d(SF.func._L("ScrollkeeperData", "DEBUG_BANKED_GOLD_MISSING"))
  end
  
  if guild.roster then
    local count = 0
    for _ in pairs(guild.roster) do count = count + 1 end
    d(string.format(SF.func._L("ScrollkeeperData", "DEBUG_ROSTER_COUNT"), count))
  else
    d(SF.func._L("ScrollkeeperData", "DEBUG_ROSTER_MISSING"))
  end
end

-- Add a function to check if a specific member has donations
function D.checkMemberGold(guildName, displayName, days)
  if not guildName or not displayName then
    return 0, "Missing parameters"
  end
  
  -- Use getEvents for consistency
  local events = D.getEvents(guildName, "bankedGold", 999999)
  
  if not events or #events == 0 then
    return 0, "No cache available for this guild"
  end
  
  local cutoff = GetTimeStamp() - (days * 86400)
  local total = 0
  local count = 0
  
  for _, event in ipairs(events) do
    if event.eventType == GUILD_HISTORY_BANKED_CURRENCY_EVENT_DEPOSITED and
       event.timestamp >= cutoff then
      local name = event.info.displayName or event.info.actingDisplayName
      if name == displayName then
        total = total + (event.info.amount or 0)
        count = count + 1
      end
    end
  end
  
  return total, string.format("Found %d deposits", count)
end

-- Load manual donations from saved variables on startup
local function loadManualDonations()
  local settings = getSettings()
  if not settings or not settings.manualDonations then
    return
  end
  
  local loadedCount = 0
  for guildName, donations in pairs(settings.manualDonations) do
    eventCache[guildName] = eventCache[guildName] or {}
    eventCache[guildName].bankedGold = eventCache[guildName].bankedGold or {}
    
    for _, donation in ipairs(donations) do
      if donation and donation.eventId and donation.info and donation.info.amount then
        eventCache[guildName].bankedGold[donation.eventId] = donation
        loadedCount = loadedCount + 1
      end
    end
  end
  cacheGeneration = cacheGeneration + 1
end

-- Add to cache status
local originalGetCacheStatus = D.getCacheStatus
D.getCacheStatus = function()
  local status = originalGetCacheStatus()
  
  local manualDonations = getManualDonations()
  -- Add manual donation counts (manualDonations[guildName] is an array of logged events)
  for guildName, entries in pairs(manualDonations) do
    status[guildName] = status[guildName] or {}
    local manualCount = #entries
    if manualCount > 0 then
      status[guildName].manualDonations = manualCount
    end
  end
  
  return status
end

-- Update clear function to include manual donations
local originalClear = D.clear
D.clear = function()
  originalClear()
  local manualDonations = getManualDonations()
  for k in pairs(manualDonations) do
    manualDonations[k] = nil
  end
end

-- Start processor for a specific guild/category
local function startProcessor(guildId, guildName, categoryKey, categoryId)
  if not guildId or not guildName or not categoryKey or not categoryId then
    return false
  end
  
  local processorKey = guildName .. "_" .. categoryKey
  
  if processors[processorKey] and processors[processorKey]:IsRunning() then
    processors[processorKey]:Stop()
  end
  
  local processor = LibHistoire:CreateGuildHistoryProcessor(guildId, categoryId, _addon.Name)
  if not processor then
    return false
  end
  
  eventCache[guildName] = eventCache[guildName] or {}
  eventCache[guildName][categoryKey] = eventCache[guildName][categoryKey] or {}
  
  processor:SetEventCallback(function(event)
    local eventId = event:GetEventId()
    
    local info = {}
    local rawInfo = event:GetEventInfo()
    for k, v in pairs(rawInfo) do
      info[k] = v
    end
    
    eventCache[guildName][categoryKey][eventId] = {
      eventId = eventId,
      eventType = event:GetEventType(),
      timestamp = event:GetEventTimestampS(),
      category = categoryKey,
      guildName = guildName,
      info = info,
    }
	cacheGeneration = cacheGeneration + 1
    
  end)
  
  processor:SetOnStopCallback(function(reason)
    loaded[processorKey] = nil  -- stream ended; cache no longer guaranteed current
  end)
  processor:SetRegisteredForFutureEventsCallback(function()
    loaded[processorKey] = true
  end)
  processor:Start()
  processors[processorKey] = processor
  
  return true
end

-- Start caching ALL categories for ALL guilds
local function startAllProcessors()
  for i = 1, GetNumGuilds() do
    local guildId = GetGuildId(i)
    local guildName = GetGuildName(guildId)
    if guildName then
      for categoryId, categoryKey in pairs(CATEGORIES) do
        local processorKey = guildName .. "_" .. categoryKey
        if not processors[processorKey] or not processors[processorKey]:IsRunning() then
          startProcessor(guildId, guildName, categoryKey, categoryId)
        end
      end
    end
  end
end

-- Restart a processor when LibHistoire (re)establishes a managed range
local rangeCallbackRegistered = false
local function onManagedRangeFound(guildId, category)
  local categoryKey = CATEGORIES[category]
  local guildName = GetGuildName(guildId)
  if not categoryKey or not guildName then return end
  local processorKey = guildName .. "_" .. categoryKey
  if processors[processorKey] and processors[processorKey]:IsRunning() then return end
  startProcessor(guildId, guildName, categoryKey, category)
end

-- Delete a manual entry from the cache
function D.deleteManualEntry(guildName, timestamp, eventInfo)
  if not guildName or not timestamp or not eventInfo then
    d(SF.func._L("ScrollkeeperData", "ERROR_DELETE_MISSING_PARAMS"))
    return false
  end
  
  local deleted = false
  
  -- 1. Remove from runtime cache
  if eventCache[guildName] and eventCache[guildName].bankedGold then
    for eventId, event in pairs(eventCache[guildName].bankedGold) do
      if event.timestamp == timestamp and 
         event.info and event.info._manualEntry and
         event.info.displayName == eventInfo.displayName then
        eventCache[guildName].bankedGold[eventId] = nil
		cacheGeneration = cacheGeneration + 1
        deleted = true
        break
      end
    end
  end
  
  -- 2. Remove from persistent storage
  local settings = getSettings()
  if settings and settings.manualDonations and settings.manualDonations[guildName] then
    for i = #settings.manualDonations[guildName], 1, -1 do
      local entry = settings.manualDonations[guildName][i]
      if entry and entry.timestamp == timestamp and
         entry.info and entry.info.displayName == eventInfo.displayName then
        table.remove(settings.manualDonations[guildName], i)
        deleted = true
      end
    end
  end
  
  if deleted then
    d(SF.func._L("ScrollkeeperData", "SUCCESS_DELETE_ENTRY"))
    return true
  end
  
  d(SF.func._L("ScrollkeeperData", "ERROR_DELETE_NOT_FOUND"))
  return false
end

-- Debug slash commands
SLASH_COMMANDS["/sgtcache"] = function()
  d(SF.func._L("ScrollkeeperData", "CACHE_STATUS"))
  local status = SF.Data.getCacheStatus()
  local hasData = false
  for guild, cats in pairs(status) do
    hasData = true
    d("|cFFD700" .. string.format(SF.func._L("ScrollkeeperData", "GUILD_HEADER"), guild) .. "|r")
    for cat, count in pairs(cats) do
      if cat == "manualDonations" then
        d(string.format(SF.func._L("ScrollkeeperData", "CATEGORY_MANUAL_LINE"), count))
      else
        d(string.format(SF.func._L("ScrollkeeperData", "CATEGORY_LINE"), cat, count))
      end
    end
  end
  if not hasData then
    d("|cFF0000" .. SF.func._L("ScrollkeeperData", "NO_CACHED_DATA") .. "|r")
    d(string.format(SF.func._L("ScrollkeeperData", "HISTOIRE_STATUS"), tostring(histoireReady)))
    if histoireReady then
      d(SF.func._L("ScrollkeeperData", "CACHE_EMPTY"))
    else
      d("[ScrollkeeperData] " .. SF.func._L("ScrollkeeperData", "WAITING_FOR_HISTOIRE"))
    end
  end
end

-- Test specific member donations
SLASH_COMMANDS["/sgtcheckgold"] = function(args)
  if not SF.Data or not SF.Data.checkMemberGold then
    d(SF.func._L("ScrollkeeperData", "ERROR_DATA_MODULE_UNAVAILABLE"))
    return
  end
  
  -- Expected format: guildName|displayName|days
  local parts = {}
  for part in string.gmatch(args, "[^|]+") do
    table.insert(parts, part)
  end
  
  if #parts < 2 then
    d(SF.func._L("ScrollkeeperData", "CMD_CHECKGOLD_USAGE"))
    d(SF.func._L("ScrollkeeperData", "CMD_CHECKGOLD_EXAMPLE"))
    return
  end
  
  local guildName = parts[1]
  local displayName = parts[2]
  local days = tonumber(parts[3]) or 30
  
  local total, msg = SF.Data.checkMemberGold(guildName, displayName, days)
  d(string.format(SF.func._L("ScrollkeeperData", "CMD_CHECKGOLD_RESULT"), displayName, total, days, msg))
end

-- Start initialization
local _dataModuleStarted = false

local function startDataModule()
  if _dataModuleStarted then return end
  
  if not LibHistoire then
    d(SF.func._L("ScrollkeeperData", "ERROR_LIBHISTOIRE_MISSING"))
    return
  end
  
  LibHistoire:OnReady(function()
    histoireReady = true
    
    -- Load manual donations silently
    loadManualDonations()
    
    -- Start processors
    startAllProcessors()
    if not rangeCallbackRegistered then
      rangeCallbackRegistered = true
      LibHistoire:RegisterCallback(LibHistoire.callback.MANAGED_RANGE_FOUND, onManagedRangeFound)
    end
    _dataModuleStarted = true
  end)
end

-- Wait for framework callback
CALLBACK_MANAGER:RegisterCallback("Scrollkeeper_Initialized", function()
  zo_callLater(function()
    startDataModule()
  end, 1000)
end)

-- Fallback initialization
EVENT_MANAGER:RegisterForEvent(_addon.Name, EVENT_PLAYER_ACTIVATED, function(_, initial)
  if not initial then return end
  EVENT_MANAGER:UnregisterForEvent(_addon.Name, EVENT_PLAYER_ACTIVATED)
  
  zo_callLater(function()
    startDataModule()
  end, 2000)
end)
