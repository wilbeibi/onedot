local M = {}

-- Paths
local BASE_DIR = os.getenv("HOME") .. "/.hammerspoon/focus-color"
local UV_PATH = "/opt/homebrew/bin/uv"
local SCRIPT_PATH = BASE_DIR .. "/classify.py"
local CONFIG_PATH = BASE_DIR .. "/config.yaml"
local SCREENSHOT_PATH = "/tmp/focus-color.png"

-- Parse simple YAML (key: value, one per line)
local function loadConfig()
    local config = {}
    local f = io.open(CONFIG_PATH, "r")
    if not f then
        print("[focus-color] config.yaml not found")
        return config
    end
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
local API_KEY = config.api_key or ""
local INTERVAL = tonumber(config.interval) or 30

-- Colors: green/blue/red for output/input/distracted
local COLORS = {
    OUTPUT     = { red = 0.2, green = 0.9, blue = 0.3 },  -- vivid lime, pops on blue bg
    INPUT      = { red = 0.3, green = 0.85, blue = 1.0 }, -- cyan/sky, distinct from dark blue bg
    DISTRACTED = { red = 1.0, green = 0.25, blue = 0.25 }, -- bright red
    UNKNOWN    = { red = 0.6, green = 0.6, blue = 0.6 },  -- light gray
}

local menubar = nil
local timer = nil
local currentTask = nil
local RING_COLOR = { red = 1.0, green = 0.85, blue = 0.0 }  -- yellow

local lastCategory = "UNKNOWN"
local lastReason = ""
local lastApp = ""
local lastSwitching = false

local function updateDot(category, app, reason, switching)
    if not menubar then return end
    lastCategory = category
    lastApp = app or ""
    lastReason = reason or ""
    lastSwitching = switching or false
    local color = COLORS[category] or COLORS.UNKNOWN

    local canvas = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
    if lastSwitching then
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 9,
            fillColor = RING_COLOR,
            action = "fill",
        })
    end
    canvas:appendElements({
        type = "circle",
        center = { x = 11, y = 11 },
        radius = 6,
        fillColor = color,
        action = "fill",
    })
    menubar:setIcon(canvas:imageFromCanvas(), false)
    canvas:delete()

    local tip = category .. " — " .. lastApp .. "\n" .. lastReason
    if lastSwitching then tip = tip .. "\n⚡ switching frequently" end
    menubar:setTooltip(tip)
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
    currentTask:setEnvironment({ GEMINI_API_KEY = API_KEY })
    currentTask:start()
end

function M.start()
    if menubar then return end

    menubar = hs.menubar.new()
    updateDot("UNKNOWN")

    menubar:setMenu(function()
        return {
            { title = "Focus Color", disabled = true },
            { title = lastCategory .. " — " .. lastApp, disabled = true },
            { title = lastReason, disabled = true },
            { title = "-" },
            { title = "Stop", fn = function() M.stop() end },
        }
    end)

    timer = hs.timer.doEvery(INTERVAL, captureAndClassify)
    captureAndClassify()
    print("[focus-color] started")
end

function M.stop()
    if timer then timer:stop(); timer = nil end
    if currentTask and currentTask:isRunning() then currentTask:terminate() end
    if menubar then menubar:delete(); menubar = nil end
    print("[focus-color] stopped")
end

M.start()

return M
