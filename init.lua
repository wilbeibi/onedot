local M = {}

-- Derive BASE_DIR from this script's location (works regardless of where it's cloned)
local BASE_DIR = debug.getinfo(1, "S").source:match("@(.*/)")

-- Find uv: try PATH first, then common install locations
local function findUv()
    local output, ok = hs.execute("which uv")
    if ok and output then
        local path = output:gsub("%s+$", "")
        if path ~= "" then return path end
    end
    local fallbacks = { "/opt/homebrew/bin/uv", "/usr/local/bin/uv" }
    for _, p in ipairs(fallbacks) do
        local f = io.open(p, "r")
        if f then f:close(); return p end
    end
    return nil
end

local UV_PATH = findUv()
local SCRIPT_PATH = BASE_DIR .. "classify.py"
local CONFIG_PATH = os.getenv("HOME") .. "/.config/focus-color/config.yaml"
local SCREENSHOT_PATH = "/tmp/focus-color.png"

-- Parse simple YAML (key: value, one per line)
local function loadConfig()
    local config = {}
    local f = io.open(CONFIG_PATH, "r")
    if not f then return nil end
    for line in f:lines() do
        if not line:match("^#") and line:match(":") then
            local key, val = line:match("^(%S+):%s*(.+)$")
            if key and val then
                val = val:gsub("%s+#.*$", "")   -- strip inline comments
                val = val:match('^"(.*)"$') or val:match("^'(.*)'$") or val  -- strip quotes
                config[key] = val
            end
        end
    end
    f:close()
    return config
end

local config = loadConfig()
if not config then
    hs.alert.show("focus-color: ~/.config/focus-color/config.yaml not found.\nCopy config.yaml.example there and add your Gemini API key.")
    return M
end

local API_KEY = config.api_key or ""
if API_KEY == "" then
    hs.alert.show("focus-color: Set api_key in ~/.config/focus-color/config.yaml")
    return M
end

if not UV_PATH then
    hs.alert.show("focus-color: 'uv' not found.\nInstall it: curl -LsSf https://astral.sh/uv/install.sh | sh")
    return M
end

local MODEL = config.model or "gemini-2.5-flash"
local INTERVAL = tonumber(config.interval) or 30

local function parseAppList(raw)
    local set = {}
    if not raw or raw == "" then return set end
    for part in raw:gmatch("[^,]+") do
        local app = part:gsub("^%s+", ""):gsub("%s+$", "")
        if app ~= "" then
            set[app] = true
        end
    end
    return set
end

local EXCLUDED_APPS = parseAppList(config.exclude_apps)

-- Desaturated palette — see docs/color-psychology-research.md for rationale
local COLORS = {
    OUTPUT     = { red = 0.24, green = 0.65, blue = 0.42 }, -- #3DA66A emerald green: productive creation
    INPUT      = { red = 0.36, green = 0.64, blue = 0.85 }, -- #5BA4D9 steel blue: calm absorption
    DISTRACTED = { red = 0.83, green = 0.41, blue = 0.23 }, -- #D4693A burnt orange: attention warning
    UNKNOWN    = { red = 0.48, green = 0.48, blue = 0.50 }, -- #7A7A80 cool gray: neutral/starting
    ERROR      = { red = 0.55, green = 0.23, blue = 0.23 }, -- #8C3A3A muted red: visible but not alarming
    SWITCHING  = { red = 0.83, green = 0.63, blue = 0.19 }, -- #D4A030 muted amber: context transition ring
}

local indicator = require("focus-color.indicator")
local history = require("focus-color.history")
local overlay = require("focus-color.overlay")
local JSONL_PATH = os.getenv("HOME") .. "/.config/focus-color/log.jsonl"
local HISTORY_MINUTES = 60

-- Append a JSONL log entry (mirrors classify.py's log_jsonl format)
local function logEntry(entry)
    entry.ts = entry.ts or os.date("%Y-%m-%dT%H:%M:%S")
    entry.model = entry.model or MODEL
    local lf = io.open(JSONL_PATH, "a")
    if lf then lf:write(hs.json.encode(entry) .. "\n"); lf:close() end
end

local PAUSE_FILE = "/tmp/focus-color-paused"

local menubar = nil
local timer = nil
local currentTask = nil
local pauseTimer = nil
local paused = false

local function readPauseFile()
    local f = io.open(PAUSE_FILE, "r")
    if not f then return nil end
    local val = f:read("*a"):gsub("%s+", "")
    f:close()
    return tonumber(val)
end

local function writePauseFile(resumeAt)
    local f = io.open(PAUSE_FILE, "w")
    if not f then return end
    f:write(tostring(resumeAt))
    f:close()
end

local function clearPauseFile()
    os.remove(PAUSE_FILE)
end

local lastCategory = "UNKNOWN"
local lastReason = ""
local lastApp = ""
local switchTimes = {}
local overlaySuppressedUntil = 0
local SWITCH_WINDOW = 600    -- look at last 10 minutes
local SWITCH_THRESHOLD = 5   -- popup after 5 switches within the window

local function updateIndicator(category, app, reason, switching)
    if not menubar then return end

    local now = os.time()
    if switching then
        table.insert(switchTimes, now)
    end
    -- Prune old timestamps outside the window
    local cutoff = now - SWITCH_WINDOW
    while #switchTimes > 0 and switchTimes[1] < cutoff do
        table.remove(switchTimes, 1)
    end

    if #switchTimes >= SWITCH_THRESHOLD and now >= overlaySuppressedUntil then
        local switchMinutes = SWITCH_WINDOW / 60
        local summary = history.switchingSummary(JSONL_PATH, INTERVAL, switchMinutes)
        if summary then
            local bulletCount = select(2, summary:gsub("•", ""))
            if bulletCount > SWITCH_THRESHOLD then
                overlay.show("Here's where you've been in the last " .. math.floor(switchMinutes) .. " min:\n\n" .. summary)
            end
            overlaySuppressedUntil = now + 300
            switchTimes = {}
        end
    end

    lastCategory = category
    lastApp = app or ""
    lastReason = reason or ""
    local color = COLORS[category] or COLORS.UNKNOWN
    local switchingColor = (#switchTimes > 0) and COLORS.SWITCHING or nil

    if category == "DISTRACTED" then
        indicator.startBreathe(menubar, color, switchingColor)
    else
        indicator.solid(menubar, color, switchingColor)
    end

    menubar:setTooltip(lastCategory == "UNKNOWN" and (lastReason ~= "" and lastReason or "Starting…") or lastApp)
end

local function captureAndClassify()
    if currentTask and currentTask:isRunning() then return end

    -- Get frontmost app name from the OS (stable, no AI guessing)
    local frontApp = hs.application.frontmostApplication()
    local appName = frontApp and frontApp:name() or "Unknown"

    if EXCLUDED_APPS[appName] then
        logEntry({ event = "excluded", category = "EXCLUDED", app = appName, activity = "excluded", reason = "excluded app" })
        updateIndicator("UNKNOWN", appName .. " — excluded", "App excluded from capture", false)
        return
    end

    -- Hammerspoon captures screenshot (has Screen Recording permission)
    local screen = hs.screen.mainScreen()
    local snapshot = screen:snapshot()
    if not snapshot then
        print("[focus-color] failed to capture screenshot")
        return
    end
    -- Downscale for faster upload to Gemini (Retina screenshots are unnecessarily large)
    local size = snapshot:size()
    local MAX_W = 1536
    if size.w > MAX_W then
        local scale = MAX_W / size.w
        snapshot = snapshot:copy():setSize({ w = MAX_W, h = math.floor(size.h * scale) })
    end
    snapshot:saveToFile(SCREENSHOT_PATH)

    -- Spawn Python to classify the screenshot
    currentTask = hs.task.new(
        UV_PATH,
        function(exitCode, stdout, stderr)
            if exitCode == 0 and stdout then
                local ok, result = pcall(hs.json.decode, stdout)
                if ok and result then
                    if COLORS[result.category] then
                        local display = appName
                        if result.activity and result.activity ~= "" then
                            display = appName .. " — " .. result.activity
                        end
                        updateIndicator(result.category, display, result.reason, result.switching)
                    else
                        print("[focus-color] unknown category: " .. tostring(result.category))
                        updateIndicator("UNKNOWN", appName, "Unknown category: " .. tostring(result.category), false)
                    end
                end
            else
                print("[focus-color] error: " .. (stderr or "unknown"))
                updateIndicator("ERROR", nil, "Classification failed", nil)
            end
            currentTask = nil
        end,
        { "run", SCRIPT_PATH, SCREENSHOT_PATH, appName }
    )
    currentTask:setEnvironment({ GEMINI_API_KEY = API_KEY, MODEL = MODEL })
    currentTask:start()
end

function M.start()
    if menubar then return end

    menubar = hs.menubar.new()
    updateIndicator("UNKNOWN")

    -- Restore pause state from previous session
    local resumeAt = readPauseFile()
    if resumeAt then
        local now = os.time()
        if resumeAt > now then
            paused = true
            local remaining = resumeAt - now
            indicator.paused(menubar, COLORS.UNKNOWN)
            local mins = math.ceil(remaining / 60)
            if mins >= 60 then
                menubar:setTooltip("Paused for " .. math.floor(mins / 60) .. "h")
            else
                menubar:setTooltip("Paused for " .. mins .. "m")
            end
            pauseTimer = hs.timer.doAfter(remaining, function() M.resume() end)
        else
            clearPauseFile()
        end
    end

    menubar:setMenu(function()
        local items = {}
        if lastReason ~= "" then
            -- Word-wrap reason into ~40-char lines (UTF-8-aware)
            local line = ""
            for word in lastReason:gmatch("%S+") do
                local lineLen = utf8.len(line) or #line
                local wordLen = utf8.len(word) or #word
                if lineLen + wordLen + 1 > 40 and lineLen > 0 then
                    table.insert(items, { title = line, disabled = true })
                    line = word
                else
                    line = lineLen > 0 and (line .. " " .. word) or word
                end
            end
            if #line > 0 then
                table.insert(items, { title = line, disabled = true })
            end
            table.insert(items, { title = "-" })
        end
        table.insert(items, {
            title = "Last " .. HISTORY_MINUTES .. " minutes",
            menu = history.recentActivity(JSONL_PATH, INTERVAL, HISTORY_MINUTES),
        })
        table.insert(items, { title = "-" })
        if paused then
            table.insert(items, { title = "Resume", fn = function() M.resume() end })
        else
            -- Compute "Until this evening" (7 PM today, or nil if already past)
            local now = os.time()
            local tonight = os.time({
                year = os.date("%Y", now), month = os.date("%m", now) + 0,
                day = os.date("%d", now) + 0, hour = 19, min = 0, sec = 0,
            })
            local eveningMins = tonight > now and math.ceil((tonight - now) / 60) or nil

            -- Compute "Until tomorrow" (9 AM next day)
            local tomorrow9 = os.time({
                year = os.date("%Y", now), month = os.date("%m", now) + 0,
                day = os.date("%d", now) + 1, hour = 9, min = 0, sec = 0,
            })
            local tomorrowMins = math.ceil((tomorrow9 - now) / 60)

            local pauseMenu = {
                { title = "30 minutes", fn = function() M.pause(30) end },
                { title = "1 hour",     fn = function() M.pause(60) end },
            }
            if eveningMins then
                table.insert(pauseMenu, { title = "Until this evening", fn = function() M.pause(eveningMins) end })
            end
            table.insert(pauseMenu, { title = "Until tomorrow",    fn = function() M.pause(tomorrowMins) end })

            table.insert(items, {
                title = "Pause",
                menu = pauseMenu,
            })
        end
        return items
    end)

    if not paused then
        timer = hs.timer.doEvery(INTERVAL, captureAndClassify)
        captureAndClassify()
    end
    print("[focus-color] started" .. (paused and " (paused)" or ""))
end

function M.pause(minutes)
    if paused or not timer then return end
    paused = true
    timer:stop()
    if currentTask and currentTask:isRunning() then currentTask:terminate() end

    -- Persist pause state to survive reloads
    writePauseFile(os.time() + minutes * 60)

    -- Show paused state
    if menubar then
        indicator.paused(menubar, COLORS.UNKNOWN)
        local label
        if minutes >= 60 then
            label = "Paused for " .. math.floor(minutes / 60) .. "h"
        else
            label = "Paused for " .. minutes .. "m"
        end
        menubar:setTooltip(label)
    end

    pauseTimer = hs.timer.doAfter(minutes * 60, function()
        M.resume()
    end)
    print("[focus-color] paused for " .. minutes .. "m")
end

function M.resume()
    if not paused then return end
    if pauseTimer then pauseTimer:stop(); pauseTimer = nil end
    paused = false
    clearPauseFile()
    timer = hs.timer.doEvery(INTERVAL, captureAndClassify)
    captureAndClassify()
    print("[focus-color] resumed")
end

function M.stop()
    if pauseTimer then pauseTimer:stop(); pauseTimer = nil end
    paused = false
    clearPauseFile()
    indicator.stopBreathe()
    if timer then timer:stop(); timer = nil end
    if currentTask and currentTask:isRunning() then currentTask:terminate() end
    if menubar then menubar:delete(); menubar = nil end
    print("[focus-color] stopped")
end

M.start()

return M
