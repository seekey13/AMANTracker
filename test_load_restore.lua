--[[
Standalone check for the boot-vs-login settings race.

Ashita resolves settings paths from the logged-in character, so an addon loaded
while the game is still booting gets the 'defaults' profile. The character's real
settings only arrive later, via the settings library's change event. This replays
that sequence against stubbed Ashita APIs and asserts the UI follows.

Run: lua test_load_restore.lua
]]

-- ponytail: hand-rolled stubs, no framework. Enough to load the addon file.
local ui = { mode = nil, open_calls = 0, close_calls = 0, visible = false };
local settings_cb = nil;
local defaults_profile, character_profile;

local function copy(t)
    local r = {};
    for k, v in pairs(t) do r[k] = (type(v) == 'table') and copy(v) or v; end
    return r;
end

_G.addon = {};
_G.T = function (t) return t or {}; end
_G.GetPlayerEntity = function () return nil; end

_G.ashita = { events = { register = function () end, unregister = function () end } };

package.preload['common'] = function () return true; end
package.preload['chat'] = function ()
    local id = function (s) return tostring(s); end
    return { header = id, message = id, warning = id, error = id };
end
package.preload['settings'] = function ()
    return {
        load = function () return copy(defaults_profile); end,
        save = function () return true; end,
        register = function (_, _, cb) settings_cb = cb; end,
    };
end
package.preload['lib.parser'] = function () return {}; end
package.preload['lib.family'] = function () return {}; end
package.preload['lib.packet_handler'] = function () return { init = function () end }; end
package.preload['lib.tracker_ui'] = function ()
    return {
        init = function (_, mode) ui.mode = mode; end,
        set_ui_mode = function (mode) ui.mode = mode; end,
        open = function () ui.open_calls = ui.open_calls + 1; ui.visible = true; end,
        close = function () ui.close_calls = ui.close_calls + 1; ui.visible = false; end,
        toggle = function () ui.visible = not ui.visible; end,
        is_visible = function () return ui.visible; end,
        render = function () end,
        cleanup = function () end,
    };
end

-- Boot: not logged in, so the addon only sees the 'defaults' profile.
defaults_profile = { is_active = false, enemies = {}, ui_mode = 'gdifonts' };
character_profile = {
    is_active = true,
    enemies = { { name = 'Bees', total = 3, killed = 1, match_type = 'exact' } },
    target_level_range = '10-15',
    training_area_zone = 'Valkurm Dunes',
    ui_mode = 'imgui',
};

dofile('AMANTracker.lua');

assert(not ui.visible, 'UI must stay hidden at boot: no active regime in defaults profile');
assert(settings_cb ~= nil, 'addon must register a settings change callback');

-- Login: the settings library swaps in the character profile and raises the event.
settings_cb(character_profile);

assert(ui.visible, 'UI must auto-open on login when the character has an active regime');
assert(ui.open_calls == 1, 'expected exactly one open() on login, got ' .. ui.open_calls);
assert(ui.mode == 'imgui', "expected saved ui_mode 'imgui' to be applied, got " .. tostring(ui.mode));

-- Logout: back to the defaults profile, UI must not keep showing stale data.
settings_cb(copy(defaults_profile));
assert(not ui.visible, 'UI must close on logout');

print('ok');
