--[[
AMANTracker
GUI Tracker for Adventurers' Mutual Aid Network Training Regimes
Copyright (c) 2025 Seekey
https://github.com/seekey13/AMANTracker

This addon is designed for Ashita v4.
]]

addon.name      = 'AMANTracker';
addon.author    = 'Seekey';
addon.version   = '1.0';
addon.desc      = 'GUI Tracker for Adventurers\' Mutual Aid Network Training Regimes';
addon.link      = 'https://github.com/seekey13/AMANTracker';

require('common');
local settings = require('settings');

-- Load UI module
local tracker_ui = require('lib.tracker_ui');

-- Default settings (structure for persistent data)
local default_settings = T{
    is_active = false,
    enemies = {},  -- Array of {total, killed, name} tables
    target_level_range = nil,
    training_area_zone = nil,
};

-- Training data storage (includes both persistent and transient data)
local training_data = {
    is_active = false,
    is_parsing = false,
    enemies = {},  -- Array of {total, killed, name} tables
    target_level_range = nil,
    training_area_zone = nil,
    raw_enemy_lines = {},  -- Debug: capture all raw lines between markers
    last_defeated_enemy = nil,  -- Track last defeated enemy name for progress matching
};

-- Load saved settings
local saved_data = settings.load(default_settings);

-- Helper function to sync persistent data fields between tables
local function sync_persistent_data(source, target)
    target.is_active = source.is_active;
    target.enemies = source.enemies;
    target.target_level_range = source.target_level_range;
    target.training_area_zone = source.training_area_zone;
end

-- Restore saved hunt data if it exists
if saved_data.is_active then
    sync_persistent_data(saved_data, training_data);
    
    -- Print restoration message
    if #training_data.enemies > 0 then
        print('[AMANTracker] Restored active hunt from saved data');
    end
end

-- Initialize the UI with training data reference
tracker_ui.init(training_data);

-- Helper function to save current hunt data
local function save_training_data()
    saved_data.is_active = training_data.is_active;
    saved_data.enemies = training_data.enemies;
    saved_data.target_level_range = training_data.target_level_range;
    saved_data.training_area_zone = training_data.training_area_zone;
    settings.save();
end

-- Register settings callback for external changes
settings.register('settings', 'settings_update', function(s)
    if s ~= nil then
        saved_data = s;
        -- Restore to training_data if different
        if s.is_active ~= training_data.is_active or 
           s.target_level_range ~= training_data.target_level_range then
            sync_persistent_data(s, training_data);
        end
    end
end);

-- Helper function to clear training data
local function clear_training_data()
    training_data.is_active = false;
    training_data.is_parsing = false;
    training_data.enemies = {};
    training_data.target_level_range = nil;
    training_data.training_area_zone = nil;
    training_data.raw_enemy_lines = {};
    training_data.last_defeated_enemy = nil;
    
    -- Save the cleared state
    save_training_data();
end

-- Helper function to find enemy in tracking list by name
-- Handles both singular and plural forms
local function find_enemy_by_name(enemy_name)
    for i, enemy in ipairs(training_data.enemies) do
        -- Exact match
        if enemy.name == enemy_name then
            return enemy, i;
        end
        
        -- Try singular to plural match (defeat message is singular, list might be plural)
        -- Simple pluralization: add 's'
        if enemy.name == enemy_name .. "s" then
            return enemy, i;
        end
        
        -- Try plural to singular match (list is plural, message might be singular)
        if enemy.name:sub(-1) == "s" and enemy.name:sub(1, -2) == enemy_name then
            return enemy, i;
        end
    end
    return nil, nil;
end

-- Helper function to parse enemy line (e.g., "5 Donjon Bats.")
local function parse_enemy_line(line)
    -- Exclude lines that are level range or training area
    if string.find(line, "Target level range:") or string.find(line, "Training area:") then
        return nil, nil;
    end
    
    -- Match: number, spaces, non-period characters, then a period
    -- This prevents matching across multiple enemies
    local count, name = string.match(line, "^%s*(%d+)%s+([^%.]+)%.");
    if count and name then
        return tonumber(count), name;
    end
    return nil, nil;
end

-- Helper function to parse level range (e.g., "Target level range: 48~49.")
local function parse_level_range(line)
    -- Extract the two numbers after "Target level range:"
    local first_num, second_num = string.match(line, "Target level range:%s*(%d+)%D*(%d+)");
    if first_num and second_num then
        return first_num .. "~" .. second_num;
    end
    return nil;
end

-- Helper function to parse training area (e.g., "Training area: Garlaige Citadel.")
local function parse_training_area(line)
    local area = string.match(line, "Training area:%s*(.-)%.$");
    return area;
end

-- Event: Incoming text (chat messages)
ashita.events.register('text_in', 'text_in_cb', function (e)
    local msg = e.message;
    local msg_stripped = msg:strip_colors();
    
    -- Check for Grounds Tome interaction - initialize tracking
    if string.find(msg, "A grounds tome has been placed here by the Adventurers' Mutual Aid Network %(A%.M%.A%.N%.%)") then
        training_data.is_active = true;
    end
    
    -- Only process further messages if tracking is active
    if not training_data.is_active then
        return;
    end
    
    -- Use stripped message for pattern matching (removes color codes)
    msg = msg_stripped;
    
    -- Check for training selection start
    if string.find(msg, "The information on this page instructs you to defeat the following:") then
        training_data.is_parsing = true;
        clear_training_data();
        training_data.is_active = true;
        training_data.is_parsing = true;
        return;
    end
    -- Parse enemy and training details while in parsing mode
    if training_data.is_parsing then
        -- Check if we hit the level range line - this ends enemy parsing
        local level_range = parse_level_range(msg);
        if level_range then
            training_data.target_level_range = level_range;
            training_data.is_parsing = false;  -- Stop parsing enemies
            return;
        end
        
        -- Store only the first raw line for debugging
        if #training_data.raw_enemy_lines == 0 then
            table.insert(training_data.raw_enemy_lines, msg);
            
            -- Parse all enemies from this first line only
            local remaining_text = msg;
            while true do
                local count, name = string.match(remaining_text, "(%d+)%s+([^%.?]+)%.");
                if not count or not name then
                    break;  -- No more enemies found
                end
                
                -- Check if this is not a level range or training area
                if not string.find(name, "Target level range") and not string.find(name, "Training area") then
                    table.insert(training_data.enemies, {total = tonumber(count), killed = 0, name = name});
                end
                
                -- Remove this enemy from the remaining text
                local pattern = count .. "%s+" .. name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "%.";
                remaining_text = string.gsub(remaining_text, pattern, "", 1);
            end
        end
        return;
    end
    
    -- Parse training area (after level range, outside parsing mode)
    if not training_data.is_parsing and training_data.target_level_range and not training_data.training_area_zone then
        local training_area = parse_training_area(msg);
        if training_area then
            training_data.training_area_zone = training_area;
            return;
        end
    end
    
    -- Check for training confirmation
    if string.find(msg, "New training regime registered!") then
        print("[AMANTracker] Training regime confirmed!");
        local enemy_str = "";
        for i, enemy in ipairs(training_data.enemies) do
            if i > 1 then enemy_str = enemy_str .. ", " end
            enemy_str = enemy_str .. string.format("%d %s", enemy.total, enemy.name);
        end
        print(string.format("[AMANTracker] Active Training: %s in %s (Level %s)", 
            enemy_str ~= "" and enemy_str or "Unknown",
            training_data.training_area_zone or "Unknown",
            training_data.target_level_range or "Unknown"));
        
        -- Save the confirmed training data
        save_training_data();
        return;
    end
    
    -- Check for training cancellation
    if string.find(msg, "Training regime canceled%.") then
        clear_training_data();
        return;
    end
    
    -- Check for training completion and reset
    if string.find(msg, "Your current training regime will begin anew!") then
        -- Reset all kill counts to 0
        for i, enemy in ipairs(training_data.enemies) do
            enemy.killed = 0;
        end
        save_training_data();
        return;
    end
    
    -- Check for enemy defeat (two patterns)
    -- Pattern 1: "[Player] defeats the [Enemy Name]."
    -- Pattern 2: "The [Enemy Name] falls to the ground."
    local defeated_enemy = nil;
    
    -- Try pattern 1: player defeats enemy
    defeated_enemy = string.match(msg, "defeats the (.-)%.");
    
    -- Try pattern 2: enemy falls to ground
    if not defeated_enemy then
        defeated_enemy = string.match(msg, "The (.-) falls to the ground%.");
    end
    
    if defeated_enemy then
        -- Check if this enemy is in our tracking list
        local enemy, index = find_enemy_by_name(defeated_enemy);
        if enemy then
            training_data.last_defeated_enemy = defeated_enemy;
        end
        return;
    end
    
    -- Check for progress update (must follow an enemy defeat)
    -- Pattern: "You have defeated a designated target. (Progress: X/Y)"
    if string.find(msg, "designated target") then
        local current, total = string.match(msg, "Progress:%s*(%d+)/(%d+)");
        if current and total and training_data.last_defeated_enemy then
            local enemy, index = find_enemy_by_name(training_data.last_defeated_enemy);
            if enemy then
                enemy.killed = tonumber(current);
                -- Save progress
                save_training_data();
            end
        end
        training_data.last_defeated_enemy = nil;  -- Reset after processing
        return;
    end
end);

-- Event: Render UI
ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    tracker_ui.render();
end);

-- Event: Addon unload - save data
ashita.events.register('unload', 'unload_cb', function()
    save_training_data();
end);

-- Command: Handle addon commands
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if #args == 0 or args[1] ~= '/amantracker' then
        return;
    end
    
    e.blocked = true;
    
    -- Toggle UI visibility
    if #args == 1 or args[2] == 'toggle' then
        tracker_ui.toggle();
        return;
    end
    
    -- Show UI
    if args[2] == 'show' then
        tracker_ui.open();
        return;
    end
    
    -- Hide UI
    if args[2] == 'hide' then
        tracker_ui.close();
        return;
    end
    
    -- Clear saved data
    if args[2] == 'clear' then
        clear_training_data();
        print('[AMANTracker] Training data cleared and saved.');
        return;
    end
    
    -- Help
    print('[AMANTracker] Commands:');
    print('  /amantracker - Toggle UI');
    print('  /amantracker toggle - Toggle UI');
    print('  /amantracker show - Show UI');
    print('  /amantracker hide - Hide UI');
    print('  /amantracker clear - Clear saved training data');
    print('  /amantracker debug - Show debug information');
end);