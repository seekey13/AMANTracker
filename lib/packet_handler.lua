--[[
AMANTracker - Packet Handler Module
Handles incoming packets for reliable event detection
Supports kill tracking from players, pets (BST pets, SMN avatars, etc.), and trusts
]]

local packet_handler = {};

-- Message IDs from action_messages.lua
local MESSAGE_IDS = {
    DEFEAT = 6,                    -- "${actor} defeats ${target}."
    FALLS_NO_ACTOR = 20,           -- "${target} falls to the ground."
    FALLS_SPELL = 113,             -- "${actor} casts ${spell}.${lb}${target} falls to the ground."
    FALLS_WEAPONSKILL = 406,       -- "${actor} uses ${weapon_skill}.${lb}${target} falls to the ground."
    DESIGNATED_TARGET = 558,       -- "You defeated a designated target. (Progress: ${number}/${number2})"
    REGIME_COMPLETE = 559,         -- "You have successfully completed the training regime."
    FALLS_ADDITIONAL = 605,        -- "Additional effect: ${target} falls to the ground."
    REGIME_RESET = 643,            -- "Your current training regime will begin anew!"
    FALLS_TO_GROUND = 646,         -- "${actor} uses ${ability}.${lb}${target} falls to the ground."
    PROGRESS = 698,                -- "Progress: ${number}/${number2}."
};

-- Every message that announces a monster's death. Only 6, 113, 406 and 646 name
-- an actor; 20 (self-destruct, damage-over-time) and 605 (additional effect) do
-- not, which is why the engaged list below exists.
local DEATH_MESSAGE_IDS = {
    [MESSAGE_IDS.DEFEAT] = true,
    [MESSAGE_IDS.FALLS_NO_ACTOR] = true,
    [MESSAGE_IDS.FALLS_SPELL] = true,
    [MESSAGE_IDS.FALLS_WEAPONSKILL] = true,
    [MESSAGE_IDS.FALLS_ADDITIONAL] = true,
    [MESSAGE_IDS.FALLS_TO_GROUND] = true,
};

-- Mobs the party (or a party member's pet) has acted on, keyed by server id and
-- valued with the os.time() of the last action. A death message with no usable
-- actor is credited to us only if the dying mob is in here.
local engaged = {};

-- Seconds an engagement stays usable. Server ids are reused as mobs respawn, so
-- an entry that has sat untouched for this long is not trusted.
local ENGAGED_TTL = 900;

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
    
    -- Check if the actor is a pet of any party member (including local player)
    for i = 0, 5 do
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
    -- A monster died. Messages 6/113/406/646 name the actor, so a party actor
    -- credits the kill outright. Messages 20 (self-destruct, damage-over-time)
    -- and 605 (additional effect) name no usable actor, so the dying mob has to
    -- be one the party was already acting on.
    --
    -- Nothing here counts a kill: message 558 below carries the server's own
    -- absolute progress number. All this does is resolve the dead mob's name so
    -- 558 knows which tracked enemy to write that number into.
    if DEATH_MESSAGE_IDS[am.message_id] then
        local credited = is_in_party(am.actor_id) or packet_handler.is_engaged(am.target_id);

        if callbacks.on_debug then
            callbacks.on_debug('death msg=%d actor=%d target=%d credited=%s',
                am.message_id, am.actor_id, am.target_id, tostring(credited));
        end

        -- The mob is dead; its entry can never help again, and leaving it would
        -- let a respawn on the same server id inherit the credit.
        packet_handler.clear_engagement(am.target_id);

        if credited and callbacks.on_defeat then
            local target_name = get_entity_name(am.target_id);
            if target_name then
                callbacks.on_defeat(target_name);
            end
        end

    -- Message 558: "You defeated a designated target. (Progress: ${number}/${number2})"
    -- This message only provides progress numbers, not enemy identity
    elseif am.message_id == MESSAGE_IDS.DESIGNATED_TARGET then
        -- Message 558 doesn't contain enemy ID, only progress information.
        -- The enemy name comes from the death message, which fires first.
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
    end

    -- NOTE: Message 698 ("Progress: X/Y") is NOT processed because it's used
    -- by both AMAN and Records of Eminence. Message 558 is AMAN-specific.
end

-- Mark a mob as one the party has acted on
-- Args:
--   server_id (number) - Mob's server ID
--   now (number) - Optional timestamp; defaults to os.time()
function packet_handler.record_engagement(server_id, now)
    engaged[server_id] = now or os.time();
end

-- Check whether a mob is one the party has acted on recently
-- Args:
--   server_id (number) - Mob's server ID
--   now (number) - Optional timestamp; defaults to os.time()
-- Returns:
--   boolean - True if engaged within ENGAGED_TTL seconds
function packet_handler.is_engaged(server_id, now)
    local seen = engaged[server_id];
    if not seen then
        return false;
    end
    if ((now or os.time()) - seen) > ENGAGED_TTL then
        engaged[server_id] = nil;
        return false;
    end
    return true;
end

-- Forget every engagement. Server IDs are only unique within one zone instance.
function packet_handler.clear_engagements()
    engaged = {};
end

-- Forget one mob's engagement
-- Args:
--   server_id (number) - Mob's server ID
function packet_handler.clear_engagement(server_id)
    engaged[server_id] = nil;
end

-- Every server ID that counts as "ours" for engagement purposes: the six party
-- slots plus each member's pet/avatar/automaton, which has no party slot of its
-- own. Reached through each slot's target index, so this costs a dozen memory
-- reads rather than a walk of the entity table.
--
-- Trusts are deliberately not included: a trust only ever acts against something
-- a party member is already acting against, so the party member's own action
-- already covers whatever the trust would have added.
--
-- Returns:
--   table - Set of server IDs, keyed by ID, valued true
local function party_actor_ids()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local entity_mgr = AshitaCore:GetMemoryManager():GetEntity();
    local ids = {};
    if not party or not entity_mgr then
        return ids;
    end

    for i = 0, 5 do
        local member_id = party:GetMemberServerId(i);
        if member_id ~= 0 then
            ids[member_id] = true;

            local member_index = party:GetMemberTargetIndex(i);
            local member = member_index ~= 0 and entity_mgr:GetRawEntity(member_index) or nil;
            if member and member.PetTargetIndex > 0 then
                local pet = entity_mgr:GetRawEntity(member.PetTargetIndex);
                if pet then
                    ids[pet.ServerId] = true;
                end
            end
        end
    end

    return ids;
end

-- Minimal decode of an Action packet (0x28): who acted, and which server IDs
-- they targeted. This packet is bit-packed rather than byte-aligned like 0x29,
-- so it needs ashita.bits.unpack_be instead of struct.unpack.
--
-- Every field between the actor ID and the target list, and every field inside
-- each target's actions, is read even though none of the values are kept: the
-- packet is packed bit by bit, so a field cannot be skipped without decoding its
-- width first. The actor ID comes first, so a packet from somebody else's action
-- bails after 32 bits -- which is most of them in a crowded zone.
--
-- Args:
--   e (table) - Packet event data (needs e.data_raw and e.size)
--   mine (table) - Set of server IDs that count as ours
-- Returns:
--   table - Array of target server IDs, empty when the actor is not ours
local function parse_action(e, mine)
    local bit_offset = 40; -- header
    local max_bits = e.size * 8;

    local function bits(n)
        if (bit_offset + n) > max_bits then
            max_bits = 0; -- malformed; every further read returns 0
            return 0;
        end
        local v = ashita.bits.unpack_be(e.data_raw, 0, bit_offset, n);
        bit_offset = bit_offset + n;
        return v;
    end

    local actor_id = bits(32);
    if not mine[actor_id] then
        return {};
    end

    local target_count = bits(6);
    bits(4); -- reserved
    local action_type = bits(4);
    if action_type == 8 or action_type == 9 then
        bits(16); bits(16); -- Param, SpellGroup
    else
        bits(32); -- Param
    end
    bits(32); -- Recast

    local targets = {};
    for _ = 1, target_count do
        local target_id = bits(32);
        if max_bits == 0 then
            break; -- packet ran out mid-read; nothing past here is real data
        end
        targets[#targets + 1] = target_id;

        for _ = 1, bits(4) do -- action count
            bits(5); bits(12); bits(7); bits(3); bits(17); bits(10); bits(31); -- reaction..flags
            if bits(1) == 1 then
                bits(10); bits(17); bits(10); -- additional effect
            end
            if bits(1) == 1 then
                bits(10); bits(14); bits(10); -- spikes effect
            end
        end
    end

    return targets;
end

-- Record every mob a party action touched
-- Args:
--   e (table) - Packet event data for an Action packet (0x28)
local function record_engagements(e)
    -- ponytail: party members are recorded alongside mobs rather than filtered
    -- out with a SpawnFlags check, because the set is only ever read when a
    -- death message names that server ID as the dying target and the name still
    -- has to match a tracked enemy. Add the flag check if the set ever grows
    -- enough to matter.
    local targets = parse_action(e, party_actor_ids());
    if #targets == 0 then
        return;
    end

    local now = os.time();
    for _, target_id in ipairs(targets) do
        packet_handler.record_engagement(target_id, now);
    end
end

-- Handle incoming packet
-- Args:
--   e (table) - Packet event data
function packet_handler.handle_incoming_packet(e)
    -- Action message: defeats, progress, regime state
    if e.id == 0x29 then
        local am = parse_action_message(e.data);
        if am then
            handle_action_message(am);
        end

    -- Action: who hit what, which is how a mob gets onto the engaged list
    elseif e.id == 0x28 then
        record_engagements(e);

    -- Zone in / zone out. Server IDs are only unique within one zone instance.
    elseif e.id == 0x0A or e.id == 0x0B then
        packet_handler.clear_engagements();
    end
end

return packet_handler;