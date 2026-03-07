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

local function formatDuration(ticks, interval)
    local secs = ticks * interval
    if secs < 60 then return secs .. "s" end
    return math.floor(secs / 60 + 0.5) .. "m"
end

local function readRecentEntries(jsonl_path, minutes)
    local f = io.open(jsonl_path, "r")
    if not f then return nil end

    local size = f:seek("end")
    local tail_bytes = 64 * 1024
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
        if ok and entry and entry.ts and entry.app and entry.event ~= "excluded" then
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

    -- Aggregate total ticks per activity
    local totals = {}
    local order = {}
    for _, e in ipairs(entries) do
        local text = e.activity or "idle"
        if not totals[text] then
            totals[text] = 0
            table.insert(order, text)
        end
        totals[text] = totals[text] + 1
    end

    -- Sort by duration descending
    table.sort(order, function(a, b) return totals[a] > totals[b] end)

    local items = {}
    for _, text in ipairs(order) do
        local dur = formatDuration(totals[text], interval)
        local display = utf8_trunc(text, 55)
        table.insert(items, { title = display .. " (" .. dur .. ")", disabled = true })
    end
    return items
end

function H.switchingSummary(jsonl_path, interval, minutes)
    local entries = readRecentEntries(jsonl_path, minutes)
    if not entries then return nil end

    -- Group consecutive same-activity entries
    local groups = {}
    local cur = { text = entries[1].activity or "idle", ticks = 1 }
    for i = 2, #entries do
        local text = entries[i].activity or "idle"
        if text == cur.text then
            cur.ticks = cur.ticks + 1
        else
            table.insert(groups, cur)
            cur = { text = text, ticks = 1 }
        end
    end
    table.insert(groups, cur)

    local lines = {}
    for _, g in ipairs(groups) do
        local dur = formatDuration(g.ticks, interval)
        local bullet = "• " .. g.text .. " (" .. dur .. ")"
        table.insert(lines, bullet)
    end
    return table.concat(lines, "\n")
end

return H
