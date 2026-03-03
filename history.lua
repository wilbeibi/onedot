local H = {}

local function parseISO(ts)
    local y, mo, d, hr, mi, s = ts:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                     hour = tonumber(hr), min = tonumber(mi), sec = tonumber(s) })
end

function H.recentActivity(jsonl_path, interval, minutes)
    local f = io.open(jsonl_path, "r")
    if not f then return {{ title = "No log data yet", disabled = true }} end

    -- Read tail of file (~32KB covers 20 min easily)
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
                table.insert(entries, { app = entry.app })
            end
        end
    end
    f:close()

    if #entries == 0 then return {{ title = "No recent activity", disabled = true }} end

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

return H
