--[[
AMANTracker - Packet Handler Module
Handles incoming packets for reliable event detection
Supports kill tracking from players, pets (BST pets, SMN avatars, etc.), and trusts
]]

local packet_handler = {};

-- Message IDs from action_messages.lua
local MESSAGE_IDS = {
    DEFEAT = 6,                    -- "${actor} defeats ${target}."
    DESIGNATED_TARGET = 558,       -- "You defeated a designated target. (Progress: ${number}/${number2})"
    REGIME_COMPLETE = 559,         -- "You have successfully completed the training regime."
    REGIME_RESET = 643,            -- "Your current training regime will begin anew!"
    FALLS_TO_GROUND = 646,         -- "${actor} uses ${ability}.${lb}${target} falls to the ground."
    PROGRESS = 698,                -- "Progress: ${number}/${number2}."
};

-- Callbacks for packet events
local callbacks = {
    on_defeat = nil,
    on_progress = nil,
    on_regime_complete = nil,
    on_regime_reset = nil,
};

-- Initialize the packet handler with callbacks
-- Args:
--   handlers (table) - Table of callback functions:
--     on_defeat(target_name) - Called when an enemy is defeated
--     on_progress(current, total) - Called when progress update is received
--     on_regime_complete() - Called when regime is completed
--     on_regime_reset() - Called when regime resets
function packet_handler.init(handlers)
    callbacks = handlers or {};
end

-- Parse action message packet (0x29)
-- Args:
--   data (string) - Raw packet data
-- Returns:
--   table - Parsed action message data or nil
local function parse_action_message(data)
    if #data < 0x1B then
        return nil;
    end
    
    local am = {};
    am.actor_id = struct.unpack('I', data, 0x05);
    am.target_id = struct.unpack('I', data, 0x09);
    am.param_1 = struct.unpack('I', data, 0x0D);
    am.param_2 = struct.unpack('H', data, 0x11) % (2^9); -- First 7 bits
    am.param_3 = math.floor(struct.unpack('I', data, 0x11) / (2^5)); -- Rest
    am.actor_index = struct.unpack('H', data, 0x15);
    am.target_index = struct.unpack('H', data, 0x17);
    am.message_id = struct.unpack('H', data, 0x19) % (2^15); -- Cut off the most significant bit
    
    return am;
end

-- Get entity name by server ID
-- Args:
--   server_id (number) - Entity server ID
-- Returns:
--   string - Entity name or nil
local function get_entity_name(server_id)
    local entity_mgr = AshitaCore:GetMemoryManager():GetEntity();
    if not entity_mgr then
        return nil;
    end
    
    -- Search through all entities to find matching server ID
    for i = 0, 2303 do
        local entity = entity_mgr:GetRawEntity(i);
        if entity and entity.ServerId == server_id then
            return entity.Name;
        end
    end
    
    return nil;
end

-- Get player server ID
-- Returns:
--   number - Player's server ID or 0
local function get_player_id()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party then
        return party:GetMemberServerId(0);
    end
    return 0;
end

-- Check if an actor is in the player's party or is a pet/trust belonging to a party member
-- Args:
--   actor_id (number) - Actor's server ID
-- Returns:
--   boolean - True if actor is in party or is a party member's pet/trust, false otherwise
local function is_in_party(actor_id)
    local party = AshitaCore:GetMemoryManager():GetParty();
    local entity_mgr = AshitaCore:GetMemoryManager():GetEntity();
    if not party or not entity_mgr then
        return false;
    end
    
    -- Check all 6 party slots (0-5) for party members
    for i = 0, 5 do
        local member_id = party:GetMemberServerId(i);
        if member_id ~= 0 and member_id == actor_id then
            return true;
        end
    end
    
    -- Check if the actor is the local player's pet
    local player = entity_mgr:GetRawEntity(0);
    if player and player.PetTargetIndex > 0 then
        local pet = entity_mgr:GetRawEntity(player.PetTargetIndex);
        if pet and pet.ServerId == actor_id then
            return true;
        end
    end
    
    -- Check if the actor is a pet of any party member (indices 1-5)
    for i = 1, 5 do
        local member_id = party:GetMemberServerId(i);
        if member_id ~= 0 then
            -- Find the party member's entity
            for j = 1, 2303 do
                local entity = entity_mgr:GetRawEntity(j);
                if entity and entity.ServerId == member_id then
                    -- Check if this party member has a pet
                    if entity.PetTargetIndex > 0 then
                        local pet = entity_mgr:GetRawEntity(entity.PetTargetIndex);
                        if pet and pet.ServerId == actor_id then
                            return true;
                        end
                    end
                    break; -- Found the party member, no need to continue inner loop
                end
            end
        end
    end
    
    -- Check if the actor is a trust belonging to any party member
    for i = 0, 2303 do
        local entity = entity_mgr:GetRawEntity(i);
        if entity and entity.ServerId == actor_id then
            -- Check if this entity is a trust with an owner
            if entity.TrustOwnerTargetIndex and entity.TrustOwnerTargetIndex > 0 then
                local owner_entity = entity_mgr:GetRawEntity(entity.TrustOwnerTargetIndex);
                if owner_entity then
                    -- Check if trust owner is in party
                    for j = 0, 5 do
                        local member_id = party:GetMemberServerId(j);
                        if member_id ~= 0 and member_id == owner_entity.ServerId then
                            return true;
                        end
                    end
                end
            end
            break; -- Found the entity, no need to continue
        end
    end
    
    return false;
end

-- Handle action message packet
-- Args:
--   am (table) - Parsed action message data
local function handle_action_message(am)
    local player_id = get_player_id();
    
    -- Message 6: "${actor} defeats ${target}."
    -- Used to capture the enemy name when player defeats an enemy
    if am.message_id == MESSAGE_IDS.DEFEAT then
        -- Only process if actor is in the party (filter out non-party members)
        if is_in_party(am.actor_id) and callbacks.on_defeat then
            local target_name = get_entity_name(am.target_id);
            if target_name then
                callbacks.on_defeat(target_name);
            end
        end
    
    -- Message 558: "You defeated a designated target. (Progress: ${number}/${number2})"
    -- This message only provides progress numbers, not enemy identity
    elseif am.message_id == MESSAGE_IDS.DESIGNATED_TARGET then
        -- Message 558 doesn't contain enemy ID, only progress information
        -- The enemy name comes from message 6 which fires first
        if callbacks.on_progress then
            local current = am.param_1;
            local total = am.param_2;
            callbacks.on_progress(current, total);
        end
    
    -- Message 559: "You have successfully completed the training regime."
    elseif am.message_id == MESSAGE_IDS.REGIME_COMPLETE then
        if callbacks.on_regime_complete then
            callbacks.on_regime_complete();
        end
    
    -- Message 643: "Your current training regime will begin anew!"
    elseif am.message_id == MESSAGE_IDS.REGIME_RESET then
        if callbacks.on_regime_reset then
            callbacks.on_regime_reset();
        end
    
    -- Message 646: "${actor} uses ${ability}.${lb}${target} falls to the ground."
    -- Alternative defeat message for abilities/weapon skills
    elseif am.message_id == MESSAGE_IDS.FALLS_TO_GROUND then
        -- Only process if actor is in the party (filter out non-party members)
        if is_in_party(am.actor_id) and callbacks.on_defeat then
            local target_name = get_entity_name(am.target_id);
            if target_name then
                callbacks.on_defeat(target_name);
            end
        end
    end
    
    -- NOTE: Message 698 ("Progress: X/Y") is NOT processed because it's used
    -- by both AMAN and Records of Eminence. Message 558 is AMAN-specific.
end

-- Handle incoming packet
-- Args:
--   e (table) - Packet event data
function packet_handler.handle_incoming_packet(e)
    -- Only process action message packets (0x29)
    if e.id == 0x29 then
        local am = parse_action_message(e.data);
        if am then
            handle_action_message(am);
        end
    end
end

return packet_handler;
