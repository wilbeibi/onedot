-- overlay.lua — click-to-dismiss context switching overlay using hs.canvas

local overlay = {}

local canvas = nil
local escModal = nil
local onDismissCallback = nil

local function dismiss()
    if escModal then escModal:exit(); escModal = nil end
    if canvas then canvas:delete(); canvas = nil end
    if onDismissCallback then
        local cb = onDismissCallback
        onDismissCallback = nil
        cb()
    end
end

function overlay.show(text, onDismiss)
    -- Only one overlay at a time
    dismiss()
    onDismissCallback = onDismiss

    local win = hs.window.focusedWindow()
    local screen = (win and win:screen() or hs.screen.mainScreen()):frame()
    local padding = 28
    local lineHeight = 18
    local charsPerLine = 58  -- Menlo 13 in 520px - padding
    local visualLines = 0
    for line in text:gmatch("[^\n]+") do
        local len = utf8.len(line) or #line
        visualLines = visualLines + math.max(1, math.ceil(len / charsPerLine))
    end
    local textH = visualLines * lineHeight
    local hintH = 14
    local w = 520
    local h = padding + textH + padding + hintH + padding / 2

    local x = screen.x + (screen.w - w) / 2
    local y = screen.y + (screen.h - h) / 2

    canvas = hs.canvas.new({ x = x, y = y, w = w, h = h })
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })

    -- Background
    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = w, h = h },
        roundedRectRadii = { xRadius = 12, yRadius = 12 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.70 },
        action = "fill",
    })

    -- Text
    canvas:appendElements({
        type = "text",
        frame = { x = padding, y = padding, w = w - padding * 2, h = textH },
        text = hs.styledtext.new(text, {
            font = { name = "Menlo", size = 13 },
            color = { white = 1, alpha = 0.95 },
            paragraphStyle = { lineSpacing = 4 },
        }),
    })

    -- Hint
    canvas:appendElements({
        type = "text",
        frame = { x = padding, y = padding + textH + padding, w = w - padding * 2, h = hintH },
        text = hs.styledtext.new("click or esc to dismiss", {
            font = { name = "Menlo", size = 10 },
            color = { white = 1, alpha = 0.35 },
            paragraphStyle = { alignment = "center" },
        }),
    })

    -- Click to dismiss
    canvas:mouseCallback(function() dismiss() end)
    canvas:canvasMouseEvents(true, false, false, false)

    canvas:show()

    -- Escape to dismiss
    escModal = hs.hotkey.modal.new()
    escModal:bind("", "escape", function() dismiss() end)
    escModal:enter()
end

function overlay.dismiss()
    dismiss()
end

return overlay
