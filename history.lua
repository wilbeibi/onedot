local H = {}

-- UTF-8-safe truncation using Lua's built-in utf8 library
local function utf8_trunc(s, max_chars)
    if utf8.len(s) and utf8.len(s) <= max_chars then return s end
    local pos = utf8.offset(s, max_chars + 1)
    if not pos then return s end
    return s:sub(1, pos - 1) .. "…"
end

local function parseISO(ts)
    local y, mo, d, hr, mi, s = ts:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                     hour = tonumber(hr), min = tonumber(mi), sec = tonumber(s) })
end

local function readRecentEntries(jsonl_path, minutes)
    local f = io.open(jsonl_path, "r")
    if not f then return nil end

    local size = f:seek("end")
    local tail_bytes = 32 * 1024
    if size > tail_bytes then
        f:seek("set", size - tail_bytes)
        f:read("*l") -- skip partial line
    else
        f:seek("set", 0)
    end

    local cutoff = os.time() - minutes * 60
    local entries = {}
    for line in f:lines() do
        local ok, entry = pcall(hs.json.decode, line)
        if ok and entry and entry.ts and entry.app then
            local t = parseISO(entry.ts)
            if t and t >= cutoff then
                table.insert(entries, { app = entry.app, activity = entry.activity or entry.context, switching = entry.switching, time = t })
            end
        end
    end
    f:close()

    if #entries == 0 then return nil end
    return entries
end

function H.recentActivity(jsonl_path, interval, minutes)
    local entries = readRecentEntries(jsonl_path, minutes)
    if not entries then return {{ title = "No log data yet", disabled = true }} end

    -- Group consecutive same-app entries
    local groups = {}
    local cur = { app = entries[1].app, context = entries[1].activity, ticks = 1 }
    for i = 2, #entries do
        if entries[i].app == cur.app then
            cur.ticks = cur.ticks + 1
            if entries[i].activity then cur.activity = entries[i].activity end
        else
            table.insert(groups, cur)
            cur = { app = entries[i].app, context = entries[i].activity, ticks = 1 }
        end
    end
    table.insert(groups, cur)

    local items = {}
    for _, g in ipairs(groups) do
        local mins = math.max(1, math.floor(g.ticks * interval / 60 + 0.5))
        local display = g.app
        if g.activity and g.activity ~= "" then
            display = display .. " — " .. g.activity
        end
        display = utf8_trunc(display, 55)
        table.insert(items, { title = display .. " (" .. mins .. "m)", disabled = true })
    end
    return items
end

function H.switchingSummary(jsonl_path, interval, minutes)
    local entries = readRecentEntries(jsonl_path, minutes)
    if not entries then return nil end

    -- Group consecutive same-app entries (like recentActivity)
    local groups = {}
    local cur = { app = entries[1].app, activity = entries[1].activity, ticks = 1 }
    for i = 2, #entries do
        if entries[i].app == cur.app then
            cur.ticks = cur.ticks + 1
            if entries[i].activity then cur.activity = entries[i].activity end
        else
            table.insert(groups, cur)
            cur = { app = entries[i].app, activity = entries[i].activity, ticks = 1 }
        end
    end
    table.insert(groups, cur)

    local lines = {}
    for _, g in ipairs(groups) do
        local mins = math.max(1, math.floor(g.ticks * interval / 60 + 0.5))
        local text = g.activity or "idle"
        local bullet = "• " .. text .. " (" .. mins .. "m)"
        table.insert(lines, utf8_trunc(bullet, 60))
    end
    return table.concat(lines, "\n")
end

return H
