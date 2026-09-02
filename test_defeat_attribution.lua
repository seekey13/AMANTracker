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
-- math.floor rather than // so this file also parses under LuaJIT (Lua 5.1),
-- which is what the addon actually runs on.
local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256);
end

local function u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256);
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
                    -- Active whenever the slot is occupied; no scenario here needs
                    -- a stale non-zero id sitting in a vacated slot.
                    GetMemberIsActive = function (_, i) return (party_ids[i] and party_ids[i] ~= 0) and 1 or 0; end,
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

-- Ashita runs LuaJIT (Lua 5.1), which ships the `bit` library the addon uses.
-- Standalone Lua 5.4 does not, so stand in the one function packet_handler calls.
_G.bit = {
    band = function (a, b)
        local result, shift = 0, 1;
        while a > 0 and b > 0 do
            if (a % 2 == 1) and (b % 2 == 1) then
                result = result + shift;
            end
            a = (a - a % 2) / 2;
            b = (b - b % 2) / 2;
            shift = shift * 2;
        end
        return result;
    end,
};

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
    entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0, SpawnFlags = 0x10 } },
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
    entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0, SpawnFlags = 0x10 } },
});
packet_handler.handle_incoming_packet({
    id = 0x29,
    data = message_packet(0x02000123, 0x02000123, 20),
});
assert_eq(#defeats, 0, 'unengaged self-destruct ignored');

-- 97 (defeated by), 113 (spell), 406 (weapon skill) and 605 (additional effect)
-- are death messages too.
for _, id in ipairs({ 97, 113, 406, 605 }) do
    set_world({
        party_ids = { [0] = 0x01000001 },
        entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0, SpawnFlags = 0x10 } },
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
    entities = { [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0, SpawnFlags = 0x10 } },
});
packet_handler.record_engagement(0x02000123, os.time() - 5000);
assert_eq(packet_handler.is_engaged(0x02000123), false, 'stale engagement expires');

-- ---------------------------------------------------------------------------
-- Credit via is_in_party (message 6 names the actor directly)
-- ---------------------------------------------------------------------------

-- A party member's own kill credits outright -- message 6 names the actor,
-- so it doesn't matter that the target was never separately engaged.
set_world({
    party_ids = { [0] = 0x01000001 },
    entities = {
        [1] = { ServerId = 0x01000001, Name = 'You', PetTargetIndex = 0, SpawnFlags = 0x02 },
        [18] = { ServerId = 0x02000456, Name = 'Goblin', PetTargetIndex = 0, SpawnFlags = 0x10 },
    },
});
packet_handler.handle_incoming_packet({
    id = 0x29,
    data = message_packet(0x01000001, 0x02000456, 6),
});
assert_eq(#defeats, 1, 'party actor kill credited');
assert_eq(defeats[1], 'Goblin', 'party actor kill name');

-- A stranger's kill is nobody's here: not a party actor, and the target was
-- never engaged either.
set_world({
    party_ids = { [0] = 0x01000001 },
    entities = {
        [1] = { ServerId = 0x01000001, Name = 'You', PetTargetIndex = 0, SpawnFlags = 0x02 },
        [18] = { ServerId = 0x02000456, Name = 'Goblin', PetTargetIndex = 0, SpawnFlags = 0x10 },
    },
});
packet_handler.handle_incoming_packet({
    id = 0x29,
    data = message_packet(0x0100BEEF, 0x02000456, 6),
});
assert_eq(#defeats, 0, 'stranger kill not credited');

-- A party member (cured, then killed) can land on the engaged list the same
-- as a mob would, but get_mob_name refuses to name a non-monster, so the
-- death is never credited. Regression test for Fix 1.
set_world({
    party_ids = { [0] = 0x01000001 },
    entities = { [5] = { ServerId = 0x01000777, Name = 'Sakura', PetTargetIndex = 0, SpawnFlags = 0x02 } },
});
packet_handler.record_engagement(0x01000777);
packet_handler.handle_incoming_packet({
    id = 0x29,
    data = message_packet(0, 0x01000777, 20),
});
assert_eq(#defeats, 0, 'engaged party member death not credited');

-- ---------------------------------------------------------------------------
-- Engagement recording from Action packets (0x28)
-- ---------------------------------------------------------------------------

-- Scripted bit reader: parse_action walks 0x28's bit-packed fields in a fixed
-- order, so feeding it a queue lets each call return the scripted value
-- without reimplementing Ashita's bit primitive. The stub also records each
-- call's width (n) argument, so the actual sequence of widths parse_action
-- reads can be asserted against the widths it is expected to read -- without
-- that, transposing two field widths in parse_action would still pass, since
-- the values returned never depended on width.
local bit_reads = 0;
local widths_seen = {};

local function script_bits(values)
    local i = 0;
    bit_reads = 0;
    widths_seen = {};
    _G.ashita.bits.unpack_be = function (_, _, _, n)
        i = i + 1;
        bit_reads = bit_reads + 1;
        widths_seen[#widths_seen + 1] = n;
        return values[i] or 0;
    end
end

-- Field widths parse_action reads, in order, for one melee_round() target with
-- one action and no additional/spikes effect. Verified against parse_action's
-- own bits(n) calls: actor(32), target_count(6), reserved(4), type(4),
-- param(32), recast(32), target_id(32), action_count(4), then the seven
-- reaction..flags fields (5,12,7,3,17,10,31), and finally the two 1-bit
-- additional-effect/spikes-effect flags.
local MELEE_ROUND_WIDTHS = {
    32, 6, 4, 4, 32, 32, 32, 4, 5, 12, 7, 3, 17, 10, 31, 1, 1,
};

local function assert_widths_eq(actual, expected, label)
    assert_eq(#actual, #expected, label .. ' (count)');
    for i = 1, #expected do
        assert_eq(actual[i], expected[i], ('%s (field %d)'):format(label, i));
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
assert_widths_eq(widths_seen, MELEE_ROUND_WIDTHS, 'melee round field widths');

-- A party member's pet counts as ours.
set_world({
    party_ids = { [0] = 0x01000001 },
    party_indexes = { [0] = 1 },
    entities = {
        [1] = { ServerId = 0x01000001, Name = 'You', PetTargetIndex = 20, SpawnFlags = 0x02 },
        [20] = { ServerId = 0x03000999, Name = 'Carbuncle', PetTargetIndex = 0, SpawnFlags = 0x10 },
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

-- A packet too short to hold the fields parse_action reads must engage
-- nothing: bits() poisons max_bits and the target loop bails.
set_world({ party_ids = { [0] = 0x01000001 }, party_indexes = { [0] = 1 } });
script_bits(melee_round(0x01000001, 0x02000123));
-- 20 bytes is enough for the actor id and the header fields (150 bits) but
-- not the first target id (needs 182), so the read that fails is the one
-- inside the target loop.
packet_handler.handle_incoming_packet({ id = 0x28, data_raw = '', size = 20 });
assert_eq(packet_handler.is_engaged(0x02000123), false, 'truncated action engages nothing');
-- 6 successful reads (actor, count, reserved, type, param, recast); the 7th,
-- the target id, fails the bounds check and never reaches unpack_be.
assert_eq(bit_reads, 6, 'truncated action fails on the target id, not the actor id');

-- Zoning invalidates every server id.
set_world({ party_ids = { [0] = 0x01000001 }, party_indexes = { [0] = 1 } });
packet_handler.record_engagement(0x02000123);
packet_handler.handle_incoming_packet({ id = 0x0A, data = string.rep('\0', 64) });
assert_eq(packet_handler.is_engaged(0x02000123), false, 'zone in clears engagements');

packet_handler.record_engagement(0x02000123);
packet_handler.handle_incoming_packet({ id = 0x0B, data = string.rep('\0', 64) });
assert_eq(packet_handler.is_engaged(0x02000123), false, 'zone out clears engagements');

print('test_defeat_attribution: OK');
