--[[
AMANTracker - Parser Module
Handles parsing of AMAN training regime messages
]]

local parser = {};

-- Parse level range (e.g., "Target level range: 48~49.")
-- Returns: string formatted as "48~49" or nil
function parser.parse_level_range(line)
    local first_num, second_num = string.match(line, "Target level range:%s*(%d+)%D*(%d+)");
    if first_num and second_num then
        return first_num .. "~" .. second_num;
    end
    return nil;
end

-- Parse training area (e.g., "Training area: Garlaige Citadel.")
-- Returns: area name string or nil
function parser.parse_training_area(line)
    local area = string.match(line, "Training area:%s*(.-)%.$");
    return area;
end

-- Parse enemies from a line containing multiple enemy entries
-- Returns: array of {total, killed, name} tables
function parser.parse_enemies(line)
    local enemies = {};
    local remaining_text = line;
    
    while true do
        local count, name = string.match(remaining_text, "(%d+)%s+([^%.?]+)%.");
        if not count or not name then
            break;
        end
        
        -- Exclude level range and training area entries
        if not string.find(name, "Target level range") and not string.find(name, "Training area") then
            table.insert(enemies, {
                total = tonumber(count),
                killed = 0,
                name = name
            });
        end
        
        -- Remove this enemy from the remaining text
        local pattern = count .. "%s+" .. parser.escape_pattern(name) .. "%.";
        remaining_text = string.gsub(remaining_text, pattern, "", 1);
    end
    
    return enemies;
end

-- Escape special pattern characters in a string
-- Returns: escaped string safe for use in Lua patterns
function parser.escape_pattern(str)
    return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1");
end

-- Parse single enemy line (legacy format - now unused but kept for compatibility)
-- Returns: count (number), name (string) or nil, nil
function parser.parse_enemy_line(line)
    if string.find(line, "Target level range:") or string.find(line, "Training area:") then
        return nil, nil;
    end
    
    local count, name = string.match(line, "^%s*(%d+)%s+([^%.]+)%.");
    if count and name then
        return tonumber(count), name;
    end
    return nil, nil;
end

return parser;
