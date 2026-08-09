--- === VoiceIMEHelper ===
---
--- Automatically switches back to the previous input method after voice IME usage.
---
--- This Spoon monitors input source changes and microphone usage to detect when
--- a voice input method (e.g., Doubao/豆包语音输入) is activated. When the
--- microphone transitions from "in use" to "not in use", it automatically
--- switches back to the previously used input method.
---
--- ### Usage
---
--- Add the following to your `~/.hammerspoon/init.lua`:
---
--- ```lua
--- hs.loadSpoon("VoiceIMEHelper")
--- spoon.VoiceIMEHelper:start()
--- ```
---
--- ### How it works
---
--- 1. Monitors system input source changes
--- 2. When a change is detected, records the previous input method and starts
---    checking microphone status (with a configurable delay)
--- 3. If the microphone transitions from "not in use" to "in use", it assumes
---    a voice IME has been activated
--- 4. Continues monitoring the microphone; when it transitions from "in use"
---    to "not in use", automatically switches back to the previous input method
---
--- ### Configuration
---
--- Adjust these properties before calling `:start()`:
---
--- ```lua
--- spoon.VoiceIMEHelper.checkDelay = 0.5    -- Delay before checking mic (seconds)
--- spoon.VoiceIMEHelper.checkInterval = 0.3  -- Polling interval (seconds)
--- spoon.VoiceIMEHelper.checkTimeout = 3.0   -- Timeout for mic detection (seconds)
--- spoon.VoiceIMEHelper.restoreDelay = 1.0   -- Delay before switching back (seconds)
--- ```

local obj = {}
obj.__index = obj

-- Metadata
--- VoiceIMEHelper.name
--- Variable
--- The name of the Spoon.
obj.name = "VoiceIMEHelper"

--- VoiceIMEHelper.version
--- Variable
--- The version of the Spoon.
obj.version = "1.0.0"

--- VoiceIMEHelper.author
--- Variable
--- The author of the Spoon.
obj.author = "Elias Soong"

--- VoiceIMEHelper.license
--- Variable
--- The license of the Spoon.
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- VoiceIMEHelper.homepage
--- Variable
--- The homepage of the Spoon.
obj.homepage = "https://github.com/eliassoong/Voice-IME-Helper"

-- Configuration
--- VoiceIMEHelper.checkDelay
--- Variable
--- Delay in seconds after input source change before checking microphone status.
--- This gives the voice IME time to start using the microphone.
--- Default: `0.5`
obj.checkDelay = 0.5

--- VoiceIMEHelper.checkInterval
--- Variable
--- Interval in seconds for polling microphone status during the checking phase.
--- Used as a backup mechanism alongside the audio device watcher.
--- Default: `0.3`
obj.checkInterval = 0.3

--- VoiceIMEHelper.checkTimeout
--- Variable
--- Maximum time in seconds to wait for microphone to become "in use" after
--- an input source change. If exceeded, monitoring is cancelled and the
--- Spoon returns to the idle state.
--- Default: `3.0`
obj.checkTimeout = 3.0

--- VoiceIMEHelper.restoreDelay
--- Variable
--- Delay in seconds after microphone becomes "not in use" before actually
--- switching back to the previous input method. This prevents premature
--- switching if the voice IME briefly releases the microphone between
--- speech segments.
--- Default: `1.0`
obj.restoreDelay = 1.0

--- VoiceIMEHelper.voiceIMEPatterns
--- Variable
--- Optional list of Lua patterns to match against input method names.
--- If set, the Spoon will only activate monitoring when the new input
--- method's name matches one of these patterns.
--- Set to `nil` (default) to monitor all input method changes.
---
--- Example:
--- ```lua
--- spoon.VoiceIMEHelper.voiceIMEPatterns = {"语音", "Voice", "Dictation", "Doubao", "豆包"}
--- ```
obj.voiceIMEPatterns = nil

--- VoiceIMEHelper.logLevel
--- Variable
--- Logging level for the Spoon. Set to `"debug"` for verbose logging,
--- `"info"` for normal operation, or `"warning"` to suppress most messages.
--- Default: `"info"`
obj.logLevel = "info"

-- Logger (will be initialized with configured level)
local logger = nil

--- Internal: Initialize or update the logger
local function initLogger()
    logger = hs.logger.new("VoiceIMEHelper", obj.logLevel or "info")
end

-- Internal state
-- State machine: IDLE | CHECKING | MONITORING
local state = "IDLE"

-- lastSourceID: the most recently known input source ID (updated on each change)
local lastSourceID = nil

-- previousSourceID: the input source we want to restore to (saved when voice IME starts)
local previousSourceID = nil

-- micDevice: the audio input device being watched
local micDevice = nil

-- checkTimer: timer for polling mic status during CHECKING or MONITORING
local checkTimer = nil

-- checkStartTime: timestamp when CHECKING phase started (for timeout)
local checkStartTime = nil

-- restoreTimer: timer for delayed restore after mic becomes "not in use"
local restoreTimer = nil

-- pendingCheckTimer: timer for the delayed start of the CHECKING phase
local pendingCheckTimer = nil


-- ============================================================================
-- Internal Functions
-- ============================================================================

--- Stops all mic monitoring and returns to IDLE state.
local function stopMicMonitoring()
    state = "IDLE"

    if checkTimer then
        checkTimer:stop()
        checkTimer = nil
    end

    if restoreTimer then
        restoreTimer:stop()
        restoreTimer = nil
    end

    if micDevice then
        micDevice:watcherStop()
        micDevice:watcherCallback(nil)
        micDevice = nil
    end

    logger.d("Mic monitoring stopped, returned to IDLE")
end

--- Switches the input source back to the previously saved one.
local function switchBackToPreviousIME()
    if previousSourceID then
        logger.i("Switching back to previous IME: " .. previousSourceID)
        local ok = hs.keycodes.currentSourceID(previousSourceID)
        if ok then
            logger.i("Successfully switched back to: " .. previousSourceID)
        else
            logger.e("Failed to switch back to: " .. previousSourceID)
        end
    else
        logger.w("No previous IME saved, cannot switch back")
    end
end

--- Sets up the audio device watcher for the MONITORING state.
--- In this state, we're waiting for the mic to become "not in use".
local function setupWatcherForMonitoring()
    -- Stop any existing watcher
    if micDevice then
        micDevice:watcherStop()
        micDevice:watcherCallback(nil)
    end

    -- Get a fresh device reference
    micDevice = hs.audiodevice.defaultInputDevice()
    if not micDevice then
        logger.w("No input device available for monitoring")
        stopMicMonitoring()
        return
    end

    micDevice:watcherCallback(function(uid, event, scope, element)
        if state ~= "MONITORING" then return end

        if event == "gone" then
            logger.d("Device 'gone' event: in-use status changed")
            local inUse = micDevice and micDevice:inUse()
            if inUse == false then
                logger.i("Microphone is no longer in use, scheduling restore")

                -- Cancel any existing restore timer
                if restoreTimer then
                    restoreTimer:stop()
                    restoreTimer = nil
                end

                -- Schedule restore after a delay
                restoreTimer = hs.timer.doAfter(obj.restoreDelay, function()
                    if state == "MONITORING" then
                        logger.i("Restore delay elapsed, switching back")
                        switchBackToPreviousIME()
                        stopMicMonitoring()
                    end
                end)
            elseif inUse == true then
                -- Mic became "in use" again, cancel any pending restore
                if restoreTimer then
                    logger.d("Mic became in use again, cancelling restore")
                    restoreTimer:stop()
                    restoreTimer = nil
                end
            end
        end
    end)
    micDevice:watcherStart()
    logger.d("Mic watcher started for MONITORING state")
end

--- Transitions from CHECKING to MONITORING state.
local function transitionToMonitoring()
    state = "MONITORING"

    -- Stop the checking timer
    if checkTimer then
        checkTimer:stop()
        checkTimer = nil
    end

    local currentMethod = hs.keycodes.currentMethod() or "Unknown"
    logger.i("Voice IME confirmed: " .. currentMethod .. ". Monitoring for completion.")

    -- Set up the watcher for monitoring
    setupWatcherForMonitoring()

    -- Also start polling as a backup (uses the same micDevice as the watcher
    -- to ensure consistent state and proper restoreTimer coordination)
    checkTimer = hs.timer.doEvery(obj.checkInterval, function()
        if state ~= "MONITORING" then
            if checkTimer then checkTimer:stop(); checkTimer = nil end
            return
        end

        -- Use the same device reference as the watcher for consistency
        if micDevice then
            local inUse = micDevice:inUse()
            if inUse == false then
                -- Mic is not in use, schedule restore if not already pending
                if not restoreTimer then
                    logger.i("Mic not in use (poll), scheduling restore")
                    restoreTimer = hs.timer.doAfter(obj.restoreDelay, function()
                        if state == "MONITORING" then
                            logger.i("Restore delay elapsed (poll), switching back")
                            switchBackToPreviousIME()
                            stopMicMonitoring()
                        end
                    end)
                end
            elseif inUse == true then
                -- Mic is in use again, cancel any pending restore
                -- (catches both watcher-scheduled and poll-scheduled timers)
                if restoreTimer then
                    logger.d("Mic in use again (poll), cancelling restore")
                    restoreTimer:stop()
                    restoreTimer = nil
                end
            end
        end
    end)
end

--- Sets up the audio device watcher for the CHECKING state.
--- In this state, we're waiting for the mic to become "in use".
local function setupWatcherForChecking()
    if micDevice then
        micDevice:watcherStop()
        micDevice:watcherCallback(nil)
    end

    micDevice = hs.audiodevice.defaultInputDevice()
    if not micDevice then
        logger.w("No input device available for checking")
        stopMicMonitoring()
        return
    end

    micDevice:watcherCallback(function(uid, event, scope, element)
        if state ~= "CHECKING" then return end

        if event == "gone" then
            logger.d("Device 'gone' event during CHECKING")
            local inUse = micDevice and micDevice:inUse()
            if inUse == true then
                logger.i("Microphone became in use (watcher event)")
                transitionToMonitoring()
            end
        end
    end)
    micDevice:watcherStart()
    logger.d("Mic watcher started for CHECKING state")
end

--- Starts the CHECKING phase: polls and watches for mic to become "in use".
local function startCheckingMic()
    if state == "MONITORING" then
        logger.d("Already in MONITORING state, skipping")
        return
    end

    state = "CHECKING"
    checkStartTime = hs.timer.secondsSinceEpoch()

    logger.d("Starting mic check phase (timeout: " .. obj.checkTimeout .. "s)")

    -- Check if mic is already in use (voice IME might have started immediately)
    local device = hs.audiodevice.defaultInputDevice()
    if device then
        local inUse = device:inUse()
        if inUse == true then
            logger.i("Microphone already in use, transitioning to MONITORING immediately")
            transitionToMonitoring()
            return
        end
    else
        logger.w("No input device available")
        stopMicMonitoring()
        return
    end

    -- Set up watcher to detect mic becoming "in use"
    setupWatcherForChecking()

    -- Also poll as a backup
    checkTimer = hs.timer.doEvery(obj.checkInterval, function()
        if state ~= "CHECKING" then
            if checkTimer then checkTimer:stop(); checkTimer = nil end
            return
        end

        -- Check timeout
        local elapsed = hs.timer.secondsSinceEpoch() - checkStartTime
        if elapsed > obj.checkTimeout then
            logger.d("Check timeout reached (" .. obj.checkTimeout .. "s), returning to IDLE")
            stopMicMonitoring()
            return
        end

        -- Check mic status
        local dev = hs.audiodevice.defaultInputDevice()
        if dev then
            local inUse = dev:inUse()
            if inUse == true then
                logger.i("Microphone became in use (poll)")
                transitionToMonitoring()
            end
        end
    end)
end


-- ============================================================================
-- Public API
-- ============================================================================

--- VoiceIMEHelper:init()
--- Method
--- Initializes the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- You generally do not need to call this manually.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VoiceIMEHelper object
function obj:init()
    initLogger()
    lastSourceID = hs.keycodes.currentSourceID()
    logger.i("Initialized. Current input source: " .. tostring(lastSourceID))
    return self
end

--- VoiceIMEHelper:start()
--- Method
--- Starts monitoring for input source changes and microphone usage.
---
--- This registers a callback for `hs.keycodes.inputSourceChanged`. Note that
--- only one callback can be registered at a time; if you have other Spoons or
--- code using this callback, they may conflict.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VoiceIMEHelper object
function obj:start()
    -- Ensure we start fresh
    self:stop()

    lastSourceID = hs.keycodes.currentSourceID()
    logger.i("Starting with current input source: " .. tostring(lastSourceID))

    hs.keycodes.inputSourceChanged(function()
        local newSourceID = hs.keycodes.currentSourceID()
        local newMethodName = hs.keycodes.currentMethod() or "Unknown"
        logger.i("Input source changed: " .. tostring(lastSourceID) .. " -> " .. tostring(newSourceID) .. " (" .. newMethodName .. ")")

        -- Skip if no actual change
        if newSourceID == lastSourceID then
            logger.d("No actual change, ignoring")
            return
        end

        -- Skip if the new input method name is empty or 'Unknown'
        -- (Doubao voice IME briefly switches to such a placeholder before voice input starts)
        if newMethodName == "" or newMethodName == "Unknown" then
            logger.d("New input method name is empty or 'Unknown', ignoring")
            return
        end

        -- If we're in CHECKING or MONITORING state, cancel current monitoring
        if state ~= "IDLE" then
            logger.d("Cancelling current monitoring due to new input source change")
            stopMicMonitoring()
            -- Note: We don't handle the manual switch-back case here anymore
            -- because we always want to start fresh monitoring for the new source
        end

        -- Cancel any pending delayed check from a previous input source change
        if pendingCheckTimer then
            pendingCheckTimer:stop()
            pendingCheckTimer = nil
        end

        -- Check if we should filter by IME name
        local shouldMonitor = true
        if obj.voiceIMEPatterns and #obj.voiceIMEPatterns > 0 then
            local currentMethod = hs.keycodes.currentMethod() or ""
            local currentMethodLower = string.lower(currentMethod)
            local matches = false
            for _, pattern in ipairs(obj.voiceIMEPatterns) do
                if string.find(currentMethodLower, string.lower(pattern)) then
                    matches = true
                    logger.d("Input method name '" .. currentMethod .. "' matches pattern '" .. pattern .. "'")
                    break
                end
            end
            if not matches then
                logger.i("Input method '" .. currentMethod .. "' does not match voice IME patterns, treating as regular IME")
                -- For non-voice IMEs, update both lastSourceID and previousSourceID
                -- so this becomes the restore target when switching back from a voice IME
                lastSourceID = newSourceID
                previousSourceID = newSourceID
                return
            end
        end

        -- Save the source we want to restore to (the one before this potential voice IME)
        previousSourceID = lastSourceID
        lastSourceID = newSourceID

        logger.i("New potential voice IME detected: " .. newMethodName)
        logger.d("  Will restore to: " .. tostring(previousSourceID))
        logger.i("Will check mic status after " .. obj.checkDelay .. "s delay")

        -- After a delay, start checking mic status
        pendingCheckTimer = hs.timer.doAfter(obj.checkDelay, function()
            pendingCheckTimer = nil
            startCheckingMic()
        end)
    end)

    logger.i("Started monitoring input source changes")
    return self
end

--- VoiceIMEHelper:stop()
--- Method
--- Stops all monitoring and cleans up resources.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VoiceIMEHelper object
function obj:stop()
    -- Unregister input source change callback
    hs.keycodes.inputSourceChanged(nil)

    -- Cancel any pending delayed check
    if pendingCheckTimer then
        pendingCheckTimer:stop()
        pendingCheckTimer = nil
    end

    -- Stop any mic monitoring
    stopMicMonitoring()

    logger.i("Stopped")
    return self
end

--- VoiceIMEHelper:getState()
--- Method
--- Returns the current state of the Spoon.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A string: `"IDLE"`, `"CHECKING"`, or `"MONITORING"`
function obj:getState()
    return state
end

--- VoiceIMEHelper:getPreviousSourceID()
--- Method
--- Returns the saved previous input source ID (the one to switch back to).
---
--- Parameters:
---  * None
---
--- Returns:
---  * A string containing the previous input source ID, or `nil` if none saved
function obj:getPreviousSourceID()
    return previousSourceID
end

--- VoiceIMEHelper:triggerManualRestore()
--- Method
--- Manually triggers a restore to the previously saved input method.
--- This is useful for testing or for binding to a hotkey.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VoiceIMEHelper object
function obj:triggerManualRestore()
    if previousSourceID then
        logger.i("Manual restore triggered, switching to: " .. previousSourceID)
        switchBackToPreviousIME()
        if state ~= "IDLE" then
            stopMicMonitoring()
        end
    else
        logger.w("No previous IME saved, cannot restore")
    end
    return self
end

--- VoiceIMEHelper:setLogLevel(level)
--- Method
--- Sets the logging level for the Spoon.
---
--- Parameters:
---  * level - A string: `"debug"`, `"info"`, `"warning"`, or `"error"`
---
--- Returns:
---  * The VoiceIMEHelper object
function obj:setLogLevel(level)
    obj.logLevel = level
    initLogger()
    logger.i("Log level set to: " .. level)
    return self
end

--- VoiceIMEHelper:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for VoiceIMEHelper actions.
---
--- Supported actions:
---  * `restore` - Manually trigger a restore to the previous IME
---
--- Example:
--- ```lua
--- spoon.VoiceIMEHelper:bindHotkeys({
---     restore = {{"cmd", "shift"}, "r"}
--- })
--- ```
---
--- Parameters:
---  * mapping - A table containing hotkey mappings
---
--- Returns:
---  * The VoiceIMEHelper object
function obj:bindHotkeys(mapping)
    if mapping.restore then
        local mods, key = table.unpack(mapping.restore)
        hs.hotkey.bind(mods, key, function()
            self:triggerManualRestore()
        end)
        logger.i("Bound restore hotkey: " .. table.concat(mods, "+") .. "+" .. key)
    end
    return self
end

return obj
