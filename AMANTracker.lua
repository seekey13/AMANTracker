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
    local count, name = string.match(line, "^(%d+)%s+(.-)%.$");
    if count and name then
        return tonumber(count), name;
    end
    return nil, nil;
end

-- Helper function to parse level range (e.g., "Target level range: 48~49.")
local function parse_level_range(line)
    local range = string.match(line, "Target level range:%s*(.-)%.$");
    return range;
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
        print("[AMANTracker] Now monitoring for training regime.");
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
        print("[AMANTracker] Training regime detected, parsing targets...");
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
                print(string.format("[AMANTracker] Enemy 1: %d x %s", count, name));
            elseif not training_data.enemy_2_total then
                training_data.enemy_2_total = count;
                training_data.enemy_name_2 = name;
                print(string.format("[AMANTracker] Enemy 2: %d x %s", count, name));
            end
            return;
        end
        
        -- Try to parse level range
        local level_range = parse_level_range(msg);
        if level_range then
            training_data.target_level_range = level_range;
            print(string.format("[AMANTracker] Level Range: %s", level_range));
            return;
        end
        
        -- Try to parse training area
        local training_area = parse_training_area(msg);
        if training_area then
            training_data.training_area_zone = training_area;
            print(string.format("[AMANTracker] Training Area: %s", training_area));
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
        print("[AMANTracker] Training regime canceled, clearing data.");
        clear_training_data();
        return;
    end
end);