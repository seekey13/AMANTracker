--[[
AMANTracker - FoV/GoV Mirror Module

Replicates one character's Fields of Valor / Grounds of Valor page selection onto
every other character running the addon on the same machine.

This is a narrow port of DiscipleOfEris's Windower addon NpcInteract, which
mirrors a main character's NPC menu interactions onto alts by capturing the
main's outgoing packets and re-injecting equivalents on each alt. Only the
book-selection path is ported here: NpcInteract's full NPC surface (warps, key
items, Goblin Footprints) is deliberately left out, because the whole failure
mode of that addon is mirroring an interaction that turns out not to be the one
you meant.

How a book interaction looks on the wire:

  1. Outgoing 0x01A (Action) with Category 0 ("talk") at the Field Manual or
     Grounds Tome. The client's status flips to Event (4).
  2. The server opens a menu; incoming 0x032 or 0x034 carries the NPC, the zone
     and the Menu ID.
  3. Each menu choice -- "Individual Training", the page list, the page itself,
     the confirmation -- is an outgoing 0x05B (Dialog choice) carrying the
     Option Index and the Menu ID it is answering.
  4. The event closes and status returns to Idle (0).

Two things this port does differently from NpcInteract, both because the task
demanded it and both because they are safer:

  * NpcInteract fires the whole recorded sequence of 0x05B in one burst as soon
    as the first menu arrives. Here each choice waits for the alt's own client to
    actually advance to the next menu, so an alt whose menu tree differs stalls
    and aborts instead of blind-firing selections into whatever is on screen.
  * NpcInteract copies the leader's Target, Target Index and Menu ID verbatim.
    Here the book NPC is resolved against the alt's own entity table and the Menu
    ID is read from the alt's own incoming interaction packet. In practice these
    agree (NPC server IDs and indices are server-assigned and identical for every
    client in a zone), but they stop agreeing the moment two boxes are standing
    at different Field Manuals in the same zone, which is common.

LEVELS: the concern that a raw Option Index selects a different page at a
different level does not hold on the intended release platform. CatsEyeXI runs a
LandSandBoat fork, whose scripts/globals/regimes.lua maps options to pages
through a constant table -- page N is always option 2 + 16*N, for both Fields
and Grounds -- and looks the page up with getPageByNum(regimeType, zoneId, N)
against a per-zone table that takes no level input. The page bitmask the server
sends at book open is derived from the zone's page count, not the player's
level, and registration performs no level check at all. So in the same zone at
the same book, one option index means one page for every character.

Mixed levels are therefore allowed by default and only warned about, because the
real consequence is a gameplay one: kill credit runs through checkKillCredit(),
so a character outside the page's level range registers the page fine and simply
earns no credit. /at mirror samelevel on restores a hard refusal for servers
whose page list is level-filtered.
]]

local mirror = {};

local transport = require('lib.mirror_transport');

-- ============================================================================
-- Protocol constants
-- ============================================================================

local PKT_OUT = {
    ACTION        = 0x01A,  -- Interact with an entity
    DIALOG_CHOICE = 0x05B,  -- Choose a menu option
};

local PKT_IN = {
    ZONE_IN        = 0x00A,
    ZONE_OUT       = 0x00B,
    NPC_INTERACT_1 = 0x032, -- Short menu: NPC, zone, menu id
    NPC_INTERACT_2 = 0x034, -- Long menu: adds 32 bytes of menu parameters
};

-- Outgoing 0x01A, 0x1C bytes. Offsets are from the start of the packet, so they
-- include the 4-byte header.
local ACTION = {
    SIZE         = 0x1C,
    TARGET       = 0x04, -- uint32, server id
    TARGET_INDEX = 0x08, -- uint16
    CATEGORY     = 0x0A, -- uint16
    PARAM        = 0x0C, -- uint16
};

-- Category 0 is "talk to this entity". Everything else (attack, cast, trade,
-- ranged attack) is ignored outright: a mirror that can replay a trade is a
-- mirror that can empty an alt's inventory.
local ACTION_CATEGORY_TALK = 0;

-- Outgoing 0x05B, 0x14 bytes.
local CHOICE = {
    SIZE         = 0x14,
    TARGET       = 0x04, -- uint32, server id of the event owner
    -- Windower splits the selection into two shorts, but the server reads one
    -- 32-bit value: regimes.lua tests bit 0x80000000 for "repeat this regime"
    -- before masking it off with 0x7FFFFFFF. So OPTION is the low half and
    -- UNKNOWN1 the flag half of a single number. Cloning the packet preserves
    -- both, which is how the repeat checkbox survives a mirror.
    OPTION       = 0x08, -- uint16, low half of the 32-bit option
    UNKNOWN1     = 0x0A, -- uint16, high half: 0x8000 repeat, 0x4000 closes a menu
    TARGET_INDEX = 0x0C, -- uint16
    AUTOMATED    = 0x0E, -- uint8, 1 when the client generated the response itself
    UNKNOWN2     = 0x0F, -- uint8
    ZONE         = 0x10, -- uint16
    MENU         = 0x12, -- uint16
};

-- Incoming interaction packets. Both carry the same four fields; 0x034 just
-- pushes them past a 32-byte parameter blob.
local INTERACT = {
    [PKT_IN.NPC_INTERACT_1] = { NPC = 0x04, NPC_INDEX = 0x08, ZONE = 0x0A, MENU = 0x0C, SIZE = 0x10 },
    [PKT_IN.NPC_INTERACT_2] = { NPC = 0x04, NPC_INDEX = 0x28, ZONE = 0x2A, MENU = 0x2C, SIZE = 0x34 },
};

-- Entity status, matching the values NpcInteract tracks through UPDATE_CHAR.
local STATUS = {
    IDLE   = 0,
    EVENT  = 4,
    ZONING = 5,
};

-- ============================================================================
-- Tuning
-- ============================================================================

-- How long an alt waits for its own client to advance to the next menu before
-- giving up on a step. Generous: this covers a server round trip plus whatever
-- the client spends rendering the menu.
local MENU_TIMEOUT = 5.0;

-- Pause between a menu arriving and the choice that answers it. Injecting into
-- the same frame the menu lands on is what produces the "alt is stuck in a
-- dialog" reports against NpcInteract.
local INJECT_DELAY = 0.15;

-- Longest an alt waits for the event to close after the final choice.
local FINISH_TIMEOUT = 8.0;

-- Upper bound on a single leader capture. A capture left open (the player
-- alt-tabbed out mid-menu, an event that never resolves) is abandoned rather
-- than left to accumulate choices that would later broadcast as one sequence.
local CAPTURE_TIMEOUT = 120.0;

-- Longest an alt trusts a broadcast. A box that was loading, zoning or logged
-- out must not act on a page its leader selected minutes ago.
local RECORD_MAX_AGE = 20;

-- Spread the alts' triggers out slightly so N boxes do not open the same book in
-- the same instant. Small enough to stay inside the "couple of seconds" budget.
local START_STAGGER_MAX = 0.4;

-- Interaction range for a Field Manual, matching NpcInteract's own check.
local INTERACT_RANGE = 6.0;

-- Channel polling and status sampling rate. d3d_present fires per frame; there
-- is no reason to stat a file 60 times a second.
local TICK_INTERVAL = 0.05;

-- Books recognised without any A.M.A.N. text confirmation. Confirmed against
-- CatsEyeXI's own sql/npc_list.sql, where the display name column holds exactly
-- 'Field Manual' (76 rows) and 'Grounds Tome' (120 rows) -- so no configuration
-- is needed there. A server that renames them is handled by the auto-learn in
-- finalise_capture below, or by /at mirror book <name>.
local DEFAULT_BOOKS = { 'Field Manual', 'Grounds Tome' };

-- ============================================================================
-- State
-- ============================================================================

-- Live reference to saved_data.mirror, handed over by the main addon. Mutating
-- a field here and calling hooks.save() is what persists a /at mirror command.
local config = nil;

local hooks = {
    printf = function() end,
    warnf  = function() end,
    errorf = function() end,
    save   = function() end,
};

-- Raw packet hex logging, toggled by /at mirror dump. The only way to check the
-- field offsets above against a live server.
local dump_enabled = false;

-- What the leader is currently recording.
local leader = {
    active      = false,
    saw_event   = false,  -- status reached Event during this capture
    started_at  = 0,
    target_id   = 0,
    target_index = 0,
    target_name = '',
    zone        = 0,
    trigger     = nil,    -- raw 0x01A bytes
    steps       = {},     -- array of { raw = string, menu_id = number }
    confirmed   = false,  -- the A.M.A.N. tome text appeared during this event
};

-- What an alt is currently replaying.
local replay = {
    state       = 'idle', -- idle | pending | wait_menu | settle | finish
    steps       = nil,
    index       = 1,
    deadline    = 0,
    start_at    = 0,
    settle_at   = 0,
    menu_mark   = 0,
    leader_name = '',
    book_id     = 0,
    book_index  = 0,
    trigger     = nil,
    record      = nil,
    -- Whether this client has seen the A.M.A.N. text for the event it just
    -- opened, and whether it is required to before the first choice goes out.
    confirmed    = false,
    require_text = false,
};

-- Most recent incoming interaction packet. seq only ever increments, which is
-- how the replay detects "the menu advanced" without caring what it advanced to.
local menu = {
    seq       = 0,
    id        = 0,
    npc_id    = 0,
    npc_index = 0,
};

local broadcast_seq = 0;
local next_tick = 0;

-- ============================================================================
-- Byte helpers
--
-- Packets are handled as plain Lua strings rather than through struct.unpack so
-- that a captured packet can be cloned byte for byte and only the per-client
-- fields patched. Everything we do not understand -- the menu-dependent flag
-- word, the second unknown byte, whatever a private server has bolted on --
-- rides along untouched.
-- ============================================================================

local function u8(s, off)
    return s:byte(off + 1);
end

local function u16(s, off)
    local a, b = s:byte(off + 1, off + 2);
    if not b then
        return nil;
    end
    return a + b * 0x100;
end

local function u32(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4);
    if not d then
        return nil;
    end
    return a + b * 0x100 + c * 0x10000 + d * 0x1000000;
end

local function set_u16(s, off, value)
    value = math.floor(value) % 0x10000;
    return s:sub(1, off) .. string.char(value % 0x100, math.floor(value / 0x100)) .. s:sub(off + 3);
end

local function set_u32(s, off, value)
    value = math.floor(value) % 0x100000000;
    local b0 = value % 0x100;
    local b1 = math.floor(value / 0x100) % 0x100;
    local b2 = math.floor(value / 0x10000) % 0x100;
    local b3 = math.floor(value / 0x1000000) % 0x100;
    return s:sub(1, off) .. string.char(b0, b1, b2, b3) .. s:sub(off + 5);
end

-- The whole 32-bit selection, as the server reads it.
local function full_option(packet)
    local low = u16(packet, CHOICE.OPTION) or 0;
    local high = u16(packet, CHOICE.UNKNOWN1) or 0;
    return high * 0x10000 + low;
end

local function to_hex(s)
    return (s:gsub('.', function(c) return string.format('%02X', c:byte()); end));
end

local function from_hex(h)
    if type(h) ~= 'string' or #h == 0 or #h % 2 ~= 0 or h:find('[^0-9A-Fa-f]') then
        return nil;
    end
    return (h:gsub('%x%x', function(cc) return string.char(tonumber(cc, 16)); end));
end

-- Ashita's packet manager takes the packet as an array of byte values. The
-- 4-byte header is included by convention even though Ashita rewrites the id,
-- size and sync fields itself when it queues the packet -- which is also why a
-- cloned packet's stale sync counter is harmless.
local function to_byte_table(s)
    local t = {};
    for i = 1, #s do
        t[i] = s:byte(i);
    end
    return t;
end

-- ============================================================================
-- Game state helpers
-- ============================================================================

local function get_party()
    local memory = AshitaCore:GetMemoryManager();
    return memory and memory:GetParty() or nil;
end

local function get_entities()
    local memory = AshitaCore:GetMemoryManager();
    return memory and memory:GetEntity() or nil;
end

local function get_zone()
    local party = get_party();
    return party and party:GetMemberZone(0) or 0;
end

local function get_self()
    local party = get_party();
    if not party then
        return nil;
    end

    local index = party:GetMemberTargetIndex(0);
    if index == 0 then
        return nil;
    end

    return {
        id    = party:GetMemberServerId(0),
        index = index,
        name  = party:GetMemberName(0) or '',
    };
end

local function get_status()
    local me = get_self();
    local entities = get_entities();
    if not me or not entities then
        return STATUS.ZONING;
    end

    local entity = entities:GetRawEntity(me.index);
    if not entity or type(entity.Status) ~= 'number' then
        return STATUS.ZONING;
    end

    return entity.Status;
end

local function get_level()
    local memory = AshitaCore:GetMemoryManager();
    local player = memory and memory:GetPlayer() or nil;
    return player and player:GetMainJobLevel() or 0;
end

-- Resolve an entity's name by server id, for naming the NPC a 0x01A targeted.
local function name_of_server_id(server_id)
    local entities = get_entities();
    if not entities or server_id == 0 then
        return nil;
    end

    for i = 0, 2303 do
        local entity = entities:GetRawEntity(i);
        if entity and entity.ServerId == server_id then
            return entity.Name;
        end
    end

    return nil;
end

-- Find this client's own copy of the book the leader used.
--
-- Matching on name rather than on the leader's server id is what lets two boxes
-- stand at different Field Manuals in the same zone. Where several copies are in
-- range the nearest wins, which is the one the player is standing at.
--
-- Args:
--   book_name (string) - Entity name the leader broadcast
-- Returns:
--   table - { id, index, distance }, or nil when no copy is within range
local function find_book(book_name)
    local entities = get_entities();
    if not entities or not book_name or book_name == '' then
        return nil;
    end

    local best = nil;
    for i = 0, 2303 do
        local entity = entities:GetRawEntity(i);
        if entity and entity.Name == book_name and entity.ServerId ~= 0
           and type(entity.Distance) == 'number' and type(entity.SpawnFlags) == 'number' then
            -- Never mistake a monster wearing the same name for the book.
            if bit.band(entity.SpawnFlags, 0x10) == 0 then
                -- The client stores the squared distance to each entity.
                local distance = math.sqrt(entity.Distance);
                if distance <= INTERACT_RANGE and (best == nil or distance < best.distance) then
                    best = { id = entity.ServerId, index = i, distance = distance };
                end
            end
        end
    end

    return best;
end

local function is_known_book(name)
    if not name or name == '' then
        return false;
    end

    for _, known in ipairs(config and config.books or DEFAULT_BOOKS) do
        if known == name then
            return true;
        end
    end

    return false;
end

-- Seed off the character as well as the clock. Boxes launched in the same
-- second would otherwise draw identical start staggers, which is the one thing
-- the stagger exists to prevent.
local function seed_random()
    local me = get_self();
    math.randomseed(os.time() + (me and me.id or 0) % 100000);
end

local function is_enabled()
    return config ~= nil and config.enabled == true;
end

local function is_leader()
    return is_enabled() and config.role == 'leader';
end

local function is_follower()
    return is_enabled() and config.role == 'follower';
end

-- ============================================================================
-- Packet injection
-- ============================================================================

local function inject_outgoing(id, packet)
    if dump_enabled then
        hooks.printf('mirror: inject 0x%03X %s', id, to_hex(packet));
    end

    local manager = AshitaCore:GetPacketManager();
    if not manager then
        hooks.errorf('mirror: no packet manager; cannot inject.');
        return false;
    end

    manager:AddOutgoingPacket(id, to_byte_table(packet));
    return true;
end

-- Build a bare "close this menu" choice.
--
-- Option Index 0 with 0x4000 in the flag word is what the client itself sends
-- when you back out of a dialog, and it is how NpcInteract unsticks an alt that
-- got frozen mid-menu. Sent on every aborted replay so a divergent alt is left
-- at the book rather than trapped in a half-answered menu.
local function build_cancel(target_id, target_index, zone, menu_id)
    return struct.pack('bbbbIHHHbbHH',
        PKT_OUT.DIALOG_CHOICE, 0x05, 0, 0,
        target_id,      -- Target
        0,              -- Option Index
        0x4000,         -- _unknown1: close
        target_index,   -- Target Index
        0,              -- Automated Message
        0,              -- _unknown2
        zone,           -- Zone
        menu_id);       -- Menu ID
end

-- ============================================================================
-- Record encoding
--
-- One line, pipe delimited. Character and entity names cannot contain a pipe, so
-- no escaping is needed beyond defensively stripping one.
--
--   seq|epoch|leader|zone|level|book|confirmed|trigger_hex|menu:hex|menu:hex|...
-- ============================================================================

local function sanitise(s)
    return (tostring(s or ''):gsub('[|\r\n]', ' '));
end

-- Split on pipes by hand rather than with gmatch('[^|]*'), which in Lua 5.1
-- yields a spurious empty capture after every separator and would shift every
-- field of the record by one.
local function split_pipes(s)
    local parts = {};
    local start = 1;

    while true do
        local sep = s:find('|', start, true);
        if not sep then
            parts[#parts + 1] = s:sub(start);
            return parts;
        end
        parts[#parts + 1] = s:sub(start, sep - 1);
        start = sep + 1;
    end
end

local function encode_record(record)
    local parts = {
        record.seq,
        record.time,
        sanitise(record.leader),
        record.zone,
        record.level,
        record.self_id,
        sanitise(record.book),
        record.confirmed and 1 or 0,
        to_hex(record.trigger),
    };

    for _, step in ipairs(record.steps) do
        parts[#parts + 1] = string.format('%d:%s', step.menu_id, to_hex(step.raw));
    end

    return table.concat(parts, '|');
end

local function decode_record(payload)
    local parts = split_pipes(payload);

    if #parts < 10 then
        return nil, 'record has too few fields';
    end

    local record = {
        seq       = tonumber(parts[1]),
        time      = tonumber(parts[2]),
        leader    = parts[3],
        zone      = tonumber(parts[4]),
        level     = tonumber(parts[5]),
        self_id   = tonumber(parts[6]),
        book      = parts[7],
        confirmed = parts[8] == '1',
        trigger   = from_hex(parts[9]),
        steps     = {},
    };

    if not record.seq or not record.time or not record.zone or not record.level or not record.self_id then
        return nil, 'record has malformed numeric fields';
    end
    if not record.trigger or #record.trigger < ACTION.SIZE then
        return nil, 'record has a malformed trigger packet';
    end

    for i = 10, #parts do
        local menu_id, hex = parts[i]:match('^(%d+):(%x+)$');
        local raw = hex and from_hex(hex) or nil;
        if not raw or #raw < CHOICE.SIZE then
            return nil, 'record has a malformed choice packet';
        end
        record.steps[#record.steps + 1] = { menu_id = tonumber(menu_id), raw = raw };
    end

    if #record.steps == 0 then
        return nil, 'record carries no menu choices';
    end

    return record;
end

-- ============================================================================
-- Leader: capture
-- ============================================================================

local function reset_capture()
    leader.active      = false;
    leader.saw_event   = false;
    leader.started_at  = 0;
    leader.target_id   = 0;
    leader.target_index = 0;
    leader.target_name = '';
    leader.zone        = 0;
    leader.trigger     = nil;
    leader.steps       = {};
    leader.confirmed   = false;
end

-- Start recording a talk interaction.
--
-- Recording starts for any category-0 talk, not just one at a recognised book,
-- because the check that matters happens at broadcast time. Buffering a few
-- menu choices from a shop we will never broadcast costs nothing; refusing to
-- record until the NPC name matches would mean a server that renames its manuals
-- could never bootstrap itself.
local function begin_capture(packet)
    reset_capture();

    leader.active       = true;
    leader.started_at   = os.clock();
    leader.target_id    = u32(packet, ACTION.TARGET) or 0;
    leader.target_index = u16(packet, ACTION.TARGET_INDEX) or 0;
    leader.target_name  = name_of_server_id(leader.target_id) or '';
    leader.zone         = get_zone();
    leader.trigger      = packet;

    if dump_enabled then
        hooks.printf('mirror: capture start at "%s" (id=%d index=%d) %s',
            leader.target_name, leader.target_id, leader.target_index, to_hex(packet));
    end
end

-- Decide whether the finished capture was really a book, and broadcast it.
local function finalise_capture()
    -- Snapshot by value before resetting: `leader` is a single long-lived table,
    -- so holding a reference to it across reset_capture() would hand the
    -- broadcast an empty capture.
    local captured = {
        trigger     = leader.trigger,
        steps       = leader.steps,
        target_name = leader.target_name,
        zone        = leader.zone,
        confirmed   = leader.confirmed,
    };
    reset_capture();

    if not captured.trigger or #captured.steps == 0 then
        return;
    end

    local known = is_known_book(captured.target_name);

    -- The gate. In strict mode (the default) the A.M.A.N. tome text must have
    -- appeared during the event, which is the only positive proof the client has
    -- that this menu tree was a training regime and not a shop, a trade or a
    -- mission cutscene. Relaxed mode falls back to the NPC's name alone.
    if config.strict then
        if not captured.confirmed then
            if known then
                hooks.warnf('mirror: "%s" never printed the A.M.A.N. text; not broadcasting. Use /at mirror strict off to mirror on the book name alone.',
                    captured.target_name);
            end
            return;
        end
    elseif not (known or captured.confirmed) then
        return;
    end

    -- A confirmed tome whose name we did not recognise teaches us the name, so a
    -- server that calls its manuals something else configures itself after one
    -- interaction instead of needing /at mirror book.
    if captured.confirmed and not known and captured.target_name ~= '' then
        table.insert(config.books, captured.target_name);
        hooks.save();
        hooks.printf('mirror: learned a new A.M.A.N. book name: "%s"', captured.target_name);
    end

    broadcast_seq = broadcast_seq + 1;

    local me = get_self();
    local record = {
        seq       = broadcast_seq,
        time      = os.time(),
        leader    = me and me.name or '',
        zone      = captured.zone,
        level     = get_level(),
        -- The leader's own server id travels with the record so that each alt
        -- can recognise the choices that addressed the player rather than the
        -- NPC, and re-point those at itself.
        self_id   = me and me.id or 0,
        book      = captured.target_name,
        confirmed = captured.confirmed,
        trigger   = captured.trigger,
        steps     = captured.steps,
    };

    if transport.publish(encode_record(record)) then
        hooks.printf('mirror: broadcast %d choice%s from "%s".',
            #record.steps, #record.steps == 1 and '' or 's', record.book);
    else
        hooks.errorf('mirror: broadcast failed (%s)', transport.last_error() or 'unknown error');
    end
end

-- ============================================================================
-- Alt: replay
-- ============================================================================

local function abort_replay(reason, ...)
    if replay.state == 'idle' then
        return;
    end

    local step = replay.index;
    replay.state = 'idle';
    replay.steps = nil;

    hooks.warnf('mirror: replay aborted at step %d: ' .. reason, step, ...);

    -- Leave the client at the book rather than inside a half-answered menu.
    if get_status() == STATUS.EVENT and menu.npc_id ~= 0 then
        inject_outgoing(PKT_OUT.DIALOG_CHOICE,
            build_cancel(menu.npc_id, menu.npc_index, get_zone(), menu.id));
    end
end

-- Patch a captured 0x05B so it is valid on this client.
--
-- Only the four per-client fields are rewritten. Option Index, the flag word,
-- the automated-message byte and the second unknown ride along from the leader's
-- own packet, which is the point of cloning rather than rebuilding: fields this
-- port does not understand stay exactly as the real client sent them.
local function patch_choice(raw, leader_record)
    local me = get_self();
    local packet = raw;

    -- Some menus address the event back at the player rather than the NPC.
    -- Detect that on the leader's values and re-point it at this character.
    local was_self = leader_record.self_id ~= 0
        and u32(raw, CHOICE.TARGET) == leader_record.self_id;

    if was_self and me then
        packet = set_u32(packet, CHOICE.TARGET, me.id);
        packet = set_u16(packet, CHOICE.TARGET_INDEX, me.index);
    else
        -- Prefer the NPC the server itself named in this client's interaction
        -- packet over the book we resolved by name.
        local target_id = menu.npc_id ~= 0 and menu.npc_id or replay.book_id;
        local target_index = menu.npc_id ~= 0 and menu.npc_index or replay.book_index;
        packet = set_u32(packet, CHOICE.TARGET, target_id);
        packet = set_u16(packet, CHOICE.TARGET_INDEX, target_index);
    end

    packet = set_u16(packet, CHOICE.ZONE, get_zone());

    -- The Menu ID is session scoped, so this client's own is authoritative.
    if menu.id ~= 0 then
        packet = set_u16(packet, CHOICE.MENU, menu.id);
    end

    -- Every injected response is by definition automated.
    packet = packet:sub(1, CHOICE.AUTOMATED) .. string.char(1) .. packet:sub(CHOICE.AUTOMATED + 2);

    return packet;
end

local function start_replay(record)
    local me = get_self();
    if not me then
        return;
    end

    if record.leader == me.name then
        return; -- our own broadcast bouncing back off the channel
    end

    if config.leader_name ~= '' and record.leader ~= config.leader_name then
        return;
    end

    if (os.time() - record.time) > RECORD_MAX_AGE then
        hooks.warnf('mirror: ignoring a broadcast from %s that is %d seconds old.',
            record.leader, os.time() - record.time);
        return;
    end

    if replay.state ~= 'idle' then
        hooks.warnf('mirror: already replaying; ignoring the broadcast from %s.', record.leader);
        return;
    end

    if get_zone() ~= record.zone then
        hooks.warnf('mirror: %s selected a page in another zone; not mirroring.', record.leader);
        return;
    end

    -- On a LandSandBoat server (which CatsEyeXI forks) the option-to-page map is
    -- a constant and registration is not level checked, so a level difference
    -- picks the right page regardless. It still decides whether the character
    -- earns credit for the kills, so it is worth saying out loud.
    local level = get_level();
    if level ~= record.level then
        if config.same_level then
            hooks.warnf('mirror: %s is level %d and this character is level %d; /at mirror samelevel is on, so nothing was mirrored.',
                record.leader, record.level, level);
            return;
        end
        hooks.warnf('mirror: %s is level %d and this character is level %d. The same page registers either way, but kills only count inside the page\'s level range.',
            record.leader, record.level, level);
    end

    local status = get_status();
    if status ~= STATUS.IDLE then
        hooks.warnf('mirror: busy (status %d); not mirroring %s.', status, record.leader);
        return;
    end

    local book = find_book(record.book);
    if not book then
        hooks.warnf('mirror: no "%s" within %d yalms; not mirroring.', record.book, INTERACT_RANGE);
        return;
    end

    -- Point the leader's trigger at this client's own book.
    local trigger = set_u32(record.trigger, ACTION.TARGET, book.id);
    trigger = set_u16(trigger, ACTION.TARGET_INDEX, book.index);
    trigger = set_u16(trigger, ACTION.CATEGORY, ACTION_CATEGORY_TALK);

    replay.state       = 'pending';
    replay.confirmed   = false;
    -- The book's top menu can be replaced by another dialog carrying the same
    -- Menu ID -- on a LandSandBoat server an active hunt makes bookOnTrigger
    -- start the same event id with different parameters, producing a
    -- cancel-the-hunt prompt where the page list should be. The Menu ID check
    -- cannot see that, but the A.M.A.N. text can: if the leader's interaction
    -- was confirmed by that text, require the same here before choosing
    -- anything.
    replay.require_text = config.strict and record.confirmed;
    replay.steps       = record.steps;
    replay.record      = record;
    replay.index       = 1;
    replay.leader_name = record.leader;
    replay.book_id     = book.id;
    replay.book_index  = book.index;
    replay.trigger     = trigger;
    replay.start_at    = os.clock() + math.random() * START_STAGGER_MAX;

    hooks.printf('mirror: mirroring %s (%d choice%s at "%s").',
        record.leader, #record.steps, #record.steps == 1 and '' or 's', record.book);
end

local function inject_next_choice()
    local step = replay.steps[replay.index];
    local packet = patch_choice(step.raw, replay.record);

    inject_outgoing(PKT_OUT.DIALOG_CHOICE, packet);
    replay.index = replay.index + 1;

    if replay.index > #replay.steps then
        replay.state = 'finish';
        replay.menu_mark = menu.seq;
        replay.deadline = os.clock() + FINISH_TIMEOUT;
    else
        replay.state = 'wait_menu';
        replay.menu_mark = menu.seq;
        replay.deadline = os.clock() + MENU_TIMEOUT;
    end
end

local function tick_replay(now)
    if replay.state == 'pending' then
        if now < replay.start_at then
            return;
        end

        replay.menu_mark = menu.seq;
        replay.state = 'wait_menu';
        replay.deadline = now + MENU_TIMEOUT;
        inject_outgoing(PKT_OUT.ACTION, replay.trigger);

    elseif replay.state == 'wait_menu' then
        if menu.seq > replay.menu_mark then
            -- Hold the very first choice until the book identifies itself.
            if replay.index == 1 and replay.require_text and not replay.confirmed then
                if now > replay.deadline then
                    abort_replay('this character never saw the A.M.A.N. text, so the menu it opened is not the book.');
                end
                return;
            end

            local expected = replay.steps[replay.index].menu_id;

            -- A different Menu ID means this client is looking at a different
            -- menu tree than the leader answered -- a level difference that
            -- slipped past the check, a different book, a server-side variation.
            -- Blind-firing the recorded Option Index here is exactly how a
            -- mirror registers the wrong regime.
            if expected and expected ~= 0 and menu.id ~= 0 and menu.id ~= expected then
                abort_replay('this character\'s menu is %d but %s answered menu %d.',
                    menu.id, replay.leader_name, expected);
                return;
            end

            replay.state = 'settle';
            replay.settle_at = now + INJECT_DELAY;
        elseif now > replay.deadline then
            abort_replay('the menu never advanced.');
        end

    elseif replay.state == 'settle' then
        if now >= replay.settle_at then
            inject_next_choice();
        end

    elseif replay.state == 'finish' then
        if get_status() == STATUS.IDLE then
            replay.state = 'idle';
            replay.steps = nil;
            hooks.printf('mirror: mirrored %s.', replay.leader_name);
        elseif menu.seq > replay.menu_mark then
            -- The leader's sequence ran out but this client is still being
            -- asked something.
            abort_replay('this character\'s menu asked for more choices than %s made.', replay.leader_name);
        elseif now > replay.deadline then
            abort_replay('the event never closed.');
        end
    end
end

-- ============================================================================
-- Public interface
-- ============================================================================

-- Args:
--   handlers (table) - printf/warnf/errorf/save callbacks from the main addon
function mirror.init(handlers)
    hooks = handlers or hooks;
    transport.init();
    seed_random();
end

-- Adopt the character's saved mirror settings. Called again from the settings
-- callback on login, because that is when Ashita first hands an addon the real
-- character's file rather than the defaults profile.
-- Args:
--   cfg (table) - saved_data.mirror, held by reference
function mirror.apply_config(cfg)
    config = cfg;

    if config.books == nil or #config.books == 0 then
        config.books = {};
        for _, name in ipairs(DEFAULT_BOOKS) do
            table.insert(config.books, name);
        end
    end

    reset_capture();
    replay.state = 'idle';
    replay.steps = nil;

    -- Re-seed now that the character is resolvable: mirror.init() runs before
    -- login, where get_self() is still nil and every box would seed from the
    -- clock alone and draw the same start stagger.
    seed_random();

    -- Never act on a page that was selected before this character started
    -- listening.
    transport.prime();
end

-- Defaults for the addon's settings table.
function mirror.default_settings()
    local books = {};
    for _, name in ipairs(DEFAULT_BOOKS) do
        table.insert(books, name);
    end

    return {
        enabled     = false,   -- per character, off until explicitly turned on
        role        = 'leader',-- 'leader' broadcasts and never replays
        strict      = true,    -- require the A.M.A.N. text before broadcasting
        same_level  = false,   -- refuse to replay across a level difference
        leader_name = '',      -- '' accepts any leader
        books       = books,
    };
end

-- Note that the A.M.A.N. tome text appeared. Called from the main addon's
-- text_in handler, which already matches that string to detect a tome.
function mirror.note_tome_text()
    if leader.active then
        leader.confirmed = true;
    end

    -- Also proves, on a replaying alt, that the menu it just opened is the
    -- book's own and not something substituted for it.
    if replay.state ~= 'idle' then
        replay.confirmed = true;
    end
end

-- Args:
--   e (table) - packet_out event data
function mirror.handle_outgoing_packet(e)
    -- Our own injections come straight back through this hook. Recording them
    -- would let an alt's replay become a capture and re-broadcast.
    if e.injected or not is_leader() then
        return;
    end

    local packet = (e.data_modified or e.data):sub(1, e.size);

    if e.id == PKT_OUT.ACTION then
        if #packet < ACTION.SIZE then
            return;
        end
        if u16(packet, ACTION.CATEGORY) ~= ACTION_CATEGORY_TALK then
            return;
        end
        begin_capture(packet);

    elseif e.id == PKT_OUT.DIALOG_CHOICE then
        if not leader.active or #packet < CHOICE.SIZE then
            return;
        end

        leader.steps[#leader.steps + 1] = {
            raw     = packet,
            menu_id = u16(packet, CHOICE.MENU) or 0,
        };

        if dump_enabled then
            hooks.printf('mirror: capture choice %d option=0x%08X menu=%d %s',
                #leader.steps, full_option(packet), u16(packet, CHOICE.MENU) or 0, to_hex(packet));
        end
    end
end

-- Args:
--   e (table) - packet_in event data
function mirror.handle_incoming_packet(e)
    if not is_enabled() then
        return;
    end

    local layout = INTERACT[e.id];
    if layout then
        local packet = (e.data_modified or e.data):sub(1, e.size);
        if #packet >= layout.SIZE then
            menu.seq       = menu.seq + 1;
            menu.npc_id    = u32(packet, layout.NPC) or 0;
            menu.npc_index = u16(packet, layout.NPC_INDEX) or 0;
            menu.id        = u16(packet, layout.MENU) or 0;

            if dump_enabled then
                hooks.printf('mirror: menu 0x%03X npc=%d index=%d zone=%d menu=%d',
                    e.id, menu.npc_id, menu.npc_index, u16(packet, layout.ZONE) or 0, menu.id);
            end
        end

    elseif e.id == PKT_IN.ZONE_IN or e.id == PKT_IN.ZONE_OUT then
        -- Entity indices and menu sessions do not survive a zone change.
        if replay.state ~= 'idle' then
            replay.state = 'idle';
            replay.steps = nil;
            hooks.warnf('mirror: zoned mid-replay; stopped.');
        end
        reset_capture();
        menu.seq, menu.id, menu.npc_id, menu.npc_index = 0, 0, 0, 0;
    end
end

-- Driven from d3d_present. Samples status, ages out captures, polls the channel
-- and advances an in-flight replay.
function mirror.tick()
    if not is_enabled() then
        return;
    end

    local now = os.clock();
    if now < next_tick then
        return;
    end
    next_tick = now + TICK_INTERVAL;

    local status = get_status();

    if is_leader() then
        if leader.active then
            if status == STATUS.EVENT then
                leader.saw_event = true;
            elseif leader.saw_event and status == STATUS.IDLE then
                -- The event closed; this is the point the sequence is complete.
                finalise_capture();
            elseif (now - leader.started_at) > CAPTURE_TIMEOUT then
                reset_capture();
            end
        end
    else
        local payload = transport.poll();
        if payload and is_follower() then
            local record, err = decode_record(payload);
            if record then
                start_replay(record);
            else
                hooks.warnf('mirror: ignoring a malformed broadcast (%s).', err);
            end
        end

        tick_replay(now);
    end
end

-- ============================================================================
-- Commands
-- ============================================================================

local function print_status()
    hooks.printf('Mirror: %s, role %s, strict %s, samelevel %s',
        config.enabled and 'ON' or 'OFF', config.role,
        config.strict and 'on' or 'off', config.same_level and 'on' or 'off');
    hooks.printf('  Leader filter: %s', config.leader_name ~= '' and config.leader_name or '(any)');
    hooks.printf('  Books: %s', table.concat(config.books, ', '));
    hooks.printf('  Channel: %s', transport.path());
    if transport.last_error() then
        hooks.errorf('  Last broadcast error: %s', transport.last_error());
    end
    if replay.state ~= 'idle' then
        hooks.printf('  Replaying %s, step %d/%d (%s)',
            replay.leader_name, replay.index, #replay.steps, replay.state);
    end
end

local function print_help()
    hooks.printf('AMANTracker FoV/GoV mirror:');
    hooks.printf('  /at mirror                - Show mirror status');
    hooks.printf('  /at mirror on|off         - Enable/disable on this character (default off)');
    hooks.printf('  /at mirror leader         - This character broadcasts and never replays');
    hooks.printf('  /at mirror follower       - This character replays and never broadcasts');
    hooks.printf('  /at mirror only <name>    - Only accept broadcasts from <name> ("any" clears)');
    hooks.printf('  /at mirror strict on|off  - Require the A.M.A.N. text before broadcasting');
    hooks.printf('  /at mirror samelevel on|off - Refuse to mirror across a level difference');
    hooks.printf('  /at mirror book <name>    - Add a book NPC name ("reset" restores defaults)');
    hooks.printf('  /at mirror stop           - Abort an in-flight replay');
    hooks.printf('  /at mirror dump           - Toggle raw packet logging');
end

-- Args:
--   args (table) - Full /at argument list; mirror subcommands start at args[3]
function mirror.handle_command(args)
    if config == nil then
        hooks.errorf('mirror: settings are not loaded yet.');
        return;
    end

    local sub = args[3] and args[3]:lower() or nil;

    if sub == nil or sub == '' or sub == 'status' then
        print_status();

    elseif sub == 'help' then
        print_help();

    elseif sub == 'on' or sub == 'off' then
        config.enabled = (sub == 'on');
        hooks.save();
        if config.enabled then
            transport.prime();
        end
        hooks.printf('Mirror %s (role %s).', config.enabled and 'enabled' or 'disabled', config.role);

    elseif sub == 'leader' or sub == 'follower' then
        config.role = sub;
        hooks.save();
        reset_capture();
        replay.state = 'idle';
        replay.steps = nil;
        if sub == 'leader' then
            hooks.printf('Mirror role: leader. This character broadcasts and will never replay anyone.');
        else
            hooks.printf('Mirror role: follower. This character replays and will never broadcast.');
        end

    elseif sub == 'only' then
        local name = args[4];
        if not name or name == '' or name:lower() == 'any' then
            config.leader_name = '';
            hooks.printf('Mirror will accept broadcasts from any leader.');
        else
            config.leader_name = name;
            hooks.printf('Mirror will only accept broadcasts from %s.', name);
        end
        hooks.save();

    elseif sub == 'strict' then
        local value = args[4] and args[4]:lower() or nil;
        if value == 'on' then
            config.strict = true;
        elseif value == 'off' then
            config.strict = false;
        else
            config.strict = not config.strict;
        end
        hooks.save();
        hooks.printf('Mirror strict mode %s. %s', config.strict and 'on' or 'off',
            config.strict and 'Only interactions that print the A.M.A.N. text are broadcast.'
                           or 'Interactions at a known book name are broadcast without confirmation.');

    elseif sub == 'samelevel' then
        local value = args[4] and args[4]:lower() or nil;
        if value == 'on' then
            config.same_level = true;
        elseif value == 'off' then
            config.same_level = false;
        else
            config.same_level = not config.same_level;
        end
        hooks.save();
        hooks.printf('Mirror same-level requirement %s. %s', config.same_level and 'on' or 'off',
            config.same_level and 'A level difference now blocks mirroring.'
                               or 'Levels may differ; the same page registers either way.');

    elseif sub == 'book' then
        local name = table.concat(args, ' ', 4);
        if name == '' then
            hooks.printf('Books: %s', table.concat(config.books, ', '));
        elseif name:lower() == 'reset' then
            config.books = {};
            for _, book in ipairs(DEFAULT_BOOKS) do
                table.insert(config.books, book);
            end
            hooks.save();
            hooks.printf('Books reset to: %s', table.concat(config.books, ', '));
        elseif is_known_book(name) then
            hooks.printf('"%s" is already a known book.', name);
        else
            table.insert(config.books, name);
            hooks.save();
            hooks.printf('Added book: "%s"', name);
        end

    elseif sub == 'stop' then
        if replay.state == 'idle' then
            hooks.printf('Mirror: nothing to stop.');
        else
            abort_replay('stopped by command.');
        end

    elseif sub == 'dump' then
        dump_enabled = not dump_enabled;
        hooks.printf('Mirror packet logging %s.', dump_enabled and 'enabled' or 'disabled');

    else
        hooks.errorf('Unknown mirror command: %s', sub);
        print_help();
    end
end

return mirror;
