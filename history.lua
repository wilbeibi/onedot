local H = {}

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
                table.insert(entries, { app = entry.app, time = t })
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
    local cur = { app = entries[1].app, ticks = 1 }
    for i = 2, #entries do
        if entries[i].app == cur.app then
            cur.ticks = cur.ticks + 1
        else
            table.insert(groups, cur)
            cur = { app = entries[i].app, ticks = 1 }
        end
    end
    table.insert(groups, cur)

    local items = {}
    for _, g in ipairs(groups) do
        local mins = math.max(1, math.floor(g.ticks * interval / 60 + 0.5))
        local app = g.app
        if #app > 45 then app = app:sub(1, 42) .. "..." end
        table.insert(items, { title = app .. " (" .. mins .. "m)", disabled = true })
    end
    return items
end

function H.switchingSummary(jsonl_path, minutes)
    local entries = readRecentEntries(jsonl_path, minutes)
    if not entries then return nil end

    -- Deduplicate consecutive, keep first timestamp of each stretch
    local trail = { entries[1] }
    for i = 2, #entries do
        if entries[i].app ~= entries[i - 1].app then
            table.insert(trail, entries[i])
        end
    end

    -- Show last N transitions
    local max_lines = 6
    local start = math.max(1, #trail - max_lines + 1)
    local lines = {}
    for i = start, #trail do
        local app = trail[i].app
        local ts = os.date("%H:%M", trail[i].time)
        if #app > 40 then
            table.insert(lines, ts .. "  → " .. app:sub(1, 40))
            table.insert(lines, "        " .. app:sub(41))
        else
            table.insert(lines, ts .. "  → " .. app)
        end
    end
    return table.concat(lines, "\n")
end

return H
