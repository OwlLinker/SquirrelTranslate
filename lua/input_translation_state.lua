local M = {}

local STATE_FILE = (os.getenv("HOME") or "") .. "/Library/Rime/input_translation.enabled"
local PHONETIC_STATE_FILE = (os.getenv("HOME") or "") .. "/Library/Rime/input_translation.phonetic.enabled"
local COMPOSITION_STATE_FILE = (os.getenv("HOME") or "") ..
    "/Library/Rime/input_translation.composition.state"
local composition_visible
local enabled_state
local phonetic_enabled_state

local function write_atomically(path, content)
    local temp_path = path .. ".tmp"
    local file = io.open(temp_path, "w")
    if not file then return false end
    file:write(content)
    file:close()
    local ok = os.rename(temp_path, path)
    if not ok then os.remove(temp_path) end
    return ok
end

function M.set_composition_visible(visible)
    visible = not not visible
    local expected = visible and "1" or "0"
    -- The native input-method lifecycle hook may clear this file while this
    -- Lua module remains cached. Reconcile the shared state before trusting
    -- the in-memory value, so focus loss cannot leave Esc blocked as stale.
    local file = io.open(COMPOSITION_STATE_FILE, "r")
    local stored = file and file:read("*l") or nil
    if file then file:close() end
    if stored == expected then
        composition_visible = visible
        return visible
    end
    if write_atomically(COMPOSITION_STATE_FILE, expected .. "\n") then
        composition_visible = visible
    end
    return visible
end

function M.is_enabled()
    if enabled_state ~= nil then return enabled_state end
    local file = io.open(STATE_FILE, "r")
    if not file then
        enabled_state = false
        return enabled_state
    end
    local enabled = file:read("*l") == "1"
    file:close()
    enabled_state = enabled
    return enabled_state
end

function M.set_enabled(enabled)
    local file = io.open(STATE_FILE, "w")
    if not file then return false end
    file:write(enabled and "1\n" or "0\n")
    file:close()
    enabled_state = enabled
    return enabled
end

function M.toggle()
    return M.set_enabled(not M.is_enabled())
end

function M.is_phonetic_enabled()
    if phonetic_enabled_state ~= nil then return phonetic_enabled_state end
    local file = io.open(PHONETIC_STATE_FILE, "r")
    if not file then
        phonetic_enabled_state = true
        return phonetic_enabled_state
    end
    local enabled = file:read("*l") ~= "0"
    file:close()
    phonetic_enabled_state = enabled
    return phonetic_enabled_state
end

function M.set_phonetic_enabled(enabled)
    local file = io.open(PHONETIC_STATE_FILE, "w")
    if not file then return false end
    file:write(enabled and "1\n" or "0\n")
    file:close()
    phonetic_enabled_state = enabled
    return enabled
end

function M.toggle_phonetic()
    return M.set_phonetic_enabled(not M.is_phonetic_enabled())
end

return M
