--[[
Family definitions for AMAN Training Regimes
Defines mob families and their member names for tracking "Members of the [X] Family" targets
]]

local family = {};

-- Family definitions with inclusion and exclusion patterns
-- All matching is case-insensitive and uses substring matching
local families = {
    ["Pugil"] = {
        includes = { "Pugil" },
        excludes = {}
    },
    ["Goblin"] = {
        includes = { "Goblin" },
        excludes = { "Goblin's", "Goblin Gruel" }
    },
    ["Evil Weapon"] = {
        includes = { "Boggart", "Weapon", "Poltergeist" },
        excludes = {}
    },
    ["Yagudo"] = {
        includes = { "Yagudo" },
        excludes = { "Yagudo's" }
    },
    ["Doll"] = {
        includes = { "Doll", "Groundskeeper" },
        excludes = {}
    },
    ["Skeleton"] = {
        includes = { 
            "Skeleton", "Fallen", "Accursed", "Ghast", "Ghoul", 
            "Wendigo", "Wight", "Hellbound", "Lich", "Lost Soul", 
            "Mummy", "Tomb Mage", "Tomb Warrior", "Doom"
        },
        excludes = {}
    },
    ["Shadow"] = {
        includes = { "Shadow", "Specter", "Ka", "Spriggan", "Dark Stalker" },
        excludes = {}
    },
    ["Elemental"] = {
        includes = { "Elemental", "Baelfyr", "Byrgen", "Gefyrst", "Ungeweder" },
        excludes = {}
    },
    ["Golem"] = {
        includes = { "Golem", "Aura" },
        excludes = {}
    },
    ["Gigas"] = {
        includes = { "Gigas", "Giant", "Jotunn" },
        excludes = { "Gigas's" }
    },
    ["Sahagin"] = {
        includes = { "Sahagin" },
        excludes = { "Sahagin Parasite" }
    },
    ["Bat"] = {
        includes = { "Bat", "Bats", "Stirge", "Gaylas" },
        excludes = { "Gigas's", "Goblin's" }
    },
    ["Bats"] = {
        includes = { "Bat", "Bats", "Stirge", "Gaylas" },
        excludes = { "Gigas's", "Goblin's" }
    },
    ["Antica"] = {
        includes = { "Antica" },
        excludes = {}
    },
    ["Worm"] = {
        includes = { "Worm", "Sand Digger", "Sand Eater" },
        excludes = {}
    },
    ["Sabotender"] = {
        includes = { "Sabotender" },
        excludes = {}
    },
    ["Tonberry"] = {
        includes = { "Tonberry" },
        excludes = { "Tonberry's" }
    }
};

-- Check if an enemy name belongs to a specific family
-- @param enemy_name: The name of the defeated enemy
-- @param family_type: The family type (e.g., "Goblin", "Pugil")
-- @return: true if the enemy belongs to the family, false otherwise
function family.is_family_member(enemy_name, family_type)
    -- Try case-insensitive family lookup
    local family_def = nil;
    local actual_key = nil;
    
    for key, def in pairs(families) do
        if key:lower() == family_type:lower() then
            family_def = def;
            actual_key = key;
            break;
        end
    end
    
    if not family_def then
        return false;
    end
    
    local enemy_lower = enemy_name:lower();
    
    -- Check if enemy name contains any inclusion pattern (substring match)
    local has_inclusion = false;
    for _, include_pattern in ipairs(family_def.includes) do
        local pattern_lower = include_pattern:lower();
        local found = enemy_lower:find(pattern_lower, 1, true);
        if found then
            has_inclusion = true;
            break;
        end
    end
    
    -- If no inclusion match, return false immediately
    if not has_inclusion then
        return false;
    end
    
    -- Check exclusions (exact match)
    for _, exclude_pattern in ipairs(family_def.excludes) do
        if enemy_lower == exclude_pattern:lower() then
            return false;
        end
    end
    
    -- Passed inclusion and exclusion checks
    return true;
end

-- Extract family type from "Members of the [X] Family" pattern
-- @param enemy_name: The full enemy name string
-- @return: family type string if pattern matches, nil otherwise
function family.extract_family_type(enemy_name)
    -- Try case-insensitive matching
    local family_type = enemy_name:match("^[Mm]embers of the (.+) [Ff]amily$");
    return family_type;
end

-- Check if an enemy name is a family pattern
-- @param enemy_name: The enemy name to check
-- @return: true if it matches "Members of the X Family" pattern
function family.is_family_pattern(enemy_name)
    return family.extract_family_type(enemy_name) ~= nil;
end

return family;
