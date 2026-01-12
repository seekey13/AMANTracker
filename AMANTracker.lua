--[[
AMANTracker
GUI Tracker for Adventurers' Mutual Aid Network Training Regimes
Copyright (c) 2025 Seekey
https://github.com/seekey13/AMANTracker

This addon is designed for Ashita v4.
]]

addon.name      = 'AMANTracker';
addon.author    = 'Seekey';
addon.version   = '2.5';
addon.desc      = 'GUI Tracker for Adventurers Mutual Aid Network Training Regimes';
addon.link      = 'https://github.com/seekey13/AMANTracker';

require('common');
local chat = require('chat')
local settings = require('settings');
local parser = require('lib.parser');
local family = require('lib.family');

-- Load UI module
local tracker_ui = require('lib.tracker_ui');

-- Load packet handler module
local packet_handler = require('lib.packet_handler');

-- Custom print functions for categorized output.
local function printf(fmt, ...)  print(chat.header(addon.name) .. chat.message(fmt:format(...))) end
local function warnf(fmt, ...)   print(chat.header(addon.name) .. chat.warning(fmt:format(...))) end
local function errorf(fmt, ...)  print(chat.header(addon.name) .. chat.error  (fmt:format(...))) end

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
    PROGRESS_KEYWORD = "You have defeated a designated target.",
    PROGRESS_PATTERN = "Progress:%s*(%d+)/(%d+)",
    
    -- Addon messages
    RESTORED_HUNT = "Restored active hunt from saved data",
    REGIME_CONFIRMED_MSG = "Training regime confirmed!",
    REGIME_COMPLETED_MSG = "Training regime completed!",
    ACTIVE_TRAINING_FMT = "Active Training: %s in %s (Level %s)",
    DATA_CLEARED = "Training data cleared and saved.",
};

-- Persistent data field schema (fields that are saved to disk)
local PERSISTENT_FIELDS = {
    'is_active',
    'enemies',
    'target_level_range',
    'training_area_zone',
    'ui_mode',
};

-- Default settings (structure for persistent data)
local default_settings = T{
    is_active = false,
    enemies = {},  -- Array of {total, killed, name, match_type} tables
    target_level_range = nil,
    training_area_zone = nil,
    ui_mode = 'gdifonts',  -- 'gdifonts' or 'imgui'
};

-- Training data storage (includes both persistent and transient data)
local training_data = {
    is_active = false,
    is_parsing = false,
    enemies = {},  -- Array of {total, killed, name, match_type} tables ('exact' or 'family')
    target_level_range = nil,
    training_area_zone = nil,
    raw_enemy_lines = {},  -- Debug: capture all raw lines between markers
    last_defeated_enemy = nil,  -- Track last defeated enemy name for progress matching
    last_packet_progress = nil,  -- Track last progress from packet to avoid duplicate text processing
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
        printf(MESSAGES.RESTORED_HUNT);
    end
end

-- Initialize the UI with training data reference
tracker_ui.init(training_data, saved_data.ui_mode or 'gdifonts');

-- Auto-open UI if there's active training data
if saved_data.is_active and training_data.enemies and #training_data.enemies > 0 then
    tracker_ui.open();
end

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
    
    -- Save the cleared state
    save_training_data();
end

-- Helper function to find enemy in tracking list by name
-- Handles both singular and plural forms, as well as family matching
local function find_enemy_by_name(enemy_name)
    for i, enemy in ipairs(training_data.enemies) do
        -- Use match_type to optimize matching
        if enemy.match_type == 'family' then
            -- Family matching
            local family_type = family.extract_family_type(enemy.name);
            if family_type then
                if family.is_family_member(enemy_name, family_type) then
                    return enemy, i;
                end
            end
        elseif enemy.match_type == 'exact' then
            -- Exact match
            if enemy.name == enemy_name then
                return enemy, i;
            end
            
            -- Try singular to plural match (defeat message is singular, list might be plural)
            if enemy.name == enemy_name .. "s" then
                return enemy, i;
            end
            
            -- Try plural to singular match (list is plural, message might be singular)
            if enemy.name:sub(-1) == "s" and enemy.name:sub(1, -2) == enemy_name then
                return enemy, i;
            end
            
            -- Try y -> ies transformation (e.g., Damselfly -> Damselflies)
            if enemy.name:sub(-3) == "ies" and enemy.name:sub(1, -4) .. "y" == enemy_name then
                return enemy, i;
            end
            
            -- Try ies -> y transformation (e.g., defeated "Damselfly", list has "Damselflies")
            if enemy_name:sub(-1) == "y" and enemy.name == enemy_name:sub(1, -2) .. "ies" then
                return enemy, i;
            end
        else
            -- Legacy support: no match_type specified, try all methods
            
            -- Exact match
            if enemy.name == enemy_name then
                return enemy, i;
            end
            
            -- Check if enemy.name is a family pattern
            local family_type = family.extract_family_type(enemy.name);
            if family_type then
                if family.is_family_member(enemy_name, family_type) then
                    return enemy, i;
                end
            end
            
            -- Try singular/plural variations
            if enemy.name == enemy_name .. "s" then
                return enemy, i;
            end
            if enemy.name:sub(-1) == "s" and enemy.name:sub(1, -2) == enemy_name then
                return enemy, i;
            end
            
            -- Try y -> ies transformation
            if enemy.name:sub(-3) == "ies" and enemy.name:sub(1, -4) .. "y" == enemy_name then
                return enemy, i;
            end
            if enemy_name:sub(-1) == "y" and enemy.name == enemy_name:sub(1, -2) .. "ies" then
                return enemy, i;
            end
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
    print(MESSAGES.REGIME_CONFIRMED_MSG);
    local enemy_str = "";
    for i, enemy in ipairs(training_data.enemies) do
        if i > 1 then enemy_str = enemy_str .. ", " end
        enemy_str = enemy_str .. string.format("%d %s", enemy.total, enemy.name);
    end
    printf(MESSAGES.REGIME_CONFIRMED_MSG)
    printf(MESSAGES.ACTIVE_TRAINING_FMT, 
        enemy_str ~= "" and enemy_str or "Unknown",
        training_data.training_area_zone or "Unknown",
        training_data.target_level_range or "Unknown");
    save_training_data();
    
    -- Auto-open UI when a new training regime is confirmed
    tracker_ui.open();
end

local function handle_regime_cancellation()
    clear_training_data();
end

local function handle_regime_reset()
    for i, enemy in ipairs(training_data.enemies) do
        enemy.killed = 0;
    end
    training_data.last_packet_progress = nil;
    save_training_data();
end

local function handle_enemy_defeat(target_name)
    if target_name then
        local enemy, index = find_enemy_by_name(target_name);
        if enemy then
            training_data.last_defeated_enemy = target_name;
        end
    end
end

local function handle_progress_update(current, total)
    -- Find enemy and update kill count
    if training_data.last_defeated_enemy then
        local enemy, index = find_enemy_by_name(training_data.last_defeated_enemy);
        if enemy then
            enemy.killed = current;
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
    }
};

-- Initialize packet handler with callbacks (after all handler functions are defined)
packet_handler.init({
    on_defeat = function(target_name)
        if is_training_valid() then
            handle_enemy_defeat(target_name);
        end
    end,
    on_progress = function(current, total)
        if is_training_valid() then
            handle_progress_update(current, total);
        end
    end,
    on_regime_complete = function()
        if is_training_valid() then
            printf(MESSAGES.REGIME_COMPLETED_MSG);
        end
    end,
    on_regime_reset = function()
        if is_training_valid() then
            handle_regime_reset();
        end
    end,
});

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
end);

-- Event: Incoming packets
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    packet_handler.handle_incoming_packet(e);
end);

-- Command handler
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if #args == 0 or args[1] ~= '/at' then
        return;
    end
    
    -- Block the command from being sent to the game
    e.blocked = true;
    
    -- Handle subcommands
    if #args == 1 then
        -- /at - show help
        printf('AMANTracker Commands:');
        printf('  /at             - Show this help');
        printf('  /at ui          - Toggle UI visibility');
        printf('  /at ui gdifonts - Switch to transparent floating text (default)');
        printf('  /at ui imgui    - Switch to classic solid window');
        printf('  /at clear       - Clear current training data');
        printf('  /at test <name> - Test enemy name matching (debug)');
    elseif args[2] == 'ui' then
        if args[3] ~= nil and args[3] ~= '' then
            -- /at ui <mode>
            local mode = args[3]:lower();
            if mode == 'gdifonts' or mode == 'imgui' then
                saved_data.ui_mode = mode;
                settings.save();
                tracker_ui.set_ui_mode(mode);
                printf('UI mode set to: %s', mode);
            else
                errorf('Invalid UI mode. Use "gdifonts" or "imgui"');
            end
        else
            -- /at ui - toggle visibility
            tracker_ui.toggle();
            local status = tracker_ui.is_visible() and "opened" or "closed";
            printf('UI %s', status);
        end
    elseif args[2] == 'clear' then
        clear_training_data();
        printf(MESSAGES.DATA_CLEARED);
    elseif args[2] == 'test' then
        -- Test command: /at test <enemy_name>
        if #args < 3 then
            printf('Usage: /at test <enemy_name>');
            printf('Example: /at test Giant Guard');
            return;
        end
        
        -- Get enemy name from args (join all args after 'test')
        local test_enemy = table.concat(args, ' ', 3);
        printf('===== TESTING ENEMY MATCH: "%s" =====', test_enemy);
        
        if not is_training_valid() or #training_data.enemies == 0 then
            warnf('No active training regime to test against!');
            return;
        end
        
        printf('Current tracked enemies: %d', #training_data.enemies);
        
        -- Test against each tracked enemy
        for i, enemy in ipairs(training_data.enemies) do
            printf('');
            printf('[%d] Testing against: "%s"', i, enemy.name);
            printf('    Match type: %s', enemy.match_type or 'unknown');
            printf('    Progress: %d/%d', enemy.killed, enemy.total);
            
            if enemy.match_type == 'family' then
                local family_type = family.extract_family_type(enemy.name);
                if family_type then
                    printf('    Family type extracted: "%s"', family_type);
                    local is_member = family.is_family_member(test_enemy, family_type);
                    if is_member then
                        printf('    ✓ MATCH: "%s" is a member of "%s" family', test_enemy, family_type);
                    else
                        printf('    ✗ NO MATCH: "%s" is not a member of "%s" family', test_enemy, family_type);
                    end
                else
                    errorf('    ERROR: Could not extract family type from "%s"', enemy.name);
                end
            elseif enemy.match_type == 'exact' then
                if enemy.name == test_enemy then
                    printf('    ✓ MATCH: Exact match');
                elseif enemy.name == test_enemy .. "s" then
                    printf('    ✓ MATCH: Plural match');
                elseif enemy.name:sub(-1) == "s" and enemy.name:sub(1, -2) == test_enemy then
                    printf('    ✓ MATCH: Singular match');
                else
                    printf('    ✗ NO MATCH: Not an exact, plural, or singular match');
                end
            else
                printf('    Testing with legacy mode...');
                local matched, match_idx = find_enemy_by_name(test_enemy);
                if matched then
                    printf('    ✓ MATCH: Found via legacy matching');
                else
                    printf('    ✗ NO MATCH: No legacy match found');
                end
            end
        end
        
        printf('');
        printf('===== END TEST =====');
    end
end);

-- Event: Render UI
ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    tracker_ui.render();
end);

-- Event: Addon unload - save data
ashita.events.register('unload', 'unload_cb', function()
    save_training_data();
    tracker_ui.cleanup();
end);