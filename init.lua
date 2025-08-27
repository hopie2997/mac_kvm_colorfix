-- === Config ===
local TARGET_UUID = "BEFC03C0%-AA74%-4FA4%-9367%-4A3D47EC3001"
local DISPLAY_NAME = "ULTRAFINE"
local MODE_LABEL = "8bit SDR YCbCr 4:2:0 Limited SRGB"
local REAPPLY_DURATION = 2.0
local REAPPLY_INTERVAL = 0.1

-- === Globals ===
local burstTimer = nil
local debounceTimer = nil
local debounceActive = false
local screenWatcher = nil
local caffeinateWatcher = nil
local cachedModeID = nil  -- Cache for the mode ID
local displayCheckCmd = "betterdisplaycli get --identifiers"  -- Pre-build command
local getModeCmd = "betterdisplaycli get -originalNameLike=" .. DISPLAY_NAME .. " --connectionModeList"

-- === Get Connection Mode ID with Caching ===
function getTargetModeID()
  if cachedModeID then
    return cachedModeID
  end
  
  local connectionModes = hs.execute(getModeCmd, true)
  if not connectionModes then return nil end
  
  for line in connectionModes:gmatch("[^\r\n]+") do
    if line:find(MODE_LABEL) then
      cachedModeID = line:match("^%d+")
      return cachedModeID
    end
  end
  return nil
end

-- === Check if Monitor is Connected ===
function isTargetMonitorConnected()
  local displayInfo = hs.execute(displayCheckCmd, true)
  return displayInfo and displayInfo:match(TARGET_UUID)  -- Using match() instead of find()
end

-- === Burst Apply Only ===
function runFastSetBurst(modeID)
  if burstTimer then  -- Cleanup existing timer
    burstTimer:stop()
  end

  local count = 0
  local maxCount = math.floor(REAPPLY_DURATION / REAPPLY_INTERVAL)
  local setCmd = "betterdisplaycli set -originalNameLike=" .. DISPLAY_NAME .. " -connectionMode=" .. modeID

  burstTimer = hs.timer.doEvery(REAPPLY_INTERVAL, function()
    count = count + 1
    hs.execute(setCmd, true)

    if count >= maxCount then
      burstTimer:stop()
      burstTimer = nil
      hs.printf("[KVM] Applied mode %s (%s)", modeID, MODE_LABEL)
    end
  end)
end

-- === Debounced Trigger ===
function runDebouncedBurst()
  if debounceActive then return end
  debounceActive = true

  -- Cleanup existing timers
  if debounceTimer then
    debounceTimer:stop()
  end

  if not isTargetMonitorConnected() then
    hs.printf("[KVM] Monitor not connected, skipping reapply.")
    debounceActive = false
    return
  end

  local modeID = getTargetModeID()
  if not modeID then
    hs.printf("[KVM] Mode not found: %s", MODE_LABEL)
    debounceActive = false
    return
  end

  hs.printf("[KVM] Starting HDMI reapply burst for mode ID %s", modeID)
  runFastSetBurst(modeID)

  debounceTimer = hs.timer.doAfter(REAPPLY_DURATION, function()
    debounceActive = false
  end)
end

-- === Reset Cache on Screen Changes ===
local function resetCache()
  cachedModeID = nil
end

-- === Watchers ===
if screenWatcher then screenWatcher:stop() end
screenWatcher = hs.screen.watcher.new(function()
  resetCache()  -- Reset cache when screen configuration changes
  runDebouncedBurst()
end)
screenWatcher:start()

if caffeinateWatcher then caffeinateWatcher:stop() end
caffeinateWatcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake then
    resetCache()  -- Reset cache after system wake
    runDebouncedBurst()
  elseif event == hs.caffeinate.watcher.screensDidUnlock then
    resetCache()  -- Reset cache after screen unlock
    runDebouncedBurst()
  elseif event == hs.caffeinate.watcher.screensDidLock then
    hs.printf("[KVM] Screen locked")
  end
end)
caffeinateWatcher:start()

-- === Optional: Trigger once on reload
runDebouncedBurst()
