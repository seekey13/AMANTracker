--[[
AMANTracker
Automatically removes invisible status when attempting to use commands while invisible.
Copyright (c) 2025 Seekey
https://github.com/seekey13/AMANTracker

This addon is designed for Ashita v4.
]]

addon.name      = 'AMANTracker';
addon.author    = 'Seekey';
addon.version   = '0.1';
addon.desc      = 'Automatically removes invisible status when blocked by invisibility';
addon.link      = 'https://github.com/seekey13/AMANTracker';

require('common');

-- Load UI module
local tracker_ui = require('lib.tracker_ui');

-- Training data storage
local training_data = {
    is_active = false,
    is_parsing = false,
    enemy_1_total = nil,
    enemy_name_1 = nil,
    enemy_2_total = nil,
    enemy_name_2 = nil,
    target_level_range = nil,
    training_area_zone = nil
};

-- Initialize the UI with training data reference
tracker_ui.init(training_data);

-- Helper function to clear training data
local function clear_training_data()
    training_data.is_active = false;
    training_data.is_parsing = false;
    training_data.enemy_1_total = nil;
    training_data.enemy_name_1 = nil;
    training_data.enemy_2_total = nil;
    training_data.enemy_name_2 = nil;
    training_data.target_level_range = nil;
    training_data.training_area_zone = nil;
end

-- Helper function to parse enemy line (e.g., "5 Donjon Bats.")
local function parse_enemy_line(line)
    -- Try to find pattern anywhere in the line, not just at the start
    local count, name = string.match(line, "(%d+)%s+(.-)%.");
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
    
    -- Check for Grounds Tome interaction - initialize tracking
    if string.find(msg, "A grounds tome has been placed here by the Adventurers' Mutual Aid Network %(A%.M%.A%.N%.%)") then
        training_data.is_active = true;
    end
    
    -- Only process further messages if tracking is active
    if not training_data.is_active then
        return;
    end
    
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
        -- Try to parse as enemy line
        local count, name = parse_enemy_line(msg);
        if count and name then
            if not training_data.enemy_1_total then
                training_data.enemy_1_total = count;
                training_data.enemy_name_1 = name;
            elseif not training_data.enemy_2_total then
                training_data.enemy_2_total = count;
                training_data.enemy_name_2 = name;
            end
            return;
        end
        
        -- Try to parse level range
        local level_range = parse_level_range(msg);
        if level_range then
            training_data.target_level_range = level_range;
            return;
        end
        
        -- Try to parse training area
        local training_area = parse_training_area(msg);
        if training_area then
            training_data.training_area_zone = training_area;
            return;
        end
    end
    
    -- Check for training confirmation
    if string.find(msg, "New training regime registered!") then
        training_data.is_parsing = false;
        print("[AMANTracker] Training regime confirmed!");
        print(string.format("[AMANTracker] Active Training: %d %s, %d %s in %s (Level %s)", 
            training_data.enemy_1_total or 0, 
            training_data.enemy_name_1 or "Unknown",
            training_data.enemy_2_total or 0,
            training_data.enemy_name_2 or "Unknown",
            training_data.training_area_zone or "Unknown",
            training_data.target_level_range or "Unknown"));
        return;
    end
    
    -- Check for training cancellation
    if string.find(msg, "Training regime canceled%.") then
        clear_training_data();
        return;
    end
end);

-- Event: Render UI
ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    tracker_ui.render();
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
    
    -- Help
    print('[AMANTracker] Commands:');
    print('  /amantracker - Toggle UI');
    print('  /amantracker toggle - Toggle UI');
    print('  /amantracker show - Show UI');
    print('  /amantracker hide - Hide UI');
end);