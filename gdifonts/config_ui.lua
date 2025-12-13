--[[
AMANTracker - Config UI Module
Simple UI that displays the spacing and heights of elements in the gdifonts UI
]]

local config_ui = {};
local imgui = require('imgui');

-- ============================================================================
-- State
-- ============================================================================

local ui_visible = { false };

-- ============================================================================
-- UI Constants from tracker_ui.lua
-- ============================================================================
-- Note: These values are duplicated here for display purposes only.
-- They reflect the actual values used in lib/tracker_ui.lua
-- If the values in tracker_ui.lua change, update these accordingly.

-- Spacing values
local SPACING_VERTICAL = 5;  -- Vertical spacing between elements
local SPACING_HORIZONTAL = 10;  -- Horizontal spacing for inline elements
local SPACING_NAME_TO_PROGRESS = 2;  -- Space between enemy name and progress bar

-- Font height values
local FONT_HEIGHT_TITLE = 18;  -- Title font height
local FONT_HEIGHT_ENTRY = 16;  -- Entry font height
local FONT_HEIGHT_PROGRESS = 14;  -- Progress font height

-- ============================================================================
-- Module Functions
-- ============================================================================

-- Check if the config window is visible
-- Returns: boolean
function config_ui.is_visible()
    return ui_visible[1];
end

-- Open the config window
function config_ui.open()
    ui_visible[1] = true;
end

-- Close the config window
function config_ui.close()
    ui_visible[1] = false;
end

-- Toggle the config window visibility
function config_ui.toggle()
    ui_visible[1] = not ui_visible[1];
end

-- Render the config UI
function config_ui.render()
    if not ui_visible[1] then
        return;
    end
    
    -- Set window size
    imgui.SetNextWindowSize({ 350, 300 }, ImGuiCond_FirstUseEver);
    
    if imgui.Begin('AMAN Tracker - Config UI', ui_visible) then
        imgui.Text('GDI Fonts UI Configuration');
        imgui.Separator();
        imgui.Spacing();
        
        -- Spacing Section
        imgui.TextColored({ 1.0, 1.0, 0.6, 1.0 }, 'Spacing Values:');
        imgui.Spacing();
        imgui.Indent(20);
        
        imgui.Text(string.format('Vertical Spacing: %d px', SPACING_VERTICAL));
        imgui.Text(string.format('Horizontal Spacing: %d px', SPACING_HORIZONTAL));
        imgui.Text(string.format('Name to Progress Spacing: %d px', SPACING_NAME_TO_PROGRESS));
        
        imgui.Unindent(20);
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();
        
        -- Font Heights Section
        imgui.TextColored({ 1.0, 1.0, 0.6, 1.0 }, 'Font Heights:');
        imgui.Spacing();
        imgui.Indent(20);
        
        imgui.Text(string.format('Title Font Height: %d px', FONT_HEIGHT_TITLE));
        imgui.Text(string.format('Entry Font Height: %d px', FONT_HEIGHT_ENTRY));
        imgui.Text(string.format('Progress Font Height: %d px', FONT_HEIGHT_PROGRESS));
        
        imgui.Unindent(20);
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();
        
        -- Additional Info
        imgui.TextWrapped('These values define the layout spacing and font sizes used in the GDI Fonts UI mode.');
    end
    imgui.End();
end

return config_ui;
