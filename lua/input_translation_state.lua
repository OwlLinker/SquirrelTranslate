local M = {}

local STATE_FILE = (os.getenv("HOME") or "") .. "/Library/Rime/input_translation.enabled"
local PHONETIC_STATE_FILE = (os.getenv("HOME") or "") .. "/Library/Rime/input_translation.phonetic.enabled"

function M.is_enabled()
    local file = io.open(STATE_FILE, "r")
    if not file then return false end
    local enabled = file:read("*l") == "1"
    file:close()
    return enabled
end

function M.set_enabled(enabled)
    local file = io.open(STATE_FILE, "w")
    if not file then return false end
    file:write(enabled and "1\n" or "0\n")
    file:close()
    return enabled
end

function M.toggle()
    return M.set_enabled(not M.is_enabled())
end

function M.is_phonetic_enabled()
    local file = io.open(PHONETIC_STATE_FILE, "r")
    if not file then return true end
    local enabled = file:read("*l") ~= "0"
    file:close()
    return enabled
end

function M.set_phonetic_enabled(enabled)
    local file = io.open(PHONETIC_STATE_FILE, "w")
    if not file then return false end
    file:write(enabled and "1\n" or "0\n")
    file:close()
    return enabled
end

function M.toggle_phonetic()
    return M.set_phonetic_enabled(not M.is_phonetic_enabled())
end

return M
