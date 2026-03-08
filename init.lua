local M = {}

local BASE_DIR = debug.getinfo(1, "S").source:match("@(.*/)")

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
local CONFIG_PATH = os.getenv("HOME") .. "/.config/onedot/config.yaml"
local SCREENSHOT_PATH = "/tmp/onedot.png"

-- No YAML library in Hammerspoon; this handles our flat key:value config
local function loadConfig()
    local config = {}
    local f = io.open(CONFIG_PATH, "r")
    if not f then return nil end
    for line in f:lines() do
        if not line:match("^#") and line:match(":") then
            local key, val = line:match("^(%S+):%s*(.+)$")
            if key and val then
                val = val:gsub("%s+#.*$", "")
                val = val:match('^"(.*)"$') or val:match("^'(.*)'$") or val
                config[key] = val
            end
        end
    end
    f:close()
    return config
end

local config = loadConfig()
if not config then
    hs.alert.show("onedot: ~/.config/onedot/config.yaml not found.\nCopy config.yaml.example there and add your Gemini API key.")
    return M
end

local API_KEY = config.api_key or ""
if API_KEY == "" then
    hs.alert.show("onedot: Set api_key in ~/.config/onedot/config.yaml")
    return M
end

if not UV_PATH then
    hs.alert.show("onedot: 'uv' not found.\nInstall it: curl -LsSf https://astral.sh/uv/install.sh | sh")
    return M
end

local MODEL = config.model or "gemini-2.5-flash"
local INTERVAL = tonumber(config.interval_secs) or 30

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

-- Desaturated to avoid menubar dot feeling urgent/distracting
local COLORS = {
    OUTPUT     = { red = 0.24, green = 0.65, blue = 0.42 }, -- muted green
    INPUT      = { red = 0.36, green = 0.64, blue = 0.85 }, -- muted blue
    DISTRACTED = { red = 0.83, green = 0.41, blue = 0.23 }, -- burnt orange
    UNKNOWN    = { red = 0.48, green = 0.48, blue = 0.50 }, -- neutral gray
    ERROR      = { red = 0.55, green = 0.23, blue = 0.23 }, -- muted red
    SWITCHING  = { red = 0.83, green = 0.63, blue = 0.19 }, -- amber
}

local indicator = require("onedot.indicator")
local history = require("onedot.history")
local snooze = require("onedot.snooze")
local JSONL_PATH = os.getenv("HOME") .. "/.config/onedot/log.jsonl"
local HISTORY_MINUTES = 60

local dotImageCache = {}
local function colorDotImage(color)
    if not color then color = COLORS.UNKNOWN end
    local key = string.format("%.2f%.2f%.2f", color.red or 0, color.green or 0, color.blue or 0)
    if dotImageCache[key] then return dotImageCache[key] end
    local size = 12
    local c = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
    c:appendElements({
        type = "circle",
        center = { x = size / 2, y = size / 2 },
        radius = size / 2 - 1,
        fillColor = color,
        action = "fill",
    })
    local img = c:imageFromCanvas()
    c:delete()
    dotImageCache[key] = img
    return img
end

local function logEntry(entry)
    entry.ts = entry.ts or os.date("%Y-%m-%dT%H:%M:%S")
    entry.model = entry.model or MODEL
    local lf = io.open(JSONL_PATH, "a")
    if lf then lf:write(hs.json.encode(entry) .. "\n"); lf:close() end
end

local STATE_FILE = "/tmp/onedot-state"

local menubar = nil
local timer = nil
local currentTask = nil
local pauseTimer = nil
local paused = false

local function readState()
    local f = io.open(STATE_FILE, "r")
    if not f then return {} end
    local raw = f:read("*a")
    f:close()
    return hs.json.decode(raw) or {}
end

local function writeState(tbl)
    local existing = readState()
    for k, v in pairs(tbl) do existing[k] = v end
    local f = io.open(STATE_FILE, "w")
    if not f then return end
    f:write(hs.json.encode(existing))
    f:close()
end

local function clearState(key)
    if key then
        local existing = readState()
        existing[key] = nil
        local f = io.open(STATE_FILE, "w")
        if not f then return end
        f:write(hs.json.encode(existing))
        f:close()
    else
        os.remove(STATE_FILE)
    end
end

local lastResult = { category = "UNKNOWN", reason = "", app = "" }
local switchTimes = {}
local overlaySuppressedUntil = 0
local SWITCH_WINDOW = 600
local SWITCH_THRESHOLD = 5

local function updateIndicator(category, app, reason, switching)
    if not menubar then return end

    local now = os.time()
    if switching then
        table.insert(switchTimes, now)
    end
    local cutoff = now - SWITCH_WINDOW
    while #switchTimes > 0 and switchTimes[1] < cutoff do
        table.remove(switchTimes, 1)
    end

    if #switchTimes >= SWITCH_THRESHOLD and now >= overlaySuppressedUntil then
        local switchMinutes = SWITCH_WINDOW / 60
        local groups = history.switchingSummaryGroups(JSONL_PATH, INTERVAL, switchMinutes)
        if groups then
            if #groups >= SWITCH_THRESHOLD then
                local body = hs.styledtext.new("")
                for i, g in ipairs(groups) do
                    local dotColor = COLORS[g.category] or COLORS.UNKNOWN
                    local dot = hs.styledtext.new("● ", {
                        font = { name = "Menlo", size = 13 },
                        color = dotColor,
                    })
                    local text = hs.styledtext.new(g.text .. " (" .. g.duration .. ")", {
                        font = { name = "Menlo", size = 13 },
                        color = { white = 1, alpha = 0.8 },
                    })
                    body = body .. dot .. text
                    if i < #groups then
                        body = body .. hs.styledtext.new("\n", {
                            font = { name = "Menlo", size = 13 },
                        })
                    end
                end
                snooze.show(
                    "Here's your last " .. math.floor(switchMinutes) .. " minutes",
                    body,
                    function(minutes)
                        local until_time = os.time() + minutes * 60
                        overlaySuppressedUntil = until_time
                        writeState({ snoozeUntil = until_time })
                        logEntry({
                            event = "snooze",
                            minutes = minutes,
                        })
                    end
                )
            end
            overlaySuppressedUntil = math.max(overlaySuppressedUntil, now + 300)
            switchTimes = {}
        end
    end

    lastResult.category = category
    lastResult.app = app or ""
    lastResult.reason = reason or ""
    local color = COLORS[category] or COLORS.UNKNOWN
    local switchingColor = (#switchTimes > 0) and COLORS.SWITCHING or nil

    if category == "DISTRACTED" then
        indicator.startBreathe(menubar, color, switchingColor)
    else
        indicator.solid(menubar, color, switchingColor)
    end

    menubar:setTooltip(lastResult.category == "UNKNOWN" and (lastResult.reason ~= "" and lastResult.reason or "Starting…") or lastResult.app)
end

local function captureAndClassify()
    if currentTask and currentTask:isRunning() then return end

    -- OS-level app name is reliable; don't let the AI guess from screenshot
    local frontApp = hs.application.frontmostApplication()
    local appName = frontApp and frontApp:name() or "Unknown"

    if EXCLUDED_APPS[appName] then
        logEntry({ event = "excluded", category = "EXCLUDED", app = appName, activity = "excluded", reason = "excluded app" })
        updateIndicator("UNKNOWN", appName .. " — excluded", "App excluded from capture", false)
        return
    end

    local win = hs.window.focusedWindow()
    local screen = win and win:screen() or hs.screen.mainScreen()
    local snapshot = screen:snapshot()
    if not snapshot then
        print("[onedot] failed to capture screenshot")
        return
    end
    -- Retina screenshots are 2x+ larger than needed for classification
    local size = snapshot:size()
    local MAX_W = 1536
    if size.w > MAX_W then
        local scale = MAX_W / size.w
        snapshot = snapshot:copy():setSize({ w = MAX_W, h = math.floor(size.h * scale) })
    end
    snapshot:saveToFile(SCREENSHOT_PATH)

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
                        print("[onedot] unknown category: " .. tostring(result.category))
                        updateIndicator("UNKNOWN", appName, "Unknown category: " .. tostring(result.category), false)
                    end
                end
            else
                print("[onedot] error: " .. (stderr or "unknown"))
                updateIndicator("ERROR", nil, "Classification failed", nil)
            end
            currentTask = nil
        end,
        { "run", SCRIPT_PATH, SCREENSHOT_PATH, appName }
    )
    currentTask:setEnvironment({ GEMINI_API_KEY = API_KEY })
    currentTask:start()
end

function M.start()
    if menubar then return end

    menubar = hs.menubar.new()
    updateIndicator("UNKNOWN")

    -- Survive Hammerspoon reloads: restore pause/snooze timers
    local state = readState()
    if state.pauseUntil then
        local now = os.time()
        if state.pauseUntil > now then
            paused = true
            local remaining = state.pauseUntil - now
            indicator.paused(menubar, COLORS.UNKNOWN)
            local mins = math.ceil(remaining / 60)
            if mins >= 60 then
                menubar:setTooltip("Paused for " .. math.floor(mins / 60) .. "h")
            else
                menubar:setTooltip("Paused for " .. mins .. "m")
            end
            pauseTimer = hs.timer.doAfter(remaining, function() M.resume() end)
        else
            clearState("pauseUntil")
        end
    end
    if state.snoozeUntil then
        local now = os.time()
        if state.snoozeUntil > now then
            overlaySuppressedUntil = state.snoozeUntil
        else
            clearState("snoozeUntil")
        end
    end

    menubar:setMenu(function()
        local items = {}
        if lastResult.reason ~= "" then
            -- Menubar menu items don't wrap, so we break manually
            local line = ""
            for word in lastResult.reason:gmatch("%S+") do
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
        local activityItems = history.recentActivity(JSONL_PATH, INTERVAL, HISTORY_MINUTES)
        for _, item in ipairs(activityItems) do
            if item.category then
                item.image = colorDotImage(COLORS[item.category] or COLORS.UNKNOWN)
            end
        end
        table.insert(items, {
            title = "Last " .. HISTORY_MINUTES .. " minutes",
            menu = activityItems,
        })
        table.insert(items, { title = "-" })
        if paused then
            table.insert(items, { title = "Resume", fn = function() M.resume() end })
        else
            local now = os.time()
            local tonight = os.time({
                year = os.date("%Y", now), month = os.date("%m", now) + 0,
                day = os.date("%d", now) + 0, hour = 19, min = 0, sec = 0,
            })
            local eveningMins = tonight > now and math.ceil((tonight - now) / 60) or nil

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
    print("[onedot] started" .. (paused and " (paused)" or ""))
end

function M.pause(minutes)
    if paused or not timer then return end
    paused = true
    timer:stop()
    if currentTask and currentTask:isRunning() then currentTask:terminate() end

    writeState({ pauseUntil = os.time() + minutes * 60 })

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
    print("[onedot] paused for " .. minutes .. "m")
end

function M.resume()
    if not paused then return end
    if pauseTimer then pauseTimer:stop(); pauseTimer = nil end
    paused = false
    clearState("pauseUntil")
    timer = hs.timer.doEvery(INTERVAL, captureAndClassify)
    captureAndClassify()
    print("[onedot] resumed")
end

function M.stop()
    if pauseTimer then pauseTimer:stop(); pauseTimer = nil end
    paused = false
    clearState("pauseUntil")
    indicator.stopBreathe()
    if timer then timer:stop(); timer = nil end
    if currentTask and currentTask:isRunning() then currentTask:terminate() end
    if menubar then menubar:delete(); menubar = nil end
    print("[onedot] stopped")
end

M.start()

return M
