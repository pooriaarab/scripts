-- ============================================================
-- Brightness sync: built-in display -> external DDC monitors (Dell U2723QE)
--
-- The brightness keys only change the built-in panel. This module polls the
-- built-in level and pushes it to every external monitor over DDC/CI with
-- m1ddc (brew install m1ddc). Polling (not a key tap) also catches the
-- Control Center slider and auto-brightness.
--
-- Mapping is 1:1 (built-in 0-100 -> monitor luminance 0-100). Adjust
-- toMonitor() if the Dells look brighter or dimmer than the laptop.
-- ============================================================

local M = {}

local M1DDC = "/opt/homebrew/bin/m1ddc"
local POLL_SECONDS = 0.25
local MATCH = "DELL"          -- only drive displays whose name contains this

local displays = {}           -- m1ddc display indexes, e.g. {2, 3}
local lastSent = nil
local busy, pending = false, false

local function toMonitor(level)
  return math.max(0, math.min(100, math.floor(level + 0.5)))
end

local function refreshDisplays()
  local out = hs.execute(M1DDC .. " display list") or ""
  displays = {}
  for idx, name in out:gmatch("%[(%d+)%]%s+([^\n]-)%s+%(") do
    if name:find(MATCH, 1, true) then table.insert(displays, tonumber(idx)) end
  end
  lastSent = nil              -- force a push to newly attached monitors
end

-- Write one value to all monitors in sequence, without blocking Hammerspoon.
local function push(value)
  if busy then pending = true; return end
  busy = true
  local i = 0
  local function nextDisplay()
    i = i + 1
    if i > #displays then
      busy = false
      if pending then pending = false; M.tick() end
      return
    end
    M.task = hs.task.new(M1DDC, nextDisplay,
      {"display", tostring(displays[i]), "set", "luminance", tostring(value)})
    M.task:start()
  end
  nextDisplay()
end

function M.tick()
  if #displays == 0 then return end
  local level = hs.brightness.get()
  if not level then return end
  local value = toMonitor(level)
  if value ~= lastSent then
    lastSent = value
    push(value)
  end
end

function M.start()
  refreshDisplays()
  M.timer = hs.timer.doEvery(POLL_SECONDS, M.tick)
  -- Re-scan when monitors connect/disconnect or wake from sleep.
  M.screenWatcher = hs.screen.watcher.new(function()
    hs.timer.doAfter(2, refreshDisplays)
  end):start()
  M.wakeWatcher = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake
      or ev == hs.caffeinate.watcher.screensDidWake then
      hs.timer.doAfter(3, refreshDisplays)
    end
  end):start()
  M.tick()
  return M
end

function M.status()
  return string.format("displays=%s lastSent=%s builtin=%s",
    table.concat(displays, ","), tostring(lastSent), tostring(hs.brightness.get()))
end

return M
