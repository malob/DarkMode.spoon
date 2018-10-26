--- === DarkMode ===
---
--- This spoon allow you to enable, disable, and toggle Dark Mode in macOS by doing the following respectively:
---  * `DarkMode:setDarkMode(true)`
---  * `DarkMode:setDarkMode(false)`
---  * `DarkMode:setDarkMode()`
---
--- Additionally it can automatically enable/disable Dark Mode based on a schedule. The default schedule is to enable Dark Mode a sunset, and to disable it at sunrise. Use `DarkMode:setSchedule()` to change the schedule. To enable the this functionality call `DarkMode:start()`.

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
local function getUtcOffset()
  local utcOffset = hs.execute("date +%z")
  return utcOffset:sub(1, 3) + utcOffset:sub(4, 5)/60
end

--- DarkMode:setSchedule(onTime, offTime) -> self
--- Method
--- Sets the schedule on which Dark Mode is enabled/disabled. `DarkMode:start()` needs to be called for new schedule to take effect before the currently active timer fires.
---
--- Parameters:
---  * onTime (String)  - Time of day when Dark Mode should be *enable* in 24-hour time formatted as "HH:MM:SS" or "HH:MM", or the values "sunrise" or "sunset".
---  * offTime (String) - Time of day when Dark Mode should be *disable* in 24-hour time formatted as "HH:MM:SS" or "HH:MM", or the values "sunrise" or "sunset".
---
--- Returns:
---  * Self
function obj:setSchedule(onTime, offTime)
  if onTime == "sunrise" or onTime == "sunset" then
    self.schedule.onAt = onTime
  else
    local startInSeconds = hs.timer.seconds(onTime)
    assert(startInSeconds < 86400, "Start time given wasn't a time of day")
    self.schedule.onAt = startInSeconds
  end

  if offTime == "sunrise" or offTime == "sunset" then
    self.schedule.offAt = offTime
  else
    local stopInSeconds = hs.timer.seconds(offTime)
    assert(stopInSeconds < 86400, "Stop time given wasn't a time of day")
    self.schedule.offAt = stopInSeconds
  end

  return self
end

--- DarkMode.setDarkMode([state])
--- Function
--- This function enables/disables Dark Mode. When no parameter is given, it toggles Dark Mode.
---
--- Parameters
---  * (Optional) state (Boolean) - Should be `true` to enable Dark Mode and `false` to disable it. If this parameter is omitted, Dark Mode will be toggled.
function obj.setDarkMode(state)
  local appleScriptVar = state
  if type(state) == "boolean" then
    hs.preferencesDarkMode(state)
  elseif state == nil then
    hs.preferencesDarkMode(not hs.preferencesDarkMode())
    appleScriptVar = "not dark mode"
  else
    error("DarkMode.setDarkMode() called with an argument that wasn't a boolean")
  end

  hs.osascript.applescript(
    string.format(
      [[
      tell application "System Events"
        tell appearance preferences
          set dark mode to %s
        end tell
      end tell
      ]],
      appleScriptVar
    )
  )
end

-- This function does all the important work of setting Dark Mode based on the schedule.
function obj:setDarkModeOnSchedule()
  -- Setup variables that we'll need
  local location = hs.location.get()
  local utcOffset = getUtcOffset()
  local currentTime = os.time()
  local midnightTime = currentTime - hs.timer.localTime()
  local onTime = nil
  local offTime = nil
  local predicateFn = nil

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

  -- If offTime crosses the day barrier and it's currently passed onTime, move offTime to up one day.
  if onTime > offTime and currentTime >= onTime then
    if type(self.schedule.offAt) == "number" then
      offTime = offTime + 60*60*24
    else
      offTime = hs.location[self.schedule.offAt](location, utcOffset, os.date("*t",offTime + 60*60*24))
    end
  end

  -- Turn Dark Mode on/off as dictated by schedule and create predicate function for new waitUntil timer
  if currentTime >= onTime and currentTime <= offTime then
    self.setDarkMode(true)
    predicateFn = function() return os.time() >= offTime end
  else
    self.setDarkMode(false)
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
--- Binds hotkey mappings for this spoon. Currently `toggleDarkMode` is the only availabe hotkey binding:
---  * `DarkMode:bindHotkeys({ toggleDarkMode = {{"cmd", "option", "ctrl"}, "d"} })`
---
--- Parameters:
---  * mapping (Table) - A table containing hotkey mappings.
---
--- Returns:
---  * Self
function obj:bindHotkeys(mapping)
  hs.hotkey.bind(mapping.toggleDarkMode[1], mapping.toggleDarkMode[2], self.setDarkMode())
  return self
end

return obj
