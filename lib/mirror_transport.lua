--[[
AMANTracker - Mirror Transport Module

Cross-instance broadcast channel for the FoV/GoV mirror.

Windower hands NpcInteract an inter-client IPC bus for free
(windower.send_ipc_message / the 'ipc message' event). Ashita v4 has no
equivalent: each game instance loads its own Lua state with no channel between
them, and nothing in the v4 API brokers messages between clients. The options
were a named pipe or socket through LuaJIT's ffi, a companion out-of-process
broadcaster, or a shared file under Ashita's own config tree. This module is the
shared file, because it is the only one of the three that needs no code outside
the addon, no elevated permissions, and no second process to babysit -- and
because every box that could possibly be mirrored is by definition already
running on a machine that can see that directory.

The cost is that mirroring only spans clients that share a filesystem path. Boxes
on separate machines (or in separate containers with private config trees) do not
see each other's broadcasts. See the README.

Wire format, one record per file, rewritten in full on every broadcast:

    AMANTRACKER-MIRROR-1|<payload>\n
    #END\n

The trailing sentinel is what makes the single-writer/many-reader race safe. A
reader that catches the file mid-rewrite sees a truncated record with no #END and
simply ignores it, then picks the record up on its next poll a few milliseconds
later. That is cheaper and more portable than trying to get an atomic rename past
Windows' refusal to clobber an existing destination.
]]

local transport = {};

-- Bumped if the payload grammar ever changes shape. A reader that sees a
-- protocol line it does not recognise ignores the record outright rather than
-- half-parsing a future format.
local PROTOCOL = 'AMANTRACKER-MIRROR-1';
local TERMINATOR = '#END';

local channel_path = nil;

-- The last payload this client pulled off the channel. Every record carries a
-- sequence number and a timestamp, so consecutive broadcasts never produce
-- identical payloads; comparing the whole string is therefore enough to
-- de-duplicate the polls between one broadcast and the next.
local last_seen = nil;

-- Reason the most recent publish failed, for /at mirror status. Read failures
-- are not recorded: a follower polls several times a second and the file simply
-- not existing yet is the normal state, not an error worth reporting.
local last_error = nil;

-- Resolve the directory Ashita keeps this addon's config in.
--
-- The settings library already writes to config/addons/AMANTracker/<character>/,
-- so the parent exists as soon as any character has saved settings once -- and
-- enabling the mirror saves settings, which is the only way to reach a publish.
-- The channel file sits one level above the per-character folders because it is
-- deliberately shared by every character on the box.
local function default_path()
    local install = '';
    pcall(function()
        install = AshitaCore:GetInstallPath() or '';
    end);

    -- GetInstallPath is not documented to include a trailing separator.
    if install ~= '' and not install:match('[\\/]$') then
        install = install .. '\\';
    end

    return install .. 'config\\addons\\AMANTracker\\mirror_channel.txt';
end

-- Best-effort directory creation. Ashita v4 has moved this helper around between
-- builds, so both spellings are tried and neither failing is fatal: the publish
-- below reports the real problem if the directory genuinely is not there.
local function ensure_directory(path)
    local dir = path:match('^(.*)[\\/][^\\/]*$');
    if not dir then
        return;
    end

    pcall(function() ashita.fs.create_directory(dir); end);
    pcall(function() ashita.fs.create_dir(dir); end);
end

-- Point the channel at a file.
-- Args:
--   path (string) - Optional override; defaults to Ashita's config tree.
function transport.init(path)
    channel_path = path or default_path();
end

-- Returns:
--   string - The channel file's full path, for display in /at mirror status
function transport.path()
    return channel_path or default_path();
end

-- Returns:
--   string - Reason the last publish failed, or nil if it succeeded
function transport.last_error()
    return last_error;
end

-- Read the current record off the channel without any freshness checks.
-- Returns:
--   string - Payload, or nil when the file is missing, truncated or foreign
local function read_record()
    local path = transport.path();
    local handle = io.open(path, 'rb');
    if not handle then
        return nil;
    end

    local body = handle:read('*a');
    handle:close();
    if not body then
        return nil;
    end

    -- Plain string comparisons throughout rather than patterns: PROTOCOL
    -- contains a hyphen, which is the lazy-repeat quantifier in a Lua pattern
    -- and silently stops the record ever matching.
    local trimmed = (body:gsub('%s+$', ''));

    -- No sentinel means we caught a rewrite in progress. Drop it; the next poll
    -- picks up the finished record.
    if trimmed:sub(-#TERMINATOR) ~= TERMINATOR then
        return nil;
    end

    local line_end = trimmed:find('\n', 1, true);
    local line = line_end and trimmed:sub(1, line_end - 1) or trimmed;
    line = (line:gsub('\r$', ''));

    local prefix = PROTOCOL .. '|';
    if line:sub(1, #prefix) ~= prefix then
        return nil;
    end

    return line:sub(#prefix + 1);
end

-- Treat whatever is currently on the channel as already handled.
--
-- Called when a client starts mirroring, so that enabling the feature never
-- replays a page somebody selected minutes ago. Records also carry a timestamp
-- that the mirror checks, but this closes the window without relying on clocks
-- being in step between instances.
function transport.prime()
    last_seen = read_record();
end

-- Write a record, replacing whatever was there.
-- Args:
--   payload (string) - The record body, without protocol line or sentinel
-- Returns:
--   boolean - True on success; false with transport.last_error() set otherwise
function transport.publish(payload)
    local path = transport.path();
    ensure_directory(path);

    local handle, err = io.open(path, 'wb');
    if not handle then
        last_error = err or ('could not open ' .. path);
        return false;
    end

    local ok = handle:write(PROTOCOL .. '|' .. payload .. '\n' .. TERMINATOR .. '\n');
    handle:close();

    if not ok then
        last_error = 'write failed: ' .. path;
        return false;
    end

    -- A publisher never replays its own broadcast.
    last_seen = payload;
    last_error = nil;
    return true;
end

-- Poll for a record this client has not handled yet.
-- Returns:
--   string - A new payload, or nil when nothing has changed
function transport.poll()
    local payload = read_record();
    if payload == nil or payload == last_seen then
        return nil;
    end

    last_seen = payload;
    return payload;
end

return transport;
