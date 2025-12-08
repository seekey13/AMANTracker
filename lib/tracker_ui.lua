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
local MAX_WINDOW_WIDTH = 500;
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

-- Render the tracker UI (call from d3d_present event)
function tracker_ui.render()
    if not ui_visible[1] then
        return;
    end
    
    if not training_data then
        return;
    end
    
    -- Set window flags for auto-sizing
    imgui.SetNextWindowSizeConstraints({ MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT }, { MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT });
    
    if imgui.Begin('AMAN Tracker', ui_visible, ImGuiWindowFlags_AlwaysAutoResize) then
        -- Status
        if training_data.is_active then
            imgui.TextColored({ 0.0, 1.0, 0.0, 1.0 }, 'Status: Active');
        else
            imgui.TextColored({ 1.0, 0.5, 0.0, 1.0 }, 'Status: Inactive');
        end
        
        imgui.Separator();
        
        -- Enemy 1
        if training_data.enemy_1_total and training_data.enemy_name_1 then
            imgui.Text(string.format('Enemy 1: %d x %s', training_data.enemy_1_total, training_data.enemy_name_1));
        else
            imgui.TextDisabled('Enemy 1: None');
        end
        
        -- Enemy 2
        if training_data.enemy_2_total and training_data.enemy_name_2 then
            imgui.Text(string.format('Enemy 2: %d x %s', training_data.enemy_2_total, training_data.enemy_name_2));
        else
            imgui.TextDisabled('Enemy 2: None');
        end
        
        imgui.Separator();
        
        -- Target Level Range
        if training_data.target_level_range then
            imgui.Text(string.format('Level Range: %s', training_data.target_level_range));
        else
            imgui.TextDisabled('Level Range: None');
        end
        
        -- Training Area
        if training_data.training_area_zone then
            imgui.Text(string.format('Training Area: %s', training_data.training_area_zone));
        else
            imgui.TextDisabled('Training Area: None');
        end
        
        imgui.Separator();
        
        -- Parsing indicator
        if training_data.is_parsing then
            imgui.TextColored({ 1.0, 1.0, 0.0, 1.0 }, 'Parsing training data...');
        end
    end
    imgui.End();
end

return tracker_ui;
