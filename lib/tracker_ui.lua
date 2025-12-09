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
local MIN_WINDOW_HEIGHT = 150;
local MAX_WINDOW_WIDTH = 300;
local MAX_WINDOW_HEIGHT = 400;

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
    
    -- Set window flags for auto-sizing
    imgui.SetNextWindowSizeConstraints({ MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT }, { MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT });
    
    if imgui.Begin('AMAN Tracker', ui_visible, ImGuiWindowFlags_AlwaysAutoResize) then
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
