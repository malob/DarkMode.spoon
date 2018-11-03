
--- === DarkMode ===
--
-- This spoon allow you to enable, disable, and toggle Dark Mode in macOS, as well as automatically
-- enable/disable DarkMode based on a schedule. The default schedule enables Dark Mode at sunset and
-- disables it at sunrise.


-----------------------
-- Setup Environment --
-----------------------
-- Create locals for all needed globals so we have access to them
local print = print
local pairs = pairs
local os = { date = os.date, time = os.time }
local string = { format = string.format }
local hs = {
  console = hs.console,
  execute = hs.execute,
  fnutils = hs.fnutils,
  location = hs.location,
  notify = hs.notify,
  osascript = hs.osascript,
  preferencesDarkMode = hs.preferencesDarkMode,
  timer = hs.timer,
  inspect = hs.inspect
}

-- Empty environment in this scope
-- This prevents module from polluting global scope
local _ENV = {}


-------------
-- Private --
-------------
local SECONDS_IN_A_DAY = 60*60*24

-- _ -> Float
-- Returns the offset of machines timezone from UTC
local function utcOffset()
  local offset = hs.execute("date +%z")
  return offset:sub(1, 3) + offset:sub(4, 5)/60
end

-- _ -> Int
-- Returns the time in seconds from midnight of the current day
local function midnightTime()
  return os.time() - hs.timer.localTime()
end

-- String -> Int -> Int
-- Parameters:
--  * sunEvent   - "sunrise" or "sunset"
--  * daysOffset - Offset of days for current day on which to get sunEvent time
--
-- Returns:
--  * Unix time
local function adjustedSunTime(sunEvent, daysOffset)
  return hs.location[sunEvent](
    hs.location.get(),
    utcOffset(),
    os.date("*t", os.time() + daysOffset * SECONDS_IN_A_DAY)
  )
end

-- String -> Int
-- Given a string of a sunEvent, "sunrise" or "sunset", returns unix time for sunEvent on current day
local function sunTime(sunEvent)
  -- Funtion needed because of https://github.com/Hammerspoon/hammerspoon/issues/1977
  local midnight = midnightTime()
  local time = adjustedSunTime(sunEvent, 0)

  if time < midnight then
    return adjustedSunTime(sunEvent, 1)
  elseif time > midnight + SECONDS_IN_A_DAY then
    return adjustedSunTime(sunEvent, -1)
  else
    return time
  end
end

-- String -> (_ -> ScheduleTimeTable)
-- ScheduleTimeTable { time :: Number, sunEvent :: String/Nil }
--
-- Given a string with time of day formatted as "HH:MM:SS"/"HH:MM", or "sunrise"/"sunset",
-- returns a function that when called returns a table with a key `time` key with a unix time value, and
-- a `sunEvent` key with the value "sunrise"/"sunset" if present.
local function timeFnGenerator(timeOfDay)
  if timeOfDay == "sunrise" or timeOfDay == "sunset" then
    return function() return { time = sunTime(timeOfDay), sunEvent = timeOfDay} end
  else
    local secondsFromMidnight = hs.timer.seconds(timeOfDay)
    return function() return { time = midnightTime() + secondsFromMidnight } end
  end
end

-- Bool -> Nil
local function setHammerspoonDM(state)
  hs.preferencesDarkMode(state)
  hs.console.darkMode(state)
  hs.console.consoleCommandColor{ white = (state and 1) or 0}
end

-- Bool -> Bool
-- Returns a bool indicating success
local function setSystemDM(state)
  return hs.osascript.javascript(
    string.format(
      "Application('System Events').appearancePreferences.darkMode.set(%s)",
      state
    )
  )
end

-- Bool -> Bool
-- Returns a bool indicating success of setting system Dark Mode to desired state
local function setDarkMode(state)
  if functionToCall then functionToCall(state) end
  setHammerspoonDM(state)
  return setSystemDM(state)
end

-- ScheduleTimeTable -> ScheduleTimeTable -> Number -> Bool -> Number
-- ScheduleTimeTable { time :: Number, sunEvent :: String/Nil } (see timeFnGenerator() for more infomation on this table)
--
-- Determines what time Dark Mode should be toggled again
local function nextToggleTime(on, off, currentTime, darkModeisOn)
  if darkModeisOn and currentTime > on.time then
    return off.sunEvent and adjustedSunTime(off.sunEvent, 1) or off.time + SECONDS_IN_A_DAY
  elseif not darkModeisOn and currentTime > off.time then
    return on.sunEvent and adjustedSunTime(on.sunEvent, 1) or on.time + SECONDS_IN_A_DAY
  elseif darkModeisOn then
    return off.time
  else
    return on.time
  end
end

-- Number -> Number -> Number -> Bool
-- Determines whether Dark Mode should be turned on
local function shouldDMBeOn(onTime, offTime, currentTime)
  if currentTime >= offTime and currentTime < onTime then
    if onTime > offTime then return false else return true end
  end
  if onTime > offTime then return false else return true end
end

-- ScheduleTable -> hs.timer
-- ScheduleTable { onAt :: (_ -> ScheduleTimeTable), offAt :: (_ -> ScheduleTimeTable) }
-- Sets Dark Mode based on the schedule and returns a timer which fires when Dark Mode should be toggled next
local function manageDMSchedule(sched)
  local currentTime = os.time()
  local on = sched.onAt()
  local off = sched.offAt()

  local desiredState = shouldDMBeOn(on.time, off.time, currentTime)
  setDarkMode(desiredState)
  local toggleTime = nextToggleTime(on, off, currentTime, desiredState)
  print(toggleTime)
  return hs.timer.waitUntil(
    function() return currentTime >= toggleTime end,
    function() return manageDMSchedule(sched) end,
    60
  )
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

--- DarkMode.schedule (Table)
-- Variable
-- A table with two keys, `onAt` and `offAt`, who values should both be functions that when called by
-- this spoon return a table indicating the time today when Dark Mode should be turn on/off respectivly.
--
-- Messing around with `DarkMode.schedule` directly should only be done by adventurous programmers
-- for whom `DarkMode:setSchedule()` isn't sufficient for their needs.
schedule = {
  onAt = timeFnGenerator("sunset"),
  offAt = timeFnGenerator("sunrise")
}

--- DarkMode.functionToCall (Function)
-- Variable
-- A function that's called every time Dark Mode is toggle by this spoon.
-- The function provided should accept a boolean argument, which will be `true` when
-- Dark Mode is enabled, and `false` when it's disabled.
functionToCall = nil

-- DarkMode.isOn() -> Bool
-- Function
-- Returns a boolean indicating whether Dark Mode is on or off.
--
-- Returns:
--  * (Bool) `true` if Dark Mode is on and `false` if it's off.
function isOn()
  local _, darkModeState = hs.osascript.javascript(
    'Application("System Events").appearancePreferences.darkMode()'
  )
  return darkModeState
end

--- DarkMode:isScheduleOn() -> Bool
-- Method
-- Returns a boolean indicating whether Dark Mode will be enable/disabled based on a schedule.
--
-- Returns:
--  * (Bool) `true` if Dark Mode schedule is active and `false` if it's not.
function isScheduleOn(self)
  if self.timer then return self.timer:running() end
  return false
end

--- DarkMode:getSchedule([inUnixTime]) -> table
-- Method
-- Get the schedule for the current day.
--
-- Parameters:
--  * (Optional) inUnixTime (Bool) - Setting this value to `true` will return the schedule times in unix time.
--
-- Returns:
--  * (Table) A table with two elements with keys, `onAt` and `offAt`, each of which is a table with keys,
--    `time` and optionally `sunEvent`, where the later will we string "sunrise" or "sunset" if the `time`
--    that time corresponds to a either a sunrise or sunset time.
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
-- Method
-- Sets the schedule on which Dark Mode is enabled/disabled.
--
-- Parameters:
--  * onTime (String)  - Time of day when Dark Mode should be *enabled* in 24-hour time formatted
--     as "HH:MM:SS" or "HH:MM", or the values "sunrise" or "sunset".
--  * offTime (String) - Time of day when Dark Mode should be *disabled* in 24-hour time formatted
--     as "HH:MM:SS" or "HH:MM", or the values "sunrise" or "sunset".
--
-- Returns:
--  * Self
function setSchedule(self, onTime, offTime)
  self.schedule.onAt = timeFnGenerator(onTime)
  self.schedule.offAt = timeFnGenerator(offTime)

  if self.timer and self.timer:running() then
    self.timer = manageDMSchedule(self.schedule)
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
  setDarkMode(true)
  return self
end

--- DarkMode:off() -> Self
--- Method
--- Turns Dark Mode off.
---
--- Returns:
---  * Self
function off(self)
  setDarkMode(false)
  return self
end

--- DarkMode:toggle() -> Self
--- Method
--- Toggles Dark Mode.
---
--- Returns:
---  * Self
function toggle(self)
  setDarkMode(not self.isOn())
  return self
end

--- DarkMode:start() -> Self
-- Method
-- Start enabling/disabling Dark Mode base on the schedule set using `DarkMode:setSchedule()`.
-- By default, Dark Mode is enabled at sunset (`onTime`) and disabled at sunrise (`offTime`).
--
-- Returns:
--  * Self
function start(self)
  self.timer = manageDMSchedule(self.schedule)
  return self
end

--- DarkMode:stop() -> self
-- Method
-- Stops this spoon from enabling/disabling Dark Mode on a schedule.
--
-- Returns:
--  * Self
function stop(self)
  if self.timer then self.timer:stop() end
  return self
end

--- DarkMode:bindHotkeys(mapping) -> self
-- Method
-- Binds hotkey mappings for this spoon.
--
-- Parameters:
--  * mapping (Table) - A table with keys who's names correspond to methods of this spoon,
--    and values that represent hotkey mappings. For example:
--    * `{toggle = {{"cmd", "option", "ctrl"}, "d"}}`
--
-- Returns:
--  * Self
function bindHotkeys(self, mapping)
  for k, v in pairs(mapping) do
    hs.hotkey.bind(v[1], v[2], function() return self[k](self, k) end)
  end

  return self
end

return _ENV
