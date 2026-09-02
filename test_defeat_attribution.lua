--[[
Standalone checks for actor-less kill attribution.

A monster killed by its own Self-Destruct or by a damage-over-time effect is
announced with action message 20 ("${target} falls to the ground."), which
carries no actor the client can attribute to the party. The addon credits those
deaths by remembering which mobs the party acted on, so message 558's progress
number has an enemy name to attach to.

Run: lua test_defeat_attribution.lua
]]

-- ponytail: hand-rolled stubs, no framework. Enough to load lib/packet_handler.lua.

-- Little-endian byte packing, matching Ashita's struct.unpack offsets (1-based).
local function u16(v)
    return string.char(v % 256, (v // 256) % 256);
end

local function u32(v)
    return string.char(v % 256, (v // 256) % 256, (v // 65536) % 256, (v // 16777216) % 256);
end

-- Build a 0x29 action message packet body the way parse_action_message reads it.
local function message_packet(actor_id, target_id, message_id)
    return string.rep('\0', 4)  -- header
        .. u32(actor_id)        -- 0x05 actor id
        .. u32(target_id)       -- 0x09 target id
        .. u32(0)               -- 0x0D param 1
        .. u32(0)               -- 0x11 param 2 / param 3
        .. u16(0)               -- 0x15 actor index
        .. u16(0)               -- 0x17 target index
        .. u16(message_id)      -- 0x19 message id
        .. '\0';                -- pad to 0x1B
end

_G.struct = {
    unpack = function (fmt, data, pos)
        local b = { data:byte(pos, pos + 3) };
        if fmt == 'H' then
            return b[1] + b[2] * 256;
        end
        return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216;
    end,
};

-- Entity table and party, both rewritten per scenario by set_world().
local entities = {};
local party_ids = {};
local party_indexes = {};

_G.AshitaCore = {
    GetMemoryManager = function ()
        return {
            GetParty = function ()
                return {
                    GetMemberServerId = function (_, i) return party_ids[i] or 0; end,
                    GetMemberTargetIndex = function (_, i) return party_indexes[i] or 0; end,
                };
            end,
            GetEntity = function ()
                return {
                    GetRawEntity = function (_, i) return entities[i]; end,
                };
            end,
        };
    end,
};

_G.ashita = { bits = { unpack_be = function () return 0; end } };

local packet_handler = dofile('lib/packet_handler.lua');

local defeats = {};
packet_handler.init({
    on_defeat = function (name) defeats[#defeats + 1] = name; end,
});

local function set_world(world)
    entities = world.entities or {};
    party_ids = world.party_ids or {};
    party_indexes = world.party_indexes or {};
    defeats = {};
    packet_handler.clear_engagements();
end

local function assert_eq(actual, expected, label)
    assert(actual == expected,
        ('%s: expected %s, got %s'):format(label, tostring(expected), tostring(actual)));
end

-- A Bomb we hit, which then kills itself with Self-Destruct. Message 20, no
-- usable actor, but the mob is on our engaged list.
set_world({
    party_ids = { [0] = 0x01000001 },
    entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0 } },
});
packet_handler.record_engagement(0x02000123);
packet_handler.handle_incoming_packet({
    id = 0x29,
    data = message_packet(0x02000123, 0x02000123, 20),
});
assert_eq(#defeats, 1, 'engaged self-destruct credited');
assert_eq(defeats[1], 'Bomb', 'engaged self-destruct name');

-- The same death for a mob we never touched is somebody else's kill.
set_world({
    party_ids = { [0] = 0x01000001 },
    entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0 } },
});
packet_handler.handle_incoming_packet({
    id = 0x29,
    data = message_packet(0x02000123, 0x02000123, 20),
});
assert_eq(#defeats, 0, 'unengaged self-destruct ignored');

-- Message 605 (Additional effect) and 406 (weapon skill) are death messages too.
for _, id in ipairs({ 113, 406, 605 }) do
    set_world({
        party_ids = { [0] = 0x01000001 },
        entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0 } },
    });
    packet_handler.record_engagement(0x02000123);
    packet_handler.handle_incoming_packet({
        id = 0x29,
        data = message_packet(0, 0x02000123, id),
    });
    assert_eq(#defeats, 1, ('message %d credited'):format(id));
end

-- An engagement older than the TTL is stale: a server id can be reused.
set_world({
    party_ids = { [0] = 0x01000001 },
    entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0 } },
});
packet_handler.record_engagement(0x02000123, os.time() - 5000);
assert_eq(packet_handler.is_engaged(0x02000123), false, 'stale engagement expires');

-- ---------------------------------------------------------------------------
-- Engagement recording from Action packets (0x28)
-- ---------------------------------------------------------------------------

-- Scripted bit reader: parse_action walks 0x28's bit-packed fields in a fixed
-- order, so feeding it a queue proves the field widths line up without
-- reimplementing Ashita's bit primitive.
local bit_reads = 0;

local function script_bits(values)
    local i = 0;
    bit_reads = 0;
    _G.ashita.bits.unpack_be = function ()
        i = i + 1;
        bit_reads = bit_reads + 1;
        return values[i] or 0;
    end
end

-- One melee round: actor, 1 target, non-magic type, 1 action, no additional
-- effect and no spikes effect.
local function melee_round(actor_id, target_id)
    return {
        actor_id,   -- actor id (32)
        1,          -- target count (6)
        0,          -- reserved (4)
        4,          -- type (4) -- not 8 or 9, so a single 32-bit Param follows
        0,          -- param (32)
        0,          -- recast (32)
        target_id,  -- target id (32)
        1,          -- action count (4)
        0, 0, 0, 0, 0, 0, 0, -- reaction, animation, effect, stagger, param, message, flags
        0,          -- has additional effect (1)
        0,          -- has spikes effect (1)
    };
end

-- Our own swing at a Bomb puts the Bomb on the engaged list.
set_world({ party_ids = { [0] = 0x01000001 }, party_indexes = { [0] = 1 } });
script_bits(melee_round(0x01000001, 0x02000123));
packet_handler.handle_incoming_packet({ id = 0x28, data_raw = '', size = 256 });
assert_eq(packet_handler.is_engaged(0x02000123), true, 'own action engages target');

-- A party member's pet counts as ours.
set_world({
    party_ids = { [0] = 0x01000001 },
    party_indexes = { [0] = 1 },
    entities = {
        [1] = { ServerId = 0x01000001, Name = 'You', PetTargetIndex = 20 },
        [20] = { ServerId = 0x03000999, Name = 'Carbuncle', PetTargetIndex = 0 },
    },
});
script_bits(melee_round(0x03000999, 0x02000123));
packet_handler.handle_incoming_packet({ id = 0x28, data_raw = '', size = 256 });
assert_eq(packet_handler.is_engaged(0x02000123), true, 'pet action engages target');

-- A stranger's action engages nothing, and bails after reading the actor id.
set_world({ party_ids = { [0] = 0x01000001 }, party_indexes = { [0] = 1 } });
script_bits(melee_round(0x0100BEEF, 0x02000123));
packet_handler.handle_incoming_packet({ id = 0x28, data_raw = '', size = 256 });
assert_eq(packet_handler.is_engaged(0x02000123), false, 'stranger action ignored');
assert_eq(bit_reads, 1, 'stranger action bails after the actor id');

-- Zoning invalidates every server id.
set_world({ party_ids = { [0] = 0x01000001 }, party_indexes = { [0] = 1 } });
packet_handler.record_engagement(0x02000123);
packet_handler.handle_incoming_packet({ id = 0x0A, data = string.rep('\0', 64) });
assert_eq(packet_handler.is_engaged(0x02000123), false, 'zone in clears engagements');

packet_handler.record_engagement(0x02000123);
packet_handler.handle_incoming_packet({ id = 0x0B, data = string.rep('\0', 64) });
assert_eq(packet_handler.is_engaged(0x02000123), false, 'zone out clears engagements');

print('test_defeat_attribution: OK');
