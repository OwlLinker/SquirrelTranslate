-- This is a synthetic Rime session tag, not a bundle that must be installed.
local QUERY_CLIENT_APP = "org.owllinker.SquirrelTranslate.InputBar"
local WAITING_TEXT = "·"

local function translator(input, seg, env)
    if input ~= "u" then return end
    local context = env.engine.context
    if context:get_property("client_app") ~= QUERY_CLIENT_APP or
        context:get_option("ascii_mode") then
        return
    end
    -- Keep Squirrel's native candidate panel alive while waiting for the
    -- first real query letter. The processor replaces this composition when
    -- that letter arrives.
    yield(Candidate("input_translation_waiting", seg.start, seg._end,
                    WAITING_TEXT, ""))
end

return translator
