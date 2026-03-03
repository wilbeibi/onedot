-- indicator.lua — menubar dot rendering with breathing animation for DISTRACTED state

local indicator = {}

local breatheTimer = nil

local function draw(menubar, color, switchingColor, alpha)
    if not menubar then return end
    alpha = alpha or 1.0
    local c = { red = color.red, green = color.green, blue = color.blue, alpha = alpha }

    local canvas = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
    if switchingColor then
        local fill = { red = switchingColor.red, green = switchingColor.green, blue = switchingColor.blue, alpha = alpha }
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 8,
            fillColor = fill,
            action = "fill",
        })
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 8,
            strokeColor = c,
            strokeWidth = 3,
            action = "stroke",
        })
    else
        canvas:appendElements({
            type = "circle",
            center = { x = 11, y = 11 },
            radius = 6,
            fillColor = c,
            action = "fill",
        })
    end
    menubar:setIcon(canvas:imageFromCanvas(), false)
    canvas:delete()
end

function indicator.stopBreathe()
    if breatheTimer then breatheTimer:stop(); breatheTimer = nil end
end

function indicator.startBreathe(menubar, color, switchingColor)
    indicator.stopBreathe()
    breatheTimer = hs.timer.doEvery(0.1, function()
        local t = hs.timer.secondsSinceEpoch()
        local alpha = 0.3 + 0.7 * (0.5 + 0.5 * math.sin(t * 1.5))
        draw(menubar, color, switchingColor, alpha)
    end)
end

function indicator.solid(menubar, color, switchingColor)
    indicator.stopBreathe()
    draw(menubar, color, switchingColor)
end

function indicator.paused(menubar, color)
    indicator.stopBreathe()
    local canvas = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
    canvas:appendElements({
        type = "circle",
        center = { x = 11, y = 11 },
        radius = 6,
        strokeColor = color,
        strokeWidth = 2,
        action = "stroke",
    })
    menubar:setIcon(canvas:imageFromCanvas(), false)
    canvas:delete()
end

return indicator
