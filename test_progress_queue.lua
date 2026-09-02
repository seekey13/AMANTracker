--[[
End-to-end check for progress attribution.

Message 558 ("You defeated a designated target. (Progress: X/Y)") carries the
count but names no enemy; the death message names the enemy but carries no
count. The addon pairs them. One AoE can kill several tracked enemies at once,
so the pairing is a queue rather than a single slot -- this drives the real
AMANTracker.lua through stubbed Ashita services to prove the pairing holds.

Run: lua test_progress_queue.lua
]]

-- ponytail: hand-rolled stubs, no framework. Enough to load AMANTracker.lua.

package.path = './?.lua;' .. package.path;

local saved_calls = 0;

package.preload['common'] = function () return {}; end;
package.preload['chat'] = function ()
    return {
        header = function () return ''; end,
        message = function (s) return s; end,
        warning = function (s) return s; end,
        error = function (s) return s; end,
    };
end;
package.preload['settings'] = function ()
    return {
        load = function (defaults) return defaults; end,
        save = function () saved_calls = saved_calls + 1; end,
        register = function () end,
    };
end;
package.preload['lib.tracker_ui'] = function ()
    local noop = function () end;
    return {
        init = noop, open = noop, close = noop, toggle = noop, render = noop,
        cleanup = noop, set_ui_mode = noop, is_visible = function () return false; end,
    };
end;

_G.addon = {};

-- Ashita's common library wraps table literals in T{} helpers.
_G.T = function (t) return t; end;

function string.strip_colors(s)
    return s;
end

-- Counts reads of the 0x28 bit stream, which is how the tests below tell a
-- skipped Action packet from a parsed one.
local bit_calls = 0;

-- Captured Ashita event callbacks, keyed by event name.
local events = {};
_G.ashita = {
    events = {
        register = function (name, _, cb) events[name] = cb; end,
    },
    bits = { unpack_be = function () bit_calls = bit_calls + 1; return 0; end },
};

-- Ashita's struct library, as far as parse_action_message uses it.
_G.struct = {
    unpack = function (fmt, data, pos)
        local b = { data:byte(pos, pos + 3) };
        if fmt == 'H' then
            return b[1] + b[2] * 256;
        end
        return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216;
    end,
};

-- Ashita runs LuaJIT (Lua 5.1), which ships the `bit` library the addon uses.
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

-- One party member, and an entity table holding the two mobs the tests kill.
local ZONE_ID = 200;
local current_zone_name = 'Valkurm Dunes';
local entities = {
    [1] = { ServerId = 0x01000001, Name = 'You', PetTargetIndex = 0, SpawnFlags = 0x02 },
    [17] = { ServerId = 0x02000123, Name = 'Bomb', PetTargetIndex = 0, SpawnFlags = 0x10 },
    [18] = { ServerId = 0x02000456, Name = 'Goblin Smithy', PetTargetIndex = 0, SpawnFlags = 0x10 },
};

_G.AshitaCore = {
    GetMemoryManager = function ()
        return {
            GetParty = function ()
                return {
                    GetMemberServerId = function (_, i) return i == 0 and 0x01000001 or 0; end,
                    GetMemberTargetIndex = function (_, i) return i == 0 and 1 or 0; end,
                    GetMemberIsActive = function (_, i) return i == 0 and 1 or 0; end,
                    GetMemberZone = function () return ZONE_ID; end,
                };
            end,
            GetEntity = function ()
                return { GetRawEntity = function (_, i) return entities[i]; end };
            end,
        };
    end,
    GetResourceManager = function ()
        return {
            GetString = function (_, table_name, id)
                if table_name == 'zones.names' and id == ZONE_ID then
                    return current_zone_name;
                end
                return nil;
            end,
        };
    end,
};

_G.print = function () end;

local packet_handler = require('lib.packet_handler');

dofile('AMANTracker.lua');

-- Little-endian byte packing, matching Ashita's struct.unpack offsets (1-based).
-- math.floor rather than // so this file also parses under LuaJIT (Lua 5.1).
local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256);
end

local function u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256);
end

local function message_packet(actor_id, target_id, message_id, param_1)
    return string.rep('\0', 4)
        .. u32(actor_id)
        .. u32(target_id)
        .. u32(param_1 or 0)
        .. u32(0)
        .. u16(0)
        .. u16(0)
        .. u16(message_id)
        .. '\0';
end

local function text_in(msg)
    events['text_in']({ message = msg });
end

local function packet_in(id, data)
    events['packet_in']({ id = id, data = data, data_raw = '', size = #data });
end

local function assert_eq(actual, expected, label)
    assert(actual == expected,
        ('%s: expected %s, got %s'):format(label, tostring(expected), tostring(actual)));
end

-- Register a regime the way the tome does: prompt, header, then the enemy list.
text_in("This page has been placed here by the Adventurers' Mutual Aid Network (A.M.A.N.).");
text_in('The information on this page instructs you to defeat the following:');
text_in('3 Bombs. 3 Goblin Smithies.');
text_in('Target level range: 48~49.');
text_in('Training area: Valkurm Dunes.');
text_in('New training regime registered!');

-- The tracked enemies are unreachable from here, so read progress back through
-- the only other thing that sees it: a fresh 558 has to land on the right row.
local function kill(server_id, message_id)
    packet_in(0x29, message_packet(0x01000001, server_id, message_id));
end

local function progress(current)
    packet_in(0x29, message_packet(0, 0, 558, current));
end

-- A single kill pairs with the single 558 behind it.
kill(0x02000123, 6);
progress(1);
assert(saved_calls > 0, 'a credited kill saves');

-- The AoE case: both mobs die before either 558 arrives. A single slot would
-- drop the first death entirely and write the second 558 into the wrong row.
local before = saved_calls;
kill(0x02000123, 20);          -- Bomb, killed by a damage-over-time tick
kill(0x02000456, 20);          -- Goblin Smithy, same AoE
progress(2);                   -- Bomb's count
progress(1);                   -- Goblin Smithy's count
assert_eq(saved_calls - before, 2, 'both AoE deaths credited, not just the last');

-- A 558 with nothing queued behind it credits nothing.
before = saved_calls;
progress(3);
assert_eq(saved_calls - before, 0, 'unpaired 558 credits nothing');

-- A death for an untracked mob never queues, so the next 558 finds nothing.
before = saved_calls;
entities[19] = { ServerId = 0x02000789, Name = 'Sand Cockatrice', PetTargetIndex = 0, SpawnFlags = 0x10 };
kill(0x02000789, 6);
progress(3);
assert_eq(saved_calls - before, 0, 'untracked enemy death does not queue');

-- Action packets are only worth decoding inside the regime's own training area.
bit_calls = 0;
packet_in(0x28, string.rep('\0', 64));
assert(bit_calls > 0, 'action packets are parsed inside the training area');

current_zone_name = 'Konschtat Highlands';
bit_calls = 0;
packet_in(0x28, string.rep('\0', 64));
assert_eq(bit_calls, 0, 'action packets are skipped outside the training area');

io.write('test_progress_queue: OK\n');
