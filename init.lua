--- === DarkMode ===
---
--- This spoon allow you to enable, disable, and toggle Dark Mode in macOS, as well as automatically enable/disable DarkMode based on a schedule. The default schedule enables Dark Mode at sunset and disables it at sunrise.

local obj = {}

-- Metadata
obj.name = "DarkMode"
obj.version = "1.0"
obj.author = "Malo Bourgon"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/malob/DarkMode.spoon"

-- Spoon variables (no intended for public use)
obj.schedule = {
  onAt = "sunset",
  offAt = "sunrise"
}
obj.timer = nil


-- Local helper functions

-- Get UTC offset needed to get sunrise and sunset times
local function getUtcOffset()
  local utcOffset = hs.execute("date +%z")
  return utcOffset:sub(1, 3) + utcOffset:sub(4, 5)/60
end

-- Enable/disable darkMode
local function setDarkMode(state)
  hs.preferencesDarkMode(state)
  hs.console.darkMode(state)
  hs.console.consoleCommandColor{ white = (state and 1) or 0}

  hs.osascript.javascript(
    string.format(
      "Application('System Events').appearancePreferences.darkMode.set(%s)",
      state
    )
  )
end

-- Validate and process schedule times
local function processScheduleTime(time)
  if time == "sunrise" or time == "sunset" then
    return time
  else
    local secondsFromMidnight = hs.timer.seconds(time)
    assert(secondsFromMidnight < 86400, "Time given wasn't a time of day")
    return secondsFromMidnight
  end
end

--- DarkMode:setSchedule(onTime, offTime) -> self
--- Method
--- Sets the schedule on which Dark Mode is enabled/disabled.
---
--- Parameters:
---  * onTime (String)  - Time of day when Dark Mode should be *enabled* in 24-hour time formatted as "HH:MM:SS" or "HH:MM", or the values "sunrise" or "sunset".
---  * offTime (String) - Time of day when Dark Mode should be *disabled* in 24-hour time formatted as "HH:MM:SS" or "HH:MM", or the values "sunrise" or "sunset".
---
--- Returns:
---  * Self
function obj:setSchedule(onTime, offTime)
  self.schedule.onAt = processScheduleTime(onTime)
  self.schedule.offAt = processScheduleTime(offTime)

  if self.timer and self.timer:running() then
    self:setDarkModeOnSchedule()
  end
  return self
end

--- DarkMode.isOn() -> boolean
--- Function
--- Returns a boolean indicating whether Dark Mode is on or off.
---
--- Returns:
---  * (Boolean) `true` if Dark Mode is on and `false` if it's off.
function obj.isOn()
  local _, darkModeState = hs.osascript.javascript(
    'Application("System Events").appearancePreferences.darkMode()'
  )
  return darkModeState
end

--- DarkMode:on() -> self
--- Method
--- Turns Dark Mode on.
---
--- Returns:
---  * Self
function obj:on()
  setDarkMode(true)
  return self
end

--- DarkMode:off() -> self
--- Method
--- Turns Dark Mode off.
---
--- Returns:
---  * Self
function obj:off()
  setDarkMode(false)
  return self
end

--- DarkMode:toggle() -> self
--- Method
--- Toggles Dark Mode.
---
--- Returns:
---  * Self
function obj:toggle()
  setDarkMode(not self.isOn())
  return self
end

-- This function does all the important work of setting Dark Mode based on the schedule.
function obj:setDarkModeOnSchedule()
  -- Setup variables that we'll need
  local location = hs.location.get()
  local utcOffset = getUtcOffset()
  local currentTime = os.time()
  local midnightTime = currentTime - hs.timer.localTime()
  local onTime
  local offTime
  local predicateFn

  -- Get the unix time for the onTime and offTime
  if type(self.schedule.onAt) == "number" then
    onTime = midnightTime + self.schedule.onAt
  else
    onTime = hs.location[self.schedule.onAt](location, utcOffset)
  end

  if type(self.schedule.offAt) == "number" then
    offTime = midnightTime + self.schedule.offAt
  else
    offTime = hs.location[self.schedule.offAt](location, utcOffset)
  end

  -- If offTime crosses the day barrier and it's currently passed onTime, move offTime to forward one day.
  if onTime > offTime and currentTime >= onTime then
    if type(self.schedule.offAt) == "number" then
      offTime = offTime + 60*60*24
    else
      offTime = hs.location[self.schedule.offAt](location, utcOffset, os.date("*t",offTime + 60*60*24))
    end
  end

  -- Turn Dark Mode on/off as dictated by schedule and create predicate function for new waitUntil timer
  if currentTime >= onTime and currentTime < offTime then
    setDarkMode(true)
    predicateFn = function() return os.time() >= offTime end
  else
    setDarkMode(false)
    predicateFn = function() return os.time() >= onTime end
  end

  -- Create new timer. hs.timer.waitUntil used since timers that fire at a set time will skip a day if computer is sleeping when the time comes.
  local actionFn = function() return self:setDarkModeOnSchedule() end
  self.timer = hs.timer.waitUntil(predicateFn, actionFn, 60)

  return self
end

--- DarkMode:start() -> self
--- Method
--- Start enabling/disabling Dark Mode base on the schedule set using `DarkMode:setSchedule()`. By default, Dark Mode is enabled at sunset (`onTime`) and disabled at sunrise (`offTime`).
---
--- Returns:
---  * Self
function obj:start()
  self:setDarkModeOnSchedule()
  return self
end

--- DarkMode:stop() -> self
--- Method
--- Stops this spoon from enabling/disabling Dark Mode on a schedule.
---
--- Returns:
---  * Self
function obj:stop()
  self.timer:stop()
  return self
end

--- DarkMode:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkey mappings for this spoon.
---
--- Parameters:
---  * mapping (Table) - A table with keys who's names correspond to methods of this spoon, and values that represent hotkey mappings. For example:
---    * `{toggle = {{"cmd", "option", "ctrl"}, "d"}}`
---
--- Returns:
---  * Self
function obj:bindHotkeys(mapping)
  for k, v in pairs(mapping) do
    hs.hotkey.bind(v[1], v[2], function() return self[k](self, k) end)
  end

  return self
end

return obj
