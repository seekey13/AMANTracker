--[[
AMANTracker - Tracker UI
Goldilox-style window: untitled auto-sized panel, Shift to drag,
progress bars with the count on the right, and BG-Wiki links.
]]

local tracker_ui = {};
local imgui = require('imgui');
local family = require('lib.family');

-- ============================================================================
-- State
-- ============================================================================

local ui_visible = { false };  -- Start hidden, auto-show when a regime is restored or confirmed
tracker_ui.shift_held = false;

-- Training data reference (set via init)
local training_data = nil;

-- Minimum width keeps a short target name from sitting on top of its count.
-- Long family labels ("Members of the Evil Weapon Family") plus the count need the room.
local MIN_WINDOW_WIDTH = 420;

-- ============================================================================
-- Colors and bar helpers (same palette and bar layout as goldilox-ui)
-- ============================================================================

local COLORS = {
    white     = { 1.0, 1.0, 1.0, 1.0 },
    green     = { 0.0, 1.0, 0.0, 0.25 },
    link      = { 0.0, 1.0, 0.0, 1.0 },
    orange    = { 1.0, 0.6, 0.0, 1.0 },
    grey_text = { 0.5, 0.5, 0.5, 1.0 },
    grey_bar  = { 0.4, 0.4, 0.4, 1.0 },
    dark_grey = { 0.3, 0.3, 0.3, 1.0 },
};

local SPACING = 10;

-- Words that are already singular and happen to end in "s".
local SINGULAR_NAMES = {
    gigas = true,
};

-- Draw a collapsible section header. Returns true when the section is expanded.
local function draw_section_header(text)
    imgui.PushStyleColor(ImGuiCol_Header,        COLORS.dark_grey);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, COLORS.grey_bar);
    imgui.PushStyleColor(ImGuiCol_HeaderActive,  COLORS.grey_text);
    local expanded = imgui.CollapsingHeader(text, ImGuiTreeNodeFlags_DefaultOpen);
    imgui.PopStyleColor(3);
    return expanded;
end

-- fraction: 0.0-1.0. count_text is drawn on the right of the bar, not in the bar's own label.
local function draw_progress_bar(fraction, count_text, bar_color)
    imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color or COLORS.green);
    imgui.ProgressBar(fraction, { -1, 0 }, '');
    imgui.PopStyleColor(1);

    local min_x, min_y = imgui.GetItemRectMin();
    local max_x, max_y = imgui.GetItemRectMax();
    local draw_list = imgui.GetWindowDrawList();
    local text_color = (bar_color == COLORS.grey_bar) and 0xFF808080 or 0xFFFFFFFF;
    local pad = 4;
    local text_y = min_y + ((max_y - min_y) - imgui.GetTextLineHeight()) * 0.5;
    local count_width = imgui.CalcTextSize(count_text);
    draw_list:AddText({ max_x - count_width - pad, text_y }, text_color, count_text);

    return min_x, min_y, max_x, max_y;
end

local function begin_bar_overlay(min_x, min_y, max_y)
    local pad = 4;
    local text_y = min_y + ((max_y - min_y) - imgui.GetTextLineHeight()) * 0.5;
    imgui.SetCursorScreenPos({ min_x + pad, text_y });
end

-- content_fn receives the bar rect. add_spacing defaults to a gap under the bar.
local function draw_bar_with_overlay(fraction, count_text, bar_color, content_fn, add_spacing)
    local bx, by, bx2, by2 = draw_progress_bar(fraction, count_text, bar_color);
    local after_x, after_y = imgui.GetCursorScreenPos();
    begin_bar_overlay(bx, by, by2);
    if content_fn then
        content_fn(bx, by, bx2, by2);
    end
    imgui.SetCursorScreenPos({ after_x, after_y });
    if add_spacing ~= false then
        imgui.Spacing(SPACING);
    end
end

-- ============================================================================
-- Wiki links
-- ============================================================================

local function to_wiki_path(name)
    return name:gsub(' ', '_'):gsub("'", '%%27');
end

local function to_wiki_path_titled(name)
    local titled = name:gsub('(%a)([%w\']*)', function(first, rest)
        return first:upper() .. rest:lower();
    end);
    return titled:gsub(' ', '_'):gsub("'", '%%27');
end

-- Tome lines are plural ("5 Leeches."). The wiki page is the singular.
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
    local draw_list = imgui.GetWindowDrawList();
    local a = math.floor((color[4] or 1.0) * 255);
    local b = math.floor((color[3] or 0) * 255);
    local g = math.floor((color[2] or 0) * 255);
    local r = math.floor((color[1] or 0) * 255);
    local col_u32 = bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r);
    draw_list:AddLine({ min_x, max_y }, { max_x, max_y }, col_u32, 1.0);
    if imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip_text);
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

-- Family rows link to the BG-Wiki category. "Bats" is filed under Bat; Gigas is already singular.
local function draw_family_link(family_type, color)
    local display = title_case(family_type);
    local wiki_name = display;
    if display:lower() == 'bats' then
        wiki_name = 'Bat';
    end
    local url = 'https://www.bg-wiki.com/ffxi/Category:' .. to_wiki_path_titled(wiki_name);
    draw_link(display, color, url);
end

-- Exact tome targets are specific mobs, so the link is the mob page rather than a category.
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

    draw_bar_with_overlay(0, '', COLORS.dark_grey, function(bx, by, bx2, by2)
        local right_text = level and ('Lv ' .. level) or '';
        local right_w = (right_text ~= '') and imgui.CalcTextSize(right_text) or 0;
        local pad = 4;
        local draw_list = imgui.GetWindowDrawList();

        if right_text ~= '' then
            draw_list:PushClipRect({ bx, by }, { bx2 - right_w - pad * 2, by2 }, true);
        end

        if zone then
            imgui.TextColored(COLORS.white, 'Training in ');
            imgui.SameLine();
            draw_zone_link(zone, COLORS.link);
        else
            imgui.TextColored(COLORS.orange, 'Training area unknown');
        end

        if right_text ~= '' then
            draw_list:PopClipRect();
            local right_y = by + ((by2 - by) - imgui.GetTextLineHeight()) * 0.5;
            imgui.SetCursorScreenPos({ bx2 - right_w - pad, right_y });
            imgui.TextColored(COLORS.white, right_text);
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
        -- The count is painted on the draw list, so reserve its width in the layout.
        imgui.SameLine();
        imgui.TextColored(label_color, '            ');
    end);
end

-- Returns true while the character is still zoning or sitting on the character select screen.
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

    imgui.SetNextWindowSizeConstraints({ MIN_WINDOW_WIDTH, 0 }, { FLT_MAX, FLT_MAX });
    local win_flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar);
    if not tracker_ui.shift_held then
        win_flags = bit.bor(win_flags, ImGuiWindowFlags_NoMove);
    end

    if imgui.Begin('AMAN Tracker', ui_visible, win_flags) then
        if draw_section_header('A.M.A.N. Training  ') then
            draw_regime_context();
            for _, enemy in ipairs(enemies) do
                draw_enemy_row(enemy);
            end
        end
    end
    imgui.End();
end

return tracker_ui;
