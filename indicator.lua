local indicator = {}

local breatheTimer = nil

local function draw(menubar, color, switchingColor, alpha)
    if not menubar then return end
    alpha = alpha or 1.0
    local c = { red = color.red, green = color.green, blue = color.blue, alpha = alpha }

    local canvas = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
    if switchingColor then
        local sc = { red = switchingColor.red, green = switchingColor.green, blue = switchingColor.blue, alpha = alpha }
        local cx, cy, r = 11, 11, 6
        -- Two-tone dot: category + switching color at a glance
        local function semicircle(startAngle, sweep)
            local pts = {}
            local steps = 20
            for i = 0, steps do
                local angle = startAngle + (sweep * i / steps)
                table.insert(pts, { x = cx + r * math.cos(angle), y = cy + r * math.sin(angle) })
            end
            return pts
        end
        canvas:appendElements({
            type = "segments",
            closed = true,
            action = "fill",
            fillColor = c,
            coordinates = semicircle(-math.pi/2, -math.pi),
        })
        canvas:appendElements({
            type = "segments",
            closed = true,
            action = "fill",
            fillColor = sc,
            coordinates = semicircle(-math.pi/2, math.pi),
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
