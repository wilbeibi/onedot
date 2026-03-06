-- snooze.lua — lever-style snooze overlay for context-switch popup
-- Self-contained: delete this file and revert snooze.show() in init.lua to remove.

local snooze = {}

local canvas = nil
local escModal = nil
local dragTap = nil
local onSnoozeCallback = nil
local snoozeLevel = 0
local dragging = false

local MAX_LEVEL = 3
local BLOCK_MINUTES = 10

-- Bar layout
local BAR_W = 200
local BAR_H = 20
local BAR_RADIUS = 6
local BAR_HIT_PAD = 12        -- extra px around bar for hit testing

-- Canvas-local bar geometry (set during show())
local barX, barY = 0, 0
-- Canvas absolute origin (for converting global mouse coords to local)
local canvasX, canvasY = 0, 0

local function cleanup()
    if dragTap then dragTap:stop(); dragTap = nil end
    if escModal then escModal:exit(); escModal = nil end
    if canvas then canvas:delete(); canvas = nil end
    snoozeLevel = 0
    dragging = false
end

local function dismiss()
    cleanup()
    onSnoozeCallback = nil
end

-- Map canvas-local X to nearest snap level (0..MAX_LEVEL)
local function snapLevel(localX)
    local rel = (localX - barX) / BAR_W
    rel = math.max(0, math.min(1, rel))
    return math.floor(rel * MAX_LEVEL + 0.5)
end

-- Redraw fill bar, label, and hint for current snoozeLevel
local function updateBar(alpha)
    if not canvas then return end
    alpha = alpha or 0.55
    local fillW = (snoozeLevel / MAX_LEVEL) * BAR_W

    canvas["fill"].frame = { x = barX, y = barY, w = math.max(0, fillW), h = BAR_H }
    canvas["fill"].fillColor = { white = 1, alpha = snoozeLevel > 0 and alpha or 0 }

    if snoozeLevel > 0 then
        canvas["label"].frame = { x = barX, y = barY, w = fillW, h = BAR_H }
        canvas["label"].text = hs.styledtext.new(snoozeLevel * BLOCK_MINUTES .. "m", {
            font = { name = "Menlo-Bold", size = 11 },
            color = { white = 0.1, alpha = 0.9 },
            paragraphStyle = { alignment = "center" },
        })
    else
        canvas["label"].text = hs.styledtext.new("", {
            font = { name = "Menlo-Bold", size = 11 },
            color = { white = 0, alpha = 0 },
            paragraphStyle = { alignment = "center" },
        })
    end

    local hint
    if dragging and snoozeLevel > 0 then
        hint = "release to snooze " .. snoozeLevel * BLOCK_MINUTES .. "m"
    elseif dragging then
        hint = "release to cancel · drag right to snooze"
    else
        hint = "drag to snooze · click background or esc to dismiss"
    end
    canvas["hint"].text = hs.styledtext.new(hint, {
        font = { name = "Menlo", size = 10 },
        color = { white = 1, alpha = 0.45 },
        paragraphStyle = { alignment = "center" },
    })
end

local function confirmNow()
    local minutes = snoozeLevel * BLOCK_MINUTES
    if minutes == 0 then dismiss(); return end
    local cb = onSnoozeCallback
    onSnoozeCallback = nil
    updateBar(1.0)
    hs.timer.doAfter(0.1, function()
        cleanup()
        if cb then cb(minutes) end
    end)
end

-- Global eventtap: tracks drag even if mouse leaves canvas,
-- and catches mouseUp outside canvas to finalize the interaction
local function startDragTap()
    if dragTap then dragTap:stop() end
    dragTap = hs.eventtap.new(
        { hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp },
        function(ev)
            if not canvas then return false end
            local evType = ev:getType()
            if evType == hs.eventtap.event.types.leftMouseDragged then
                if not dragging then return false end
                local pos = hs.mouse.absolutePosition()
                local localX = pos.x - canvasX
                local newLevel = snapLevel(localX)
                if newLevel ~= snoozeLevel then
                    snoozeLevel = newLevel
                    updateBar()
                end
            elseif evType == hs.eventtap.event.types.leftMouseUp then
                if dragging then
                    dragging = false
                    stopDragTap()
                    if snoozeLevel > 0 then
                        confirmNow()
                    else
                        -- Dragged back to 0 = cancel
                        snoozeLevel = 0
                        updateBar()
                    end
                end
            end
            return false
        end
    )
    dragTap:start()
end

local function stopDragTap()
    if dragTap then dragTap:stop(); dragTap = nil end
end

local function inBar(mx, my)
    return mx >= (barX - BAR_HIT_PAD) and mx <= (barX + BAR_W + BAR_HIT_PAD)
       and my >= (barY - BAR_HIT_PAD) and my <= (barY + BAR_H + BAR_HIT_PAD)
end

function snooze.show(title, body, onSnooze)
    cleanup()
    onSnoozeCallback = onSnooze
    snoozeLevel = 0

    local win = hs.window.focusedWindow()
    local screen = (win and win:screen() or hs.screen.mainScreen()):frame()
    local padding = 28
    local lineHeight = 18
    local charsPerLine = 58  -- Menlo 13 in 520px - padding

    -- Title height
    local titleLines = 0
    for line in title:gmatch("[^\n]+") do
        local len = utf8.len(line) or #line
        titleLines = titleLines + math.max(1, math.ceil(len / charsPerLine))
    end
    local titleH = titleLines * 22  -- larger line height for title

    -- Body height
    local bodyLines = 0
    for line in body:gmatch("[^\n]+") do
        local len = utf8.len(line) or #line
        bodyLines = bodyLines + math.max(1, math.ceil(len / charsPerLine))
    end
    local bodyH = bodyLines * lineHeight

    local textH = titleH + 8 + bodyH  -- 8px gap between title and body
    local hintH = 14
    local LABEL_H = 14
    local w = 520
    local h = padding + textH + 16 + LABEL_H + 4 + BAR_H + 12 + hintH + padding / 2

    canvasX = screen.x + (screen.w - w) / 2
    canvasY = screen.y + (screen.h - h) / 2
    barX = (w - BAR_W) / 2
    barY = padding + textH + 16 + LABEL_H + 4

    canvas = hs.canvas.new({ x = canvasX, y = canvasY, w = w, h = h })
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })

    -- Background
    canvas:appendElements({
        id = "bg",
        type = "rectangle",
        frame = { x = 0, y = 0, w = w, h = h },
        roundedRectRadii = { xRadius = 12, yRadius = 12 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 },
        action = "fill",
    })

    -- Title text (bold, larger)
    canvas:appendElements({
        id = "title",
        type = "text",
        frame = { x = padding, y = padding, w = w - padding * 2, h = titleH },
        text = hs.styledtext.new(title, {
            font = { name = "Menlo-Bold", size = 14 },
            color = { white = 1, alpha = 0.95 },
            paragraphStyle = { lineSpacing = 4 },
        }),
    })

    -- Body text
    canvas:appendElements({
        id = "text",
        type = "text",
        frame = { x = padding, y = padding + titleH + 8, w = w - padding * 2, h = bodyH },
        text = hs.styledtext.new(body, {
            font = { name = "Menlo", size = 13 },
            color = { white = 1, alpha = 0.8 },
            paragraphStyle = { lineSpacing = 4 },
        }),
    })

    -- Segment labels (10m, 20m, 30m) above the bar
    local segW = BAR_W / MAX_LEVEL
    local labelY = barY - LABEL_H - 2
    for i = 1, MAX_LEVEL do
        canvas:appendElements({
            id = "seg" .. i,
            type = "text",
            frame = { x = barX + segW * (i - 1), y = labelY, w = segW, h = LABEL_H },
            text = hs.styledtext.new(i * BLOCK_MINUTES .. "m", {
                font = { name = "Menlo", size = 10 },
                color = { white = 1, alpha = 0.4 },
                paragraphStyle = { alignment = "center" },
            }),
        })
    end

    -- Bar track (empty outline)
    canvas:appendElements({
        id = "track",
        type = "rectangle",
        frame = { x = barX, y = barY, w = BAR_W, h = BAR_H },
        roundedRectRadii = { xRadius = BAR_RADIUS, yRadius = BAR_RADIUS },
        strokeColor = { white = 1, alpha = 0.25 },
        fillColor = { white = 0, alpha = 0 },
        action = "stroke",
        strokeWidth = 1,
    })

    -- Tick marks at segment boundaries
    for i = 1, MAX_LEVEL - 1 do
        canvas:appendElements({
            id = "tick" .. i,
            type = "segments",
            coordinates = {
                { x = barX + segW * i, y = barY + 4 },
                { x = barX + segW * i, y = barY + BAR_H - 4 },
            },
            strokeColor = { white = 1, alpha = 0.2 },
            action = "stroke",
            strokeWidth = 1,
        })
    end

    -- Bar fill
    canvas:appendElements({
        id = "fill",
        type = "rectangle",
        frame = { x = barX, y = barY, w = 0, h = BAR_H },
        roundedRectRadii = { xRadius = BAR_RADIUS, yRadius = BAR_RADIUS },
        fillColor = { white = 1, alpha = 0 },
        action = "fill",
    })

    -- Time label (inside filled portion)
    canvas:appendElements({
        id = "label",
        type = "text",
        frame = { x = barX, y = barY, w = 0, h = BAR_H },
        text = hs.styledtext.new("", {
            font = { name = "Menlo-Bold", size = 11 },
            color = { white = 0, alpha = 0 },
            paragraphStyle = { alignment = "center" },
        }),
    })

    -- Hint text
    canvas:appendElements({
        id = "hint",
        type = "text",
        frame = { x = padding, y = barY + BAR_H + 8, w = w - padding * 2, h = hintH },
        text = hs.styledtext.new("drag to snooze · click background or esc to dismiss", {
            font = { name = "Menlo", size = 10 },
            color = { white = 1, alpha = 0.45 },
            paragraphStyle = { alignment = "center" },
        }),
    })

    -- Canvas handles mouseDown and mouseUp; drag tracked via eventtap
    canvas:mouseCallback(function(_, event, _, mx, my)
        if event == "mouseDown" then
            if inBar(mx, my) then
                dragging = true
                snoozeLevel = snapLevel(mx)
                updateBar()
                startDragTap()
            else
                dismiss()
            end
        end
    end)
    canvas:canvasMouseEvents(true, false, false, false)

    canvas:show()

    -- Escape to dismiss
    escModal = hs.hotkey.modal.new()
    escModal:bind("", "escape", function() dismiss() end)
    escModal:enter()
end

function snooze.dismiss()
    dismiss()
end

return snooze
