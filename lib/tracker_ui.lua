--[[
AMANTracker - Tracker UI

The panel matches Vanacore Goldilox (ui.lua): the /vana palette, Segoe UI,
a title with a close mark, folding small-cap headers, and one well per row.
A teal meter along the bottom of a row is the kill progress.
]]

local tracker_ui = {};
local imgui = require('imgui');
local family = require('lib.family');

-- ============================================================================
-- State
-- ============================================================================

local ui_visible = { false };  -- Start hidden, auto-show when a regime is restored or confirmed
tracker_ui.shift_held = false;

local training_data = nil;

-- Width remembered from the previous frame so wells and the close mark line up
-- without a short row locking the panel open. Same fields Goldilox keeps on ui.
local panel = {
    fit_w = nil,
    fit_now = 0,
    row_x = nil,
    natural = nil,
};

-- ============================================================================
-- /vana palette (Vanacore goldilox-ui/ui.lua)
-- ============================================================================

local HEX = {
    bg = '#161822', border = '#2A2E3E', line = '#242838', well = '#0E1017',
    hover = '#1F2334', white = '#FFFFFF', text = '#E8EAF1', text2 = '#BDC1D0',
    dim = '#7B8095', faint = '#4E536A', accent = '#7AA2F7', accent2 = '#A9C1FF',
    accent_lo = '#3E5CB3', teal = '#5FD3B3', amber = '#E8B45C', rose = '#EE6F78',
    off = '#2B2F42', popup = '#0F1118',
};

local function rgba(hex, alpha)
    return {
        tonumber(hex:sub(2, 3), 16) / 255,
        tonumber(hex:sub(4, 5), 16) / 255,
        tonumber(hex:sub(6, 7), 16) / 255,
        alpha or 1,
    };
end

local function u32(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16);
    local g = tonumber(hex:sub(4, 5), 16);
    local b = tonumber(hex:sub(6, 7), 16);
    local a = math.floor(math.max(0, math.min(1, alpha or 1)) * 255 + 0.5);
    return ((a * 256 + b) * 256 + g) * 256 + r;
end

local function mix(a, b, t)
    t = math.max(0, math.min(1, t or 0));
    local out = '#';
    for i = 2, 6, 2 do
        local x = tonumber(a:sub(i, i + 1), 16);
        local y = tonumber(b:sub(i, i + 1), 16);
        out = out .. string.format('%02X', math.floor(x + (y - x) * t + 0.5));
    end
    return out;
end

-- grey_bar and dark_grey are sentinels compared by identity, same as Goldilox.
local COLORS = {
    white     = rgba(HEX.text),
    link      = rgba(HEX.accent),
    orange    = rgba(HEX.amber),
    grey_text = rgba(HEX.dim),
    grey_bar  = rgba(HEX.teal),
    dark_grey = rgba(HEX.off),
};

-- Screen height sets the size the way /vana does: 1440px tall is 1.1, held between 0.75 and 1.6.
local scale = 1;
local function S(n)
    return math.floor(n * scale + 0.5);
end

local function update_scale()
    local h = 1080;
    local ok, io = pcall(imgui.GetIO);
    if ok and io and io.DisplaySize then
        h = tonumber(io.DisplaySize.y) or h;
    end
    scale = math.max(0.75, math.min(1.6, h / 1440)) * 1.1;
end

local BODY, SMALL = 16, 13.5;
local DYNAMIC = (tonumber(IMGUI_VERSION_NUM) or 0) >= 19200;
local fonts = { tried = false, ready = false };
local fonts_pending = nil;
local measured, measured_scale, measured_n = {}, nil, 0;

local function fonts_begin()
    if fonts_pending then
        fonts.text = fonts_pending.text;
        fonts.semi = fonts_pending.semi;
        fonts.bold_italic = fonts_pending.bold_italic;
        fonts.semi_italic = fonts_pending.semi_italic;
        fonts_pending = nil;
        fonts.ready = true;
        measured, measured_n = {}, 0;
    end
    if fonts.tried then
        return;
    end
    fonts.tried = true;
    if not DYNAMIC then
        local face_now = imgui.GetFont();
        fonts.text, fonts.semi, fonts.bold_italic, fonts.semi_italic = face_now, face_now, face_now, face_now;
        fonts.ready = true;
        return;
    end
    local dir = ((os.getenv and os.getenv('WINDIR')) or 'C:\\Windows') .. '\\Fonts\\';
    local function add(file, fallback)
        local path = dir .. file;
        local handle = io.open(path, 'rb');
        if not handle then
            return fallback;
        end
        handle:close();
        local ok, face_now = pcall(imgui.AddFontFromFileTTF, path, 18);
        if ok and face_now then
            return face_now;
        end
        return fallback;
    end
    -- Usable from the next frame: ImGui cannot draw a font in the frame it was added.
    local text = add('segoeui.ttf', imgui.GetFont());
    local semi = add('seguisb.ttf', text);
    fonts_pending = {
        text = text,
        semi = semi,
        bold_italic = add('segoeuiz.ttf', semi),
        semi_italic = add('seguisbi.ttf', semi),
    };
end

local function measure(str, font, size)
    str = tostring(str or '');
    if measured_scale ~= scale or measured_n > 4000 then
        measured, measured_scale, measured_n = {}, scale, 0;
    end
    local key = tostring(font) .. '|' .. tostring(size) .. '|' .. str;
    local found = measured[key];
    if not found then
        local w, h;
        if DYNAMIC and fonts.ready and font then
            imgui.PushFont(font, S(size));
            w, h = imgui.CalcTextSize(str);
            imgui.PopFont();
        else
            w, h = imgui.CalcTextSize(str);
        end
        found = { w or 0, h or 0 };
        measured[key] = found;
        measured_n = measured_n + 1;
    end
    return found[1], found[2];
end

local function text_mid(dl, x, cy, str, hex, font, size, alpha)
    local _, h = measure(str, font, size);
    local y = cy - h / 2;
    if DYNAMIC and fonts.ready then
        y = y - math.floor(h * 0.06 + 0.5);
    end
    if DYNAMIC and fonts.ready and font then
        imgui.PushFont(font, S(size));
        dl:AddText({ x, y }, u32(hex, alpha), str);
        imgui.PopFont();
    else
        dl:AddText({ x, y }, u32(hex, alpha), str);
    end
end

-- One letter at a time, `spacing` past the glyph. Nil `dl` only measures. Returns the width.
local function text_spaced(dl, x, cy, str, hex, font, size, spacing)
    local start = x;
    local i, n = 1, #str;
    while i <= n do
        local b = str:byte(i);
        local len = 1;
        if b >= 0xF0 then
            len = 4;
        elseif b >= 0xE0 then
            len = 3;
        elseif b >= 0xC0 then
            len = 2;
        end
        local letter = str:sub(i, i + len - 1);
        if dl ~= nil then
            text_mid(dl, x, cy, letter, hex, font, size);
        end
        x = x + measure(letter, font, size) + spacing;
        i = i + len;
    end
    if x == start then
        return 0;
    end
    return x - start - spacing;
end

local function fill(dl, x, y, w, h, hex, radius, alpha, corners)
    if w <= 0 or h <= 0 then
        return;
    end
    local col = u32(hex, alpha);
    if corners then
        dl:AddRectFilled({ x, y }, { x + w, y + h }, col, radius or 0, corners);
    else
        dl:AddRectFilled({ x, y }, { x + w, y + h }, col, radius or 0);
    end
end

local function outline(dl, x, y, w, h, hex, radius, alpha)
    if w <= 0 or h <= 0 then
        return;
    end
    dl:AddRect({ x, y }, { x + w, y + h }, u32(hex, alpha), radius or 0);
end

local anim, last_clock, frame_dt = {}, nil, 0;
local function tick()
    local now = os.clock();
    frame_dt = last_clock and math.max(0, math.min(0.1, now - last_clock)) or 0;
    last_clock = now;
end

local function ease(id, target)
    local v = anim[id];
    if v == nil then
        v = target;
    else
        v = v + (target - v) * math.min(1, frame_dt * 18);
        if math.abs(v - target) < 0.004 then
            v = target;
        end
    end
    anim[id] = v;
    return v;
end

local function face(which)
    return fonts[which] or imgui.GetFont();
end

-- A chevron or an × drawn with lines, so no icon font is required.
local function glyph(dl, kind, cx, cy, hex, glyph_scale)
    local k = S(11) / 24 * (glyph_scale or 1);
    local col = u32(hex);
    local thickness = math.max(1, 2 * k);
    local function p(px, py)
        return { cx + (px - 12) * k, cy + (py - 12) * k };
    end
    if kind == 'right' then
        dl:AddLine(p(9, 5), p(16, 12), col, thickness);
        dl:AddLine(p(16, 12), p(9, 19), col, thickness);
    elseif kind == 'close' then
        dl:AddLine(p(6, 6), p(18, 18), col, thickness);
        dl:AddLine(p(18, 6), p(6, 18), col, thickness);
    else
        dl:AddLine(p(5, 9), p(12, 16), col, thickness);
        dl:AddLine(p(12, 16), p(19, 9), col, thickness);
    end
end

local folded = {};

local function piece_w(s)
    local w = imgui.CalcTextSize(tostring(s or ''));
    if type(w) == 'table' then
        return w.x or w[1] or 0;
    end
    return w or 0;
end

local function mark_width(w)
    if w > (panel.fit_now or 0) then
        panel.fit_now = w;
    end
end

-- Space between a row's text and the edges of its well.
local ROW_PAD_X = 6;

-- The next widget, `item_w` wide, stays on this line. It sits `min_gap` after the
-- last item, or just inside the right pad once the panel is wider than this line.
local function place_after(min_gap, item_w)
    local left_end = select(1, imgui.GetItemRectMax());
    local row_left = panel.row_x or left_end;
    local natural = (left_end - row_left) + min_gap + item_w;
    panel.natural = math.max(panel.natural or 0, natural);
    local fitted = (panel.fit_w or 0) - ROW_PAD_X;
    if fitted < natural then
        fitted = natural;
    end
    local gap = math.max(min_gap, fitted - (left_end - row_left) - item_w);
    imgui.SameLine(0, gap);
end

-- A section heading: small capitals, tracked, in teal, with a hairline.
-- Click folds the rows. The hit box is only the title. Returns true while open.
local function draw_section_header(text)
    local h = S(18);
    local x, y = imgui.GetCursorScreenPos();
    local title_font = face('semi_italic');
    local title_size = SMALL;
    local title = string.upper(text);
    local spacing = S(1.2);
    if spacing < 1 then
        spacing = 1;
    end
    local title_w = text_spaced(nil, 0, 0, title, nil, title_font, title_size, spacing);
    local btn_w = S(14) + title_w + S(6);
    imgui.InvisibleButton('##fold.' .. text, { btn_w, h });
    local hovered = imgui.IsItemHovered();
    local clicked = imgui.IsItemClicked(0);
    if clicked then
        folded[text] = not folded[text] or nil;
    end
    local open = folded[text] ~= true;
    local t = ease('fold.' .. text, hovered and 1 or 0);
    local dl = imgui.GetWindowDrawList();
    local cy = y + h / 2;
    local color = mix(HEX.teal, HEX.white, t * 0.25);
    glyph(dl, open and 'down' or 'right', x + S(5), cy, hovered and HEX.teal or HEX.faint);
    text_spaced(dl, x + S(14), cy, title, color, title_font, title_size, spacing);
    local line_x = x + S(14) + title_w + S(8);
    local line_end = x + math.max(btn_w, panel.fit_w or 0);
    if line_end > line_x + S(4) then
        dl:AddLine({ line_x, cy }, { line_end, cy }, u32(HEX.teal, 0.85), 1);
    end
    mark_width(btn_w);
    return open;
end

local function show_tooltip(text)
    if text == nil or text == '' then
        return;
    end
    imgui.PushStyleColor(ImGuiCol_PopupBg, rgba(HEX.popup, 0.97));
    imgui.PushStyleColor(ImGuiCol_Border, rgba(HEX.border));
    imgui.PushStyleColor(ImGuiCol_Text, rgba(HEX.text));
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(9), S(6) });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, S(4));
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(4));
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    local pushed = false;
    if DYNAMIC and fonts.ready and fonts.text then
        imgui.PushFont(fonts.text, S(SMALL + 0.5));
        pushed = true;
    end
    if imgui.BeginTooltip() then
        imgui.TextUnformatted(text);
        imgui.EndTooltip();
    end
    if pushed then
        imgui.PopFont();
    end
    imgui.PopStyleVar(4);
    imgui.PopStyleColor(3);
end

-- fraction nil draws no meter. The meter is the /vana teal.
-- COLORS.dark_grey means the amount is not yet known, so the fill is duller.
-- content_fn draws the left side. Right-side pieces use place_after.
local function draw_bar_with_overlay(fraction, count_text, bar_color, content_fn, add_spacing)
    local has_meter = fraction ~= nil;
    local pad_y = S(1);
    local dl = imgui.GetWindowDrawList();
    local split = false;
    local ok_method, method = pcall(function() return dl.ChannelsSplit end);
    if ok_method and type(method) == 'function' then
        split = pcall(function()
            dl:ChannelsSplit(2);
            dl:ChannelsSetCurrent(1);
        end);
    end

    imgui.BeginGroup();
    if pad_y > 0 then
        imgui.Dummy({ 0, pad_y });
    end
    local row_x = select(1, imgui.GetCursorScreenPos());
    panel.row_x = row_x;
    panel.natural = nil;
    imgui.Dummy({ ROW_PAD_X, 1 });
    imgui.SameLine(0, 0);
    if content_fn then
        content_fn();
    end
    if count_text and count_text ~= '' then
        place_after(S(8), piece_w(count_text));
        local hex = (bar_color == COLORS.grey_bar) and HEX.dim or HEX.text2;
        imgui.TextColored(rgba(hex), count_text);
    end
    imgui.SameLine(0, 0);
    imgui.Dummy({ ROW_PAD_X, 1 });
    if has_meter then
        imgui.Dummy({ 0, S(4) });
    end
    if pad_y > 0 then
        imgui.Dummy({ 0, pad_y });
    end
    imgui.EndGroup();

    local x1, y1 = imgui.GetItemRectMin();
    local x2, y2 = imgui.GetItemRectMax();
    local row_w = math.max(1, x2 - x1);
    local row_h = math.max(1, y2 - y1);
    mark_width(panel.natural and (panel.natural + ROW_PAD_X) or row_w);
    local well_w = math.max(row_w, panel.fit_w or 0);

    local function paint_back()
        local radius = S(3);
        fill(dl, x1, y1, well_w, row_h, HEX.well, radius, 1);
        outline(dl, x1, y1, well_w, row_h, HEX.line, radius, 1);
        if not has_meter or well_w <= S(8) then
            return;
        end
        local mh = math.max(2, S(3));
        local mx = x1 + S(4);
        local mw = well_w - S(8);
        local my = y2 - S(2) - mh;
        fill(dl, mx, my, mw, mh, HEX.off, mh / 2, 1);
        local frac = math.max(0, math.min(1, fraction or 0));
        if frac <= 0 then
            return;
        end
        local meter = HEX.teal;
        if bar_color == COLORS.dark_grey then
            meter = mix(HEX.teal, HEX.off, 0.45);
        end
        fill(dl, mx, my, math.max(mh, mw * frac), mh, meter, mh / 2, 1);
    end

    if split then
        pcall(function() dl:ChannelsSetCurrent(0) end);
        paint_back();
        pcall(function() dl:ChannelsMerge() end);
    elseif has_meter then
        local mh = math.max(2, S(3));
        local my = y2 - S(2) - mh;
        fill(dl, x1, my, well_w, mh, HEX.off, mh / 2, 1);
    end
    if add_spacing ~= false then
        imgui.Dummy({ 0, S(1) });
    end
end

local function draw_static_bar(content_fn, add_spacing)
    draw_bar_with_overlay(nil, '', nil, content_fn, add_spacing);
end

-- Amber or teal callout: a wash, a stripe down the left, the line in that colour.
local function draw_notice(text, hex)
    local h = S(18);
    local tw = measure(text, face('text'), SMALL + 1);
    local w = tw + S(10);
    local x, y = imgui.GetCursorScreenPos();
    imgui.Dummy({ w, h });
    mark_width(w);
    local dl = imgui.GetWindowDrawList();
    fill(dl, x, y, w, h, hex, S(3), 0.12);
    local left = ImDrawFlags_RoundCornersLeft or ImDrawCornerFlags_Left;
    fill(dl, x, y, S(2), h, hex, S(2), 1, left);
    text_mid(dl, x + S(6), y + h / 2, text, hex, face('text'), SMALL + 1);
end

local STYLE_COLORS = nil;

local function push_window_style()
    if STYLE_COLORS == nil then
        STYLE_COLORS = {
            { ImGuiCol_Text, rgba(HEX.text) },
            { ImGuiCol_TextDisabled, rgba(HEX.faint) },
            { ImGuiCol_WindowBg, rgba(HEX.bg) },
            { ImGuiCol_ChildBg, rgba(HEX.bg) },
            { ImGuiCol_PopupBg, rgba(HEX.popup) },
            { ImGuiCol_Border, rgba(HEX.border) },
            { ImGuiCol_Separator, rgba(HEX.line) },
            { ImGuiCol_ScrollbarBg, rgba(HEX.bg, 0) },
            { ImGuiCol_ScrollbarGrab, rgba('#3A4158') },
            { ImGuiCol_ScrollbarGrabHovered, rgba('#4A5270') },
            { ImGuiCol_ScrollbarGrabActive, rgba(HEX.accent_lo) },
        };
    end
    for _, entry in ipairs(STYLE_COLORS) do
        imgui.PushStyleColor(entry[1], entry[2]);
    end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(8), S(4) });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, S(5));
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, S(3));
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(5));
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { S(4), S(2) });
    imgui.PushStyleVar(ImGuiStyleVar_ScrollbarSize, S(6));
    imgui.PushStyleVar(ImGuiStyleVar_ScrollbarRounding, S(3));
end

local function pop_window_style()
    imgui.PopStyleVar(9);
    imgui.PopStyleColor(#STYLE_COLORS);
end

local TITLE = 'AMAN';
local SUBTITLE = 'Tracker';

local function draw_title()
    local h = S(18);
    local x, y = imgui.GetCursorScreenPos();
    imgui.Dummy({ 0, h });
    local dl = imgui.GetWindowDrawList();
    local cy = y + h / 2;
    local title_font = face('semi');
    local title_size = BODY;
    text_mid(dl, x, cy, TITLE, HEX.white, title_font, title_size);
    local title_w = measure(TITLE, title_font, title_size);
    text_mid(dl, x + title_w + S(6), cy, SUBTITLE, HEX.faint, face('text'), SMALL);
    local note_w = measure(SUBTITLE, face('text'), SMALL);
    local title_end = title_w + S(6) + note_w;
    mark_width(title_end + S(16));
    local close_box = S(14) * 1.5;
    local cx = x + math.max(title_end + S(10), (panel.fit_w or 0) - S(6));
    local restore_x, restore_y = imgui.GetCursorScreenPos();
    imgui.SetCursorScreenPos({ cx - close_box / 2, cy - close_box / 2 });
    imgui.InvisibleButton('##aman.close', { close_box, close_box });
    local close_hover = imgui.IsItemHovered();
    if imgui.IsItemClicked(0) then
        ui_visible[1] = false;
    end
    imgui.SetCursorScreenPos({ restore_x, restore_y });
    glyph(dl, 'close', cx, cy, close_hover and HEX.rose or HEX.dim, 1.5);
    local line_end = x + math.max(title_end, panel.fit_w or 0);
    dl:AddLine({ x, y + h }, { line_end, y + h }, u32(HEX.border), 1);
end

local function draw_shadow()
    local ok, dl = pcall(imgui.GetBackgroundDrawList);
    if not ok or dl == nil then
        return;
    end
    local x, y = imgui.GetWindowPos();
    local w, h = imgui.GetWindowSize();
    dl:AddRectFilled({ x - S(1), y + S(1) }, { x + w + S(1), y + h + S(3) }, u32('#000000', 0.35), S(6));
end

-- ============================================================================
-- Wiki links
-- ============================================================================

local SINGULAR_NAMES = {
    gigas = true,
};

local function to_wiki_path(name)
    return name:gsub(' ', '_'):gsub("'", '%%27');
end

local function to_wiki_path_titled(name)
    local titled = name:gsub('(%a)([%w\']*)', function(first, rest)
        return first:upper() .. rest:lower();
    end);
    return titled:gsub(' ', '_'):gsub("'", '%%27');
end

local function singularize_mob(name)
    local lower = name:lower();
    if SINGULAR_NAMES[lower] then
        return name;
    end
    if #name > 3 and name:sub(-3):lower() == 'ies' then
        return name:sub(1, -4) .. 'y';
    end
    if #name > 3 and name:sub(-2):lower() == 'es' then
        local stem = name:sub(1, -3);
        local tail = stem:sub(-2):lower();
        local last = stem:sub(-1):lower();
        if last == 's' or last == 'x' or last == 'z' or tail == 'ch' or tail == 'sh' then
            return stem;
        end
    end
    if #name > 1 and name:sub(-1):lower() == 's' and name:sub(-2, -2):lower() ~= 's' then
        return name:sub(1, -2);
    end
    return name;
end

local function title_case(name)
    return (name:gsub('(%a)([%w\']*)', function(first, rest)
        return first:upper() .. rest:lower();
    end));
end

local function draw_interactive_text(text, color, tooltip_text, on_click_fn)
    imgui.TextColored(color, text);
    local min_x, min_y = imgui.GetItemRectMin();
    local max_x, max_y = imgui.GetItemRectMax();
    local hovered = imgui.IsItemHovered();
    local draw_list = imgui.GetWindowDrawList();
    local hot = hovered and color == COLORS.link;
    if hot then
        draw_list:AddText({ min_x, min_y }, u32(HEX.accent2), text);
    end
    local a = math.floor((color[4] or 1.0) * 255);
    local b = math.floor((color[3] or 0) * 255);
    local g = math.floor((color[2] or 0) * 255);
    local r = math.floor((color[1] or 0) * 255);
    local col_u32 = hot and u32(HEX.accent2) or bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r);
    draw_list:AddLine({ min_x, max_y }, { max_x, max_y }, col_u32, 1.0);
    if hovered then
        show_tooltip(tooltip_text);
    end
    if imgui.IsItemClicked(0) then
        on_click_fn();
    end
end

local function draw_link(text, color, url, tooltip)
    draw_interactive_text(text, color, tooltip or ('Open FFXI Wiki: ' .. text), function()
        os.execute('start "" "' .. url .. '"');
    end);
end

local function draw_zone_link(zone_name, color)
    local url = 'https://www.bg-wiki.com/ffxi/' .. to_wiki_path(zone_name);
    draw_link(zone_name, color, url);
end

local function draw_family_link(family_type, color)
    local display = title_case(family_type);
    local wiki_name = display;
    if display:lower() == 'bats' then
        wiki_name = 'Bat';
    end
    local url = 'https://www.bg-wiki.com/ffxi/Category:' .. to_wiki_path_titled(wiki_name);
    draw_link(display, color, url);
end

local function draw_exact_mob_link(mob_name, color)
    local url = 'https://www.bg-wiki.com/ffxi/' .. to_wiki_path_titled(singularize_mob(mob_name));
    draw_link(mob_name, color, url);
end

local function progress_colors(is_done)
    if is_done then
        return COLORS.grey_text, COLORS.grey_text;
    end
    return COLORS.white, COLORS.link;
end

-- ============================================================================
-- Rows
-- ============================================================================

local function draw_regime_context()
    local zone = training_data.training_area_zone;
    if type(zone) == 'string' then
        zone = zone:match('^%s*(.-)%s*$');
        if zone == '' then
            zone = nil;
        end
    else
        zone = nil;
    end

    local level = training_data.target_level_range;
    if type(level) ~= 'string' or level == '' then
        level = nil;
    end
    if not zone and not level then
        return;
    end

    draw_static_bar(function()
        if zone then
            imgui.TextColored(COLORS.white, 'Training in ');
            imgui.SameLine();
            draw_zone_link(zone, COLORS.link);
        else
            imgui.TextColored(COLORS.orange, 'Training area unknown');
        end
        if level then
            local right_text = 'Lv ' .. level;
            place_after(S(12), piece_w(right_text));
            imgui.TextColored(rgba(HEX.text2), right_text);
        end
    end);
end

local function draw_enemy_row(enemy)
    local killed = tonumber(enemy.killed) or 0;
    local total = tonumber(enemy.total) or 0;
    if killed < 0 then
        killed = 0;
    end
    local is_done = total > 0 and killed >= total;
    local fraction = 0;
    if total > 0 then
        fraction = killed / total;
        if fraction > 1 then
            fraction = 1;
        end
    end
    local count_text = string.format('%d/%d', killed, total);
    local label_color, highlight_color = progress_colors(is_done);
    local bar_color = is_done and COLORS.grey_bar or nil;
    local family_type = family.extract_family_type(enemy.name or '');

    draw_bar_with_overlay(fraction, count_text, bar_color, function()
        if family_type then
            imgui.TextColored(label_color, 'Members of the ');
            imgui.SameLine();
            draw_family_link(family_type, highlight_color);
            imgui.SameLine();
            imgui.TextColored(label_color, ' Family');
        else
            draw_exact_mob_link(enemy.name or 'Unknown', highlight_color);
        end
    end);
end

local function regime_complete(enemies)
    local any = false;
    for _, enemy in ipairs(enemies) do
        local total = tonumber(enemy.total) or 0;
        local killed = tonumber(enemy.killed) or 0;
        if total > 0 then
            any = true;
            if killed < total then
                return false;
            end
        end
    end
    return any;
end

local function is_loading()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then
        return true;
    end
    local level = player:GetMainJobLevel();
    return not level or level == 0;
end

-- ============================================================================
-- Module functions
-- ============================================================================

function tracker_ui.init(data)
    training_data = data;
end

function tracker_ui.is_visible()
    return ui_visible[1];
end

function tracker_ui.open()
    ui_visible[1] = true;
end

function tracker_ui.close()
    ui_visible[1] = false;
end

function tracker_ui.toggle()
    ui_visible[1] = not ui_visible[1];
end

function tracker_ui.render()
    if not ui_visible[1] then
        return;
    end
    if is_loading() then
        return;
    end
    if not training_data or not training_data.is_active then
        return;
    end

    local enemies = training_data.enemies;
    if not enemies or #enemies == 0 then
        return;
    end

    update_scale();
    tick();
    fonts_begin();

    imgui.SetNextWindowSizeConstraints({ 0, 0 }, { FLT_MAX, FLT_MAX });
    local win_flags = bit.bor(
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoNavInputs
    );
    if not tracker_ui.shift_held then
        win_flags = bit.bor(win_flags, ImGuiWindowFlags_NoMove);
    end

    push_window_style();
    local font_pushed = false;
    if DYNAMIC and fonts.ready and fonts.text then
        imgui.PushFont(fonts.text, S(BODY));
        font_pushed = true;
    end
    if imgui.Begin('AMAN Tracker', ui_visible, win_flags) then
        panel.fit_now = 0;
        draw_title();
        if draw_section_header('Targets') then
            draw_regime_context();
            for _, enemy in ipairs(enemies) do
                draw_enemy_row(enemy);
            end
            if regime_complete(enemies) then
                draw_notice('Regime complete', HEX.teal);
            end
        end
        if (panel.fit_now or 0) > 0 then
            panel.fit_w = panel.fit_now;
        end
        draw_shadow();
    end
    imgui.End();
    if font_pushed then
        imgui.PopFont();
    end
    pop_window_style();
end

return tracker_ui;
