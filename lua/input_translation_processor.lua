local state = require("input_translation_state")

local HOME = os.getenv("HOME") or ""
local RUNTIME_DIR = HOME .. "/Library/Rime"
local CACHE_FILE = RUNTIME_DIR .. "/input_translation.cache.tsv"
local SPEECH_REQUEST_FILE = RUNTIME_DIR .. "/input_translation.speech.requests.tsv"

local function is_english(text)
    return text and text:match("^[A-Za-z][A-Za-z0-9%s%-%'%.]*$") ~= nil
end

local function translation_target(text, configured_target)
    if is_english(text) then return "zh-CN" end
    return configured_target
end

local function load_translation(text, target)
    local file = io.open(CACHE_FILE, "r")
    if not file then return nil end
    for line in file:lines() do
        local cached_target, word, translation = line:match("^(.-)\t(.-)\t(.-)\t.*$")
        if not cached_target then
            cached_target, word, translation = line:match("^(.-)\t(.-)\t(.*)$")
        end
        if cached_target == target and word == text and translation and translation ~= "" then
            file:close()
            return translation
        end
    end
    file:close()
    return nil
end

local function request_speech(text)
    local file = io.open(SPEECH_REQUEST_FILE, "a")
    if not file then return false end
    file:write((text:gsub("[\r\n\t]", " ")), "\n")
    file:close()
    return true
end

local function is_raw_commit_key(repr, configured_key)
    return repr == configured_key or
        (configured_key == "Shift_L" and repr == "Shift+Shift_L")
end

local function is_escape_key(key)
    local repr = key:repr()
    return repr == "Escape" or repr == "Esc"
end

local function processor(key, env)
    local toggle_key = "Control+t"
    local speak_key = "Control+p"
    local commit_translation_key = "Control+y"
    local phonetic_toggle_key = "Control+Shift+p"
    local raw_commit_key = "Shift_L"
    local target_language = "en"
    local config = env.engine.schema.config
    if config then
        toggle_key = config:get_string("translation/toggle_key") or toggle_key
        speak_key = config:get_string("translation/speak_key") or speak_key
        commit_translation_key = config:get_string("translation/commit_translation_key") or commit_translation_key
        phonetic_toggle_key = config:get_string("translation/phonetic_toggle_key") or phonetic_toggle_key
        raw_commit_key = config:get_string("translation/raw_commit_key") or raw_commit_key
        target_language = config:get_string("translation/target_language") or target_language
    end

    local context = env.engine.context
    -- Consume Escape while Rime is composing or showing candidates.  Clearing
    -- here preserves the normal Rime cancel behavior without forwarding Esc
    -- to the foreground application.
    if is_escape_key(key) and
        ((context.input or "") ~= "" or context:has_menu()) then
        if not key:release() then context:clear() end
        return kAccepted
    end

    if not key:release() and is_raw_commit_key(key:repr(), raw_commit_key) then
        local input = context.input or ""
        if input ~= "" then
            env.engine:commit_text(input)
            context:clear()
            return kAccepted
        end
    end

    if key:repr() == toggle_key then
        state.toggle()
        context:refresh_non_confirmed_composition()
        return kAccepted
    end

    if key:repr() == phonetic_toggle_key then
        state.toggle_phonetic()
        context:refresh_non_confirmed_composition()
        return kAccepted
    end

    local context = env.engine.context
    if not context:has_menu() then return kNoop end
    local candidate = context:get_selected_candidate()
    if not candidate or not candidate.text or candidate.text == "" then return kNoop end

    if key:repr() == speak_key then
        local target = translation_target(candidate.text, target_language)
        local translation = load_translation(candidate.text, target)
        if not translation then return kNoop end
        return request_speech(translation) and kAccepted or kNoop
    end

    if key:repr() == commit_translation_key then
        local target = translation_target(candidate.text, target_language)
        local translation = load_translation(candidate.text, target)
        if not translation then return kNoop end
        env.engine:commit_text(translation)
        context:clear()
        return kAccepted
    end

    return kNoop
end

return processor
