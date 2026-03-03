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

local api_key_raw = config.api_key or ""
local API_KEY = os.getenv(api_key_raw) or api_key_raw
if API_KEY == "" then
    hs.alert.show("focus-color: Set api_key in config.yaml (env var name or raw key)")
    return M
end

if not UV_PATH then
    hs.alert.show("focus-color: 'uv' not found.\nInstall it: curl -LsSf https://astral.sh/uv/install.sh | sh")
    return M
end

local MODEL = config.model or "gemini-2.5-flash"
local INTERVAL = tonumber(config.interval) or 30

-- Desaturated palette — no halation on dark menubar, semantic amber for distracted
local COLORS = {
    OUTPUT     = { red = 0.20, green = 0.65, blue = 0.35 }, -- emerald green
    INPUT      = { red = 0.40, green = 0.70, blue = 0.95 }, -- lighter sky blue
    DISTRACTED = { red = 0.85, green = 0.40, blue = 0.20 }, -- burnt orange (warning, not error)
    UNKNOWN    = { red = 0.55, green = 0.55, blue = 0.55 }, -- mid gray
}

local history = require("focus-color.history")
local JSONL_PATH = os.getenv("HOME") .. "/.config/focus-color/log.jsonl"
local HISTORY_MINUTES = 60

local menubar = nil
local timer = nil
local currentTask = nil
local pauseTimer = nil
local paused = false

local lastCategory = "UNKNOWN"
local lastReason = ""
local lastApp = ""
local lastSwitching = false
local prevCategory = "UNKNOWN"  -- category before current streak
local streakCount = 0
local STREAK_THRESHOLD = 3      -- ticks before showing popup

local function updateDot(category, app, reason, switching)
    if not menubar then return end

    -- Debounced context-switch popup
    if category == lastCategory then
        streakCount = streakCount + 1
    else
        prevCategory = lastCategory
        streakCount = 1
    end
    if streakCount == STREAK_THRESHOLD and prevCategory ~= "UNKNOWN" and category ~= prevCategory then
        hs.alert.show(app or category, 3)
    end

    lastCategory = category
    lastApp = app or ""
    lastReason = reason or ""
    lastSwitching = switching or false
    local color = COLORS[category] or COLORS.UNKNOWN

    local SWITCHING_FILL = { red = 0.90, green = 0.65, blue = 0.15 } -- amber warning
    local canvas = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
    if lastSwitching then
        -- Amber filled dot + category ring = switching with warning vibe
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 8,
            fillColor = SWITCHING_FILL,
            action = "fill",
        })
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 8,
            strokeColor = color,
            strokeWidth = 3,
            action = "stroke",
        })
    else
        -- Solid dot = sustained focus
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 6,
            fillColor = color,
            action = "fill",
        })
    end
    menubar:setIcon(canvas:imageFromCanvas(), false)
    canvas:delete()

    menubar:setTooltip(lastApp)
end

local function captureAndClassify()
    if currentTask and currentTask:isRunning() then return end

    -- Hammerspoon captures screenshot (has Screen Recording permission)
    local screen = hs.screen.mainScreen()
    local snapshot = screen:snapshot()
    if not snapshot then
        print("[focus-color] failed to capture screenshot")
        return
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
                        updateDot(result.category, result.active_app, result.reason, result.switching)
                    else
                        print("[focus-color] unknown category: " .. tostring(result.category))
                    end
                end
            else
                print("[focus-color] error: " .. (stderr or "unknown"))
            end
            currentTask = nil
        end,
        { "run", SCRIPT_PATH, SCREENSHOT_PATH }
    )
    currentTask:setEnvironment({ GEMINI_API_KEY = API_KEY, MODEL = MODEL })
    currentTask:start()
end

function M.start()
    if menubar then return end

    menubar = hs.menubar.new()
    updateDot("UNKNOWN")

    menubar:setMenu(function()
        local items = {}
        if lastReason ~= "" then
            -- Word-wrap reason into ~40-char lines
            local line = ""
            for word in lastReason:gmatch("%S+") do
                if #line + #word + 1 > 40 and #line > 0 then
                    table.insert(items, { title = line, disabled = true })
                    line = word
                else
                    line = #line > 0 and (line .. " " .. word) or word
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
            table.insert(items, {
                title = "Pause",
                menu = {
                    { title = "10 minutes", fn = function() M.pause(10) end },
                    { title = "30 minutes", fn = function() M.pause(30) end },
                    { title = "1 hour",     fn = function() M.pause(60) end },
                    { title = "-" },
                    { title = "Forever",    fn = function() M.pause(nil) end },
                },
            })
        end
        return items
    end)

    timer = hs.timer.doEvery(INTERVAL, captureAndClassify)
    captureAndClassify()
    print("[focus-color] started")
end

function M.pause(minutes)
    if paused or not timer then return end
    paused = true
    timer:stop()
    if currentTask and currentTask:isRunning() then currentTask:terminate() end

    -- Show paused state
    if menubar then
        local canvas = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 6,
            strokeColor = COLORS.UNKNOWN,
            strokeWidth = 2,
            action = "stroke",
        })
        menubar:setIcon(canvas:imageFromCanvas(), false)
        canvas:delete()
        menubar:setTooltip(minutes and ("Paused for " .. minutes .. "m") or "Paused")
    end

    if minutes then
        pauseTimer = hs.timer.doAfter(minutes * 60, function()
            M.resume()
        end)
    end
    print("[focus-color] paused" .. (minutes and (" for " .. minutes .. "m") or ""))
end

function M.resume()
    if not paused then return end
    if pauseTimer then pauseTimer:stop(); pauseTimer = nil end
    paused = false
    timer = hs.timer.doEvery(INTERVAL, captureAndClassify)
    captureAndClassify()
    print("[focus-color] resumed")
end

function M.stop()
    if pauseTimer then pauseTimer:stop(); pauseTimer = nil end
    paused = false
    if timer then timer:stop(); timer = nil end
    if currentTask and currentTask:isRunning() then currentTask:terminate() end
    if menubar then menubar:delete(); menubar = nil end
    print("[focus-color] stopped")
end

M.start()

return M
