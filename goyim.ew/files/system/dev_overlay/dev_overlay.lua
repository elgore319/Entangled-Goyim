-- Dev mode: a small stats panel in a bottom corner of the screen, for finding
-- out where lag comes from. Toggled with the "dev overlay" mod setting or its
-- hotkey (F3 by default). While it is shown, every hook call is timed (see
-- ctx.add_hook) and the proxy sends network numbers once per second.
--
-- Frames that take longer than SPIKE_MS are also written to the log as
-- "[dev] lag spike ..." lines with position, biome and the slowest systems.

local module = {}

local SPIKE_MS = 50
local WINDOW = 1 -- seconds per stats window

local gui = GuiCreate()

local enabled = false
local proxy_told = nil

-- Current window, reset every WINDOW seconds.
local win = nil
-- Numbers from the last finished window; what the panel shows.
local shown = nil
-- Latest `dev_stats` message from the proxy.
local proxy_stats = nil
local proxy_stats_time = 0
local last_spike = nil
local last_spike_log = -100

local last_frame_time = nil
local frame_mod_time = 0

local function now()
    return GameGetRealWorldTimeSinceStarted()
end

local function new_window()
    return {
        start = now(),
        frames = 0,
        frame_sum = 0,
        frame_max = 0,
        mod_sum = 0,
        mod_max = 0,
        new_entities = 0,
        net = { sent_msgs = net.stats.sent_msgs, sent_bytes = net.stats.sent_bytes,
            recv_msgs = net.stats.recv_msgs, recv_bytes = net.stats.recv_bytes },
    }
end

local function set_enabled(value)
    enabled = value
    if enabled then
        ctx.dev = { hooks = {}, frame_hooks = {} }
        win = new_window()
        last_frame_time = nil
    else
        ctx.dev = nil
        win = nil
        shown = nil
        proxy_stats = nil
    end
end

local function top_systems(hooks, frames, count)
    local list = {}
    for name, t in pairs(hooks) do
        table.insert(list, { name = name, t = t })
    end
    table.sort(list, function(a, b)
        return a.t > b.t
    end)
    local out = {}
    for i = 1, math.min(count, #list) do
        local name = string.match(list[i].name, "([%w_]+)%.lua$") or list[i].name
        table.insert(out, { name = name, ms = list[i].t * 1000 / math.max(frames, 1) })
    end
    return out
end

local function biome_at(x, y)
    local name = BiomeMapGetName(x, y)
    if name == nil or name == "_EMPTY_" then
        return "?"
    end
    return GameTextGetTranslatedOrNot(name)
end

local function count_near(x, y)
    local r = 1024
    return #(EntityGetInRadius(x, y, r) or {}),
        #(EntityGetInRadiusWithTag(x, y, r, "enemy") or {}),
        #(EntityGetInRadiusWithTag(x, y, r, "projectile") or {})
end

local function finish_window()
    local elapsed = now() - win.start
    local frames = math.max(win.frames, 1)
    local s = net.stats
    local x, y = EntityGetTransform(ctx.my_player.entity)
    x, y = x or 0, y or 0
    local ents, enemies, projs = count_near(x, y)
    shown = {
        fps = win.frames / elapsed,
        frame_avg = win.frame_sum * 1000 / frames,
        frame_max = win.frame_max * 1000,
        mod_avg = win.mod_sum * 1000 / frames,
        mod_max = win.mod_max * 1000,
        top = top_systems(ctx.dev.hooks, frames, 3),
        new_entities = win.new_entities / elapsed,
        ents = ents,
        enemies = enemies,
        projs = projs,
        x = x,
        y = y,
        biome = biome_at(x, y),
        sent_msgs = (s.sent_msgs - win.net.sent_msgs) / elapsed,
        sent_bytes = (s.sent_bytes - win.net.sent_bytes) / elapsed,
        recv_msgs = (s.recv_msgs - win.net.recv_msgs) / elapsed,
        recv_bytes = (s.recv_bytes - win.net.recv_bytes) / elapsed,
    }
    ctx.dev.hooks = {}
    win = new_window()
end

local function on_spike(frame_s, mod_s)
    local x, y = EntityGetTransform(ctx.my_player.entity)
    x, y = x or 0, y or 0
    local top = top_systems(ctx.dev.frame_hooks or {}, 1, 3)
    local parts = {}
    for _, e in ipairs(top) do
        table.insert(parts, string.format("%s %.1fms", e.name, e.ms))
    end
    last_spike = {
        time = now(),
        ms = frame_s * 1000,
        mod_ms = mod_s * 1000,
        x = x,
        y = y,
        biome = biome_at(x, y),
        top = table.concat(parts, ", "),
    }
    -- At most one log line per second, so a long stall doesn't flood the log.
    if last_spike.time - last_spike_log >= 1 then
        last_spike_log = last_spike.time
        print(
            string.format(
                "[dev] lag spike %.0fms (mod %.0fms) frame %d at %d,%d %s; slowest: %s",
                last_spike.ms,
                last_spike.mod_ms,
                GameGetFrameNum(),
                x,
                y,
                last_spike.biome,
                last_spike.top
            )
        )
    end
end

-- Pausing (or opening the inventory) stops world updates, so the next frame
-- would look like a huge spike. Called from OnPausedChanged.
function module.reset_frame_timer()
    last_frame_time = nil
end

-- Called from init.lua with the time the mod spent in this frame's
-- OnWorldPreUpdate and OnWorldPostUpdate.
function module.add_mod_time(t)
    frame_mod_time = frame_mod_time + t
end

function module.on_new_entity(arr)
    if win ~= nil then
        win.new_entities = win.new_entities + #arr
    end
end

-- Runs first thing each frame (from init.lua), before any hooks.
function module.frame_start()
    local want = ModSettingGet("goyim.ew.dev_overlay") == true
    local key = tonumber(ModSettingGet("goyim.ew.rebind_dev_overlay") or 60) or 60
    if key ~= 0 and InputIsKeyJustDown(key) and not ctx.is_texting then
        want = not want
        ModSettingSet("goyim.ew.dev_overlay", want)
        ModSettingSetNextValue("goyim.ew.dev_overlay", want, false)
    end
    if want ~= enabled then
        set_enabled(want)
    end
    if proxy_told ~= enabled then
        proxy_told = enabled
        net.proxy_send("dev_stats", enabled and "1" or "0")
    end
    if not enabled then
        return
    end

    local t = now()
    if last_frame_time ~= nil then
        local frame_s = t - last_frame_time
        win.frames = win.frames + 1
        win.frame_sum = win.frame_sum + frame_s
        win.frame_max = math.max(win.frame_max, frame_s)
        win.mod_sum = win.mod_sum + frame_mod_time
        win.mod_max = math.max(win.mod_max, frame_mod_time)
        -- Skip pauses: the game doesn't run world updates while paused.
        if frame_s * 1000 >= SPIKE_MS and not ctx.is_paused then
            on_spike(frame_s, frame_mod_time)
        end
    end
    last_frame_time = t
    frame_mod_time = 0
    ctx.dev.frame_hooks = {}
    if t - win.start >= WINDOW then
        finish_window()
    end
end

function module.on_proxy_stats(value, peers)
    proxy_stats = { value = value, peers = peers }
    proxy_stats_time = now()
end

local WHITE = { 1, 1, 1 }
local YELLOW = { 1, 0.85, 0.3 }
local RED = { 1, 0.4, 0.4 }
local GRAY = { 0.7, 0.7, 0.7 }

local function level(v, warn, bad)
    if v >= bad then
        return RED
    elseif v >= warn then
        return YELLOW
    end
    return WHITE
end

local function kb(bytes)
    return string.format("%.1f", bytes / 1024)
end

local function peer_name(hex)
    local p = ctx.players[hex]
    if p ~= nil and p.name ~= nil then
        return p.name
    end
    return string.sub(hex, -6)
end

local function build_lines()
    local lines = {}
    local function add(text, color)
        table.insert(lines, { text = text, color = color or WHITE })
    end
    add(
        string.format(
            "DEV  %s  frame %d",
            ctx.is_host and "host" or "client",
            GameGetFrameNum()
        ),
        GRAY
    )
    if shown == nil then
        add("collecting...")
        return lines
    end
    add(
        string.format(
            "fps %.0f (game %d)  frame %.1f avg / %.1f max ms",
            shown.fps,
            ctx.my_player.fps or 0,
            shown.frame_avg,
            shown.frame_max
        ),
        level(shown.frame_max, 25, SPIKE_MS)
    )
    add(
        string.format("mod lua %.2f avg / %.1f max ms per frame", shown.mod_avg, shown.mod_max),
        level(shown.mod_max, 8, 20)
    )
    if #shown.top > 0 then
        local parts = {}
        for _, e in ipairs(shown.top) do
            table.insert(parts, string.format("%s %.2f", e.name, e.ms))
        end
        add("slowest ms/frame: " .. table.concat(parts, "  "), GRAY)
    end
    add(
        string.format(
            "entities near %d (enemies %d, proj %d)  spawned %.0f/s",
            shown.ents,
            shown.enemies,
            shown.projs,
            shown.new_entities
        ),
        level(shown.ents, 1500, 3000)
    )
    add(string.format("pos %d, %d  %s", shown.x, shown.y, shown.biome))
    add(
        string.format(
            "mod net out %.0f msg/s %s KB/s  in %.0f msg/s %s KB/s",
            shown.sent_msgs,
            kb(shown.sent_bytes),
            shown.recv_msgs,
            kb(shown.recv_bytes)
        )
    )

    if proxy_stats ~= nil and now() - proxy_stats_time < 3 then
        local tick, wbytes, wmsgs, des = string.match(proxy_stats.value or "", "^(%d+):(%d+):(%d+):(%d+)$")
        if tick ~= nil then
            local tick_ms = tonumber(tick) / 1000
            add(
                string.format(
                    "proxy tick max %.1f ms  world in %s KB/s (%s upd/s)  des out %s/s",
                    tick_ms,
                    kb(tonumber(wbytes)),
                    wmsgs,
                    des
                ),
                level(tick_ms, 20, 50)
            )
        end
        local peers = proxy_stats.peers
        if peers ~= nil and peers ~= "-" then
            for entry in string.gmatch(peers, "[^;]+") do
                local f = util.string_split(entry, ",")
                local name = peer_name(f[1])
                if f[2] == "-" then
                    add(string.format("  %s  (no stats on this connection type)", name), GRAY)
                else
                    local ping = tonumber(f[2]) or 0
                    local q = math.min(tonumber(f[3]) or 100, tonumber(f[4]) or 100)
                    local unacked = tonumber(f[9]) or 0
                    local color = level(ping, 100, 200)
                    if q < 95 or unacked > 50 then
                        color = RED
                    end
                    add(
                        string.format(
                            "  %s  %dms  q %s/%s%%  in %s out %s KB/s  rel %s unack %s",
                            name,
                            ping,
                            f[3],
                            f[4],
                            kb(tonumber(f[5]) or 0),
                            kb(tonumber(f[6]) or 0),
                            f[7],
                            f[8]
                        ),
                        color
                    )
                end
            end
        else
            add("  no peers connected", GRAY)
        end
    else
        add("proxy: no stats (older proxy?)", GRAY)
    end

    if last_spike ~= nil then
        add(
            string.format(
                "last spike %.0fms %ds ago at %d,%d %s",
                last_spike.ms,
                now() - last_spike.time,
                last_spike.x,
                last_spike.y,
                last_spike.biome
            ),
            RED
        )
        if last_spike.top ~= "" then
            add(string.format("  mod %.0fms: %s", last_spike.mod_ms, last_spike.top), RED)
        end
    end
    return lines
end

function module.on_world_update_post()
    if not enabled then
        return
    end
    local lines = build_lines()
    GuiStartFrame(gui)
    GuiZSet(gui, -1000)
    local sw, sh = GuiGetScreenDimensions(gui)
    local right = ModSettingGet("goyim.ew.dev_overlay_corner") ~= "left"
    local line_h = 8
    local w = 0
    for _, line in ipairs(lines) do
        line.w = GuiGetTextDimensions(gui, line.text)
        w = math.max(w, line.w)
    end
    local h = #lines * line_h
    local pad = 3
    local x0 = right and (sw - w - pad - 2) or (pad + 2)
    -- Keep clear of the chat hint in the bottom left corner.
    local y0 = sh - h - pad - (right and 2 or 14)
    GuiZSetForNextWidget(gui, -999)
    GuiImageNinePiece(gui, 1, x0 - pad, y0 - pad, w + pad * 2, h + pad * 2, 0.75)
    for i, line in ipairs(lines) do
        local x = right and (x0 + w - line.w) or x0
        GuiColorSetForNextWidget(gui, line.color[1], line.color[2], line.color[3], 1)
        GuiText(gui, x, y0 + (i - 1) * line_h, line.text)
    end
end

return module
