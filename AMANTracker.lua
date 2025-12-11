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
addon.desc      = 'GUI Tracker for Adventurers Mutual Aid Network Training Regimes';
addon.link      = 'https://github.com/seekey13/AMANTracker';

require('common');
local settings = require('settings');
local parser = require('lib.parser');

-- Load UI module
local tracker_ui = require('lib.tracker_ui');

-- ============================================================================
-- String Constants
-- ============================================================================

local MESSAGES = {
    -- Game messages
    START_PROMPT = "has been placed here by the Adventurers' Mutual Aid Network %(A%.M%.A%.N%.%)",
    TRAINING_START = "The information on this page instructs you to defeat the following:",
    REGIME_CONFIRMED = "New training regime registered!",
    REGIME_CANCELED = "Training regime canceled%.",
    REGIME_COMPLETE = "You have successfully completed the training regime.",
    REGIME_RESET = "Your current training regime will begin anew!",
    DEFEAT_PATTERN_1 = "defeats the (.-)%.",
    DEFEAT_PATTERN_2 = "The (.-) falls to the ground%.",
    PROGRESS_KEYWORD = "designated target",
    PROGRESS_PATTERN = "Progress:%s*(%d+)/(%d+)",
    
    -- Addon messages
    ADDON_PREFIX = "[AMANTracker]",
    RESTORED_HUNT = "Restored active hunt from saved data",
    REGIME_CONFIRMED_MSG = "Training regime confirmed!",
    ACTIVE_TRAINING_FMT = "Active Training: %s in %s (Level %s)",
    DATA_CLEARED = "Training data cleared and saved.",
};

-- Persistent data field schema (fields that are saved to disk)
local PERSISTENT_FIELDS = {
    'is_active',
    'enemies',
    'target_level_range',
    'training_area_zone',
};

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
    regime_will_repeat = false,  -- Track if regime reset message was seen before completion
};

-- Load saved settings
local saved_data = settings.load(default_settings);

-- Helper function to sync persistent data fields between tables
local function sync_persistent_data(source, target)
    for _, field in ipairs(PERSISTENT_FIELDS) do
        target[field] = source[field];
    end
end

-- Restore saved hunt data if it exists
if saved_data.is_active then
    sync_persistent_data(saved_data, training_data);
    
    -- Print restoration message
    if #training_data.enemies > 0 then
        print(MESSAGES.ADDON_PREFIX .. ' ' .. MESSAGES.RESTORED_HUNT);
    end
end

-- Initialize the UI with training data reference
tracker_ui.init(training_data);

-- Helper function to save current hunt data
local function save_training_data()
    sync_persistent_data(training_data, saved_data);
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
    training_data.regime_will_repeat = false;
    
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

-- Helper function to validate training state
local function is_training_valid()
    return training_data and training_data.is_active;
end

-- Message handler functions
local function handle_tome_interaction()
    training_data.is_active = true;
end

local function handle_training_start()
    training_data.is_parsing = true;
    clear_training_data();
    training_data.is_active = true;
    training_data.is_parsing = true;
end

local function handle_level_range(msg)
    local level_range = parser.parse_level_range(msg);
    if level_range then
        training_data.target_level_range = level_range;
        training_data.is_parsing = false;
        return true;
    end
    return false;
end

local function handle_enemy_parsing(msg)
    if #training_data.raw_enemy_lines == 0 then
        table.insert(training_data.raw_enemy_lines, msg);
        
        -- Use parser module to extract all enemies
        local enemies = parser.parse_enemies(msg);
        for _, enemy in ipairs(enemies) do
            table.insert(training_data.enemies, enemy);
        end
    end
end

local function handle_training_area(msg)
    if not training_data.is_parsing and training_data.target_level_range and not training_data.training_area_zone then
        local training_area = parser.parse_training_area(msg);
        if training_area then
            training_data.training_area_zone = training_area;
            return true;
        end
    end
    return false;
end

local function handle_regime_confirmation()
    print(MESSAGES.ADDON_PREFIX .. ' ' .. MESSAGES.REGIME_CONFIRMED_MSG);
    local enemy_str = "";
    for i, enemy in ipairs(training_data.enemies) do
        if i > 1 then enemy_str = enemy_str .. ", " end
        enemy_str = enemy_str .. string.format("%d %s", enemy.total, enemy.name);
    end
    print(string.format(MESSAGES.ADDON_PREFIX .. ' ' .. MESSAGES.ACTIVE_TRAINING_FMT, 
        enemy_str ~= "" and enemy_str or "Unknown",
        training_data.training_area_zone or "Unknown",
        training_data.target_level_range or "Unknown"));
    save_training_data();
end

local function handle_regime_cancellation()
    clear_training_data();
end

local function handle_regime_reset()
    training_data.regime_will_repeat = true;
    for i, enemy in ipairs(training_data.enemies) do
        enemy.killed = 0;
    end
    save_training_data();
end

local function handle_regime_complete()
    if training_data.regime_will_repeat then
        -- Reset was seen before completion, just reset the flag
        training_data.regime_will_repeat = false;
    else
        -- No reset message, regime is complete and won't repeat
        clear_training_data();
    end
end

local function handle_enemy_defeat(msg)
    local defeated_enemy = string.match(msg, MESSAGES.DEFEAT_PATTERN_1);
    if not defeated_enemy then
        defeated_enemy = string.match(msg, MESSAGES.DEFEAT_PATTERN_2);
    end
    
    if defeated_enemy then
        local enemy, index = find_enemy_by_name(defeated_enemy);
        if enemy then
            training_data.last_defeated_enemy = defeated_enemy;
        end
        return true;
    end
    return false;
end

local function handle_progress_update(msg)
    local current, total = string.match(msg, MESSAGES.PROGRESS_PATTERN);
    if current and total and training_data.last_defeated_enemy then
        local enemy, index = find_enemy_by_name(training_data.last_defeated_enemy);
        if enemy then
            enemy.killed = tonumber(current);
            save_training_data();
        end
    end
    training_data.last_defeated_enemy = nil;
end

-- Message handler dispatch table
local message_handlers = {
    {
        pattern = MESSAGES.START_PROMPT,
        handler = handle_tome_interaction,
        check_active = false
    },
    {
        pattern = MESSAGES.TRAINING_START,
        handler = handle_training_start,
        check_active = true
    },
    {
        pattern = MESSAGES.REGIME_CONFIRMED,
        handler = handle_regime_confirmation,
        check_active = true
    },
    {
        pattern = MESSAGES.REGIME_CANCELED,
        handler = handle_regime_cancellation,
        check_active = true
    },
    {
        pattern = MESSAGES.REGIME_RESET,
        handler = handle_regime_reset,
        check_active = true
    },
    {
        pattern = MESSAGES.REGIME_COMPLETE,
        handler = handle_regime_complete,
        check_active = true
    },
    {
        pattern = MESSAGES.PROGRESS_KEYWORD,
        handler = handle_progress_update,
        check_active = true
    }
};

-- Event: Incoming text (chat messages)
ashita.events.register('text_in', 'text_in_cb', function (e)
    local msg = e.message;
    local msg_stripped = msg:strip_colors();
    
    -- Process message handlers
    for _, handler_info in ipairs(message_handlers) do
        if string.find(msg, handler_info.pattern) then
            -- Check if handler requires active training
            if not handler_info.check_active or is_training_valid() then
                handler_info.handler(msg_stripped);
                return;
            end
        end
    end
    
    -- Only process further messages if tracking is active
    if not is_training_valid() then
        return;
    end
    
    msg = msg_stripped;
    
    -- Handle parsing mode
    if training_data.is_parsing then
        if handle_level_range(msg) then
            return;
        end
        handle_enemy_parsing(msg);
        return;
    end
    
    -- Handle training area parsing
    if handle_training_area(msg) then
        return;
    end
    
    -- Handle enemy defeat
    if handle_enemy_defeat(msg) then
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