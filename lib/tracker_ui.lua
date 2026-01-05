--[[
AMANTracker - Tracker UI Module
ImGui + GDI Fonts hybrid display interface for the AMANTracker addon
]]

local tracker_ui = {};
local imgui = require('imgui');
local gdi = require('gdifonts.include');
local ffi = require('ffi');

-- ============================================================================
-- State
-- ============================================================================

local ui_visible = { false };  -- Start hidden, auto-show when data is available
local ui_mode = 'gdifonts';  -- 'gdifonts' or 'imgui'

-- Training data reference (set via init)
local training_data = nil;

-- GDI Font Objects Storage
local ui_objects = T{
    training_area_text = nil,
    level_range_text = nil,
    enemy_entries = {},  -- Array of {name_text, progress_text} objects
};

-- Font Settings
local font_settings = T{
    title = T{
        font_alignment = gdi.Alignment.Left,
        font_color = 0xFFFFFF99,        -- Light yellow
        font_family = 'Consolas',
        font_flags = gdi.FontFlags.Bold,
        font_height = 18,
        outline_color = 0xFF000000,
        outline_width = 2,
    },
    entry = T{
        font_alignment = gdi.Alignment.Left,
        font_color = 0xFFFFFFFF,        -- White
        font_family = 'Consolas',
        font_flags = gdi.FontFlags.Bold,
        font_height = 16,
        outline_color = 0xFF000000,
        outline_width = 2,
    },
    progress = T{
        font_alignment = gdi.Alignment.Left,
        font_color = 0xFF00FF00,        -- Green
        font_family = 'Consolas',
        font_flags = gdi.FontFlags.Bold,
        font_height = 14,
        outline_color = 0xFF000000,
        outline_width = 2,
    },
};

-- ============================================================================
-- UI Constants
-- ============================================================================

local SPACING_VERTICAL = 5;  -- Vertical spacing between elements
local SPACING_HORIZONTAL = 10;  -- Horizontal spacing for inline elements
local SPACING_NAME_TO_PROGRESS = 2;  -- Space between enemy name and progress bar

-- Window position settings (nil = user controlled, or set {x, y} for default position)
local window_position = nil;  -- Example: { 100, 100 } to position at x=100, y=100

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Format enemy names for display with proper capitalization
local function format_enemy_name_for_display(enemy_name)
    -- Check if this is a family pattern (e.g., "members of the bee family")
    local family_type = enemy_name:match("^[Mm]ember[s]? of (?:the )?(.+) [Ff]amily$");
    if family_type then
        -- Capitalize "Members" and the first letter of family name
        local capitalized_family = family_type:sub(1,1):upper() .. family_type:sub(2):lower();
        return string.format("Members of the %s Family", capitalized_family);
    end
    
    -- For non-family enemies, return as-is
    return enemy_name;
end

-- ============================================================================
-- Module Functions
-- ============================================================================

-- Initialize GDI font objects
-- Must be called after any settings changes
local function initialize_ui_objects()
    -- Destroy existing objects if they exist
    if ui_objects.training_area_text ~= nil then
        gdi:destroy_object(ui_objects.training_area_text);
    end
    if ui_objects.level_range_text ~= nil then
        gdi:destroy_object(ui_objects.level_range_text);
    end
    
    -- Clear out old enemy entries
    for i, entry in ipairs(ui_objects.enemy_entries) do
        if entry ~= nil then
            if entry.name_text ~= nil then
                gdi:destroy_object(entry.name_text);
            end
            if entry.progress_text ~= nil then
                gdi:destroy_object(entry.progress_text);
            end
        end
    end
    ui_objects.enemy_entries = {};
    
    -- Create new text objects
    ui_objects.training_area_text = gdi:create_object(font_settings.title);
    ui_objects.level_range_text = gdi:create_object(font_settings.title);
end

-- Set visibility for all GDI text objects
-- Args:
--   visible (boolean) - Whether text should be visible
--   num_enemies (number, optional) - Number of enemy entries to show
local function set_text_visible(visible, num_enemies)
    if ui_objects.training_area_text then
        ui_objects.training_area_text:set_visible(visible);
    end
    if ui_objects.level_range_text then
        ui_objects.level_range_text:set_visible(visible);
    end
    
    num_enemies = num_enemies or #ui_objects.enemy_entries;
    for i, entry in ipairs(ui_objects.enemy_entries) do
        local entry_visible = visible and i <= num_enemies;
        if entry.name_text then
            entry.name_text:set_visible(entry_visible);
        end
        if entry.progress_text then
            entry.progress_text:set_visible(entry_visible);
        end
    end
end

-- Initialize the module with training data reference
-- Args:
--   data (table) - Reference to the training_data table
--   mode (string, optional) - UI mode: 'gdifonts' or 'imgui'
function tracker_ui.init(data, mode)
    training_data = data;
    ui_mode = mode or 'gdifonts';
    if ui_mode == 'gdifonts' then
        initialize_ui_objects();
    end
end

-- Set UI mode
-- Args:
--   mode (string) - 'gdifonts' or 'imgui'
function tracker_ui.set_ui_mode(mode)
    ui_mode = mode;
    if ui_mode == 'gdifonts' then
        initialize_ui_objects();
    else
        -- Clean up GDI objects when switching to imgui
        if ui_objects.training_area_text ~= nil then
            gdi:destroy_object(ui_objects.training_area_text);
            ui_objects.training_area_text = nil;
        end
        if ui_objects.level_range_text ~= nil then
            gdi:destroy_object(ui_objects.level_range_text);
            ui_objects.level_range_text = nil;
        end
        for i, entry in ipairs(ui_objects.enemy_entries) do
            if entry ~= nil then
                if entry.name_text ~= nil then
                    gdi:destroy_object(entry.name_text);
                end
                if entry.progress_text ~= nil then
                    gdi:destroy_object(entry.progress_text);
                end
            end
        end
        ui_objects.enemy_entries = {};
    end
end

-- Check if the tracker window is visible
-- Returns: boolean
function tracker_ui.is_visible()
    return ui_visible[1];
end

-- Open the tracker window
function tracker_ui.open()
    ui_visible[1] = true;
end

-- Close the tracker window
function tracker_ui.close()
    ui_visible[1] = false;
end

-- Toggle the tracker window visibility
function tracker_ui.toggle()
    ui_visible[1] = not ui_visible[1];
end

-- Cleanup function (call on unload)
function tracker_ui.cleanup()
    gdi:destroy_interface();
end

-- Render the old ImGui UI (solid window with decorations)
local function render_imgui_mode()
    if not training_data then
        return;
    end
    
    -- Determine if we have valid data to display
    local has_data = training_data.is_active and 
                     training_data.target_level_range and 
                     training_data.training_area_zone and 
                     training_data.enemies and 
                     #training_data.enemies > 0;
    
    -- Don't render if visibility is false
    if not ui_visible[1] then
        return;
    end
    
    -- Calculate window height based on content
    local line_height = imgui.GetTextLineHeightWithSpacing();
    local separator_height = 8;
    local padding = 20;
    local progress_bar_height = 24;
    
    local num_enemies = has_data and #training_data.enemies or 1;
    local calculated_height = padding + line_height + separator_height + 
                              (num_enemies * (line_height + progress_bar_height)) + 
                              separator_height + line_height + padding;
    
    local MIN_WINDOW_WIDTH = 300;
    local MAX_WINDOW_WIDTH = 500;
    imgui.SetNextWindowSizeConstraints({ MIN_WINDOW_WIDTH, calculated_height }, { MAX_WINDOW_WIDTH, calculated_height });
    
    if imgui.Begin('AMAN Tracker', ui_visible) then
        -- Training Area
        if training_data.training_area_zone then
            imgui.Text(string.format('Training Area: %s', training_data.training_area_zone));
        else
            imgui.TextDisabled('Training Area: None');
        end
        
        imgui.Separator();
        
        -- Display all enemies
        if has_data and training_data.enemies and #training_data.enemies > 0 then
            for i, enemy in ipairs(training_data.enemies) do
                local killed_count = enemy.killed or 0;
                local progress_fraction = killed_count / enemy.total;
                
                imgui.Text(format_enemy_name_for_display(enemy.name));
                
                local bar_color = { 0.2, 0.8, 0.2, 1.0 };
                imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color);
                imgui.ProgressBar(progress_fraction, { -1, 0 }, string.format('%d/%d', killed_count, enemy.total));
                imgui.PopStyleColor(1);
            end
        else
            imgui.TextDisabled('Enemies: None');
        end
        
        imgui.Separator();
        
        -- Level Range
        if training_data.target_level_range then
            imgui.Text(string.format('Level Range: %s', training_data.target_level_range));
        else
            imgui.TextDisabled('Level Range: None');
        end
    end
    imgui.End();
end

-- Render the GDI Fonts hybrid UI (transparent with outlined text)
local function render_gdifonts_mode()
    if not training_data then
        set_text_visible(false);
        return;
    end
    
    -- Determine if we have valid data to display
    local has_data = training_data.is_active and 
                     training_data.target_level_range and 
                     training_data.training_area_zone and 
                     training_data.enemies and 
                     #training_data.enemies > 0;
    
    -- Don't render if visibility is false
    if not ui_visible[1] then
        set_text_visible(false);
        return;
    end
    
    -- Window flags for transparent, moveable window
    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground
    );
    
    -- Set window position if configured
    if window_position ~= nil then
        imgui.SetNextWindowPos(window_position, ImGuiCond_FirstUseEver);
    end
    
    if imgui.Begin('AMAN Tracker', ui_visible, windowFlags) then
        -- Get starting cursor position for absolute positioning
        local cursor_x, cursor_y = imgui.GetCursorScreenPos();
        local offsetY = 0;
        local max_width = 0;
        
        -- Training Area
        if training_data.training_area_zone then
            local training_area_text = string.format('Training Area: %s', training_data.training_area_zone);
            ui_objects.training_area_text:set_text(training_area_text);
            ui_objects.training_area_text:set_position_x(cursor_x);
            ui_objects.training_area_text:set_position_y(cursor_y + offsetY);
            
            local text_w, text_h = ui_objects.training_area_text:get_text_size();
            max_width = math.max(max_width, text_w);
            offsetY = offsetY + text_h + SPACING_VERTICAL * 2;
        else
            ui_objects.training_area_text:set_visible(false);
        end
        
        -- Display all enemies
        if has_data and training_data.enemies and #training_data.enemies > 0 then
            for i, enemy in ipairs(training_data.enemies) do
                -- Create entry objects if they don't exist
                local entry = ui_objects.enemy_entries[i];
                if entry == nil then
                    entry = {};
                    entry.name_text = gdi:create_object(font_settings.entry);
                    entry.progress_text = gdi:create_object(font_settings.progress);
                    ui_objects.enemy_entries[i] = entry;
                end
                
                -- Enemy name
                entry.name_text:set_text(format_enemy_name_for_display(enemy.name));
                entry.name_text:set_position_x(cursor_x);
                entry.name_text:set_position_y(cursor_y + offsetY);
                entry.name_text:set_visible(true);
                
                local name_w, name_h = entry.name_text:get_text_size();
                max_width = math.max(max_width, name_w);
                -- Use consistent font height instead of measured text height to avoid descender issues
                offsetY = offsetY + font_settings.entry.font_height + SPACING_NAME_TO_PROGRESS;
                
                -- Move ImGui cursor to the correct position for progress bar
                imgui.SetCursorScreenPos({ cursor_x, cursor_y + offsetY });
                
                -- Progress bar using ImGui
                local killed_count = enemy.killed or 0;
                local progress_fraction = killed_count / enemy.total;
                local progress_text = string.format('%d/%d', killed_count, enemy.total);
                
                -- Style the progress bar
                local bar_color = { 0.2, 0.8, 0.2, 1.0 };
                imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color);
                imgui.PushItemWidth(250);  -- Set width for progress bar
                imgui.ProgressBar(progress_fraction, { -1, 0 }, progress_text);
                imgui.PopItemWidth();
                imgui.PopStyleColor(1);
                
                local progress_bar_height = 24;  -- Fixed height for progress bar
                max_width = math.max(max_width, 250);
                offsetY = offsetY + progress_bar_height + SPACING_VERTICAL * 2;
                
                -- Reset cursor to ensure consistent positioning for next enemy
                imgui.SetCursorScreenPos({ cursor_x, cursor_y + offsetY });
                
                -- Hide the progress text object since we're using ImGui progress bar
                if entry.progress_text then
                    entry.progress_text:set_visible(false);
                end
            end
            
            -- Hide any extra enemy entries that aren't being used
            for i = #training_data.enemies + 1, #ui_objects.enemy_entries do
                if ui_objects.enemy_entries[i] then
                    ui_objects.enemy_entries[i].name_text:set_visible(false);
                    ui_objects.enemy_entries[i].progress_text:set_visible(false);
                end
            end
        else
            -- Hide all enemy entries if no data
            for i, entry in ipairs(ui_objects.enemy_entries) do
                entry.name_text:set_visible(false);
                entry.progress_text:set_visible(false);
            end
        end
        
        -- Level Range
        if training_data.target_level_range then
            local level_range_text = string.format('Level Range: %s', training_data.target_level_range);
            ui_objects.level_range_text:set_text(level_range_text);
            ui_objects.level_range_text:set_position_x(cursor_x);
            ui_objects.level_range_text:set_position_y(cursor_y + offsetY);
            ui_objects.level_range_text:set_visible(true);
            
            local text_w, text_h = ui_objects.level_range_text:get_text_size();
            max_width = math.max(max_width, text_w);
            offsetY = offsetY + text_h;
        else
            ui_objects.level_range_text:set_visible(false);
        end
        
        -- Create an invisible dummy to make the window draggable
        imgui.Dummy({ max_width, offsetY });
        
        set_text_visible(true, has_data and #training_data.enemies or 0);
    else
        set_text_visible(false);
    end
    imgui.End();
end

-- Main render function (call from d3d_present event)
function tracker_ui.render()
    if ui_mode == 'imgui' then
        render_imgui_mode();
    else
        render_gdifonts_mode();
    end
end

return tracker_ui;
