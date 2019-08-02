--- === DarkMode ===
---
--- This spoon allows you to enable, disable, and toggle Dark Mode, as well as automatically enable/disable DarkMode based on a schedule. The default schedule enables Dark Mode at sunset and disables it at sunrise.


-----------------------
-- Setup Environment --
-----------------------
-- Create locals for all needed globals so we have access to them
local assert, pairs = assert, pairs
local os = { date = os.date, time = os.time }
local string = { format = string.format }
local hs = {
  brightness = hs.brightness,
  console = hs.console,
  execute = hs.execute,
  fnutils = hs.fnutils,
  hotkey = hs.hotkey,
  location = hs.location,
  osascript = hs.osascript,
  preferencesDarkMode = hs.preferencesDarkMode,
  settings = hs.settings,
  timer = hs.timer
}

-- Empty environment in this scope
-- This prevents module from polluting global scope
local _ENV = {}


-------------
-- Private --
-------------
local SECONDS_IN_A_DAY = 86400
local SETTINGS_KEY = "DarkModeSpoon"
local LOCATION_CACHE_TTL = 3600 -- seconds
local DEFAULT_LIGHT_THRESHOLD = 75
local DEFAULT_LIGHT_OFFSET = 5
local DEFAULT_LIGHT_INTERVAL = 1 -- seconds

-- IO Int
local function locationExpiryTime()
  return os.time() + LOCATION_CACHE_TTL
end

-- IO hs.location Table
-- Return location table of current location if available and last cached location
-- otherwise, in the format returned by hs.location.get()
local function location()
  local settings = hs.settings.get(SETTINGS_KEY)

  if os.time() < settings.locationExpiryTime then
    return settings.location
  end

  local updatedLocation = hs.location.get()

  if updatedLocation then
    settings.location = updatedLocation
    settings.locationExpiryTime = locationExpiryTime()
    hs.settings.set(SETTINGS_KEY, settings)
    return updatedLocation
  end

  return settings.location
end

-- IO Float
-- Returns the offset of machines timezone from UTC
local function utcOffset()
  local offset = hs.execute("date +%z")
  return offset:sub(1, 3) + offset:sub(4, 5)/60
end

-- os.date Table -> Int
-- Returns unix time for start of current day.
local function dayStartUnixTime(date)
  date = hs.fnutils.copy(date)
  hs.fnutils.ieach(
    { "hour", "min", "sec" },
    function(x) date[x] = 0 end
  )
  return os.time(date)
end

-- os.date Table -> Number -> IO os.date Table
-- Given a date table and a number of days, returns a new table offset by original by days.
local function addDaysToDate(date, days)
  return os.date("*t", os.time(date) + days * SECONDS_IN_A_DAY)
end

-- String -> hs.location Table -> Numeber -> os.date Table -> IO Int
-- Wraper for hs.location sunrise/sunset functions.
-- Funtion needed because of https://github.com/Hammerspoon/hammerspoon/issues/1977
local function sunTime(sunEvent, loc, offset, date)
  local dayStatTime = dayStartUnixTime(date)

  local time = hs.location[sunEvent](loc, offset, date)

  if time < dayStatTime then
    return hs.location[sunEvent](loc, offset, addDaysToDate(date, 1))
  elseif time > dayStatTime + SECONDS_IN_A_DAY then
    return hs.location[sunEvent](loc, offset, addDaysToDate(date, -1))
  end
  return time
end

-- String -> IO (ScheduleTimeTable)
-- ScheduleTimeTable { time :: Number, sunEvent :: String/Nil }
--
-- Given a string with time of day formatted as "HH:MM:SS"/"HH:MM", or "sunrise"/"sunset",
-- returns a function that when called returns a table with a key `time` key with a unix time value, and
-- a `sunEvent` key with the value "sunrise"/"sunset" if present.
local function timeFnGenerator(timeOfDay)
  if timeOfDay == "sunrise" or timeOfDay == "sunset" then
    return function()
      return {
        time = sunTime(timeOfDay, location(), utcOffset(), os.date("*t")),
        sunEvent = timeOfDay
      }
    end
  end

  return function()
    return { time = dayStartUnixTime(os.date("*t")) + hs.timer.seconds(timeOfDay) }
  end
end

-- Bool -> IO Nil
local function setHammerspoonDM(state)
  hs.preferencesDarkMode(state)
  hs.console.darkMode(state)
  hs.console.consoleCommandColor{ white = (state and 1) or 0}
end

-- Bool -> IO Bool
-- Returns a bool indicating success
local function setSystemDM(state)
  return hs.osascript.javascript(
    string.format(
      "Application('System Events').appearancePreferences.darkMode.set(%s)",
      state
    )
  )
end

-- Bool -> (Bool -> Nil) -> IO Bool
-- Returns a bool indicating success of setting system Dark Mode to desired state
local function setDarkMode(state, callback)
  if callback then callback(state) end
  setHammerspoonDM(state)
  return setSystemDM(state)
end

-- ScheduleTimeTable -> Int
-- ScheduleTimeTable { time :: Number, sunEvent :: String/Nil }
-- (see timeFnGenerator() for more infomation on this table)
-- Returns unix time representing time in ScheduleTimeTable move forward by one day
local function offsetTimeByDay(schedTime)
  if schedTime.sunEvent then
    return sunTime(schedTime.sunEvent, location(), utcOffset(), addDaysToDate(os.date("*t"), 1))
  end
  return schedTime.time + SECONDS_IN_A_DAY
end

-- ScheduleTimeTable -> ScheduleTimeTable -> Number -> Bool -> Number
-- ScheduleTimeTable { time :: Number, sunEvent :: String/Nil }
-- (see timeFnGenerator() for more infomation on this table)
-- Determines what time Dark Mode should be toggled again
local function nextToggleTime(on, off, currentTime, darkModeisOn)
  if currentTime >= on.time and currentTime >= off.time then
    return darkModeisOn and offsetTimeByDay(off) or offsetTimeByDay(on)
  end
  return darkModeisOn and off.time or on.time
end

-- Number -> Number -> Number -> Bool
-- Determines whether Dark Mode should be turned on
local function shouldDMBeOn(onTime, offTime, currentTime)
  if onTime > offTime then
    if currentTime >= onTime or currentTime < offTime then return true end
  else
    if currentTime >= onTime and currentTime < offTime then return true end
  end
  return false
end

-- Number -> Number -> Bool -> (Bool -> Nil) -> Nil
local function toggleDMOnBrightness(threshold, offset, callback)
  local brightness = hs.brightness.get()
  if brightness >= threshold + offset then setDarkMode(false, callback) end
  if brightness <= threshold - offset then setDarkMode(true, callback) end
end

-- DarkMode Object -> Nil
-- Sets Dark Mode based on the schedule
local function autoToggleDM(self)
  local scheduleDesiredDMState

  if self.schedule then
    local currentTime = os.time()
    local on = self.schedule.onAt()
    local off = self.schedule.offAt()

    scheduleDesiredDMState = shouldDMBeOn(on.time, off.time, currentTime)
    setDarkMode(scheduleDesiredDMState, self.callbackFn)
    local toggleTime = nextToggleTime(on, off, currentTime, scheduleDesiredDMState)

    self.scheduleTimer = hs.timer.waitUntil(
      function() return os.time() >= toggleTime end,
      function() autoToggleDM(self) end,
      60
    )
  end

  if self.lightAutoToggle.enabled then
    if scheduleDesiredDMState then
      self.lightTimer = nil
    else
      local light = self.lightAutoToggle
      local toggleFn = function()
        toggleDMOnBrightness(
          light.threshold or DEFAULT_LIGHT_THRESHOLD,
          light.offset or DEFAULT_LIGHT_OFFSET,
          self.callbackFn
        )
      end
      toggleFn()
      self.lightTimer = hs.timer.doEvery(
        light.interval or DEFAULT_LIGHT_INTERVAL,
        toggleFn
      )
    end
  end
end

-- luacheck: no global
------------
-- Public --
------------
-- Spoon metadata
name = "DarkMode"
version = "1.0"
author = "Malo Bourgon"
license = "MIT - https://opensource.org/licenses/MIT"
homepage = "https://github.com/malob/DarkMode.spoon"

lightAutoToggle = {
  enabled = false
}

--- DarkMode.schedule (Table)
--- Variable
--- A table with two keys, `onAt` and `offAt`, who's values should both be functions that when called by this spoon return a table indicating the time today when Dark Mode should be turn on/off respectivly.
---
--- Messing around with `DarkMode.schedule` directly should only be done by adventurous programmers for whom `DarkMode:setSchedule()` isn't sufficient for their needs. To get a better understanding of the table the functions should return, have a look at the private function `timeFnGenerator()`.
schedule = {
  onAt = timeFnGenerator("sunset"),
  offAt = timeFnGenerator("sunrise")
}

--- DarkMode.callbackFn (Function)
--- Variable
--- A function that's called every time Dark Mode is toggle by this spoon. The function provided should accept a boolean argument, which will be `true` when Dark Mode is enabled, and `false` when it's disabled.
callbackFn = nil

--- DarkMode.isOn() -> Bool
--- Function
--- Returns a boolean indicating whether Dark Mode is on or off.
---
--- Returns:
---  * (Bool) `true` if Dark Mode is on and `false` if it's off.
function isOn()
  local _, darkModeState = hs.osascript.javascript(
    'Application("System Events").appearancePreferences.darkMode()'
  )
  return darkModeState
end

--- DarkMode:isScheduleOn() -> Bool
--- Method
--- Returns a boolean indicating whether Dark Mode will be enable/disabled based on a schedule.
---
--- Returns:
---  * (Bool) `true` if the Dark Mode schedule is active and `false` if it's not.
function isScheduleOn(self)
  if self.scheduleTimer then return self.scheduleTimer:running() end
  return false
end

--- DarkMode:getSchedule([inUnixTime]) -> table
--- Method
--- Gets the schedule for the current day.
---
--- Parameters:
---  * (Optional) inUnixTime (Bool) - Setting this value to `true` will return the schedule times in unix time.
---
--- Returns:
---  * (Table) A table with two elements with keys, `onAt` and `offAt`, each of which is a table with keys, `time` and optionally `sunEvent`, where the later will be a string with a value of `"sunrise"` or `"sunset"` if the value for the `time` key corresponds to a sunrise or sunset time respectively.
function getSchedule(self, inUnixTime)
  return hs.fnutils.imap(
    {"onAt", "offAt"},
    function(x)
      if inUnixTime then return { [x] = self.schedule[x]() } end
      return {
        [x] = {
          time = os.date("%T", self.schedule[x]().time),
          sunEvent = self.schedule[x]().sunEvent
        }
      }
    end
  )
end

--- DarkMode:setSchedule(onTime, offTime) -> Self
--- Method
--- Sets the schedule on which Dark Mode is enabled/disabled.
---
--- Parameters:
---  * onTime (String)  - Time of day when Dark Mode should be *enabled* in 24-hour time formatted as "HH:MM:SS" or "HH:MM", or the values `"sunrise"` or `"sunset"`.
---  * offTime (String) - Time of day when Dark Mode should be *disabled* in 24-hour time formatted as "HH:MM:SS" or "HH:MM", or the values `"sunrise"` or `"sunset"`.
---
--- Returns:
---  * Self
function setSchedule(self, onTime, offTime)
  assert(onTime ~= offTime, "onTime and offTime cannot be the same value")

  self.schedule.onAt = timeFnGenerator(onTime)
  self.schedule.offAt = timeFnGenerator(offTime)

  if self.scheduleTimer and self.scheduleTimer:running() then
    autoToggleDM(self)
  end

  return self
end

--- DarkMode:on() -> Self
--- Method
--- Turns Dark Mode on.
---
--- Returns:
---  * Self
function on(self)
  setDarkMode(true, self.callbackFn)
  return self
end

--- DarkMode:off() -> Self
--- Method
--- Turns Dark Mode off.
---
--- Returns:
---  * Self
function off(self)
  setDarkMode(false, self.callbackFn)
  return self
end

--- DarkMode:toggle() -> Self
--- Method
--- Toggles Dark Mode.
---
--- Returns:
---  * Self
function toggle(self)
  setDarkMode(not self.isOn(), self.callbackFn)
  return self
end

--- DarkMode:init() -> Self
--- Method
--- Creates an `hs.settings` record for this spoon to use as cache for location and location cache expiry time. This cached location allows the spoon to keep functioning when the schedule includes a sunrise or sunset time and `hs.location.get()` can't get a location.
---
--- Returns:
---  * Self
function init(self)
  if not hs.settings.getKeys()[SETTINGS_KEY] then hs.settings.set(SETTINGS_KEY, {}) end

  local settings = hs.settings.get(SETTINGS_KEY)
  if not settings.location then
    settings.location = hs.location.get()
    settings.locationExpiryTime = locationExpiryTime()
    hs.settings.set(SETTINGS_KEY, settings)
  end
  return self
end

--- DarkMode:start() -> Self
--- Method
--- Start enabling/disabling Dark Mode based on the schedule set using `DarkMode:setSchedule()`. By default, Dark Mode is enabled at sunset (`onTime`) and disabled at sunrise (`offTime`).
---
--- Returns:
---  * Self
function start(self)
  autoToggleDM(self)
  return self
end

--- DarkMode:stop() -> Self
--- Method
--- Stops this spoon from enabling/disabling Dark Mode on a schedule.
---
--- Returns:
---  * Self
function stop(self)
  if self.scheduleTimer then self.scheduleTimer:stop() end
  if self.lightTimer then self.lightTimer:stop() end
  return self
end

--- DarkMode:bindHotkeys(mapping) -> Self
--- Method
--- Binds hotkey mappings for this spoon.
---
--- Parameters:
---  * mapping (Table) - A table with keys who's names correspond to methods of this spoon and values that represent hotkey mappings. For example:
---    * `{toggle = {{"cmd", "option", "ctrl"}, "d"}}`
---
--- Returns:
---  * Self
function bindHotkeys(self, mapping)
  for k, v in pairs(mapping) do
    hs.hotkey.bind(v[1], v[2], function() return self[k](self, k) end)
  end
  return self
end

return _ENV
