--[[
AMANTracker - Tracker UI Module
ImGui-based display interface for the AMANTracker addon
]]

local tracker_ui = {};
local imgui = require('imgui');

-- ============================================================================
-- State
-- ============================================================================

local ui_visible = { true };

-- Training data reference (set via init)
local training_data = nil;

-- ============================================================================
-- UI Constants
-- ============================================================================

local MIN_WINDOW_WIDTH = 300;
local MAX_WINDOW_WIDTH = 500;

-- ============================================================================
-- Module Functions
-- ============================================================================

-- Initialize the module with training data reference
-- Args:
--   data (table) - Reference to the training_data table
function tracker_ui.init(data)
    training_data = data;
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

-- Helper function to display a field with fallback to "None" text
-- Args:
--   label (string) - The label for the field
--   value (any) - The value to display (nil shows as disabled "None")
--   format_string (string, optional) - Format string with %s placeholder for value
local function display_field(label, value, format_string)
    if value then
        local display_text = format_string and string.format(format_string, value) or string.format('%s: %s', label, value);
        imgui.Text(display_text);
    else
        imgui.TextDisabled(string.format('%s: None', label));
    end
end

-- Helper function to render a styled progress bar
-- Args:
--   fraction (number) - Progress fraction (0.0 to 1.0)
--   label (string) - Label text to display on the progress bar
--   color (table, optional) - RGBA color table {r, g, b, a}, defaults to green
local function render_progress_bar(fraction, label, color)
    local bar_color = color or { 0.2, 0.8, 0.2, 1.0 };
    imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color);
    imgui.ProgressBar(fraction, { -1, 0 }, label);
    imgui.PopStyleColor(1);
end

-- Render the tracker UI (call from d3d_present event)
function tracker_ui.render()
    if not ui_visible[1] then
        return;
    end
    
    if not training_data then
        return;
    end
    
    -- Only show UI when training is active
    if not training_data.is_active then
        return;
    end
    
    -- Only show UI when we have parsed data (not all nil)
    if not training_data.target_level_range or not training_data.training_area_zone or not training_data.enemies or #training_data.enemies == 0 then
        return;
    end
    
    -- Calculate window height based on content
    local line_height = imgui.GetTextLineHeightWithSpacing();
    local separator_height = 8; -- Approximate height of separator
    local padding = 20; -- Window padding
    local progress_bar_height = 24; -- Height of progress bar
    
    -- Content: Training Area (1 line) + Separator + Enemies (name + progress bar per enemy) + Separator + Level Range (1 line)
    local num_enemies = #training_data.enemies;
    local calculated_height = padding + line_height + separator_height + 
                              (num_enemies * (line_height + progress_bar_height)) + 
                              separator_height + line_height + padding;
    
    -- Set window size constraints (width adjustable, height fixed)
    imgui.SetNextWindowSizeConstraints({ MIN_WINDOW_WIDTH, calculated_height }, { MAX_WINDOW_WIDTH, calculated_height });
    
    if imgui.Begin('AMAN Tracker', ui_visible) then
        -- Training Area
        display_field('Training Area', training_data.training_area_zone);
        
        imgui.Separator();
        
        -- Display all enemies
        if training_data.enemies and #training_data.enemies > 0 then
            for i, enemy in ipairs(training_data.enemies) do
                local killed_count = enemy.killed or 0;
                local progress_fraction = killed_count / enemy.total;
                
                -- Enemy name (left justified)
                imgui.Text(enemy.name);
                
                -- Progress bar with count overlay
                render_progress_bar(progress_fraction, string.format('%d/%d', killed_count, enemy.total));
            end
        else
            imgui.TextDisabled('Enemies: None');
        end
        
        imgui.Separator();
        
        -- Target Level Range
        display_field('Level Range', training_data.target_level_range);
    end
    imgui.End();
end

return tracker_ui;
