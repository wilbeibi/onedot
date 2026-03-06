-- snooze.lua — lever-style snooze overlay for context-switch popup
-- Self-contained: delete this file and revert snooze.show() in init.lua to remove.

local snooze = {}

local canvas = nil
local escModal = nil
local dragTap = nil
local onSnoozeCallback = nil
local snoozeLevel = 0
local dragging = false
local flashTimer = nil
local lastClickTime = 0

local MAX_LEVEL = 3
local BLOCK_MINUTES = 10
local FLASH_PAUSE = 0.3       -- delay after release before flash starts
local FLASH_INTERVAL = 0.2    -- time between each flash step
local DBLCLICK_TIME = 0.35    -- double-click window

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
    if flashTimer then flashTimer:stop(); flashTimer = nil end
    if dragTap then dragTap:stop(); dragTap = nil end
    if escModal then escModal:exit(); escModal = nil end
    if canvas then canvas:delete(); canvas = nil end
    snoozeLevel = 0
    dragging = false
    lastClickTime = 0
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

    local hint = snoozeLevel == 0
        and "drag to snooze · click outside to dismiss"
        or "drag to adjust · double-click to confirm"
    canvas["hint"].text = hs.styledtext.new(hint, {
        font = { name = "Menlo", size = 10 },
        color = { white = 1, alpha = 0.35 },
        paragraphStyle = { alignment = "center" },
    })
end

-- Instant confirm (for double-click)
local function confirmNow()
    if flashTimer then flashTimer:stop(); flashTimer = nil end
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

-- Progressive flash: 3 steps of increasing brightness, then confirm
local function startFlash()
    if flashTimer then flashTimer:stop() end
    local step = 0
    local alphas = { 0.65, 0.8, 1.0 }

    flashTimer = hs.timer.doAfter(FLASH_PAUSE, function()
        local function nextStep()
            step = step + 1
            if step > #alphas then
                confirmNow()
                return
            end
            updateBar(alphas[step])
            flashTimer = hs.timer.doAfter(FLASH_INTERVAL, nextStep)
        end
        nextStep()
    end)
end

local function stopFlash()
    if flashTimer then flashTimer:stop(); flashTimer = nil end
    updateBar()
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
                        startFlash()
                    else
                        dismiss()
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

function snooze.show(text, onSnooze)
    cleanup()
    onSnoozeCallback = onSnooze
    snoozeLevel = 0

    local screen = hs.screen.mainScreen():frame()
    local padding = 28
    local lineHeight = 18
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    local textH = #lines * lineHeight
    local hintH = 14
    local w = 520
    local h = padding + textH + padding + BAR_H + 12 + hintH + padding / 2

    canvasX = screen.x + (screen.w - w) / 2
    canvasY = screen.y + (screen.h - h) / 2
    barX = (w - BAR_W) / 2
    barY = padding + textH + padding

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

    -- Activity text
    canvas:appendElements({
        id = "text",
        type = "text",
        frame = { x = padding, y = padding, w = w - padding * 2, h = textH },
        text = hs.styledtext.new(text, {
            font = { name = "Menlo", size = 13 },
            color = { white = 1, alpha = 0.95 },
            paragraphStyle = { lineSpacing = 4 },
        }),
    })

    -- Bar track (empty outline)
    canvas:appendElements({
        id = "track",
        type = "rectangle",
        frame = { x = barX, y = barY, w = BAR_W, h = BAR_H },
        roundedRectRadii = { xRadius = BAR_RADIUS, yRadius = BAR_RADIUS },
        strokeColor = { white = 1, alpha = 0.15 },
        fillColor = { white = 0, alpha = 0 },
        action = "stroke",
        strokeWidth = 1,
    })

    -- Tick marks at segment boundaries
    local segW = BAR_W / MAX_LEVEL
    for i = 1, MAX_LEVEL - 1 do
        canvas:appendElements({
            id = "tick" .. i,
            type = "segments",
            coordinates = {
                { x = barX + segW * i, y = barY + 4 },
                { x = barX + segW * i, y = barY + BAR_H - 4 },
            },
            strokeColor = { white = 1, alpha = 0.1 },
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
        text = hs.styledtext.new("drag to snooze · click outside to dismiss", {
            font = { name = "Menlo", size = 10 },
            color = { white = 1, alpha = 0.35 },
            paragraphStyle = { alignment = "center" },
        }),
    })

    -- Canvas handles mouseDown and mouseUp; drag tracked via eventtap
    canvas:mouseCallback(function(_, event, _, mx, my)
        if event == "mouseDown" then
            local now = hs.timer.secondsSinceEpoch()
            if snoozeLevel > 0 and (now - lastClickTime) < DBLCLICK_TIME then
                confirmNow()
                return
            end
            lastClickTime = now

            if inBar(mx, my) then
                dragging = true
                stopFlash()
                snoozeLevel = math.max(1, snapLevel(mx))
                updateBar()
                startDragTap()
            else
                if snoozeLevel == 0 then
                    dismiss()
                end
            end

        -- mouseUp handled by eventtap (works even if released outside canvas)
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
