# Actor-less Kill Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Credit AMAN regime kills when the death message carries no usable actor id (self-destruct, damage-over-time, additional effects), by remembering which mobs the party has acted on.

**Architecture:** The server already sends the authoritative kill count in action message 558 (`You defeated a designated target. (Progress: X/Y)`), and it sends it for DoT and self-destruct deaths too. The addon drops that progress because `handle_progress_update` needs `training_data.last_defeated_enemy` to know *which* tracked enemy row to write into, and that field is only set when a death message passes the `is_in_party(actor_id)` check. So this is an **attribution** problem, not a counting problem — nothing here increments a counter, it only resolves the dead mob's name so the existing 558 handler can do its job. Two changes: (1) recognize all six death messages and accept one when either the actor is ours **or** the dying mob's server id is in an "engaged" set; (2) populate that engaged set by decoding Action packets (0x28) whose actor is a party member or a party member's pet.

**Tech Stack:** Lua 5.4, Ashita v4 addon API (`ashita.events`, `AshitaCore:GetMemoryManager()`, `ashita.bits.unpack_be`, `struct.unpack`). No new dependencies. Tests are standalone Lua files with hand-rolled stubs, run with `lua`, matching the convention of the (since-removed) `test_load_restore.lua`.

## Global Constraints

- **Ashita v4 runs LuaJIT (Lua 5.1).** Do NOT use `//`, `&`, `|`, `<<`, `>>`, `goto`, or `table.unpack` in anything the addon loads at runtime -- they are 5.2/5.3+ syntax and fail to parse. Use the `bit` library (`bit.band`, `bit.bor`) for bitwise work, as every other addon in this client does. The standalone tests run under the local `lua` (5.4.6), which is more permissive, so a test passing locally does NOT prove the addon loads -- stub `bit` in the test rather than writing 5.4-only arithmetic in the module.
- Ashita v4 addon. No external libraries, no luarocks, no test framework.
- Existing code style: 4-space indent, semicolon-terminated statements, `local function` for file-private helpers, block comments (`--[[ ]]`) at file head, `-- Args:` / `-- Returns:` comment blocks on public functions.
- Deliberate simplifications are marked with a `ponytail:` comment naming the ceiling and the upgrade path.
- `addon.version` in `AMANTracker.lua` goes `'2.7'` → `'2.8'`; every version bump gets a matching `### Version 2.8` section at the top of the changelog area in `README.md`.
- Server ids are only unique within one zone instance — any cache keyed on server id must be cleared on zone change.
- Do not add a counter that increments `enemy.killed`. Message 558 sets `enemy.killed = current` absolutely; a second source of truth would double-count.

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `lib/packet_handler.lua` | Modify | All packet decoding and the engaged-mob set. Owns the death-message table, the 0x28 Action decode, and the credit decision. |
| `AMANTracker.lua` | Modify | Wires the new `on_debug` callback and adds `/at debug`. Version bump. |
| `test_defeat_attribution.lua` | Create | Standalone check for the credit decision, the 0x28 engagement recording, and the zone clear. |
| `README.md` | Modify | Changelog entry and `/at debug` in the command list. |

`lib/parser.lua`, `lib/family.lua`, and `lib/tracker_ui.lua` are untouched.

---

### Task 1: Recognize all death messages and credit engaged mobs

**Files:**
- Modify: `lib/packet_handler.lua:10-17` (message id table), `lib/packet_handler.lua:86-93` (delete dead helper), `lib/packet_handler.lua:162-210` (death branch)
- Test: `test_defeat_attribution.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `packet_handler.record_engagement(server_id: number, now: number|nil)` → nil. Marks a mob as one the party acted on.
  - `packet_handler.is_engaged(server_id: number, now: number|nil)` → boolean. True when the mob was engaged within `ENGAGED_TTL` seconds; expires and drops the entry otherwise.
  - `packet_handler.clear_engagements()` → nil. Empties the set.
  - `callbacks.on_debug(fmt: string, ...)` — new optional callback in the `packet_handler.init` handler table, called once per death message.

- [ ] **Step 1: Write the failing test**

Create `test_defeat_attribution.lua` with this exact content:

```lua
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

print('test_defeat_attribution: OK');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua test_defeat_attribution.lua`
Expected: FAIL with `attempt to call a nil value (field 'clear_engagements')`

- [ ] **Step 3: Add the engaged-mob set and the death message table**

In `lib/packet_handler.lua`, replace the `MESSAGE_IDS` table at lines 10-17 with:

```lua
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
```

Then delete `get_player_id` at lines 86-93 in the original file (it becomes unused once the death branch is rewritten):

```lua
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
```

Add the engagement API immediately above `function packet_handler.handle_incoming_packet(e)`:

```lua
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
```

- [ ] **Step 4: Rewrite the death branch**

In `lib/packet_handler.lua`, replace the whole of `handle_action_message` (original lines 162-210) with:

```lua
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
```

`handle_action_message` calls `packet_handler.clear_engagement`, which does not exist yet. Add it next to the other engagement functions:

```lua
-- Forget one mob's engagement
-- Args:
--   server_id (number) - Mob's server ID
function packet_handler.clear_engagement(server_id)
    engaged[server_id] = nil;
end
```

`handle_action_message` is defined above the `packet_handler.*` engagement functions in the file, but that is fine: it only reads them at call time, and `packet_handler` is already an upvalue declared at line 6.

- [ ] **Step 5: Run test to verify it passes**

Run: `lua test_defeat_attribution.lua`
Expected: `test_defeat_attribution: OK`

- [ ] **Step 6: Commit**

```bash
git add lib/packet_handler.lua test_defeat_attribution.lua
git commit -m "fix: credit deaths announced without an actor id

Self-destruct and damage-over-time kills arrive as action message 20
(and additional effects as 605), neither of which names an actor the
client can match against the party, so the defeat was dropped and
message 558's progress number had no enemy name to attach to.

Recognize all six death messages and accept one when either the actor
is ours or the dying mob is on a list of mobs the party acted on.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Populate engagements from Action packets

**Files:**
- Modify: `lib/packet_handler.lua` (add `party_actor_ids`, `parse_action`, `record_engagements`; extend `packet_handler.handle_incoming_packet`)
- Test: `test_defeat_attribution.lua`

**Interfaces:**
- Consumes from Task 1: `packet_handler.record_engagement(server_id, now)`, `packet_handler.is_engaged(server_id, now)`, `packet_handler.clear_engagements()`.
- Produces: `packet_handler.handle_incoming_packet(e)` now also handles `e.id == 0x28` (reads `e.data_raw` and `e.size`) and `e.id == 0x0A` / `e.id == 0x0B`. No new public functions.

- [ ] **Step 1: Write the failing test**

Append to `test_defeat_attribution.lua`, immediately above the final `print('test_defeat_attribution: OK');` line:

```lua
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua test_defeat_attribution.lua`
Expected: FAIL with `own action engages target: expected true, got false`

- [ ] **Step 3: Add the party actor set and the Action packet decode**

In `lib/packet_handler.lua`, add these three functions immediately above `-- Handle incoming packet` / `function packet_handler.handle_incoming_packet(e)`:

```lua
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
```

- [ ] **Step 4: Route the new packet IDs**

In `lib/packet_handler.lua`, replace `packet_handler.handle_incoming_packet` (original lines 218-226) with:

```lua
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua test_defeat_attribution.lua`
Expected: `test_defeat_attribution: OK`

- [ ] **Step 6: Commit**

```bash
git add lib/packet_handler.lua test_defeat_attribution.lua
git commit -m "feat: track mobs the party has acted on

Decode Action packets (0x28) and record every mob targeted by a party
member or their pet, keyed by server id with a 15-minute TTL and cleared
on zone change. This is the list an actor-less death message is checked
against before its kill is credited.

Packets from other players bail after reading the 32-bit actor id.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Add `/at debug`, bump version, update README

**Files:**
- Modify: `AMANTracker.lua:12` (version), `AMANTracker.lua:78-88` (debug flag), `AMANTracker.lua:355-395` (packet handler callbacks), `AMANTracker.lua:448-460` (help text), `AMANTracker.lua:476` (command dispatch)
- Modify: `README.md`

**Interfaces:**
- Consumes from Task 1: the `on_debug(fmt, ...)` callback slot in `packet_handler.init`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the debug flag**

In `AMANTracker.lua`, immediately after the `training_data` table (which ends with `};` following the `last_packet_progress` field around line 88), add:

```lua
-- Prints every death message the packet handler sees, with the actor and target
-- IDs and whether the kill was credited. Off by default, toggled by /at debug.
-- The only way to confirm on a live server which message ID a Self-Destruct or a
-- damage-over-time death actually arrives as.
local debug_enabled = false;
```

- [ ] **Step 2: Wire the callback**

In `AMANTracker.lua`, inside the `packet_handler.init({ ... })` call, add this entry after the `on_regime_reset` entry and before the closing `});`:

```lua
    on_debug = function(fmt, ...)
        if debug_enabled then
            printf(fmt, ...);
        end
    end,
```

- [ ] **Step 3: Add the command**

In `AMANTracker.lua`, add a help line after `printf('  /at clear       - Clear current training data');`:

```lua
        printf('  /at debug       - Toggle death-packet logging');
```

Then add the dispatch branch immediately after the `elseif args[2] == 'clear' then` block (which ends with `printf(MESSAGES.DATA_CLEARED);`):

```lua
    elseif args[2] == 'debug' then
        debug_enabled = not debug_enabled;
        printf('Death packet logging %s', debug_enabled and 'enabled' or 'disabled');
```

- [ ] **Step 4: Bump the version**

In `AMANTracker.lua` line 12, change:

```lua
addon.version   = '2.7';
```

to:

```lua
addon.version   = '2.8';
```

- [ ] **Step 5: Update the README**

In `README.md` line 59, add a `/at debug` entry directly under the existing `/at clear` line:

```markdown
- `/at debug` - Toggle death-packet logging (prints actor, target and credit decision)
```

In `README.md` line 159, drop the `(Current)` marker from the old heading:

```markdown
### Version 2.7
```

Then add this section directly above it, under the `## Changelog` heading on line 158:

```markdown
### Version 2.8 (Current)
- **Fixed: kills that announce no actor were not counted**
- Self-destruct and damage-over-time deaths arrive as action message 20 ("The Bomb falls to the ground."), which names no actor the client can match against the party, so the kill was silently dropped
- Added death messages 20, 113 (spell), 406 (weapon skill) and 605 (additional effect) alongside the existing 6 and 646
- Added an engaged-mob list, built from Action packets (0x28), of every mob a party member or their pet has acted on; an actor-less death is credited only if the dying mob is on it
- Engagements expire after 15 minutes and clear on zone change, since server IDs are reused
- Added `/at debug` to log every death message with its actor, target and credit decision
- Removed the unused `get_player_id` helper
```

- [ ] **Step 6: Verify the addon still parses**

Run: `lua -e "if loadfile('AMANTracker.lua') then print('AMANTracker.lua parses') else error('syntax error') end" && lua -e "if loadfile('lib/packet_handler.lua') then print('packet_handler.lua parses') else error('syntax error') end"`
Expected:
```
AMANTracker.lua parses
packet_handler.lua parses
```

- [ ] **Step 7: Run the test suite one more time**

Run: `lua test_defeat_attribution.lua`
Expected: `test_defeat_attribution: OK`

- [ ] **Step 8: Commit**

```bash
git add AMANTracker.lua README.md
git commit -m "feat: add /at debug and bump to 2.8

/at debug prints every death message with its actor, target and credit
decision -- the only way to confirm on a live server which message id a
Self-Destruct or damage-over-time death actually arrives as.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## In-Game Verification

The unit tests cover the decision logic against stubbed memory, but nothing here proves the real packets carry the fields this assumes. Verify on CatsEyeXI:

1. `/addon reload AMANTracker`, then `/at debug`.
2. Start a regime whose target list includes Bombs (or any family with a self-destruct), and one with a second enemy type so attribution is actually being tested.
3. Pull a Bomb, let it Self-Destruct. Expect a line like `death msg=20 actor=... target=... credited=true`, followed by the tracker count advancing.
4. Apply a DoT (Poison, Dia, Burn) and walk away until it ticks the mob down. Expect the same, with the tracker crediting the correct enemy row.
5. Stand near another party's fight and let them kill a tracked mob type. Expect `credited=false` and no count change.

If step 3 logs a message ID not in `DEATH_MESSAGE_IDS`, add it to that table — the table is the whole fix for a new case.

## What This Deliberately Does Not Do

- **No HP%-based arming.** The proposal was to watch tracked mobs for HP reaching 0 and arm them for counting. The death message already *is* that signal, arriving as its own packet, so polling HP would add a second detector for an event the client is told about directly.
- **No independent kill counter.** Message 558 carries the server's own absolute progress (`enemy.killed = current`). Incrementing a local counter alongside it would double-count. Everything above exists only to resolve the dead mob's *name* so 558 knows which row to write.
- **No SpawnFlags mob filter on engagement.** Marked with a `ponytail:` comment in `record_engagements`.

Task 1 alone fixes the reported bug for any regime with a single enemy type, and for multi-type regimes in every case except a stranger killing a second tracked type inside the few frames between our death message and our 558. Task 2 is what closes that window.
