-- Audi Digital Cockpit - Conky 1.22.2 / X11 / Cairo-Xlib
-- Adds TOP 3 RAM, CPU and per-process NETWORK cards.
-- Runtime data: /run/conky-digital-cockpit/

require 'cairo'
require 'cairo_xlib'

local WIDTH  = 940
local HEIGHT = 835
local DATA_FILE = '/run/conky-digital-cockpit/top-processes.tsv'
local INTERFACES_FILE = '/run/conky-digital-cockpit/interfaces.tsv'
local interfaces = { ETHERNET = nil, WIRELESS = nil, VPN = nil }
local last_interfaces_read = 0

local COLORS = {
    red       = {0.89, 0.15, 0.21, 1.00},
    white     = {0.96, 0.97, 0.99, 1.00},
    muted     = {0.62, 0.67, 0.73, 1.00},
    track     = {0.25, 0.29, 0.34, 0.80},
    green     = {0.25, 0.82, 0.55, 1.00},
    amber     = {1.00, 0.67, 0.20, 1.00},
    panel     = {0.08, 0.10, 0.13, 0.30},
    scale     = {0.48, 0.54, 0.62, 0.85},
}

local network_peaks = {}
local process_data = { CPU = {}, RAM = {}, NET = {} }
local last_data_read = 0

local function set_color(cr, color)
    cairo_set_source_rgba(cr, color[1], color[2], color[3], color[4])
end

local function draw_text(cr, x, y, value, size, color, bold)
    cairo_select_font_face(
        cr, 'DejaVu Sans', CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL
    )
    cairo_set_font_size(cr, size)
    set_color(cr, color or COLORS.white)
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, tostring(value or ''))
end

local function draw_line(cr, x1, y1, x2, y2, color, width)
    set_color(cr, color)
    cairo_set_line_width(cr, width or 1)
    cairo_move_to(cr, x1, y1)
    cairo_line_to(cr, x2, y2)
    cairo_stroke(cr)
end

local function draw_panel(cr, x, y, width, height)
    local radius = 12
    set_color(cr, COLORS.panel)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + width - radius, y + radius, radius, -math.pi / 2, 0)
    cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, math.pi / 2)
    cairo_arc(cr, x + radius, y + height - radius, radius, math.pi / 2, math.pi)
    cairo_arc(cr, x + radius, y + radius, radius, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
    cairo_fill_preserve(cr)
    set_color(cr, COLORS.track)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)
end

local function parsed_number(expression)
    local value = conky_parse(expression)
    if not value then return 0 end
    value = tostring(value):gsub(',', '.')
    return tonumber(value) or 0
end

local function interface_is_up(interface)
    return conky_parse(
        '${if_up ' .. interface .. '}UP${else}DOWN${endif}'
    ) == 'UP'
end

local function format_speed(kbytes_per_second)
    if kbytes_per_second >= 1024 then
        return string.format('%.2f MB/s', kbytes_per_second / 1024)
    elseif kbytes_per_second > 0 and kbytes_per_second < 10 then
        return string.format('%.1f KB/s', kbytes_per_second)
    end
    return string.format('%.0f KB/s', kbytes_per_second)
end

local function get_temperature()
    local raw = conky_parse('${acpitemp}')
    if not raw then return nil end
    return tonumber((tostring(raw):gsub(',', '.')))
end

local function temperature_color(temp)
    if not temp then return COLORS.muted end
    if temp <= 65 then return COLORS.green end
    if temp <= 80 then return COLORS.amber end
    return COLORS.red
end

local function draw_gauge(cr, cx, cy, radius, value, title, caption)
    value = math.max(0, math.min(100, value))
    local start_angle = math.rad(135)
    local end_angle = math.rad(405)
    local value_angle = start_angle + (end_angle - start_angle) * value / 100

    cairo_new_path(cr)
    set_color(cr, COLORS.track)
    cairo_set_line_width(cr, 13)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_arc(cr, cx, cy, radius, start_angle, end_angle)
    cairo_stroke(cr)

    cairo_new_path(cr)
    set_color(cr, COLORS.red)
    cairo_set_line_width(cr, 13)
    cairo_arc(cr, cx, cy, radius, start_angle, value_angle)
    cairo_stroke(cr)
    cairo_new_path(cr)

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    for tick = 0, 20 do
        local angle = start_angle + (end_angle - start_angle) * tick / 20
        local major = (tick % 5 == 0)
        local r1 = radius + 10
        local r2 = radius + (major and 21 or 15)
        draw_line(
            cr,
            cx + math.cos(angle) * r1, cy + math.sin(angle) * r1,
            cx + math.cos(angle) * r2, cy + math.sin(angle) * r2,
            major and COLORS.white or COLORS.muted, major and 1.8 or 1.0
        )
    end

    draw_text(cr, cx - 43, cy + 8, string.format('%3.0f%%', value),
              31, COLORS.white, true)
    draw_text(cr, cx - 27, cy + 34, title, 11, COLORS.red, true)
    draw_text(cr, cx - 63, cy + 55, caption, 8, COLORS.muted, false)
    draw_text(cr, cx - 76, cy + 82, '0',   7, COLORS.muted, false)
    draw_text(cr, cx - 43, cy + 82, '25',  7, COLORS.muted, false)
    draw_text(cr, cx -  8, cy + 82, '50',  7, COLORS.muted, false)
    draw_text(cr, cx + 27, cy + 82, '75',  7, COLORS.muted, false)
    draw_text(cr, cx + 59, cy + 82, '100', 7, COLORS.muted, false)
end

local function get_dynamic_peak(key, value)
    local minimum_scale = 32
    local previous = network_peaks[key] or minimum_scale
    local decayed = math.max(minimum_scale, previous * 0.985)
    local peak = math.max(minimum_scale, value, decayed)
    network_peaks[key] = peak
    return peak
end

local function draw_speed_bar(cr, x, y, width, value, key)
    local fraction = math.max(0, math.min(1, value / get_dynamic_peak(key, value)))
    if value > 0 then fraction = math.max(fraction, 0.025) end

    set_color(cr, COLORS.track)
    cairo_rectangle(cr, x, y, width, 5)
    cairo_fill(cr)

    for i = 1, 4 do
        local mx = x + width * i / 4
        draw_line(cr, mx, y - 2, mx, y + 7, COLORS.scale, 0.7)
    end

    if value > 0 then
        set_color(cr, COLORS.red)
        cairo_rectangle(cr, x, y, width * fraction, 5)
        cairo_fill(cr)
    end
    draw_text(cr, x + width - 27, y - 7, 'AUTO', 6, COLORS.muted, false)
end

local function read_process_data()
    local now = os.time()
    if now == last_data_read then return end
    last_data_read = now

    local f = io.open(DATA_FILE, 'r')
    if not f then return end

    local fresh = { CPU = {}, RAM = {}, NET = {} }
    for line in f:lines() do
        local kind, pid, name, a, b =
            line:match('^([^|]+)|([^|]+)|([^|]+)|([^|]+)|?([^|]*)$')
        if kind and fresh[kind] then
            local row = {
                pid = tonumber(pid) or 0,
                name = name,
                value = tonumber(a) or 0,
                sent = tonumber(a) or 0,
                received = tonumber(b) or 0
            }
            table.insert(fresh[kind], row)
        end
    end
    f:close()

    process_data = fresh
end

local function read_interfaces()
    local now = os.time()
    if now == last_interfaces_read then return end
    last_interfaces_read = now
    local f = io.open(INTERFACES_FILE, 'r')
    if not f then return end
    local found = { ETHERNET = nil, WIRELESS = nil, VPN = nil }
    for line in f:lines() do
        local kind, name = line:match('^([^|]+)|([^|]+)$')
        if kind and found[kind] == nil then found[kind] = name end
    end
    f:close()
    interfaces = found
end

local function short_name(name, max_chars)
    name = tostring(name or 'unknown')
    if #name > max_chars then
        return string.sub(name, 1, max_chars - 2) .. '..'
    end
    return name
end

local function format_memory(mb)
    if mb >= 1024 then
        return string.format('%.1f GB', mb / 1024)
    end
    return string.format('%.0f MB', mb)
end

local function draw_process_card(cr, x, y, title, kind)
    local width, height = 285, 140
    draw_panel(cr, x, y, width, height)

    local subtitle = 'TOP 3 PROCESSES'
    if kind == 'RAM' then subtitle = 'MEMORY / RESIDENT'
    elseif kind == 'CPU' then subtitle = 'SYSTEM CPU SHARE'
    elseif kind == 'NET' then subtitle = 'DOWNLOAD / UPLOAD KB/S' end

    draw_text(cr, x + 14, y + 23, title, 12, COLORS.white, true)
    draw_text(cr, x + 14, y + 36, subtitle, 7, COLORS.muted, false)
    draw_line(cr, x + 14, y + 43, x + width - 14, y + 43, COLORS.track, 1)

    local rows = process_data[kind] or {}
    local max_value = 1
    for _, row in ipairs(rows) do
        local v = kind == 'NET' and (row.sent + row.received) or row.value
        if v > max_value then max_value = v end
    end

    for i = 1, 3 do
        local row = rows[i]
        local base_y = y + 62 + (i - 1) * 25

        if row then
            local name = short_name(row.name, 17)
            local metric
            local bar_value

            if kind == 'RAM' then
                metric = format_memory(row.value)
                bar_value = row.value
            elseif kind == 'CPU' then
                metric = string.format('%.1f%%', row.value)
                bar_value = row.value
            else
                metric = string.format('D %.1f / U %.1f', row.received, row.sent)
                bar_value = row.received + row.sent
            end

            draw_text(cr, x + 14, base_y, tostring(i) .. '. ' .. name,
                      8, COLORS.white, true)
            draw_text(cr, x + 185, base_y, metric, 8, COLORS.muted, true)

            local bar_width = 255
            local fraction = math.max(0, math.min(1, bar_value / max_value))
            set_color(cr, COLORS.track)
            cairo_rectangle(cr, x + 14, base_y + 5, bar_width, 4)
            cairo_fill(cr)

            if fraction > 0 then
                set_color(cr, kind == 'NET' and COLORS.amber or COLORS.red)
                cairo_rectangle(cr, x + 14, base_y + 5,
                                math.max(2, bar_width * fraction), 4)
                cairo_fill(cr)
            end
        else
            draw_text(cr, x + 14, base_y, 'No process data', 8, COLORS.muted, false)
        end
    end
end

local function draw_network_card(cr, x, y, title, interface)
    local width, height = 285, 205
    draw_panel(cr, x, y, width, height)

    local online = interface and interface_is_up(interface) or false
    draw_text(cr, x + 17, y + 29, title, 13, COLORS.white, true)
    draw_text(cr, x + 205, y + 29, online and 'ONLINE' or 'OFFLINE',
              9, online and COLORS.green or COLORS.amber, true)
    draw_text(cr, x + 17, y + 49, interface or 'not detected', 9, COLORS.muted, false)
    draw_line(cr, x + 17, y + 62, x + width - 17, y + 62, COLORS.track, 1)

    local download, upload = 0, 0
    if interface then
        download = parsed_number('${downspeedf ' .. interface .. '}')
        upload = parsed_number('${upspeedf ' .. interface .. '}')
    end

    draw_text(cr, x + 17, y + 91, 'DOWNLOAD', 8, COLORS.muted, true)
    draw_text(cr, x + 17, y + 117, format_speed(download), 18, COLORS.white, true)
    draw_speed_bar(cr, x + 157, y + 101, 108, download, (interface or title) .. '_download')

    draw_text(cr, x + 17, y + 150, 'UPLOAD', 8, COLORS.muted, true)
    draw_text(cr, x + 17, y + 176, format_speed(upload), 18, COLORS.white, true)
    draw_speed_bar(cr, x + 157, y + 160, 108, upload, (interface or title) .. '_upload')
end

function conky_draw_dashboard()
    if not conky_window then return end
    read_process_data()
    read_interfaces()

    local surface = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable, conky_window.visual,
        WIDTH, HEIGHT
    )
    local cr = cairo_create(surface)

    -- Header
    draw_text(cr, 24, 37, 'AUDI', 25, COLORS.white, true)
    draw_text(cr, 103, 36, 'DIGITAL COCKPIT', 14, COLORS.red, true)
    draw_text(cr, 24, 58, 'SYSTEM MONITOR  /  LIVE TELEMETRY', 9, COLORS.muted, false)
    draw_text(cr, 835, 36, 'LINUX', 10, COLORS.muted, true)
    draw_line(cr, 24, 76, 916, 76, COLORS.red, 2)

    -- CPU and RAM gauges
    draw_gauge(cr, 260, 205, 91, parsed_number('${cpu}'), 'CPU', 'PROCESSOR LOAD')
    draw_gauge(cr, 680, 205, 91, parsed_number('${memperc}'), 'RAM', 'MEMORY USAGE')

    -- CPU temperature and frequency
    local temperature = get_temperature()
    draw_text(cr, 24, 103, 'CPU TEMP', 8, COLORS.muted, true)
    draw_text(cr, 91, 103,
        temperature and string.format('%.0f°C', temperature) or '--°C',
        10, temperature_color(temperature), true)
    draw_text(cr, 760, 103, 'CPU FREQ', 8, COLORS.muted, true)
    draw_text(cr, 830, 103,
        tostring(conky_parse('${freq_g}')) .. ' GHz', 10, COLORS.white, true)

    -- New TOP 3 process cards, directly below the gauges
    draw_text(cr, 24, 330, 'TOP RESOURCE CONSUMERS', 11, COLORS.red, true)
    draw_text(cr, 758, 330, 'LIVE PROCESS RANKING', 8, COLORS.muted, false)
    draw_line(cr, 24, 338, 916, 338, COLORS.track, 1)

    draw_process_card(cr, 24, 350, 'TOP RAM', 'RAM')
    draw_process_card(cr, 327, 350, 'TOP CPU', 'CPU')
    draw_process_card(cr, 630, 350, 'TOP NETWORK', 'NET')

    -- Network interfaces moved below process cards
    draw_text(cr, 24, 520, 'NETWORK INTERFACES', 11, COLORS.red, true)
    draw_text(cr, 758, 520, 'TRAFFIC / REAL TIME', 9, COLORS.muted, false)
    draw_line(cr, 24, 533, 916, 533, COLORS.track, 1)

    draw_network_card(cr, 24, 550, 'ETHERNET', interfaces.ETHERNET)
    draw_network_card(cr, 327, 550, 'WIRELESS', interfaces.WIRELESS)
    draw_network_card(cr, 630, 550, 'VPN TUNNEL', interfaces.VPN)

    -- Footer
    draw_line(cr, 24, 775, 916, 775, COLORS.track, 1)
    draw_text(cr, 24, 800,
        'HOST: ' .. tostring(conky_parse('${nodename}')),
        9, COLORS.muted, false)
    draw_text(cr, 24, 821,
        'UPTIME: ' .. tostring(conky_parse('${uptime}')),
        9, COLORS.muted, false)
    draw_text(cr, 760, 821, 'AUDI DIGITAL SYSTEM', 9, COLORS.red, true)

    cairo_destroy(cr)
    cairo_surface_destroy(surface)
end
