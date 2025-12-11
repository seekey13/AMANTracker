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
    local family_def = families[family_type];
    if not family_def then
        print(string.format('[Family Debug] No family definition found for "%s"', family_type));
        return false;
    end
    
    local enemy_lower = enemy_name:lower();
    print(string.format('[Family Debug] Checking "%s" against "%s" family', enemy_lower, family_type));
    
    -- Check exclusions first (exact match)
    for _, exclude_pattern in ipairs(family_def.excludes) do
        print(string.format('[Family Debug]   Exclusion check: "%s" == "%s" ?', enemy_lower, exclude_pattern:lower()));
        if enemy_lower == exclude_pattern:lower() then
            print(string.format('[Family Debug]   -> EXCLUDED (exact match)'));
            return false;
        end
    end
    
    -- Check if enemy name contains any inclusion pattern (substring match)
    for _, include_pattern in ipairs(family_def.includes) do
        local pattern_lower = include_pattern:lower();
        local found = enemy_lower:find(pattern_lower, 1, true);
        print(string.format('[Family Debug]   Inclusion check: "%s" contains "%s" ? %s', enemy_lower, pattern_lower, tostring(found ~= nil)));
        if found then
            print(string.format('[Family Debug]   -> MATCH FOUND at position %d', found));
            return true;
        end
    end
    
    -- No inclusion match found
    print(string.format('[Family Debug] No match found for "%s" in "%s" family', enemy_lower, family_type));
    return false;
end

-- Extract family type from "Members of the [X] Family" pattern
-- @param enemy_name: The full enemy name string
-- @return: family type string if pattern matches, nil otherwise
function family.extract_family_type(enemy_name)
    -- Try case-insensitive matching
    local family_type = enemy_name:match("^[Mm]embers of the (.+) [Ff]amily$");
    if family_type then
        print(string.format('[Family Debug] Extracted family type: "%s" from "%s"', family_type, enemy_name));
    else
        print(string.format('[Family Debug] No family pattern match for: "%s"', enemy_name));
    end
    return family_type;
end

-- Check if an enemy name is a family pattern
-- @param enemy_name: The enemy name to check
-- @return: true if it matches "Members of the X Family" pattern
function family.is_family_pattern(enemy_name)
    return family.extract_family_type(enemy_name) ~= nil;
end

return family;
